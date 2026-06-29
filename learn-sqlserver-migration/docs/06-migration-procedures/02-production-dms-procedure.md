# SQL Server 2008 R2（本番2TB）→ Azure SQL Database 移行手順書
### Azure DMS（Database Migration Service）利用・オフライン移行

---

## 検証手順書との違い

| | 検証手順書 | 本手順書（本番） |
|---|---|---|
| データ量 | ダミー（小） | 本番2TB |
| 移行ツール | SqlPackage（BACPAC） | Azure DMS |
| ローカルへの一時ファイル | 必要 | **不要** |
| SHIR | 不要 | **必要**（オンプレ↔Azure接続用） |
| 所要時間 | 数分 | 数時間〜1日 |

---

## 全体の流れ

```
STEP 1  互換性レベルを確認（オンプレで実施）
STEP 2  Azure SQL Database を作成（移行先・高スペックで用意）
STEP 3  Azure Storage Account を作成
STEP 4  DataMigration リソースプロバイダーを登録
STEP 5  Azure DMS インスタンスを作成
STEP 6  SHIR をオンプレPCにインストール・登録
STEP 7  移行プロジェクトを作成・実行
STEP 8  進捗を監視
STEP 9  動作確認
STEP 10 サーバレスにスケールダウン
STEP 11 READ_ONLY設定
STEP 12 後片付け（不要リソース削除）
```

---

## STEP 1｜互換性レベルを確認（オンプレで実施）

SSMSを使い、オンプレのSQL Server 2008 R2に接続して実行します。

```sql
USE master;
GO

-- 互換性レベル確認（100であること）
SELECT name, compatibility_level
FROM sys.databases
WHERE name = '（移行対象のDB名）';
```

> **結果の見方**
> - `100`：問題なし → STEP 2へ進む
> - `80`や`90`：以下のSQLで変更してから進む

```sql
-- 互換性レベルを100に変更する場合
ALTER DATABASE （移行対象のDB名）
SET COMPATIBILITY_LEVEL = 100;
```

> ⚠️ **変更前に確認すること**
> 古い結合構文（`*=` など）や `GROUP BY ALL` を使ったクエリがある場合、
> 変更後に動作しなくなる可能性があります。
> 不安な場合は検証環境で先に確認してください。

---

## STEP 2｜Azure SQL Database を作成（移行先）

> ⚠️ **移行中だけ高スペックにします**
> 転送速度を上げるためにMicrosoftが推奨している方法です。
> 移行完了後（STEP 10）にサーバレスへ変更します。

1. **Azureポータル**（https://portal.azure.com）にサインイン
2. 「リソースの作成」→「Azure SQL」→「SQLデータベース」を選択
3. 以下を設定：

| 項目 | 設定値 |
|---|---|
| リソースグループ | 新規作成：`rg-production-migration` |
| データベース名 | 本番DBと同じ名前を推奨 |
| サーバー | 新規作成（リージョン：Japan East） |
| コンピューティング＋ストレージ | 「データベースの構成」をクリック |

4. 「データベースの構成」内の設定：

| 項目 | 移行中の設定 |
|---|---|
| サービスレベル | General Purpose |
| コンピューティングレベル | プロビジョニング済み |
| 仮想コア数 | **8 vCore**（移行中のみ・後で下げる） |

5. 「ネットワーク」タブを設定：

| 項目 | 設定値 |
|---|---|
| Azureサービスのアクセス許可 | **ON** |
| 自分のIPアドレスを追加 | **✅ 追加する** |

6. 「確認および作成」→「作成」

### 移行用ユーザーを作成

作成した Azure SQL Database の `master` で実行します。

```sql
CREATE LOGIN dmsuser WITH PASSWORD = '（強いパスワード）';

ALTER SERVER ROLE ##MS_DefinitionReader##   ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_DatabaseConnector##  ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_DatabaseManager##    ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_LoginManager##       ADD MEMBER [dmsuser];

CREATE USER dmsuser FOR LOGIN dmsuser;
EXECUTE sp_addRoleMember 'dbmanager',   'dmsuser';
EXECUTE sp_addRoleMember 'loginmanager','dmsuser';
```

---

## STEP 3｜Azure Storage Account を作成

DMSがデータを一時的に置くストレージです。

1. ポータル → 「ストレージアカウント」→「作成」
2. 以下を設定：

| 項目 | 設定値 |
|---|---|
| リソースグループ | `rg-production-migration`（同じもの） |
| ストレージアカウント名 | 任意（英小文字と数字のみ） |
| リージョン | **Japan East**（※SQL Databaseと必ず同じに） |
| パフォーマンス | Standard |

