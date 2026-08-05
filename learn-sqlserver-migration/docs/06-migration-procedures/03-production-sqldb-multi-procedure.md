# SQL Server 2008 R2（本番・複数DB）→ Azure SQL Database 移行手順書
### Azure DMS（Database Migration Service）利用・オフライン移行・複数DB水準移行

---

## 既存手順書との違い

| | 02-production-dms-procedure.md | 本手順書 |
|---|---|---|
| 対象DB数 | 1DB | **複数DB（水準移行）** |
| SHIRの設置場所 | オンプレPC（新規） | **既存オンプレサーバ（プロキシ経由）** |
| プロキシ設定 | 不要 | **必要（FQDN許可リスト登録）** |
| Azureへの経路 | インターネット | **ExpressRoute経由（SQL Database PE）** |
| 中間ストレージ（Blob等） | 不要 | **不要** |
| 互換性評価 | 互換性レベル確認のみ | **SSMA事前評価 + 互換性レベル確認** |

---

## 全体の流れ

```
STEP 1  互換性評価（SSMA + 互換性レベル確認）
STEP 2  Azure SQL Database を DB数分作成（移行先・高スペック）
STEP 3  DataMigration リソースプロバイダーを登録
STEP 4  Azure DMS インスタンスを作成
STEP 5  SHIR をオンプレサーバに設定（プロキシ設定含む）
STEP 6  移行プロジェクトを作成・実行（複数DB一括）
STEP 7  進捗を監視
STEP 8  動作確認（全DB）
STEP 9  サーバレスにスケールダウン（全DB）
STEP 10 READ_ONLY設定（全DB）
STEP 11 後片付け（不要リソース削除）
```

---

## 事前確認事項

### ネットワーク構成

```
オンプレ SQL Server 2008 R2（移行元・複数DB）
        ↕ TCP 1433（同一ネットワーク）
オンプレ SHIRサーバ（既存サーバに追加インストール）
        ↕ TCP 443（プロキシ経由・インターネット）  → DMS制御プレーン / Azure AD / Service Bus
        ↕ TCP 1433（ExpressRoute経由）            → Azure SQL Database（Private Endpoint）
Azure DMS
        ↕
Azure SQL Database × DB数分（移行先）
```

### 制約事項

- **SQL Server 2008 R2**：`BACKUP TO URL` 非対応のため、Blob経由バックアップは不可（SQL Databaseへのオフライン移行は直接転送のため本制約は影響なし）
- **Azure SQL Database**：クロスDB参照・リンクサーバー不可。各DBが独立したリソースとして動作する
- **SHIR**：同一サーバにADF用SHIRが存在する場合は同居不可（1台1インスタンスの制約）。移行期間中の再登録か別サーバの用意が必要

---

## STEP 1｜互換性評価

### 1-1 SSMA（SQL Server Migration Assistant）による評価

SSMAはMicrosoftが提供する無償の互換性評価・スキーマ変換ツールです。
DMS移行前にSSMAで問題を洗い出します。

**ダウンロード**
```
https://www.microsoft.com/download/details.aspx?id=54258
```

**評価手順**
1. SSMAを管理PC（Windows）にインストールして起動
2. 「New Project」→ターゲットを「Azure SQL Database」に設定
3. 「Add Databases」で移行対象の**全DBを選択**
4. 「Create Report」で評価レポートを生成
5. エラー・警告項目を確認する

**主な確認ポイント**

| カテゴリ | 内容 | 対応 |
|---|---|---|
| 非対応構文 | `*=`（旧外部結合）、`GROUP BY ALL` | SQL書き換えが必要 |
| システムオブジェクト参照 | `master..sysobjects` 等 | `sys.*` ビューへの変更 |
| SQL Agent ジョブ | Azure SQL Database非対応 | Elastic Jobs等への移行を検討 |
| リンクサーバー | Azure SQL Database非対応 | 不要であればスキップ |
| クロスDB参照 | Azure SQL Database非対応 | アプリ側の接続先変更が必要 |

> ⚠️ **SSMAのレポート内容は必ず記録しておいてください**
> 移行後の動作確認チェックリストに活用します。

### 1-2 互換性レベルの確認

SSMSでオンプレ SQL Server 2008 R2 に接続して実行します。

```sql
USE master;
GO

-- 全移行対象DBの互換性レベルを一括確認
SELECT name, compatibility_level
FROM sys.databases
WHERE name IN ('DB名1', 'DB名2', 'DB名3');  -- 移行対象のDB名を列挙
```

