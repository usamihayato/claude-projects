# 個人検証ラボ手順書 — Azure上でオンプレを模擬した SQL Database 移行検証（方式C・方式D）

> **移行元**: SQL Server（オンプレ模擬・Azure VM上に構築）
> **移行先**: Azure SQL Database（複数DB）
> **検証方式**: 方式C（SqlPackage／BACPAC）／方式D（Azure DMS + SHIR）
> **検証観点**: 複数DB構成・クロスDB参照Viewが各方式でどこまで再現できるか
> **想定コスト**: 個人サブスクリプションの無料枠中心（月数百円〜）
> **作成日**: 2026-08-06

---

## この検証の目的

- [00-summary.md](./00-summary.md) で比較した **方式C（SqlPackage）** と **方式D（Azure DMS + SHIR）** を、実際にAzure上で動かして挙動を確認する
- Azure SQL Database の既知の制約である「クロスDB参照・リンクサーバー不可」（[03-production-sqldb-multi-procedure.md](./03-production-sqldb-multi-procedure.md) で言及）が、**実際の移行作業のどの段階で・どう表面化するか**（エクスポート時にエラーか、移行は通ってクエリ実行時にエラーか）を実機で確認する
- 個人の Azure サブスクリプションで、追加コストを最小限に抑えながら完結させる

> このドキュメントは結果を先に断定せず、「想定される挙動」と「実際の検証結果」を分けて記録する形式にしています。検証しながら空欄を埋めてください。

---

## 検証用アーキテクチャ

```
[個人 Azure サブスクリプション]

  リソースグループ: rg-sqldb-verify-lab
  │
  ├─ VNet (10.0.0.0/24)
  │    └─ Subnet (10.0.0.0/26)
  │         └─ VM: vm-onprem-sim（Windows Server + SQL Server Developer Edition）
  │              ├─ SQL Server インスタンス  ← オンプレ SQL Server の代替
  │              │     ├─ DB: LabCustomer（Customers テーブル）
  │              │     └─ DB: LabSales   （Orders テーブル）
  │              │           └─ dbo.vw_OrderWithCustomer
  │              │                 → LabCustomer.dbo.Customers を3部名参照（★クロスDB View）
  │              └─ SHIR（統合ランタイム）  ※方式D検証時のみインストール
  │
  └─ Azure SQL 論理サーバー: sql-verify-target
       ├─ LabCustomer_c / LabSales_c　（方式C検証用）
       └─ LabCustomer_d / LabSales_d　（方式D検証用）
```

すべて **1つのリソースグループに集約**し、最後は `az group delete` 一発で片付けられるようにします。

---

## コスト最小化の方針

| 項目 | 方針 | 補足 |
|---|---|---|
| VM | `Standard_B2s`。検証しない時間は必ず「停止（割り当て解除）」 | 割り当て解除しないと課金が続く点に注意 |
| SQL Server ライセンス | Marketplace の「SQL Server Developer」イメージを使用 | Developer Edition は本番利用不可だがライセンス費用なし。VM のコンピューティング代のみ課金 |
| Azure SQL Database | General Purpose **サーバーレス** + **無料データベースオファー** | 無料オファーは **1サブスクリプションにつき1DBのみ**。2つ目以降はサーバーレス最小構成（0.5 vCore・自動一時停止1時間）で数十円/日程度 |
| Azure DMS | 方式Dの検証時のみ作成し、**検証後は即削除** | 稼働時間課金のため、方式C検証中は作成しない。SQL DB向けDMSは内部でADFパイプラインを使い直接データコピーするため、Storage Accountは不要 |
| ネットワーク | パブリックエンドポイント＋ファイアウォール規則のみ | Private Endpoint・ExpressRoute は本番手順（[03-production-sqldb-multi-procedure.md](./03-production-sqldb-multi-procedure.md)）専用の構成のため、個人検証では使わない（コスト増要因） |
| SHIR | ソフトウェア自体は無料 | `vm-onprem-sim` に同居させて追加VM費用を発生させない |

> 目安：VM は検証時間のみ稼働（数時間×数回）、DB はサーバーレス＋無料オファーで運用した場合、月あたり数百円〜千円程度に収まる想定です。DMSは「使う日だけ作る」を徹底してください。

---