3. 「確認および作成」→「作成」

> ⚠️ **リージョンが異なると転送コストが発生し、速度も下がります**

---

## STEP 4｜DataMigration リソースプロバイダーを登録

AzureサブスクリプションでDMSを使えるようにする**一回だけの設定**です。

1. ポータル → 「サブスクリプション」→ 対象を選択
2. 左メニュー「リソースプロバイダー」を選択
3. 検索欄に `Microsoft.DataMigration` と入力
4. 選択して「登録」をクリック
5. 状態が `Registered` になるまで待つ（数分）

---

## STEP 5｜Azure DMS インスタンスを作成

1. ポータル → 「Azure Database Migration Service」→「作成」
2. 以下を設定：

| 項目 | 設定値 |
|---|---|
| リソースグループ | `rg-production-migration` |
| 移行サービス名 | 任意 |
| リージョン | Japan East |
| サービスモード | Azure |
| 価格レベル | Standard |

3. 「確認および作成」→「作成」

> 移行完了後（STEP 12）に削除してOKです

---

## STEP 6｜SHIR をオンプレPCにインストール・登録

### SHIRとは？

オンプレのSQL ServerとAzure DMSを繋ぐ橋渡し役のソフトウェアです。

```
オンプレ SQL Server 2008 R2
        ↕（SHIR経由）
Azure DMS
        ↕
Azure SQL Database（移行先）
```

### ダウンロード・インストール

```
https://www.microsoft.com/download/details.aspx?id=39717
```

バージョン **5.37以上** をダウンロードしてインストールします。

### 登録キーの取得

1. ポータル → 作成したDMSインスタンスを開く
2. 「設定」→「統合ランタイム」を選択
3. 表示される **「認証キー1」をコピー**

### オンプレPCでSHIRを登録

1. インストールした `Microsoft Integration Runtime Configuration Manager` を起動
2. 「認証キーを使用してIntegration Runtimeを登録する」を選択
3. コピーしたキーを貼り付けて「登録」
4. 状態が **「実行中」** になれば完了

### 疎通確認

```cmd
sqlcmd -S localhost\（インスタンス名） -U sa -P （パスワード） -Q "SELECT @@VERSION"
```

SQL Serverのバージョン情報が表示されれば接続OK。

> ⚠️ **ファイアウォールの確認**
> 以下のポートが開いていることを確認してください。
> - SQL Server：TCP **1433**
> - SHIR → Azure通信：TCP **443**

---

## STEP 7｜移行プロジェクトを作成・実行

1. ポータル → DMSインスタンス → 「移行プロジェクトの新規作成」
2. ウィザードを順に設定：

### ① ソースの詳細

| 項目 | 設定値 |
|---|---|
| ソースの種類 | SQL Server |
| サーバー名 | オンプレSQL Serverのサーバー名またはIPアドレス |
| 認証の種類 | SQL 認証 |
| ユーザー名 | sa（またはdb_datareaderロールのユーザー） |
| パスワード | 対応するパスワード |

### ② 移行するデータベースの選択

- 対象のDBにチェックを入れる

### ③ ターゲットの接続

| 項目 | 設定値 |
|---|---|
| サーバー名 | xxxxx.database.windows.net |
| ユーザー名 | STEP 2で作成した `dmsuser` |
| パスワード | 設定したパスワード |

### ④ データベースのマッピング

- 移行元DBと移行先DBを対応づける

### ⑤ 移行の設定

- 「スキーマ移行」✅
- 「データ移行」✅ の両方を選択

### ⑥ 移行の開始

- 「移行の開始」をクリック

> ⚠️ **開始ボタンを押した時点がダウンタイムの起点です**
> オンプレのアプリケーションからの接続を事前に切断してください。
> （今回は参照専用移行のため、参照クエリを停止するだけでOK）

---

## STEP 8｜進捗を監視

DMSの監視画面でテーブル単位の進捗が確認できます。

```
移行の目安時間（2TBの場合）
  ネットワーク帯域・テーブル数により異なりますが
  数時間〜丸1日程度を想定してください。
```

> ⚠️ **監視中の注意事項**
> - SHIRをインストールしたPCの電源を切らないこと
> - ネットワーク接続を切らないこと
> - 移行中はオンプレDBへの書き込みを停止したままにすること

---

## STEP 9｜動作確認

SSMSからAzure SQL Databaseに接続して確認します。