> **結果の見方**
> - `100`：問題なし → STEP 2 へ進む
> - `80` や `90`：以下のSQLで変更してから進む

```sql
-- 互換性レベルを100に変更する（必要な場合のみ・対象DB分繰り返す）
ALTER DATABASE DB名1 SET COMPATIBILITY_LEVEL = 100;
ALTER DATABASE DB名2 SET COMPATIBILITY_LEVEL = 100;
```

> ⚠️ **変更前に確認すること**
> 古い結合構文（`*=` など）や `GROUP BY ALL` を使ったクエリがある場合、
> 変更後に動作しなくなる可能性があります。

---

## STEP 2｜Azure SQL Database を DB数分作成（移行先）

> ⚠️ **移行中だけ高スペックにします**
> 転送速度を上げるためにMicrosoftが推奨している方法です。
> 移行完了後（STEP 9）にサーバレスへ変更します。

### 2-1 論理サーバーの作成（1回だけ）

全DBは同一の論理サーバー（Azure SQL Databaseサーバー）に配置します。

1. **Azureポータル**（https://portal.azure.com）にサインイン
2. 「リソースの作成」→「Azure SQL」→「SQLデータベース」を選択
3. 「サーバー」→「新規作成」

| 項目 | 設定値 |
|---|---|
| サーバー名 | 任意（グローバル一意名） |
| リージョン | Japan East |
| 認証方法 | SQL認証（またはEntra ID認証） |
| サーバー管理者 | 任意のログイン名 |
| パスワード | 強いパスワード |

### 2-2 Azure SQL Database を移行対象DB数分作成

移行元の各DBに対して1つずつ Azure SQL Database を作成します。

| 項目 | 設定値 |
|---|---|
| リソースグループ | 新規作成：`rg-production-migration` |
| データベース名 | 移行元DBと同じ名前を推奨 |
| サーバー | 2-1で作成した論理サーバー |
| コンピューティング＋ストレージ | 「データベースの構成」をクリック |

「データベースの構成」内の設定：

| 項目 | 移行中の設定 |
|---|---|
| サービスレベル | General Purpose |
| コンピューティングレベル | プロビジョニング済み |
| 仮想コア数 | **8 vCore**（移行中のみ・後で下げる） |

> **DB数が多い場合の効率化（Azure CLI）**
> ```bash
> RESOURCE_GROUP="rg-production-migration"
> SERVER_NAME="<サーバー名>"
> DB_NAMES=("DB名1" "DB名2" "DB名3")
>
> for DB_NAME in "${DB_NAMES[@]}"; do
>   az sql db create \
>     --resource-group $RESOURCE_GROUP \
>     --server $SERVER_NAME \
>     --name $DB_NAME \
>     --service-objective GP_Gen5_8
> done
> ```

### 2-3 ネットワーク設定（プライベートエンドポイント）

論理サーバーのネットワーク設定：

| 項目 | 設定値 |
|---|---|
| 接続方法 | プライベートエンドポイント |
| パブリックアクセス | **無効** |

**プライベートエンドポイントの作成**
1. 論理サーバー → 「セキュリティ」→「プライベートエンドポイント接続」
2. 「＋プライベートエンドポイント」をクリック
3. ER経由でSHIRからアクセスできるVNetのサブネットを選択

> 論理サーバー1つに対してPEを1つ作成するだけで、配下の全DBにアクセスできます。

### 2-4 移行用ユーザーを作成

論理サーバーの `master` で実行します。

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

## STEP 3｜DataMigration リソースプロバイダーを登録

AzureサブスクリプションでDMSを使えるようにする**一回だけの設定**です。

1. ポータル → 「サブスクリプション」→ 対象を選択
2. 左メニュー「リソースプロバイダー」を選択
3. 検索欄に `Microsoft.DataMigration` と入力
4. 選択して「登録」をクリック
5. 状態が `Registered` になるまで待つ（数分）

---

## STEP 4｜Azure DMS インスタンスを作成

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

> 移行完了後（STEP 11）に削除してOKです

---

## STEP 5｜SHIR をオンプレサーバに設定

### SHIRとは？

オンプレのSQL ServerとAzure DMSを繋ぐ橋渡し役のソフトウェアです。

```
オンプレ SQL Server 2008 R2
        ↕ TCP 1433（同一NW）
オンプレ SHIRサーバ（既存サーバ）
        ↕ TCP 443（プロキシ経由）  → DMS制御プレーン / Azure AD / Service Bus
        ↕ TCP 1433（ER経由）      → Azure SQL Database PE
```

