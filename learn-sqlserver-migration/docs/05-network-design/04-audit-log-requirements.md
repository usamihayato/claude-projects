# SQL MI 監査ログ 要件・設計方針

> **作成日**: 2026-07-08  
> **対象**: Azure SQL Managed Instance（移行後の運用設計）

---

## 要件

| # | 要件 |
|---|---|
| 1 | 監査ログは SQL クエリで検索・参照できること |
| 2 | 短期間はオンラインで即時参照できること |
| 3 | 超長期保管（コンプライアンス・監査証跡）は低コストで保管できること |
| 4 | ローカルストレージの容量を圧迫しないこと |

---

## 仕様確認（SQL MI の監査ログ動作）

> **出典**: [SQL Server Audit - Azure SQL MI](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/auditing?view=azuresql) / [監査の構成 - Azure SQL MI](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/auditing-configure?view=azuresql)

### 送信先の2系統

| 設定方法 | 送信先 | ファイル形式 | SQL クエリ | 用途 |
|---|---|---|---|---|
| **T-SQL（SQL Server Audit）** | ローカル | `.sqlaudit` | ✅ `fn_get_audit_file` | 短期・即時参照 |
| **Azure Portal（Azure 監査）** | Blob / Log Analytics / Event Hubs | `.xel`（Blob）| ❌（KQL のみ） | 長期保管・外部連携 |

> 両系統は独立しており、**同時に有効化できる**。  
> Blob に転送してもローカルへの書き込みは止まらない（個別に設定が必要）。

### ローカルストレージの特性

- SQL MI に割り当てたストレージ容量を消費する
- 標準の自動削除機能はなく、**SQL Agent ジョブでの手動削除実装が必要**
- PaaS だが監査ログのストレージ管理は顧客責任

---

## 設計方針

### 採用構成：ローカル（短期）＋ Blob（長期）の2段階

```
SQL Server Audit（T-SQL）
    └── ローカル .sqlaudit
        ├── fn_get_audit_file で SQL 検索可能
        └── SQL Agent ジョブで X 日以降のファイルを自動削除

Azure 監査（Azure Portal）
    └── Azure Blob Storage
        ├── ライフサイクルポリシーで長期保管・自動削除
        └── コンプライアンス証跡として保管
```

### 保持期間（暫定）

| 保管先 | 保持期間 | 理由 |
|---|---|---|
| ローカル（SQL 検索用） | 90日（要確認） | 運用上の調査・問い合わせ対応に十分な期間 |
| Blob Storage（長期証跡） | 7年（要確認） | コンプライアンス要件に合わせて調整 |

---

## 実装方針

### 1. T-SQL で SQL Server Audit を設定（ローカル書き込み）

```sql
-- サーバー監査の作成（ローカルファイル出力）
CREATE SERVER AUDIT [LocalAudit]
TO FILE (
    FILEPATH = 'D:\SQLAudit\',
    MAXSIZE = 100 MB,
    MAX_ROLLOVER_FILES = 50,
    RESERVE_DISK_SPACE = OFF
)
WITH (
    QUEUE_DELAY = 1000,
    ON_FAILURE = CONTINUE
);

ALTER SERVER AUDIT [LocalAudit] WITH (STATE = ON);
```

### 2. SQL Agent ジョブで古いファイルを自動削除

```sql
-- X 日以上経過した .sqlaudit ファイルを削除するジョブを作成
-- xp_cmdshell または PowerShell ジョブステップで実装
EXEC xp_cmdshell 'forfiles /p "D:\SQLAudit" /s /m *.sqlaudit /d -90 /c "cmd /c del @path"';
```

> `xp_cmdshell` の使用可否は SQL MI の設定による。代替として PowerShell ジョブステップも可。

### 3. Azure Portal で Blob への長期保管を設定

```
Azure Portal
    → SQL Managed Instance
    → 監査
    → ストレージアカウントを選択
    → 保持期間を設定（0 = 無制限）
```

### 4. Blob Storage のライフサイクルポリシーで自動削除

```json
{
  "rules": [
    {
      "name": "audit-log-retention",
      "type": "Lifecycle",
      "definition": {
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["sqlaudit/"] },
        "actions": {
          "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 2555 } }
        }
      }
    }
  ]
}
```

> 2555 日 ≒ 7年

---

## 通信経路への影響

| 通信 | 必要 | 備考 |
|---|---|---|
| SQL MI → Blob Storage（TCP 443） | ✅ | Azure 監査の Blob 転送に必要 |
| SQL MI → Event Hubs（TCP 443） | ❌ | SIEM 連携が不要なため対象外 |
| SQL MI → Log Analytics（TCP 443） | ❌（当面） | 要件が出た場合に追加検討 |

---

## 未決事項

- [ ] ローカル保持期間の確定（90日は暫定）
- [ ] Blob 長期保管の保持期間の確定（コンプライアンス要件確認）
- [ ] `xp_cmdshell` の使用可否確認（代替手段の検討）
- [ ] 監査対象イベントの定義（ログイン失敗 / DDL / DML 等）

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL Server Audit（SQL MI） | https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/auditing?view=azuresql |
| 監査の構成（SQL MI） | https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/auditing-configure?view=azuresql |
| VNet・FW 背後のストレージへの監査書き込み | https://learn.microsoft.com/en-us/azure/azure-sql/database/audit-write-storage-account-behind-vnet-firewall?view=azuresql |
| 監査ログの分析 | https://learn.microsoft.com/en-us/azure/azure-sql/database/auditing-analyze-audit-logs?view=azuresql |
| 診断ログのストリーミングエクスポート | https://learn.microsoft.com/en-us/azure/azure-sql/database/metrics-diagnostic-telemetry-logging-streaming-export-configure?view=azuresql |
| Blob Storage ライフサイクル管理 | https://learn.microsoft.com/ja-jp/azure/storage/blobs/lifecycle-management-overview |
| fn_get_audit_file | https://learn.microsoft.com/ja-jp/sql/relational-databases/system-functions/sys-fn-get-audit-file-transact-sql |