```sql
-- テーブル一覧と行数を確認
SELECT
    t.name        AS テーブル名,
    p.rows        AS 行数
FROM sys.tables t
INNER JOIN sys.partitions p
    ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
ORDER BY p.rows DESC;
```

```sql
-- オンプレ側と件数を突合（オンプレ・Azure両方で実行して比較）
SELECT COUNT(*) AS 件数 FROM （主要テーブル名）;
```

```sql
-- 代表的なクエリが動作するか確認
SELECT TOP 100 * FROM （主要テーブル名）;
```

> **件数が一致し、クエリが正常に動作すれば移行成功です**

---

## STEP 10｜サーバレスにスケールダウン

移行確認後、コストを下げるためにサービスレベルを変更します。

1. ポータル → SQL Database → 「コンピューティング＋ストレージ」
2. 以下に変更：

| 項目 | 移行後の設定 |
|---|---|
| コンピューティングレベル | **サーバレス** |
| 最小仮想コア | **0.5** |
| 自動一時停止の遅延 | **1時間** |
| 無料データベースオファー | 適用できる場合はチェック |

3. 「適用」をクリック（数分で完了・ダウンタイムなし）

---

## STEP 11｜READ_ONLY設定

```sql
-- 読み取り専用に設定
ALTER DATABASE （DB名）
SET READ_ONLY;
GO

-- 確認（1であればOK）
SELECT name, is_read_only
FROM sys.databases
WHERE name = '（DB名）';
```

```sql
-- 書き込みができないことを確認（エラーになればOK）
INSERT INTO （テーブル名） VALUES (...);
```

> エラー `The database '...' is read-only.` が出れば成功です。

---

## STEP 12｜後片付け（不要リソース削除）

移行が完了したら課金リソースを削除します。

| リソース | 対応 |
|---|---|
| Azure DMS インスタンス | ✅ **削除する**（課金対象） |
| Azure Storage Account | ✅ **削除する** |
| SHIR（オンプレPC上） | ✅ アンインストール |
| Azure SQL Database | 🔒 **残す**（本番運用リソース） |
| リソースグループ | 🔒 **残す**（管理用） |

---

## チェックリスト

| 項目 | 確認 |
|---|---|
| 互換性レベルが100である | ☐ |
| Azure SQL Database（移行先・8vCore）が作成された | ☐ |
| Storage Accountが作成された（Japan East） | ☐ |
| Microsoft.DataMigrationが登録された | ☐ |
| DMSインスタンスが作成された | ☐ |
| SHIRがインストール・登録された（状態：実行中） | ☐ |
| ファイアウォール（1433・443）が開放されている | ☐ |
| 移行プロジェクトが設定された | ☐ |
| 移行が正常完了した（エラーなし） | ☐ |
| 全テーブルの件数がオンプレと一致した | ☐ |
| 代表クエリが正常に動作した | ☐ |
| サーバレスにスケールダウンした | ☐ |
| READ_ONLYが設定された | ☐ |
| DMSとStorageを削除した | ☐ |

---

## トラブルシューティング

### SHIRが「接続できない」と表示される場合

```
確認項目：
① ファイアウォールでTCP 1433・443が開放されているか
② SQL Server BrowserサービスがオンプレPC上で起動しているか
③ SHIRのバージョンが5.37以上か
```

### 移行中に特定のテーブルでエラーが出る場合

問題のテーブルだけエラーになることがあります。
DMSの監視画面でエラー内容を確認し、そのテーブルだけ
SqlPackageで補完する方法もあります。

### 移行後に件数が合わない場合

```sql
-- オンプレ側で実行
SELECT COUNT(*) FROM （テーブル名）;

-- Azure SQL側でも同じSQLを実行して比較
SELECT COUNT(*) FROM （テーブル名）;
```

件数が異なる場合はDMSの移行ログでエラーを確認してください。

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| Azure Database Migration Service 概要 | https://learn.microsoft.com/ja-jp/azure/dms/dms-overview |
| SQL Server → SQL DB（DMS オフライン移行） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/database-migration-service |
| SQL Server → SQL MI（DMS オフライン移行） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/managed-instance/database-migration-service |
| セルフホステッド統合ランタイム（SHIR） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| SSMS ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| Azure SQL Database Serverless 概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/serverless-tier-overview |
| ALTER DATABASE 互換性レベル | https://learn.microsoft.com/ja-jp/sql/t-sql/statements/alter-database-transact-sql-compatibility-level |

---

*作成日：2026-06-22*