### ダウンロード・インストール

```
https://www.microsoft.com/download/details.aspx?id=39717
```

バージョン **5.37以上** をダウンロードしてインストールします。

> ⚠️ **ADF用SHIRが同じサーバに存在する場合**
> SHIRは1台のサーバに1インスタンスしかインストールできません（同居不可）。
> ADF用SHIRが稼働中の場合は、移行期間中に一時的にDMS用として再登録するか、
> 別のサーバにDMS用SHIRを用意する必要があります。

### 登録キーの取得

1. ポータル → 作成したDMSインスタンスを開く
2. 「設定」→「統合ランタイム」を選択
3. 表示される **「認証キー1」をコピー**

### SHIRの登録

1. インストールした `Microsoft Integration Runtime Configuration Manager` を起動
2. 「認証キーを使用してIntegration Runtimeを登録する」を選択
3. コピーしたキーを貼り付けて「登録」
4. 状態が **「実行中」** になれば完了

### プロキシ設定

SHIRが使用するプロキシを設定します。

**Configuration Manager から設定する方法：**
1. `Microsoft Integration Runtime Configuration Manager` を起動
2. 「設定」タブ → 「プロキシの設定」
3. プロキシサーバのアドレス・ポートを入力
4. 必要に応じて認証情報を設定

**または diahost.exe.config で直接設定する方法：**

`C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe.config` を編集：

```xml
<system.net>
  <defaultProxy enabled="true" useDefaultCredentials="false">
    <proxy
      usesystemdefault="true"
      proxyaddress="http://（プロキシIPまたはFQDN）:（ポート）"
      bypassonlocal="true"
    />
  </defaultProxy>
</system.net>
```

編集後、Integration Runtimeサービスを再起動します。

### プロキシ（ファイアウォール）許可リスト

SHIRからプロキシ経由でアクセスが必要なFQDNは以下の通りです。

| FQDN | プロトコル | ポート | 用途 |
|---|---|---|---|
| `*.servicebus.windows.net` | TCP | 443 | DMS/ADF 制御チャネル（Service Bus） |
| `*.frontend.clouddatahub.net` | TCP | 443 | DMS/ADF バックエンドサービス |
| `download.microsoft.com` | TCP | 443 | SHIR 自動更新 |
| `login.microsoftonline.com` | TCP | 443 | Azure AD 認証 |
| `*.login.microsoftonline.com` | TCP | 443 | Azure AD 認証（テナント別） |

> **補足**：インスタンス固有のFQDNが追加される場合があります。
> SHIR登録後にConfiguration Managerの「診断」タブ →「接続のテスト」で接続確認を行い、
> 失敗しているFQDNがあれば追加登録してください。

### ExpressRoute経由のアクセス（Private Endpoint）

Azure SQL DatabaseへはExpressRoute経由でプライベートエンドポイントにアクセスします。

| 接続先 | 経路 | ポート |
|---|---|---|
| Azure SQL Database PE | ER経由（VNet内プライベートIP） | TCP 1433 |

> ⚠️ **DNS解決の確認**
> オンプレのDNSが `（論理サーバー名）.database.windows.net` を
> PEのプライベートIPに解決できることを確認してください。
> （DNS条件付きフォワーダー + Azure Private DNS Resolver の構成が必要な場合あり）

### 疎通確認

オンプレSHIRサーバから実行します。

```cmd
REM オンプレSQL Serverへの接続確認
sqlcmd -S （オンプレSQL ServerのIPまたはホスト名） -U sa -P （パスワード） -Q "SELECT @@VERSION"

REM Azure SQL Database（PE）への接続確認
sqlcmd -S （論理サーバー名）.database.windows.net -U dmsuser -P （パスワード） -Q "SELECT @@VERSION"
```

---

## STEP 6｜移行プロジェクトを作成・実行

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

- 移行対象の**全DBにチェックを入れる**
- 1つの移行プロジェクトで複数DBを一括移行できます

### ③ ターゲットの接続

| 項目 | 設定値 |
|---|---|
| サーバー名 | （論理サーバー名）.database.windows.net |
| ユーザー名 | STEP 2 で作成した `dmsuser` |
| パスワード | 設定したパスワード |

### ④ データベースのマッピング

各移行元DBと移行先DBを対応づけます。