## SQL Server 2008 R2 の再現について

Azure Marketplace には現在 **Windows Server 2008 R2 のイメージが存在しません**（延長サポート終了に伴い提供終了）。2008 R2 を厳密に再現するには自前でカスタムVHDを用意する必要があり、個人検証には見合わないコストです。

そのため本手順では以下を採用します。

| 項目 | 採用方針 |
|---|---|
| OS / SQL Server | 最新の Windows Server + SQL Server（2019 または 2022）**Developer Edition** |
| 2008 R2 相当の挙動再現 | 対象DBの **互換性レベルを 100** に設定（[01-sql-db-sqlpackage.md](./01-sql-db-sqlpackage.md) STEP 1 と同じ考え方） |

互換性レベル100にすることで、クエリオプティマイザの挙動やT-SQLの一部制限は2008 R2に近づきますが、**エンジンのバイナリ自体は最新版**である点は認識しておいてください（サービスパック依存の不具合やごく古い構文の非互換までは再現できません）。今回の検証目的（複数DB・クロスDB参照Viewの移行可否）にはこの差分は影響しません。

---

## Part A｜検証用ソース環境の構築（共通）

### STEP A1｜リソースグループ・VNet作成

```bash
az group create --name rg-sqldb-verify-lab --location japaneast

az network vnet create \
  --resource-group rg-sqldb-verify-lab \
  --name vnet-verify-lab \
  --address-prefix 10.0.0.0/24 \
  --subnet-name subnet-onprem-sim \
  --subnet-prefix 10.0.0.0/26
```

### STEP A2｜VM作成（オンプレ模擬・SQL Server Developer Edition）

Marketplace の正確な SKU 名はリージョン・時期によって変わるため、作成前に確認します。

```bash
az vm image list --publisher MicrosoftSQLServer --sku sqldev --all --output table
```

表示された SKU を使って VM を作成します（例：SQL Server 2022 on Windows Server 2022）。

```bash
az vm create \
  --resource-group rg-sqldb-verify-lab \
  --name vm-onprem-sim \
  --image "MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2:latest" \
  --size Standard_B2s \
  --vnet-name vnet-verify-lab \
  --subnet subnet-onprem-sim \
  --admin-username azureuser \
  --admin-password "（強いパスワード）" \
  --public-ip-sku Standard
```

Portal から作成する場合は「仮想マシンの作成」→ Marketplace 検索で `SQL Server Developer` を選択しても同じです。

**NSG（ファイアウォール）設定**：検証用PCのグローバルIPからのみ、以下を許可します。

| ポート | 用途 |
|---|---|
| TCP 3389 | RDP接続 |
| TCP 1433 | SQL Server 接続（SqlPackage・DMS からの疎通確認用） |

> ⚠️ `0.0.0.0/0`（Any）への開放は避け、必ず自分のグローバルIPに絞ってください。

### STEP A3｜複数DB作成 + クロスDB参照Viewの作成

VM に RDP 接続し、SSMS で SQL Server インスタンスに接続して実行します。

> ⚠️ **証明書の警告が出た場合**
> VM上のSQL Serverは自己署名証明書を使っているため、SSMSの「サーバーへの接続」ダイアログで
> 「オプション >>」→「接続のプロパティ」タブの **「サーバー証明書を信頼する」** にチェックを入れてから接続してください。
> チェックしないと `The certificate chain was issued by an authority that is not trusted` エラーになります（Windows認証・SQL認証どちらでも発生します）。

```sql
-- Customers 側のDB
CREATE DATABASE LabCustomer;
GO
USE LabCustomer;
GO
CREATE TABLE dbo.Customers (
    CustomerId   INT PRIMARY KEY,
    CustomerName NVARCHAR(100)
);
INSERT INTO dbo.Customers VALUES
    (1, N'株式会社サンプル'),
    (2, N'テスト商事');
GO

-- Orders 側のDB
CREATE DATABASE LabSales;
GO
USE LabSales;
GO
CREATE TABLE dbo.Orders (
    OrderId     INT PRIMARY KEY,
    CustomerId  INT,
    OrderAmount DECIMAL(10,2)
);
INSERT INTO dbo.Orders VALUES
    (101, 1, 15000),
    (102, 2, 8000);
GO

-- ★クロスDB参照View（3部名で LabCustomer を参照）
CREATE VIEW dbo.vw_OrderWithCustomer AS
SELECT
    o.OrderId,
    o.OrderAmount,
    c.CustomerName
FROM LabSales.dbo.Orders AS o
JOIN LabCustomer.dbo.Customers AS c
    ON o.CustomerId = c.CustomerId;
GO

-- 互換性レベルを2008 R2相当(100)に設定
ALTER DATABASE LabCustomer SET COMPATIBILITY_LEVEL = 100;
ALTER DATABASE LabSales    SET COMPATIBILITY_LEVEL = 100;
GO
```

