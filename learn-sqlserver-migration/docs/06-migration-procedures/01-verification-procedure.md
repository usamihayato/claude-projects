# SQL Server 2008 R2 → Azure SQL Database 移行 自宅検証手順書

---

## 全体の流れ

```
STEP 1  SQL Server 2008 R2 Express をインストール
STEP 2  SSMS をインストール
STEP 3  ダミーDBを作成
STEP 4  互換性レベルを確認
STEP 5  SqlPackage をインストール
STEP 6  BACPACエクスポート
STEP 7  Azureアカウント＋SQL Databaseを準備
STEP 8  BACPACインポート
STEP 9  動作確認・READ_ONLY設定
```

---

## STEP 1｜SQL Server 2008 R2 Express をインストール

### ダウンロード

以下のMicrosoft公式ページから無償の Express Edition を入手します。

```
SQL Server 2008 R2 SP2 Express Edition（無償・永続）
https://www.microsoft.com/ja-jp/download/details.aspx?id=30438
```

> **Expressの制限事項（検証では問題なし）**
> - DB上限サイズ：10GB
> - CPU：1ソケットまで
> - メモリ：1GBまで
> - 検証用途には十分です

### インストール手順

1. ダウンロードした `SQLEXPRWT_x64_JPN.exe` を実行
2. 「新規インストール」を選択
3. インスタンス名：`SQLEXPRESS`（デフォルトのまま）
4. 認証モード：**混在モード（Windows認証＋SQLServer認証）** を選択
5. `sa` パスワードを設定（メモしておく）
6. インストール完了後、**SQLServerBrowser サービスを開始**する
   - スタート → 「SQL Server 構成マネージャー」
   - SQL Server のサービス → SQL Server Browser → 右クリック → 開始

---

## STEP 2｜SSMS をインストール

> ⚠️ **注意：SSMS 19以降はSQL Server 2008 R2への接続に問題があります**
> - SSMS 19.x：TLS互換性の問題で接続困難（v19.3までワークアラウンドが存在）
> - SSMS 20以降：上記ワークアラウンドが機能せず
> - SSMS 22（最新）：公式サポートはSQL Server 2014以降のみ
>
> SQL Server 2008 R2に接続するには必ず **SSMS 18.x** を使用してください。

```
SSMS 18.x ダウンロード
https://learn.microsoft.com/ja-jp/ssms/release-notes-ssms-18#1896
```

インストール後、SSMSを起動して接続確認します。

```
サーバー名：localhost\SQLEXPRESS
認証：SQL Server 認証
ログイン：sa
パスワード：STEP1で設定したもの
```

---

## STEP 3｜ダミーDBを作成

SSMSで「新しいクエリ」を開き、以下を実行します。

```sql
-- データベース作成
CREATE DATABASE TestMigrationDB;
GO

USE TestMigrationDB;
GO

-- テーブル作成（蓄積系データを想定したシンプルな構造）
CREATE TABLE SalesData (
    SalesID     INT          NOT NULL PRIMARY KEY,
    SalesDate   DATETIME     NOT NULL,
    ProductCode NVARCHAR(20) NOT NULL,
    ProductName NVARCHAR(100) NOT NULL,
    Quantity    INT          NOT NULL,
    UnitPrice   DECIMAL(10,2) NOT NULL,
    TotalAmount DECIMAL(10,2) NOT NULL,
    Region      NVARCHAR(50)  NULL
);
GO

CREATE TABLE ProductMaster (
    ProductCode NVARCHAR(20)  NOT NULL PRIMARY KEY,
    ProductName NVARCHAR(100) NOT NULL,
    Category    NVARCHAR(50)  NOT NULL,
    CreatedAt   DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- ダミーデータ投入（ProductMaster）
INSERT INTO ProductMaster VALUES ('P001', '製品A', 'カテゴリ1', GETDATE());
INSERT INTO ProductMaster VALUES ('P002', '製品B', 'カテゴリ1', GETDATE());
INSERT INTO ProductMaster VALUES ('P003', '製品C', 'カテゴリ2', GETDATE());
GO

-- ダミーデータ投入（SalesData：100件）
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    INSERT INTO SalesData VALUES (
        @i,
        DATEADD(DAY, -@i, GETDATE()),
        'P00' + CAST((@i % 3 + 1) AS NVARCHAR),
        '製品' + CHAR(64 + (@i % 3 + 1)),
        @i * 10,
        CAST(@i * 100 AS DECIMAL(10,2)),
        CAST(@i * 10 * @i * 100 AS DECIMAL(10,2)),
        CASE @i % 3 WHEN 0 THEN '東京' WHEN 1 THEN '大阪' ELSE '名古屋' END
    );
    SET @i = @i + 1;
END
GO

-- 確認
SELECT COUNT(*) AS 件数 FROM SalesData;
SELECT COUNT(*) AS 件数 FROM ProductMaster;
```

---

## STEP 4｜互換性レベルを確認

```sql
USE master;
GO

-- 互換性レベル確認（100以上であること）
SELECT name, compatibility_level
FROM sys.databases
WHERE name = 'TestMigrationDB';
```

> **結果の見方**
> - `100`：問題なし（Azure SQL Databaseの最低要件を満たす）
> - `80`や`90`：移行前に変更が必要
>
> 2008 R2で作成したDBは通常`100`になります。

もし変更が必要な場合：
```sql
ALTER DATABASE TestMigrationDB
SET COMPATIBILITY_LEVEL = 100;
```

---

## STEP 5｜SqlPackage をインストール

MicrosoftのNuGetページからダウンロードします。

```
SqlPackage ダウンロード
https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-download
```