| 移行元（オンプレ SQL Server） | 移行先（Azure SQL Database） |
|---|---|
| DB名1 | DB名1（STEP 2 で作成したもの） |
| DB名2 | DB名2（STEP 2 で作成したもの） |
| DB名3 | DB名3（STEP 2 で作成したもの） |

### ⑤ 移行の設定

- 「スキーマ移行」✅
- 「データ移行」✅ の両方を選択

### ⑥ 移行の開始

- 「移行の開始」をクリック

> ⚠️ **開始ボタンを押した時点がダウンタイムの起点です**
> オンプレのアプリケーションからの接続を事前に切断してください。
> 全DBへの参照クエリを停止してから開始することを推奨します。

---

## STEP 7｜進捗を監視

DMSの監視画面でDB単位・テーブル単位の進捗が確認できます。

```
監視の見方：
  ・DB一覧で各DBの進捗（%）を確認
  ・DBをクリックするとテーブル単位の詳細が表示される
  ・エラーがあるテーブルは赤く表示される
  ・全DBが「完了」になるまで待機する
```

> ⚠️ **監視中の注意事項**
> - SHIRをインストールしたサーバの電源を切らないこと
> - ネットワーク接続（オンプレ↔Azure）を切らないこと
> - 移行中はオンプレDBへの書き込みを停止したままにすること

---

## STEP 8｜動作確認（全DB）

SSMSからAzure SQL Databaseに接続して全DBの件数と動作を確認します。

### テーブル一覧と行数の確認（各DBで実行）

```sql
-- 移行先のAzure SQL Databaseに接続して実行
SELECT
    t.name        AS テーブル名,
    p.rows        AS 行数
FROM sys.tables t
INNER JOIN sys.partitions p
    ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
ORDER BY p.rows DESC;
```

### オンプレとの件数突合（各主要テーブルで実施）

```sql
-- オンプレ・Azure SQL Database 両方で実行して件数を比較
SELECT COUNT(*) AS 件数 FROM （主要テーブル名）;
```

### 移行前の件数一括取得（参考：オンプレ側で事前に実行）

移行開始前にオンプレ側で件数を記録しておき、移行後と突合します。

```sql
-- オンプレSQL Server側で実行（移行対象DB全体の件数を取得）
EXEC sp_msforeachdb '
USE [?];
IF DB_NAME() IN (''DB名1'', ''DB名2'', ''DB名3'')
BEGIN
    SELECT
        DB_NAME()   AS DB名,
        t.name      AS テーブル名,
        p.rows      AS 行数
    FROM sys.tables t
    INNER JOIN sys.partitions p
        ON t.object_id = p.object_id
    WHERE p.index_id IN (0, 1)
    ORDER BY t.name;
END
';
```

### 代表クエリの動作確認

```sql
-- 代表的なクエリが正常に動作するか確認（全DBで実施）
SELECT TOP 100 * FROM （主要テーブル名）;
```

> **全DBで件数が一致し、クエリが正常に動作すれば移行成功です**

---

## STEP 9｜サーバレスにスケールダウン（全DB）

移行確認後、コストを下げるためにサービスレベルを変更します。
**全DBに対して以下の手順を繰り返します。**

1. ポータル → SQL Database（各DB）→ 「コンピューティング＋ストレージ」
2. 以下に変更：

| 項目 | 移行後の設定 |
|---|---|
| コンピューティングレベル | **サーバレス** |
| 最小仮想コア | **0.5** |
| 自動一時停止の遅延 | **1時間** |
| 無料データベースオファー | 適用できる場合はチェック |

3. 「適用」をクリック（数分で完了・ダウンタイムなし）

> **Azure CLI で一括変更する場合：**
> ```bash
> DB_NAMES=("DB名1" "DB名2" "DB名3")
> for DB_NAME in "${DB_NAMES[@]}"; do
>   az sql db update \
>     --resource-group rg-production-migration \
>     --server <サーバー名> \
>     --name $DB_NAME \
>     --edition GeneralPurpose \
>     --compute-model Serverless \
>     --min-capacity 0.5 \
>     --auto-pause-delay 60
> done
> ```

---

## STEP 10｜READ_ONLY設定（全DB）

```sql
-- 読み取り専用に設定（全DBに対して実行）
ALTER DATABASE DB名1 SET READ_ONLY;
ALTER DATABASE DB名2 SET READ_ONLY;
ALTER DATABASE DB名3 SET READ_ONLY;
GO

-- 確認（is_read_only が 1 であればOK）
SELECT name, is_read_only
FROM sys.databases
WHERE name IN ('DB名1', 'DB名2', 'DB名3');
```

