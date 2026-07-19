# SQL MI 移行手順 — ネイティブバックアップ + RESTORE FROM URL

> **移行元**: SQL Server 2008 R2（オンプレミス）  
> **移行先**: Azure SQL Managed Instance  
> **方式**: フルバックアップ → Azure Blob Storage → RESTORE FROM URL  
> **ダウンタイム**: あり（バックアップ取得〜リストア完了まで）  
> **作成日**: 2026-06-29

---

## 前提条件

| 項目 | 要件 |
|---|---|
| 移行元 SQL Server | 2008 R2（互換性レベル 100） |
| SSMS | 18.x（SQL Server 2008 R2 への接続に必要） |
| AzCopy | v10 以上（Blob アップロード用） |
| Azure Blob Storage | 移行対象 DB と同一リージョンに作成済み |
| Azure SQL MI | 作成済み・VNet 接続確認済み |
| SQL MI への接続 | SSMS から MI エンドポイントへ接続できること |

> ⚠️ SQL Server 2008 R2 は `BACKUP TO URL`（Blob への直接バックアップ）非対応。  
> 必ずローカルに .bak を取得してから Blob にアップロードする。

---

## STEP 1｜移行前チェック

```sql
-- 移行元 SQL Server 2008 R2（master）で実行
-- DB サイズ・互換性レベルの確認
SELECT
    name,
    compatibility_level,
    SUM(size) * 8 / 1024 AS size_MB
FROM sys.databases d
JOIN sys.master_files f ON d.database_id = f.database_id
WHERE d.name = '対象DB名'
GROUP BY name, compatibility_level;

-- 復旧モデルの確認（FULL 推奨）
SELECT name, recovery_model_desc FROM sys.databases WHERE name = '対象DB名';
```

---

## STEP 2｜フルバックアップ取得（オンプレ）

```sql
-- 移行元 SQL Server 2008 R2 で実行
BACKUP DATABASE [対象DB名]
TO DISK = 'D:\Backup\対象DB名.bak'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10;

-- バックアップ整合性の確認
RESTORE VERIFYONLY
FROM DISK = 'D:\Backup\対象DB名.bak'
WITH CHECKSUM;
```

---

## STEP 3｜Azure Blob Storage の準備

### Azure Portal での作業
1. ストレージアカウント → コンテナを作成（例: `sql-migration`）
2. コンテナのアクセスレベル: **プライベート**

### SAS トークンの生成
```
Azure Portal → ストレージアカウント
→ [共有アクセス署名]
→ 許可するサービス: Blob
→ 許可するリソース: コンテナ・オブジェクト
→ 許可するアクセス許可: 読み取り・書き込み・一覧
→ 有効期限: 移行完了まで（余裕を持って設定）
→ [SAS と接続文字列を生成]
```

生成された SAS トークンを控えておく（例: `?sv=2022-...`）

---

## STEP 4｜バックアップを Blob にアップロード（AzCopy）

```bash
# AzCopy v10 でアップロード
azcopy copy "D:\Backup\対象DB名.bak" \
  "https://<ストレージアカウント>.blob.core.windows.net/sql-migration/対象DB名.bak<SASトークン>"

# アップロード確認
azcopy list "https://<ストレージアカウント>.blob.core.windows.net/sql-migration<SASトークン>"
```

---

## STEP 5｜SQL MI に認証情報（CREDENTIAL）を作成

```sql
-- SQL MI（master）で実行
-- SAS トークンの先頭の「?」は除く
CREATE CREDENTIAL [https://<ストレージアカウント>.blob.core.windows.net/sql-migration]
WITH
    IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET   = 'sv=2022-...（? を除いたSASトークン）';
```

---

## STEP 6｜RESTORE FROM URL の実行

```sql
-- SQL MI で実行
-- まずファイルリストを確認（論理名を特定）
RESTORE FILELISTONLY
FROM URL = 'https://<ストレージアカウント>.blob.core.windows.net/sql-migration/対象DB名.bak';

-- リストア実行
RESTORE DATABASE [対象DB名]
FROM URL = 'https://<ストレージアカウント>.blob.core.windows.net/sql-migration/対象DB名.bak'
WITH
    MOVE '論理データファイル名' TO '/var/opt/mssql/data/対象DB名.mdf',
    MOVE '論理ログファイル名'   TO '/var/opt/mssql/data/対象DB名_log.ldf',
    STATS = 10;
```

進捗の確認:
```sql
-- 別セッションで実行
SELECT
    r.percent_complete,
    r.estimated_completion_time / 1000 / 60 AS 残分,
    r.command,
    t.text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.command LIKE 'RESTORE%';
```

---

## STEP 7｜移行後確認

```sql
-- SQL MI で実行
-- DB の状態確認
SELECT name, state_desc, compatibility_level
FROM sys.databases
WHERE name = '対象DB名';

-- オブジェクト数の確認（移行元と件数を比較）
USE [対象DB名];
SELECT type_desc, COUNT(*) AS 件数
FROM sys.objects
WHERE is_ms_shipped = 0
GROUP BY type_desc;

-- レコード件数のサンプル確認（主要テーブルで移行元と比較）
SELECT
    t.name AS テーブル名,
    p.rows AS レコード数
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0,1)
ORDER BY p.rows DESC;
```

---

## STEP 8｜互換性レベルの調整（任意）

```sql
-- 移行後も 2008 R2 相当の動作を維持する場合はそのまま（100）
-- 段階的に上げる場合:
ALTER DATABASE [対象DB名] SET COMPATIBILITY_LEVEL = 130; -- SQL Server 2016 相当
-- テスト後に問題なければ 150（SQL 2019）へ
```

---

## チェックリスト

### 移行前
- [ ] バックアップ取得・VERIFY 完了
- [ ] Blob アップロード完了・ファイルサイズ一致を確認
- [ ] SQL MI に CREDENTIAL 作成済み
- [ ] アプリ停止・接続切断済み（ダウンタイム開始）

### 移行後
- [ ] RESTORE 完了・state_desc = ONLINE を確認
- [ ] オブジェクト数・レコード数を移行元と比較
- [ ] アプリ接続文字列を SQL MI エンドポイントに変更
- [ ] 動作確認（主要画面・バッチ実行）
- [ ] Blob の一時バックアップファイルを削除

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL MI へのバックアップリストア | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/restore-sample-database-quickstart |
| RESTORE FROM URL | https://learn.microsoft.com/ja-jp/sql/relational-databases/backup-restore/sql-server-backup-to-url |
| AzCopy v10 | https://learn.microsoft.com/ja-jp/azure/storage/common/storage-use-azcopy-v10 |
| SAS トークンの作成 | https://learn.microsoft.com/ja-jp/azure/storage/common/storage-sas-overview |
| SQL MI の接続アーキテクチャ | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connectivity-architecture-overview |
| SSMS 18.x ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| SQL Server → SQL MI 移行ガイド | https://learn.microsoft.com/ja-jp/data-migration/sql-server/managed-instance/guide |
