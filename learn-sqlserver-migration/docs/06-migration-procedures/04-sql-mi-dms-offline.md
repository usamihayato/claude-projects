# SQL MI 移行手順 — Azure DMS オフライン移行

> **移行元**: SQL Server 2008 R2（オンプレミス）  
> **移行先**: Azure SQL Managed Instance  
> **方式**: Azure Database Migration Service（オフライン）+ SHIR  
> **ダウンタイム**: あり（DMS 移行実行中）  
> **作成日**: 2026-06-29

---

## ネイティブバックアップ方式との使い分け

| 観点 | ネイティブバックアップ方式 | DMS オフライン方式（本手順） |
|---|---|---|
| 向いている DB サイズ | 単一 DB・中規模 | 複数 DB・大規模 |
| 操作の複雑さ | シンプル | やや複雑（DMS プロジェクト設定） |
| 複数 DB の一括移行 | 手動繰り返し | ✓ 一括対応 |
| 移行状況の可視化 | 限定的 | ✓ Azure Portal で進捗確認 |
| 内部動作 | RESTORE FROM URL | バックアップ → Blob → RESTORE（DMS が自動化） |

---

## 前提条件

| 項目 | 要件 |
|---|---|
| 移行元 SQL Server | 2008 R2（互換性レベル 100） |
| SSMS | 18.x（SQL Server 2008 R2 接続用） |
| SHIR | バージョン 5.37 以上（オンプレまたは Azure VNet 内 Windows VM にインストール） |
| Azure DMS | Standard 以上の SKU |
| Azure Blob Storage | 移行対象 DB と同一リージョン |
| Azure SQL MI | 作成済み・VNet 接続確認済み |
| ファイアウォール | TCP 1433（SQL Server 受信）、TCP 443（SHIR → Azure 送信）開放済み |

---

## STEP 1｜移行元ユーザーの作成（オンプレ SQL Server）

```sql
-- 移行元 SQL Server 2008 R2（master）で実行
CREATE LOGIN dmsuser WITH PASSWORD = '（強いパスワード）';

-- 必要な権限を付与
GRANT VIEW SERVER STATE TO dmsuser;
GRANT VIEW ANY DATABASE TO dmsuser;

-- 移行対象 DB ごとに実行
USE [対象DB名];
CREATE USER dmsuser FOR LOGIN dmsuser;
EXEC sp_addrolemember 'db_datareader', 'dmsuser';
```

---

## STEP 2｜SHIR のインストールと登録

### インストール
1. Azure Portal → Azure Data Factory または DMS のページから SHIR インストーラーをダウンロード
2. 以下のいずれかの Windows マシンにインストール（SQL Server と同居は非推奨）:
   - **オンプレの Windows サーバー**（SQL Server と同一ネットワーク内）
   - **Azure VNet 内の Windows VM**（VPN Gateway / ExpressRoute でオンプレと接続済みであること）
3. バージョン確認: `5.37 以上`

### DMS への登録
```
SHIR 設定画面 → [認証キー] タブ
→ Azure Portal の DMS リソースから取得した認証キーを貼り付け
→ [登録] → ステータスが「実行中」になることを確認
```

### 接続確認
```
SHIR 診断ツール → [接続のテスト]
→ オンプレ SQL Server への接続: ✓
→ Azure エンドポイントへの接続: ✓
```

---

## STEP 3｜Azure Blob Storage の準備

```
Azure Portal → ストレージアカウント → コンテナ作成（例: sql-migration）
→ SAS トークンを生成（読み取り・書き込み・一覧・削除権限、移行完了まで有効）
```

---

## STEP 4｜Azure DMS プロジェクトの作成

```
Azure Portal → [Azure Database Migration Service] → [新規移行プロジェクト]

設定値:
  プロジェクト名        : （任意）
  ソースサーバーの種類   : SQL Server
  ターゲットサーバーの種類: Azure SQL Managed Instance
  移行アクティビティの種類: データベースのオフライン移行
```

---

## STEP 5｜ソース（移行元）の設定

```
ソースの詳細:
  ソースサーバー名  : （オンプレ SQL Server の IP またはホスト名）
  認証の種類       : SQL 認証
  ユーザー名       : dmsuser
  パスワード       : （STEP 1 で設定したパスワード）
  接続の暗号化     : 証明書を信頼する（2008 R2 ではチェック推奨）
  統合ランタイム   : （STEP 2 で登録した SHIR を選択）
```