動作確認（オンプレ模擬環境ではクロスDB参照は普通に動きます）：

```sql
USE LabSales;
GO
SELECT * FROM dbo.vw_OrderWithCustomer;
-- OrderId, OrderAmount, CustomerName が正しく返れば正常
```

**SQL Server認証（`sa`ユーザー）の有効化**：

後続の SqlPackage（STEP B3）・Azure DMS（Part C）はいずれも SQL Server 認証の `sa` ユーザーで接続する前提のため、ここで有効化してパスワードを設定しておきます（既定では `sa` は無効・パスワード未設定です）。

```sql
ALTER LOGIN sa WITH PASSWORD = '（強いパスワード）';
ALTER LOGIN sa ENABLE;
GO

-- 混合モード（SQL + Windows認証）が有効か確認（結果が 0 ならOK、1ならWindows認証のみ）
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly');
```

> ⚠️ 上記の結果が `1`（Windows認証のみ）だった場合は、以下の手順で混合モードに変更してください。
>
> 1. オブジェクトエクスプローラーでインスタンス名を右クリック →「プロパティ」→「セキュリティ」ページ
> 2. 「サーバー認証」で **「SQL Server 認証モードと Windows 認証モードを使用する」** を選択 →「OK」
>    （「サービスの再起動が必要」というダイアログが出るが、ここではまだ再起動されない）
> 3. VM内のスタートメニューから **「SQL Server 構成マネージャー」** を起動
> 4. 左ペイン「SQL Server サービス」→ 右ペインの「SQL Server (MSSQLSERVER)」を右クリック →「再起動」
> 5. SSMSに再接続し、`SELECT SERVERPROPERTY('IsIntegratedSecurityOnly');` が `0` になったことを確認
> 6. 新規接続を「SQL Server 認証」・ログイン名`sa`で開き、ログインできることを確認

### STEP A4｜移行前データの記録

```sql
-- 両DBの件数を記録しておく
SELECT 'LabCustomer.Customers' AS 対象, COUNT(*) AS 件数 FROM LabCustomer.dbo.Customers
UNION ALL
SELECT 'LabSales.Orders', COUNT(*) FROM LabSales.dbo.Orders;
```

| 対象 | 件数 |
|---|---|
| LabCustomer.Customers | 2 |
| LabSales.Orders | 2 |

---

## Part B｜方式C検証（SqlPackage / BACPAC）

### STEP B1｜移行先 Azure SQL Database 作成

論理サーバー `sql-verify-target` を新規作成し、配下に2DBを作成します。

> **認証方式：「SQL 認証を使用する」を選択**
> 「Microsoft Entra 認証専用」を選ぶとSQLログインが無効化され、STEP B4のSqlPackage Import（`/TargetUser`/`/TargetPassword`）や
> 方式D側で`dmsuser`をSQL認証で作成する手順（[02-sql-db-dms-offline.md](./02-sql-db-dms-offline.md) STEP 2）が失敗します。
> 「両方」でも動きますが、Microsoft Entra管理者の追加設定が不要な分、「SQL 認証を使用する」だけで十分です。
> ここで設定するサーバー管理者ユーザー名・パスワードが、STEP B4の`/TargetUser`/`/TargetPassword`になります。

| DB名 | サービスレベル | 備考 |
|---|---|---|
| `LabCustomer_c` | General Purpose サーバーレス（無料データベースオファーを適用） | 1サブスクリプションで無料枠を使えるのは1DBのみ |
| `LabSales_c` | General Purpose サーバーレス（0.5〜1 vCore） | |

ネットワーク設定は「Azureサービスへのアクセスを許可：ON」＋自分のグローバルIPを許可、で十分です（Private Endpointは使いません）。

