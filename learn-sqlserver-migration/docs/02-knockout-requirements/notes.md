# 02. ノックアウト要件の整理と解消策

> **作成日**: 2026-04-15  
> **対象移行先**: Azure SQL Managed Instance（主）/ Azure SQL Database（副）

---

## ノックアウト要件とは

移行プロジェクトを**中断・延期・別方式に変更させる可能性のある技術的・業務的制約**のこと。
事前に特定し「潰し（解消策の確立）」を行うことで、移行プロジェクトのリスクを低減する。

```
ノックアウト要件の潰しプロセス

1. 洗い出し  → 現行システムの機能・依存関係を棚卸し
2. 判定      → 移行先でサポートされるか？ 代替手段があるか？
3. 解消策    → 代替アーキテクチャ・設定変更・回避策を検討
4. 受け入れ  → 解消できない場合は移行先を変更（SQL MI → SQL on VM など）
```

---

## 1. 機能互換性に関するノックアウト要件

### 1-1. xp_cmdshell / OS コマンド実行

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI では `xp_cmdshell` は**サポート外**（無効） |
| **影響** | SQL Agent ジョブや SP 内で OS コマンドを呼び出している場合は移行不可 |
| **解消策** | Azure Functions / Logic Apps / ADF パイプラインに処理を移管する |
| **確認方法** | `SELECT * FROM sys.configurations WHERE name = 'xp_cmdshell'` で有効化有無を確認 |

---

### 1-2. Linked Server（異種 DBMS 接続）

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI は SQL Server 間の Linked Server はサポート。Oracle / DB2 などへの OLEDB 接続は**非サポート** |
| **影響** | 異種 DBMS へのフェデレーテッドクエリを実行している場合は移行不可 |
| **解消策① ETL 分離** | Azure Data Factory / SSIS on Azure IR でデータ連携を代替 |
| **解消策② PolyBase** | 外部データソースへのクエリ（一部対応） |
| **確認方法** | `SELECT * FROM sys.servers WHERE is_linked = 1` でリンクサーバー一覧を取得 |

---

### 1-3. CLR Integration（.NET アセンブリ）

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI は CLR をサポートするが、**UNSAFE / EXTERNAL_ACCESS アセンブリは制限あり** |
| **影響** | ファイル I/O・ネットワーク通信など外部リソースにアクセスする CLR は動作しない可能性 |
| **解消策** | SAFE アセンブリのみに絞る。外部リソースアクセスは Azure Functions に移管 |
| **確認方法** | `SELECT * FROM sys.assemblies WHERE permission_set_desc <> 'SAFE_ACCESS'` |

---

### 1-4. SQL Server レプリケーション

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI はトランザクションレプリケーションの**パブリッシャ・ディストリビュータ**をサポート。マージレプリケーションはサポート外 |
| **影響** | マージレプリケーションを使用している場合は設計変更が必要 |
| **解消策** | トランザクションレプリケーションへ移行 or Azure SQL Data Sync の活用 |
| **確認方法** | SSMS のレプリケーションフォルダ / `sys.publications` で確認 |

---

### 1-5. MSDTC（分散トランザクション）

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI は MSDTC をサポートするが**プレビュー段階**（GA 後も構成が必要） |
| **影響** | 複数 DB をまたぐ分散トランザクションが業務に組み込まれている場合は要検証 |
| **解消策** | Saga パターン等のアプリ側分散トランザクション管理に設計変更 |
| **確認方法** | アプリコードで `TransactionScope` / `BEGIN DISTRIBUTED TRANSACTION` を検索 |

---

### 1-6. Service Broker（外部アクティベーション）

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI 内の Service Broker はサポート。ただし**外部アクティベーション**（SQL MI 外のサービス呼び出し）は非サポート |
| **影響** | Service Broker で外部プロセスを起動しているパターンは移行不可 |
| **解消策** | Azure Service Bus / Azure Storage Queue + Azure Functions による非同期メッセージング基盤に置き換え |