---

## STEP 6｜ターゲット（SQL MI）の設定

```
ターゲットの詳細:
  サブスクリプション         : （Azure サブスクリプションを選択）
  Azure SQL MI の場所         : （対象リージョン）
  マネージド インスタンス名   : （対象 SQL MI を選択）
  認証の種類                  : SQL 認証
  ユーザー名                  : （SQL MI の管理者ユーザー）
  パスワード                  : （管理者パスワード）
```

---

## STEP 7｜バックアップ設定

```
バックアップの場所:
  バックアップの場所の種類   : Azure Storage（Blob）
  ストレージアカウント       : （STEP 3 で作成したアカウントを選択）
  コンテナー                 : sql-migration
  SAS トークン               : （STEP 3 で取得した SAS トークン）

DMS が自動で:
  1. SHIR 経由で SQL Server のバックアップを取得
  2. Blob Storage にアップロード
  3. SQL MI に RESTORE FROM URL を実行
```

---

## STEP 8｜移行対象 DB の選択と実行

```
データベースの選択:
  → 移行対象 DB にチェック（複数選択可）
  → 各 DB の移行設定（ファイル配置等）を確認

移行の実行:
  → [移行の実行] をクリック
  → アプリを停止してから実行（オフライン移行のためダウンタイム開始）
```

---

## STEP 9｜移行状況の確認

```
Azure Portal → DMS プロジェクト → [アクティビティ]
→ 各 DB のステータスを確認
  ・実行中 → 正常進行中
  ・完了   → リストア成功
  ・エラー → エラー詳細を確認して対処
```

SQL MI 側でも確認:
```sql
-- SQL MI（master）で実行
SELECT name, state_desc FROM sys.databases ORDER BY name;
```

---

## STEP 10｜移行後確認

```sql
-- SQL MI で実行
-- オブジェクト数の確認（移行元と比較）
USE [対象DB名];
SELECT type_desc, COUNT(*) AS 件数
FROM sys.objects
WHERE is_ms_shipped = 0
GROUP BY type_desc;

-- 主要テーブルのレコード数確認
SELECT
    t.name AS テーブル名,
    p.rows AS レコード数
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0,1)
ORDER BY p.rows DESC;

-- 互換性レベルの確認
SELECT name, compatibility_level FROM sys.databases WHERE name = '対象DB名';
```

---

## STEP 11｜切り替え・後処理

```sql
-- 互換性レベルの段階的引き上げ（任意）
ALTER DATABASE [対象DB名] SET COMPATIBILITY_LEVEL = 130;

-- アプリ接続文字列の変更
-- 旧: Data Source=オンプレサーバー名\インスタンス名
-- 新: Data Source=<MI名>.database.windows.net
```

1. アプリの接続文字列を SQL MI エンドポイントに変更
2. 動作確認（主要機能・SQL Agent ジョブ・Linked Server）
3. 問題なければオンプレ SQL Server を READ_ONLY に設定（ロールバック保険）
4. 一定期間後に確定

---

## チェックリスト

### 移行前
- [ ] SHIR インストール済み・バージョン 5.37 以上を確認
- [ ] SHIR から SQL Server・Azure 両方への接続テスト成功
- [ ] dmsuser 作成・権限付与済み
- [ ] Blob Storage コンテナ・SAS トークン準備済み
- [ ] DMS プロジェクト作成済み
- [ ] アプリ停止・接続切断済み（ダウンタイム開始）

### 移行後
- [ ] 全 DB のステータスが「完了」であることを確認
- [ ] オブジェクト数・レコード数を移行元と比較
- [ ] アプリ接続文字列変更・動作確認
- [ ] SQL Agent ジョブの移行・動作確認
- [ ] Blob の一時バックアップファイルを削除

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL Server → SQL MI DMS オフライン移行 | https://learn.microsoft.com/ja-jp/data-migration/sql-server/managed-instance/database-migration-service |
| Azure DMS 概要 | https://learn.microsoft.com/ja-jp/azure/dms/dms-overview |
| セルフホステッド統合ランタイム（SHIR） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| SQL MI の接続アーキテクチャ | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connectivity-architecture-overview |
| SQL MI DMS でサポートされるシナリオ | https://learn.microsoft.com/ja-jp/azure/dms/resource-scenario-status |
| SSMS 18.x ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| AzCopy v10 | https://learn.microsoft.com/ja-jp/azure/storage/common/storage-use-azcopy-v10 |