```sql
-- 書き込みができないことを確認（エラーになればOK）
INSERT INTO DB名1.dbo.（テーブル名） VALUES (...);
```

> エラー `The database '...' is read-only.` が出れば成功です。

---

## STEP 11｜後片付け（不要リソース削除）

移行が完了したら課金リソースを削除します。

| リソース | 対応 |
|---|---|
| Azure DMS インスタンス | ✅ **削除する**（課金対象） |
| SHIR（オンプレサーバ上） | ✅ アンインストール（ADF用として継続使用する場合は再登録） |
| Azure SQL Database（全DB） | 🔒 **残す**（本番運用リソース） |
| Azure SQL Database 論理サーバー | 🔒 **残す**（管理用） |
| プライベートエンドポイント | 🔒 **残す**（運用で使用） |
| リソースグループ | 🔒 **残す**（管理用） |

---

## チェックリスト

| 項目 | 確認 |
|---|---|
| SSMAの評価レポートを確認した（問題なし / 対処済み） | ☐ |
| 全移行対象DBの互換性レベルが100である | ☐ |
| 論理サーバー（Azure SQL Databaseサーバー）が作成された | ☐ |
| 移行対象DB数分のAzure SQL Database（8vCore）が作成された | ☐ |
| プライベートエンドポイントが作成された（ER経由でアクセス可能） | ☐ |
| 移行用ユーザー（dmsuser）が作成された | ☐ |
| Microsoft.DataMigrationが登録された | ☐ |
| DMSインスタンスが作成された | ☐ |
| SHIRがインストール・登録された（状態：実行中） | ☐ |
| プロキシが設定された（FQDN許可リスト適用済み） | ☐ |
| ER経由でSQL DatabaseへのTCP 1433接続確認ができた | ☐ |
| SHIRからオンプレSQL ServerへのTCP 1433接続確認ができた | ☐ |
| 移行プロジェクトが全DBを対象に設定された | ☐ |
| 移行が正常完了した（全DBでエラーなし） | ☐ |
| 全DBの全テーブル件数がオンプレと一致した | ☐ |
| 代表クエリが正常に動作した（全DB） | ☐ |
| 全DBをサーバレスにスケールダウンした | ☐ |
| 全DBにREAD_ONLYが設定された | ☐ |
| DMSを削除した | ☐ |
| SHIRをアンインストールした（またはADF用に再登録した） | ☐ |

---

## トラブルシューティング

### SHIRが「接続できない」と表示される場合

```
確認項目：
① プロキシのFQDN許可リストに全てのFQDNが登録されているか
② ファイアウォールでTCP 443（アウトバウンド・プロキシ経由）が許可されているか
③ ファイアウォールでTCP 1433（オンプレSQL Server宛）が許可されているか
④ SHIRのバージョンが5.37以上か（Configuration Managerで確認）
⑤ Integration Runtimeサービスが「実行中」か（Windowsサービスで確認）
⑥ Configuration Managerの「診断」タブで接続テストを実行して詳細を確認する
```

### Azure SQL Databaseに接続できない場合

```
確認項目：
① オンプレのDNSがSQL DatabaseのFQDNをPEのプライベートIPに解決しているか
   → nslookup （論理サーバー名）.database.windows.net
   → プライベートIPが返却されなければDNS設定を見直す
② ERの疎通確認（PEのプライベートIP宛にTCP 1433で到達できるか）
③ 論理サーバー側のパブリックアクセスが「無効」になっているか
④ PEのネットワークポリシーが接続を許可しているか
```

### 移行中に特定のDBでエラーが出る場合

問題のDBだけエラーになることがあります。
DMSの監視画面でエラー内容を確認し、以下を検討してください：

- エラーが互換性起因の場合：SSMAでスキーマ変換を行い、そのDBのみ再移行
- エラーが接続起因の場合：SHIRおよびネットワークの疎通を再確認

### 移行後に件数が合わない場合

```sql
-- オンプレ側で実行
SELECT COUNT(*) FROM （テーブル名）;

-- Azure SQL側でも同じSQLを実行して比較
SELECT COUNT(*) FROM （テーブル名）;
```

件数が異なる場合はDMSの移行ログでエラーを確認してください。

---

*作成日：2026-08-05*
*参考：https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/database-migration-service*