### STEP B2｜SqlPackage インストール

作業用PC（VMでも手元PCでも可。VMに接続できるならどちらでも良い）に SqlPackage をインストールします。

```
https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-download
```

```cmd
SqlPackage /version
```

### STEP B3｜エクスポート実行（検証ポイント①）

**LabCustomer（外部参照なし）から実行**：

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"（vm-onprem-simのIP）,1433" ^
  /SourceDatabaseName:"LabCustomer" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（パスワード）" ^
  /SourceTrustServerCertificate:True ^
  /TargetFile:"C:\lab\LabCustomer.bacpac"
```

これは問題なく成功するはずです。

**LabSales（クロスDB Viewを含む）から実行**：

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"（vm-onprem-simのIP）,1433" ^
  /SourceDatabaseName:"LabSales" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（パスワード）" ^
  /SourceTrustServerCertificate:True ^
  /TargetFile:"C:\lab\LabSales.bacpac"
```

> **想定される挙動**：BACPACは単一DBを自己完結させる形式のため、他DBへの未解決参照を持つオブジェクト（`vw_OrderWithCustomer`）がある場合、DacFxの検証でエラーになる可能性があります（`SQL71501` 系の「未解決の参照」エラーが典型例）。実際のメッセージはバージョンにより異なるため、必ず実際のログを記録してください。

失敗した場合、検証用として以下も試します（検証目的の操作であり、根本解決ではありません）。

```cmd
SqlPackage /Action:Export ^
  /SourceServerName:"（vm-onprem-simのIP）,1433" ^
  /SourceDatabaseName:"LabSales" ^
  /SourceUser:"sa" ^
  /SourcePassword:"（パスワード）" ^
  /SourceTrustServerCertificate:True ^
  /TargetFile:"C:\lab\LabSales.bacpac" ^
  /p:VerifyExtraction=false
```

#### 検証結果記録欄

| 試行 | 結果 | エラー内容（あれば） |
|---|---|---|
| LabCustomer エクスポート | ☑成功 ☐失敗 | |
| LabSales エクスポート（デフォルト） | ☐成功 ☑失敗 | `SQL71561`：`vw_OrderWithCustomer` が `LabCustomer.dbo.Customers` への未解決の外部参照を含むためスキーマモデル検証エラー（ドキュメントの推測は`SQL71501`系だったが、実測は`SQL71561`） |
| LabSales エクスポート（`/p:VerifyExtraction=false`） | ☑成功 ☐失敗 | 検証パスをスキップして成功。ただしViewの参照自体は未解決のまま.bacpacに封じ込められているだけ（STEP B4以降で実際に機能するかは別途確認） |

### STEP B4｜インポート実行

エクスポートに成功したbacpacについてのみ実行します。

```cmd
SqlPackage /Action:Import ^
  /TargetServerName:"sql-verify-target.database.windows.net" ^
  /TargetDatabaseName:"LabCustomer_c" ^
  /TargetUser:"（管理者ユーザー名）" ^
  /TargetPassword:"（パスワード）" ^
  /SourceFile:"C:\lab\LabCustomer.bacpac"

SqlPackage /Action:Import ^
  /TargetServerName:"sql-verify-target.database.windows.net" ^
  /TargetDatabaseName:"LabSales_c" ^
  /TargetUser:"（管理者ユーザー名）" ^
  /TargetPassword:"（パスワード）" ^
  /SourceFile:"C:\lab\LabSales.bacpac"
```

### STEP B5｜動作確認（検証ポイント②）

Azure SQL Database（`LabSales_c`）に接続して実行します。

```sql
-- 通常テーブルは問題なく動くはず
SELECT * FROM dbo.Orders;

-- クロスDB参照Viewの実行結果を確認
SELECT * FROM dbo.vw_OrderWithCustomer;
```

> **実測結果**：View自体がクエリ実行以前の**インポート（デプロイ）段階で作成に失敗**しました。`SqlPackage /Action:Import`実行時に`SQL72014`／`Msg 40515`（「参照 'LabSales.dbo.Orders' 内のデータベースまたはサーバー名の指定は、このバージョンの SQL Server ではサポートされていません」）で`CREATE VIEW`自体がエラーとなり、インポート処理全体が`Could not import package.`で中断。ログ上、Viewエラー以降に`Importing data`／`Processing Table`が一切出力されておらず、データ投入フェーズまで到達していません。
> 「View自体は作成できるが、クエリ実行時にエラーになる」という当初の予想より踏み込んだ結果で、**デプロイの時点でImportそのものが失敗する**という挙動でした。