---

### 1-7. Database Mail

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI はDatabase Mail をサポートするが、SMTP 設定が必要 |
| **解消策** | Azure Communication Services（メール送信）+ SQL Agent ジョブのアラート設定で代替可能 |

---

## 2. パフォーマンス・サイズに関するノックアウト要件

### 2-1. データベースサイズ上限

| サービス | 上限 |
|---------|------|
| SQL Database（General Purpose） | 4 TB |
| SQL Database（Hyperscale） | 100 TB |
| SQL Managed Instance（GP） | **16 TB** |
| SQL Managed Instance（BC） | **4 TB** |
| SQL Server on VM | ディスク容量の範囲内（実質無制限） |

> **確認方法**: `SELECT name, size * 8 / 1024 AS size_MB FROM sys.database_files`

---

### 2-2. IOPS / スループット要件

| 項目 | SQL MI (General Purpose) | SQL MI (Business Critical) |
|------|:------------------------:|:--------------------------:|
| 最大 IOPS | 約 16,000 IOPS | 約 200,000 IOPS |
| 最大スループット | 约 200 MB/s | 约 4 GB/s |
| ストレージ種別 | Premium SSD（リモート） | ローカル SSD |

- ピーク時の I/O を事前に計測し、Business Critical または SQL on VM が必要か判断する
- 計測ツール: **Database Experimentation Assistant（DEA）** / Performance Monitor / Query Store

---

### 2-3. 照合順序（Collation）

| 項目 | 詳細 |
|------|------|
| **リスク** | SQL MI のインスタンス照合順序は作成時に固定（後から変更不可） |
| **影響** | 現行が `Japanese_CI_AS` など日本語照合順序の場合、インスタンス作成時に指定が必要 |
| **解消策** | SQL MI 作成時に照合順序を明示指定する（デフォルト: `SQL_Latin1_General_CP1_CI_AS`） |
| **確認方法** | `SELECT SERVERPROPERTY('Collation')` |

---

## 3. ネットワーク・セキュリティに関するノックアウト要件

### 3-1. VNet 統合要件

| 項目 | 詳細 |
|------|------|
| **要件** | SQL MI は **必ず VNet 内の専用サブネット**に配置される |
| **注意点** | サブネットは SQL MI 専用（他リソースと共存不可）。`/27` 以上のアドレス空間が必要 |
| **オンプレ接続** | ExpressRoute または VPN Gateway 経由でオンプレと接続 |
| **確認方法** | 必要な IP アドレス数 = SQL MI のノード数（最低 32 個推奨） |

---

### 3-2. 認証方式

| 認証方式 | SQL on VM | SQL MI | SQL DB |
|---------|:---------:|:------:|:------:|
| SQL 認証 | ✓ | ✓ | ✓ |
| Windows 認証（AD） | ✓ | ✓（Azure AD DS 連携） | ✓（Azure AD 連携） |
| Azure AD 認証 | - | ✓ | ✓ |

- オンプレ AD と Azure AD を Azure AD Connect で同期することで Windows 認証を継続利用可能

---

### 3-3. TDE（透過的データ暗号化）

| 項目 | 詳細 |
|------|------|
| **SQL MI のデフォルト** | TDE は**デフォルトで有効**（無効化不可） |
| **カスタムキー** | Bring Your Own Key（BYOK）で Azure Key Vault のキーを使用可能 |
| **注意点** | TDE で保護されたバックアップを復元する場合は証明書のインポートが必要 |

---

## 4. アプリケーション互換性に関するノックアウト要件

### 4-1. 接続文字列の変更

| 項目 | 内容 |
|------|------|
| **変更点** | サーバー名が `<インスタンス名>.database.windows.net` に変わる |
| **影響箇所** | アプリの接続文字列・設定ファイル・ODBC/OLEDB 設定すべて |
| **確認方法** | アプリコード・設定ファイル（`web.config` / `appsettings.json`）を全文検索 |