インストール後、コマンドプロンプトで動作確認：

```cmd
SqlPackage /version
```

バージョンが表示されれば成功です。

---

## STEP 6｜BACPAC エクスポート

コマンドプロンプト（管理者として実行）で以下を実行します。

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"localhost\SQLEXPRESS" ^
  /SourceDatabaseName:"TestMigrationDB" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（STEPで設定したパスワード）" ^
  /TargetFile:"C:\Temp\TestMigrationDB.bacpac"
```

> **完了すると** `C:\Temp\TestMigrationDB.bacpac` が生成されます。
> ダミーデータの場合は数秒〜数十秒で終わります。

---

## STEP 7｜Azure SQL Database を準備

### 7-1. Azureアカウント作成

まだの場合は無料アカウントを作成します。
```
https://azure.microsoft.com/ja-jp/free/
```

### 7-2. Azure SQL Database（サーバレス）を作成

1. **Azureポータル** (https://portal.azure.com) にサインイン
2. 「リソースの作成」→「Azure SQL」→「SQLデータベース」を選択
3. 以下を設定：

| 項目 | 設定値 |
|---|---|
| サブスクリプション | 無料試用版 |
| リソースグループ | 新規作成：`rg-migration-test` |
| データベース名 | `TestMigrationDB` |
| サーバー | 新規作成（任意の名前、リージョン：Japan East） |
| コンピューティング＋ストレージ | 「データベースの構成」をクリック |

4. 「データベースの構成」内の設定：

| 項目 | 設定値 |
|---|---|
| サービスレベル | General Purpose |
| コンピューティングレベル | **サーバーレス** |
| 最小仮想コア | 0.5 |
| 自動一時停止の遅延 | 1時間 |
| **無料データベースオファーを適用する** | **✅ チェックを入れる** |

5. 「ネットワーク」タブ → 「Azureサービスおよびリソースにこのサーバーへのアクセスを許可する」を**ON**、**自分のIPアドレスも追加**

6. 「確認および作成」→「作成」

---

## STEP 8｜BACPAC インポート

### 方法A：Azureポータルから（GUIで簡単）

1. 作成したSQL Serverリソースを開く
2. 「データベースのインポート」を選択
3. BACPACファイルをAzure Blob Storageにアップロードして指定
4. インポート設定を確認して実行

### 方法B：SqlPackageコマンドから（確実）

```cmd
SqlPackage /Action:Import ^
  /TargetServerName:"（作成したサーバ名）.database.windows.net" ^
  /TargetDatabaseName:"TestMigrationDB" ^
  /TargetUser:"（管理者ユーザー名）" ^
  /TargetPassword:"（パスワード）" ^
  /SourceFile:"C:\Temp\TestMigrationDB.bacpac"
```

> `（作成したサーバ名）` はAzureポータルのSQL Server概要ページに表示される
> `xxxxx.database.windows.net` 形式のサーバー名です。

---

## STEP 9｜動作確認・READ_ONLY設定

### 9-1. SSMSからAzure SQL Databaseへ接続

```
サーバー名：xxxxx.database.windows.net
認証：SQL Server 認証
```

### 9-2. データ確認クエリ

```sql
-- テーブルとデータが移行されているか確認
SELECT COUNT(*) AS 件数 FROM SalesData;
SELECT COUNT(*) AS 件数 FROM ProductMaster;

-- 念のためクエリも動作確認
SELECT TOP 5
    s.SalesDate,
    s.ProductName,
    s.TotalAmount,
    s.Region
FROM SalesData s
ORDER BY s.SalesDate DESC;
```

### 9-3. READ_ONLY 設定（本番移行後の想定）

```sql
-- 読み取り専用に設定
ALTER DATABASE TestMigrationDB
SET READ_ONLY;
GO

-- 書き込みができないことを確認（エラーになればOK）
INSERT INTO SalesData VALUES (999, GETDATE(), 'P001', 'テスト', 1, 100, 100, '東京');
```

> エラー `The database 'TestMigrationDB' is read-only.` が出れば成功です。

---

## チェックリスト

| 項目 | 確認 |
|---|---|
| SQL Server 2008 R2 Express にSSMSで接続できる | ☐ |
| TestMigrationDB が作成されデータが入っている | ☐ |
| 互換性レベルが100である | ☐ |
| BACPACファイルが生成された | ☐ |
| Azure SQL Databaseが作成された（無料枠適用） | ☐ |
| BACPACインポートが完了した | ☐ |
| クエリが正常に動作する | ☐ |
| READ_ONLY設定後に書き込みがエラーになる | ☐ |

---

## トラブルシューティング

### SqlPackageでエクスポートが失敗する場合

```cmd
-- /p:Storage=File を追加して一時ファイルをローカルに強制
SqlPackage /Action:Export ^
  /SourceServerName:"localhost\SQLEXPRESS" ^
  /SourceDatabaseName:"TestMigrationDB" ^
  /SourceUser:"sa" ^
  /SourcePassword:"パスワード" ^
  /TargetFile:"C:\Temp\TestMigrationDB.bacpac" ^
  /p:Storage=File
```

### Azure SQL Databaseに接続できない場合

Azureポータル → SQL Server → 「ネットワーク」→「ファイアウォールルール」に
自分のPCのグローバルIPアドレスが追加されているか確認。

### インポートが「互換性エラー」で失敗する場合

```sql
-- オンプレ側で互換性レベルを100に変更してから再エクスポート
ALTER DATABASE TestMigrationDB
SET COMPATIBILITY_LEVEL = 100;
```

---

*作成日：2026-06-22*