#### 検証結果記録欄

| 確認項目 | 結果 |
|---|---|
| LabCustomer_c の件数（オンプレと一致するか） | ☑一致（インポート成功） |
| LabSales_c の Orders 件数（オンプレと一致するか） | ☑不一致：0件（オンプレは2件）。Viewエラーでインポートがデータ投入前に中断したため |
| `vw_OrderWithCustomer` オブジェクト自体の有無 | ☐あり ☑なし（`SELECT * FROM sys.views WHERE name = 'vw_OrderWithCustomer'` が0件） |
| `vw_OrderWithCustomer` 実行結果 | 該当なし（オブジェクトが存在しないため実行不可） |

### STEP B6｜方式C用リソースの削除

検証結果を記録したら、方式D検証の前に削除します（無料オファーの重複取得を避けるため）。

```bash
az sql db delete --resource-group rg-sqldb-verify-lab --server sql-verify-target --name LabCustomer_c --yes
az sql db delete --resource-group rg-sqldb-verify-lab --server sql-verify-target --name LabSales_c --yes
```

---

## Part C｜方式D検証（Azure DMS + SHIR）

### STEP C1｜移行先 Azure SQL Database 再作成

Part Bと同様に、`LabCustomer_d` / `LabSales_d` を作成します（無料データベースオファーはこちらに付け替え可）。

### STEP C2｜DataMigration リソースプロバイダー登録

初回のみ必要です（登録済みならスキップ）。

```bash
az provider register --namespace Microsoft.DataMigration
az provider show --namespace Microsoft.DataMigration --query registrationState
```

`Registered` になるまで待ちます。

### STEP C3｜Azure DMS インスタンス作成

Portal →「Azure Database Migration Service」→「作成」。[02-sql-db-dms-offline.md](./02-sql-db-dms-offline.md) STEP 4 と同じ新UIの手順です。

| 項目 | 設定値 |
|---|---|
| ソースの種類 | SQL Server |
| ターゲットの種類 | Azure SQL Database |
| リソースグループ | `rg-sqldb-verify-lab` |
| リージョン | Japan East |

> **作成後、検証が終わり次第すぐ削除すること**（課金対象）。

### STEP C4｜SHIR を vm-onprem-sim にインストール・登録

個人検証のため、SQL Serverと同じVMにSHIRを同居させます（本番の03手順書では非推奨ですが、検証用途では問題ありません）。

```
https://aka.ms/sql-migration-shir-download
```

バージョン5.37以上を `vm-onprem-sim` にインストールし、DMSインスタンスの「統合ランタイム」画面で取得した認証キーで登録します。状態が「実行中」になれば完了です。

疎通確認：

```cmd
sqlcmd -S localhost -U sa -P （パスワード） -C -Q "SELECT @@VERSION"
```

### STEP C5｜移行プロジェクトを作成・実行

[02-sql-db-dms-offline.md](./02-sql-db-dms-offline.md) STEP 6 と同じ手順で、`LabCustomer` と `LabSales` を **両方選択**して一括移行します。

> **ソース接続のユーザーも `sa`**：DMSウィザードの「ソースの詳細」画面はSQL Server認証で接続するため、STEP A3で有効化した`sa`ユーザー（同じパスワード）を使います。「ソースSQL Serverへの接続」画面に証明書関連のオプション（暗号化・証明書を信頼する 等）が表示された場合は、SSMS・SqlPackageと同じ理由（VMの自己署名証明書）でオンにしてください。

- 「不足しているスキーマの移行」を **ON** にする
- ソース→ターゲットのマッピング：`LabCustomer → LabCustomer_d`、`LabSales → LabSales_d`

「移行の開始」をクリックします。

### STEP C6｜進捗を監視

DMSインスタンスの「移行の監視」画面でDB単位・テーブル単位の進捗を確認します。ラボ規模のデータなので数分で完了するはずです。

### STEP C7｜動作確認（検証ポイント③）