---

### 4-2. 互換性レベル

| 項目 | 詳細 |
|------|------|
| **概念** | SQL Server の互換性レベル（例: 2019 = 150、2016 = 130）はデータベース単位で設定可能 |
| **SQL MI での扱い** | 移行後も古い互換性レベルを維持できる（最低 100 まで対応） |
| **推奨** | 移行後は段階的に互換性レベルを上げてクエリオプティマイザの恩恵を受ける |
| **確認方法** | `SELECT name, compatibility_level FROM sys.databases` |

---

## 5. ノックアウト要件チェックリスト（移行前に必ず確認）

### 機能互換性

- [ ] `xp_cmdshell` の使用有無を確認した
- [ ] 異種 DBMS への Linked Server の有無を確認した
- [ ] CLR アセンブリの SAFE / UNSAFE / EXTERNAL_ACCESS 種別を確認した
- [ ] マージレプリケーションの使用有無を確認した
- [ ] MSDTC を使った分散トランザクションの有無を確認した
- [ ] Service Broker 外部アクティベーションの使用有無を確認した

### パフォーマンス・サイズ

- [ ] 各データベースのサイズを測定した（上限 16 TB との比較）
- [ ] ピーク時の IOPS / スループットを計測した
- [ ] インスタンスの照合順序（日本語対応か）を確認した

### ネットワーク・セキュリティ

- [ ] SQL MI 用の専用サブネット（`/27` 以上）を確保できる VNet 設計を確認した
- [ ] オンプレとの接続方式（ExpressRoute / VPN）を確定した
- [ ] Windows 認証が必要な場合、Azure AD 連携の設計を確認した
- [ ] TDE カスタムキー（BYOK）要件を確認した

### アプリケーション互換性

- [ ] 接続文字列の変更箇所をすべてリストアップした
- [ ] 現行の互換性レベルを確認し、移行後の方針を決めた
- [ ] Database Experimentation Assistant（DEA）でワークロード互換性テストを実施した

---

## 6. よく出る問題パターン

**Q. `xp_cmdshell` を使った SQL Agent ジョブが 10 本ある。SQL MI に移行できるか？**
→ A. SQL MI では `xp_cmdshell` が無効のため、ジョブの処理を Azure Functions や PowerShell Runbook などに移管する必要がある。ジョブ数が多い場合は SQL on VM を検討する。

**Q. Oracle への Linked Server を使っているが SQL MI に移行できるか？**
→ A. SQL MI は Oracle への OLEDB Linked Server をサポートしない。Azure Data Factory を使ったデータ連携パターンへの設計変更が必要。

**Q. データベースが 20 TB ある。SQL MI に移行できるか？**
→ A. SQL MI（General Purpose）の上限は 16 TB のため不可。Hyperscale（SQL Database）または SQL on VM を選択する必要がある。

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL MI と SQL Server の T-SQL 相違点 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/transact-sql-tsql-differences-sql-server |
| Azure SQL 機能比較（MI / DB / VM） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/features-comparison |
| SQL MI の接続アーキテクチャ（VNet 要件） | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connectivity-architecture-overview |
| SQL MI サブネットサイズの決定 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/vnet-subnet-determine-size |
| SQL MI での分散トランザクション（MSDTC） | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/distributed-transaction-coordinator-article |
| Azure AD 認証（Azure SQL） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/authentication-aad-overview |
| 透過的データ暗号化（TDE） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/transparent-data-encryption-tde-overview |
| ALTER DATABASE 互換性レベル | https://learn.microsoft.com/ja-jp/sql/t-sql/statements/alter-database-transact-sql-compatibility-level |
| Database Experimentation Assistant（DEA） | https://learn.microsoft.com/ja-jp/sql/dea/database-experimentation-assistant-overview |
