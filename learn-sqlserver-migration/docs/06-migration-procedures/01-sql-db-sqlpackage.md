# SQL DB 移行手順 — SqlPackage（BACPAC）

> **移行元**: SQL Server 2008 R2（オンプレミス）  
> **移行先**: Azure SQL Database  
> **方式**: SqlPackage BACPAC エクスポート → インポート  
> **ダウンタイム**: あり（エクスポート開始〜インポート完了まで）  
> **作成日**: 2026-06-29

---

## DMS オフライン方式との使い分け

| 観点 | SqlPackage 方式（本手順） | DMS オフライン方式 |
|---|---|---|
| 向いている DB サイズ | 単一 DB・中小規模（〜数百 GB） | 複数 DB・大規模（数百 GB〜） |
| ツールの複雑さ | シンプル（CLI 1 コマンド） | やや複雑（SHIR・DMS プロジェクト設定） |
| スキーマ移行 | ✓ BACPAC にスキーマ＋データを同梱 | ✓ DMS がスキーマ移行も実施 |
| 複数 DB の一括移行 | 手動繰り返し | ✓ 一括対応 |
| 移行状況の可視化 | CLI のログのみ | ✓ Azure Portal で進捗確認 |

---

## 前提条件

| 項目 | 要件 |
|---|---|
| 移行元 SQL Server | 2008 R2（互換性レベル 100） |
| SSMS | 18.x（SQL Server 2008 R2 接続用） |
| SqlPackage | 最新版（CLI ツール） |
| 移行元 DB の空き容量 | BACPAC ファイル生成分の一時領域（DB サイズ相当） |
| Azure SQL Database | 作成済み・ファイアウォールで接続許可済み |

> ⚠️ SQL Server 2008 R2 は TLS 1.2 非対応のため、SSMS は 18.x を使用すること。  
> SSMS 19 以降は接続不可になる場合がある。

---

## STEP 1｜移行前チェック（オンプレ SQL Server）

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
```

> **互換性レベルが 100 以外の場合は事前に変更する**
> ```sql
> ALTER DATABASE [対象DB名] SET COMPATIBILITY_LEVEL = 100;
> ```
> ⚠️ 旧構文（`*=` など）使用時は変更前に検証環境で動作確認すること。

---

## STEP 2｜SqlPackage のインストール

```
SqlPackage ダウンロード（最新版）
https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-download
```

インストール後、コマンドプロンプトで動作確認:

```cmd
SqlPackage /version
```

---

## STEP 3｜Azure SQL Database の作成（移行先）

> ⚠️ 移行中は高スペックで作成し、完了後にスケールダウンすることを推奨

1. Azure Portal → 「リソースの作成」→「Azure SQL」→「SQL データベース」
2. 以下を設定:

| 項目 | 設定値 |
|---|---|
| リソースグループ | 既存または新規作成 |
| データベース名 | 本番 DB と同じ名前を推奨 |
| サーバー | 新規作成（リージョン: Japan East） |
| コンピューティングレベル | プロビジョニング済み、8 vCore（移行中のみ） |

3. 「ネットワーク」タブ:

| 項目 | 設定値 |
|---|---|
| Azure サービスのアクセス許可 | ON |
| クライアント IP アドレスを追加 | ✓ 追加する（SqlPackage 実行マシンの IP） |

### 移行用認証情報の確認

Azure SQL Database の `master` で管理者ログインを確認する。  
SqlPackage の `/TargetUser` に使用するアカウントに `db_owner` 相当の権限が必要。

---

## STEP 4｜BACPAC エクスポート（オンプレ）

アプリを停止して接続を切断した後、オンプレ環境のコマンドプロンプトで実行:

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"（オンプレ SQL Server のホスト名またはIP）\（インスタンス名）" ^
  /SourceDatabaseName:"対象DB名" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（パスワード）" ^
  /TargetFile:"D:\Backup\対象DB名.bacpac"
```

> ⚠️ エクスポート開始時点がダウンタイムの起点。アプリ接続を事前に切断すること。

エクスポートが失敗する場合は `/p:Storage=File` を追加:

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"（ホスト名）\（インスタンス名）" ^
  /SourceDatabaseName:"対象DB名" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（パスワード）" ^
  /TargetFile:"D:\Backup\対象DB名.bacpac" ^
  /p:Storage=File
```

---

## STEP 5｜BACPAC インポート（Azure SQL Database）

```cmd
SqlPackage /Action:Import ^
  /TargetServerName:"（サーバー名）.database.windows.net" ^
  /TargetDatabaseName:"対象DB名" ^
  /TargetUser:"（管理者ユーザー名）" ^
  /TargetPassword:"（パスワード）" ^
  /SourceFile:"D:\Backup\対象DB名.bacpac"
```

> `（サーバー名）.database.windows.net` は Azure Portal の SQL Server 概要ページに表示される。

---

## STEP 6｜移行後確認

```sql
-- Azure SQL Database で実行
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

## STEP 7｜互換性レベルの調整（任意）

```sql
-- 段階的に引き上げる場合（移行後も 2008 R2 相当で動作させるならそのまま 100 でも可）
ALTER DATABASE [対象DB名] SET COMPATIBILITY_LEVEL = 130; -- SQL Server 2016 相当
-- テスト後に問題なければ 150（SQL Server 2019）へ
```

---

## STEP 8｜切り替え・後処理

```sql
-- アプリ接続文字列の変更
-- 旧: Data Source=オンプレサーバー名\インスタンス名
-- 新: Data Source=<サーバー名>.database.windows.net
```

1. アプリの接続文字列を Azure SQL Database エンドポイントに変更
2. 動作確認（主要機能・バッチ処理）
3. 問題なければオンプレ SQL Server を READ_ONLY に設定（ロールバック保険）
4. 移行後にスペックをサーバーレスへスケールダウン
5. 一定期間後に確定

```sql
-- オンプレ SQL Server 2008 R2 での READ_ONLY 設定（ロールバック用）
ALTER DATABASE [対象DB名] SET READ_ONLY;
```

---

## チェックリスト

### 移行前
- [ ] 互換性レベルが 100 であることを確認
- [ ] SqlPackage インストール済み・バージョン確認完了
- [ ] Azure SQL Database 作成済み・ファイアウォール設定済み
- [ ] アプリ停止・接続切断済み（ダウンタイム開始）

### 移行後
- [ ] BACPAC インポート完了・エラーなし
- [ ] オブジェクト数・レコード数を移行元と比較
- [ ] アプリ接続文字列変更・動作確認
- [ ] スペックをサーバーレスへスケールダウン
- [ ] ローカルの .bacpac ファイルを削除（容量確保）

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL Server → SQL DB 移行チュートリアル | https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/guide |
| SqlPackage Export | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-export |
| SqlPackage Import | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-import |
| SqlPackage ダウンロード | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-download |
| SSMS 18.x ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| Azure SQL Database Serverless 概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/serverless-tier-overview |
| ALTER DATABASE 互換性レベル | https://learn.microsoft.com/ja-jp/sql/t-sql/statements/alter-database-transact-sql-compatibility-level |