```sql
-- LabSales_d に接続して実行
SELECT * FROM dbo.Orders;

-- クロスDB参照Viewの移行結果を確認
SELECT * FROM dbo.vw_OrderWithCustomer;
```

> **実測結果**：SqlPackage方式と同じ`Msg 40515`相当のエラー（`Reference to database and/or server name in 'LabSales.dbo.Orders' is not supported in this version of SQL Server.`）で`vw_OrderWithCustomer`の作成が"Deployed failure"となりました。
> **方式Cとの決定的な違い**：SqlPackageはView失敗と同時にインポート全体（データ投入含む）が中断したのに対し、DMSは`dbo.Orders`のデータ移行を最後まで完走し、オンプレと同じ2件が投入されました。02-sql-db-dms-offline.mdの既知の制限事項にある「テーブル オブジェクトに問題がない限り、スキーマの移行でエラーが発生した場合でも、DMS はデータ移行フェーズに進みます」という記述通りの挙動です。**Viewだけが部分的に失敗し、テーブルデータは正常に移行される**という、方式Cより実用的な壊れ方をしています。

#### 検証結果記録欄

| 確認項目 | 結果 |
|---|---|
| LabCustomer_d の件数（オンプレと一致するか） | ☑一致：2件（初回はデータコピーフェーズが進行せず中断。原因はVM`Standard_B2s`がSHIR推奨最小スペック[4コア/8GB RAM]未満だったためと推定。リトライで成功。クロスDB参照Viewの検証とは無関係のインフラ制約） |
| LabSales_d の Orders 件数（オンプレと一致するか） | ☑一致：2件（Viewは失敗したがデータ移行は完走） |
| 移行ステータス（Succeeded / エラーの有無） | Deployed failure（`vw_OrderWithCustomer`のスキーマ展開のみ失敗、テーブルデータは移行済み） |
| `vw_OrderWithCustomer` オブジェクト自体の有無 | ☐あり ☑なし（デプロイエラーで作成自体が失敗） |
| `vw_OrderWithCustomer` 実行結果 | 該当なし（オブジェクトが存在しないため実行不可） |

### STEP C8｜方式D用リソースの削除

```bash
# DMSインスタンス削除（Portalから、または）
az dms delete --resource-group rg-sqldb-verify-lab --name （DMSインスタンス名） --yes
```

SHIRはVM上からアンインストール（VM自体を残す場合）。VMごと削除するなら不要です。

---

## 総合比較・考察

両方式を実施した後、以下の表を埋めて比較します。

| 観点 | 方式C（SqlPackage） | 方式D（DMS + SHIR） |
|---|---|---|
| 通常DB（LabCustomer）の移行 | ☑成功（件数一致） | ☑成功（件数一致。初回はVM`Standard_B2s`のスペック不足でデータコピーが停滞したが、原因はインフラ側でありDMSの挙動とは無関係） |
| クロスDB参照Viewを含むDB（LabSales）の移行そのもの | ☑失敗（View作成エラーと同時にインポート全体が中断し、`Orders`のデータも0件のまま） | **部分的成功**（Viewの作成のみ失敗。`Orders`テーブルのデータ移行は完走しオンプレと件数一致） |
| Viewオブジェクトの作成有無 | ☐あり ☑なし | ☐あり ☑なし |
| Viewクエリ実行時の挙動 | 該当なし（オブジェクト自体が存在せず実行不可） | 該当なし（オブジェクト自体が存在せず実行不可） |
| エラーが出たタイミング（移行時／クエリ実行時） | **移行時**（`SqlPackage /Action:Import`実行中、`SQL72014`/`Msg 40515`で`CREATE VIEW`が失敗し、データ投入前にインポート全体が中断） | **移行時**（スキーマ展開中に`Msg 40515`相当のエラーで`CREATE VIEW`のみ失敗。ただしテーブルのデータ移行フェーズは中断せず継続） |
| 個人的な所感・気づき | 失敗したオブジェクトが1つでもあるとインポート全体をロールバック/中断する「全か無か」の挙動。部分的に健全な`Orders`テーブルのデータすら移行されなかった。 | 「不足しているスキーマの移行でエラーが出てもデータ移行フェーズには進む」という設計（公式ドキュメント記載）の通り、Viewだけを切り離して他のオブジェクトを移行できた。エラーの根本原因（Azure SQL Databaseエンジンがクロスデータベース参照を拒否する）自体は方式Cと共通だが、複数テーブル・複数オブジェクトを含む実際の移行では、問題のあるオブジェクトだけ後から個別対応できる方式Dの方が実用的。 |

