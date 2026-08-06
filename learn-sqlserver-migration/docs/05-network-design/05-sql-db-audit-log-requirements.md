# Azure SQL Database 監査ログ 要件・設計方針

> **作成日**: 2026-08-06
> **対象**: Azure SQL Database（単一データベース。移行後の運用設計）
> **比較対象**: [04-audit-log-requirements.md](./04-audit-log-requirements.md)（SQL MI 版）

---

## 要件（MI版と同一）

| # | 要件 |
|---|---|
| 1 | 監査ログは SQL クエリで検索・参照できること |
| 2 | 短期間はオンラインで即時参照できること |
| 3 | 超長期保管（コンプライアンス・監査証跡）は低コストで保管できること |
| 4 | ローカルストレージの容量を圧迫しないこと |
| 5 | **Azure Portal にアクセスできない DB 利用ユーザーでも、日常的な監査ログ確認が SQL クライアントのみで完結すること**（今回追加） |

---

## 仕様確認（Azure SQL Database の監査ログ動作）

> **出典**: [監査 - Azure SQL Database](https://learn.microsoft.com/ja-jp/azure/azure-sql/database/auditing-overview?view=azuresql) / [監査ログとレポートを分析する](https://learn.microsoft.com/ja-jp/azure/azure-sql/database/auditing-analyze-audit-logs?view=azuresql) / [sys.fn_get_audit_file](https://learn.microsoft.com/ja-jp/sql/relational-databases/system-functions/sys-fn-get-audit-file-transact-sql)

### MI との決定的な違い：ローカル監査トラックが存在しない

| | SQL MI | SQL Database |
|---|---|---|
| ローカルファイル監査（`CREATE SERVER AUDIT ... TO FILE`） | ✅ サポート | ❌ **非サポート**（ローカルファイルシステムが存在しないため） |
| 送信先 | ローカル / Blob / Log Analytics / Event Hubs（併用可） | **Blob / Log Analytics / Event Hubs のみ**（併用可） |
| ログ形式 | `.sqlaudit`（ローカル）/ `.xel`（Blob） | `.xel`（Blob）|

MI は「ローカル（短期・SQL検索用）＋ Blob（長期証跡）」の2段階構成だったが、SQL Database には**ローカルの選択肢自体がない**。すべての監査ログは最初から外部（Blob / Log Analytics / Event Hubs）に書き出される。

### 重要な訂正：それでも T-SQL によるクエリ検索は可能

「ローカルトラックがない＝SQLクエリで検索できない」わけではない。`sys.fn_get_audit_file` は Azure Blob Storage 上の `.xel` ファイルを **URL 直接指定でクエリできる**。

```sql
SELECT *
FROM sys.fn_get_audit_file(
    'https://<storage account>.blob.core.windows.net/sqldbauditlogs/<ServerName>/<DatabaseName>/',
    DEFAULT,
    DEFAULT
);
```

- パスはワイルドカード非対応だが、**部分プレフィックス一致**で配下のファイルをまとめて取得可能
- `WHERE` / `ORDER BY` / `TOP` など通常の T-SQL 句がそのまま使える
- Azure Portal・Storage Explorer・Storage アカウントキーのいずれも不要（後述）

→ **要件1（SQLクエリで検索）と要件2（即時オンライン参照）は、Blob 経由の単一トラックだけで両方満たせる。** MI のような「ローカル＋Blobの二段構成」は不要。

---

## 設計方針

### 採用構成：Blob Storage 一本化 ＋ T-SQL VIEW でのラップ

```
Azure SQL Database 監査（Azure Portal / ARM で設定・1回のみ）
    └── Azure Blob Storage（sqldbauditlogs コンテナー）
          ├── ライフサイクルポリシーで長期保管・自動削除（要件3）
          └── sys.fn_get_audit_file で T-SQL から直接クエリ（要件1・2）
                └── VIEW でラップして利用者に公開（要件5）
```

MI と異なり、ローカルストレージを一切消費しないため、**要件4（ローカルストレージを圧迫しない）は設計上自動的に満たされる**（SQL Agent ジョブでの手動削除運用が不要）。

### 保持期間（MIと同じ暫定方針）

| 保管先 | 保持期間 | 理由 |
|---|---|---|
| Blob Storage（唯一の保管先） | 7年（要確認） | 短期の即時参照・長期証跡の両方をこの1箇所で兼ねる |

---

## 実装手順

### フェーズ1：初期設定（管理者・Azure Portal / ARM が必要・1回のみ）

DB 利用ユーザーの日常的な確認作業とは別に、**最初の設定だけ**は管理者による Azure 側の作業が必要。

1. Azure Portal → SQL Database（または論理サーバー）→「監査」→ **ON**
2. 送信先「ストレージ」を選択し、対象の Storage アカウントを指定
3. 保持期間を設定（0 = 無期限。ライフサイクルポリシー側で削除する場合は 0 のままでよい）
4. 保存

```json
// ARM / REST での構成例（storageAccountAccessKey は指定しない = マネージドID使用）
PUT https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/servers/<server>/auditingSettings/default?api-version=2017-03-01-preview
{
  "properties": {
    "state": "Enabled",
    "storageEndpoint": "https://<storage account>.blob.core.windows.net"
  }
}
```

> Storage アカウントを VNet・ファイアウォールの背後（パブリックアクセス無効）に置く場合は、
> Storage アカウント側で **「信頼された Microsoft サービスにこのストレージ アカウントへのアクセスを許可する」** を有効化し、
> 論理サーバーのシステム割り当てマネージド ID に **Storage Blob Data Contributor** ロールを付与する。
> SQL Database 側に NSG や送信許可ルールを設定する必要は **ない**（詳細は本ディレクトリの通信経路整理を参照）。

### フェーズ2：利用者向け VIEW の作成（管理者・T-SQLのみ・1回のみ）

対象データベースに接続して実行。

```sql
CREATE VIEW dbo.vw_AuditLog AS
SELECT *
FROM sys.fn_get_audit_file(
    'https://<storage account>.blob.core.windows.net/sqldbauditlogs/<ServerName>/<DatabaseName>/',
    DEFAULT,
    DEFAULT
);
```

### フェーズ3：利用者への権限付与（管理者・T-SQLのみ）

```sql
-- ログ確認だけを許可するロールを作成し、対象ユーザーをメンバーに追加
CREATE ROLE AuditLogReader;
GRANT SELECT ON dbo.vw_AuditLog TO AuditLogReader;
ALTER ROLE AuditLogReader ADD MEMBER [対象ユーザー];

-- sys.fn_get_audit_file の実行自体には CONTROL DATABASE 権限が必要
-- （最小権限の観点で許容できるか要検証。VIEW DATABASE SECURITY AUDIT で足りるかは別途確認）
GRANT CONTROL ON DATABASE::[対象DB名] TO [対象ユーザー];
```

> ⚠️ **権限要件に未確定点あり**：公式リファレンス（`sys.fn_get_audit_file`）は `CONTROL DATABASE` を要求すると明記している一方、監査の概要ページでは 2025年7月の再設計以降「ログ表示には `VIEW DATABASE SECURITY AUDIT` 権限」という記載もある。`CONTROL DATABASE` は db_owner に近い強い権限のため、閲覧専用ユーザーへの付与としては過剰な可能性がある。実際にどちらの権限で `sys.fn_get_audit_file` 経由の閲覧が成立するか、本番適用前に検証すること。

### フェーズ4：利用者の日常的な確認（DB利用者・Azure Portal 不要）

```sql
-- 直近7日分を確認
SELECT * FROM dbo.vw_AuditLog
WHERE event_time >= DATEADD(day, -7, GETUTCDATE())
ORDER BY event_time DESC;

-- 特定ユーザーの操作を確認
SELECT * FROM dbo.vw_AuditLog
WHERE server_principal_name = 'xxx'
ORDER BY event_time DESC;
```

SSMS・Azure Data Studio・`sqlcmd` など、通常の SQL クライアントで DB に接続できれば完結する。Azure Portal・Storage Explorer・Storage アカウントキーのいずれも不要。

---

## （参考）GUIで確認したい場合

Portal を使わない代替手段として、SSMS の「ファイル」→「開く」→「**監査ファイルのマージ**」（SSMS 17以降）でも Azure Storage から直接インポートできる。ただしこちらは **Storage アカウントキー**の入力が必要になるため、キー管理の手間を考えると T-SQL（VIEW経由）の方が運用上シンプル。

---

## 通信経路への影響（MIとの決定的な違い）

| 通信 | SQL MI で必要だったか | SQL Database で必要か |
|---|:---:|:---:|
| DB/MI → Blob Storage（TCP 443、顧客NSGでの許可） | ✅ 必須（MIはVNet内配置のため） | ❌ **不要**（SQL DatabaseはVNet外のマネージドテナントで動作し、顧客管理のNSGを経由しない） |
| Blob Storage 側の「信頼されたMicrosoftサービス」例外設定 | 該当構成なし（NSGで直接許可） | ✅ **これが唯一の設定ポイント**（Storage側のファイアウォール設定＋サーバーのマネージドID） |

> SQL Database は既定でパブリックエンドポイント（`<server>.database.windows.net`）としてMicrosoft管理のテナント内で動作し、顧客のVNetにデプロイされない。そのため、バックアップ・診断ログ送信・監査ログ送信などSQL Database自身が行う送信処理は、すべてMicrosoftのプラットフォーム内部で完結し、顧客側でNSG/ファイアウォールのアウトバウンド許可を設定する必要がない。
>
> 唯一の例外は、監査ログの送信先（Storage / Log Analytics）自体を閉域化した場合。この場合も「SQL Database側で送信を許可する」のではなく、「**送信先リソース側**で信頼されたサービスとして受け入れる」という逆向きの構成になる。
>
> 詳細: [03-communication-paths.md](./03-communication-paths.md)（MI向け）と本ドキュメントを対比のこと。

---

## 未決事項

- [ ] `sys.fn_get_audit_file` 実行に必要な権限が `CONTROL DATABASE` か `VIEW DATABASE SECURITY AUDIT` か、実機検証で確定する
- [ ] Blob 保持期間の確定（コンプライアンス要件確認、MI版と同じ7年で揃えるか）
- [ ] 監査対象イベントの定義（ログイン失敗 / DDL / DML 等、MI版と揃えるか個別に検討するか）
- [ ] Storage アカウントを閉域化する場合の「信頼されたMicrosoftサービス」例外設定の実機確認

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| 監査の概要（SQL Database） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/auditing-overview?view=azuresql |
| 監査ログとレポートを分析する | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/auditing-analyze-audit-logs?view=azuresql |
| VNet・FW背後のストレージへの監査書き込み | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/audit-write-storage-account-behind-vnet-firewall?view=azuresql |
| sys.fn_get_audit_file（T-SQLリファレンス） | https://learn.microsoft.com/ja-jp/sql/relational-databases/system-functions/sys-fn-get-audit-file-transact-sql |
| ネットワークアクセス制御（SQL Database） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/network-access-controls-overview?view=azuresql |
| Blob Storage ライフサイクル管理 | https://learn.microsoft.com/ja-jp/azure/storage/blobs/lifecycle-management-overview |
| （比較対象）SQL MI 監査ログ要件 | [04-audit-log-requirements.md](./04-audit-log-requirements.md) |