> クロスDB参照Viewが方式C・Dいずれでも正常に動かない場合、Azure SQL Databaseへの移行では「クロスDB参照を持つオブジェクトは移行前に設計変更が必要」という結論になります。代替案としては、Elastic Database Query（外部テーブル化）への置き換え、あるいはクロスDB参照が必要なワークロードは Azure SQL Managed Instance（[03-sql-mi-native-backup.md](./03-sql-mi-native-backup.md) / [04-sql-mi-dms-offline.md](./04-sql-mi-dms-offline.md)）を選ぶ、という判断が実務での落としどころになります。

---

## 全体クリーンアップ（最終後片付け）

検証がすべて終わったら、リソースグループごと削除するのが最も簡単で確実です。

```bash
az group delete --name rg-sqldb-verify-lab --yes --no-wait
```

削除されるリソースの確認：

| リソース | 削除方法 |
|---|---|
| VM（vm-onprem-sim）＋ディスク＋NIC＋Public IP | リソースグループ削除に含まれる |
| VNet | リソースグループ削除に含まれる |
| Azure SQL 論理サーバー・DB全て | リソースグループ削除に含まれる |
| Azure DMS インスタンス | Part C で削除済みでなければ含まれる |

> ⚠️ `az group delete` は不可逆な操作です。実行前に必要なログ・検証結果メモを別途保存してから実行してください。

個別に削除したい場合の代替コマンド：

```bash
az vm delete --resource-group rg-sqldb-verify-lab --name vm-onprem-sim --yes
az sql server delete --resource-group rg-sqldb-verify-lab --name sql-verify-target --yes
az network vnet delete --resource-group rg-sqldb-verify-lab --name vnet-verify-lab
```

---

## チェックリスト

### 構築（Part A）
- [ ] リソースグループ・VNet作成
- [ ] VM作成（SQL Server Developer Edition イメージ）
- [ ] NSGで自分のIPのみ許可（3389, 1433）
- [ ] LabCustomer / LabSales 作成、クロスDB参照View作成
- [ ] 互換性レベル100に設定
- [ ] 移行前件数を記録

### 方式C検証（Part B）
- [ ] Azure SQL Database（LabCustomer_c / LabSales_c）作成
- [ ] SqlPackageインストール
- [ ] エクスポート実行・結果記録（成功/失敗・エラー内容）
- [ ] インポート実行
- [ ] クロスDB Viewの動作確認・結果記録
- [ ] 方式C用DB削除

### 方式D検証（Part C）
- [ ] Azure SQL Database（LabCustomer_d / LabSales_d）作成
- [ ] Microsoft.DataMigration登録確認
- [ ] DMSインスタンス作成
- [ ] SHIRインストール・登録（VM同居）
- [ ] 移行プロジェクト実行（複数DB一括）
- [ ] クロスDB Viewの動作確認・結果記録
- [ ] DMS削除

### 総括・後片付け
- [ ] 総合比較表を記入
- [ ] 検証結果メモを別途保存
- [ ] リソースグループを削除（`az group delete`）
- [ ] Azureポータルで課金リソースが残っていないことを最終確認

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SqlPackage Export | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-export |
| SqlPackage Import | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-import |
| Azure SQL Database の Transact-SQL の相違点（クロスDB制約含む） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/transact-sql-tsql-differences-sql-server |
| Elastic Database Query 概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/elastic-query-overview |
| Azure SQL Database 無料オファー | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/free-offer |
| SQL Server Developer Edition の Azure VM イメージ | https://learn.microsoft.com/ja-jp/azure/azure-sql/virtual-machines/windows/create-sql-vm-portal |
| Azure Database Migration Service 概要 | https://learn.microsoft.com/ja-jp/azure/dms/dms-overview |
| セルフホステッド統合ランタイム（SHIR） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| Azure 無料アカウント | https://azure.microsoft.com/ja-jp/free/ |

---

*作成日：2026-08-06*
