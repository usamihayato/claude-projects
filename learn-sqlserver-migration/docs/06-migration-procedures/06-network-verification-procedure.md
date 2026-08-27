# DMS オフライン移行 通信要件 検証手順書
### Azure 検証環境（SHIR VM + Azure DMS）でオープン→クローズの2フェーズにより必要 FQDN を実測する

---

## 検証の目的

本番の SHIR は **ADF 用に構築済みのオンプレサーバ**に相乗りする想定です。
DMS がどの FQDN を実際に必要とするかを、Azure 検証環境で**2 フェーズ方式**で確定します。

```
フェーズ1｜オープン検証
  プロキシを「全許可 + ログ記録」にする
  → SHIR登録 ～ 移行完了まで通しで実行（＝インターネット開けた状態で成功する実績の再現）
  → ログから実際にアクセスされた全 FQDN を抽出する

フェーズ2｜クローズ検証
  プロキシをフェーズ1で抽出した FQDN だけに絞り込む
  → SHIR を再登録 ～ 移行を再実行
  → 同じ結果が再現できれば「そのリストで過不足なく動く」ことが証明される
```

> **フェーズ1の「オープン」の意味に注意**
> SHIR VM は NSG でインターネット直結を遮断したままです（STEP 4 参照）。
> 「オープン」とはプロキシ（Squid）側のホワイトリストを一時的に全許可にすることを指します。
> こうすることで「インターネットを開けた状態での成功」と同じ通信条件を保ちながら、
> **どの FQDN に実際にアクセスしたかをログとして残せます**。
> プロキシを介さず本当にインターネットへ直結してしまうと、通信先が記録できず検証になりません。

| # | 検証したいこと | 判定基準 |
|---|---|---|
| ① | フェーズ1で SHIR 登録〜移行が成功するか（実績の再現） | 登録「実行中」＋移行「完了」 |
| ② | フェーズ1で実際にアクセスされた FQDN は何か | access.log から全件抽出 |
| ③ | SQL Database の PE へ TCP 1433 で到達できるか | sqlcmd で接続できる |
| ④ | フェーズ2（②のリストのみ許可）で同じ結果が再現するか | 登録「実行中」＋移行「完了」、拒否ログなし |

> **この検証で分かること**：DMS が必要とする FQDN の**過不足ない具体的なリスト**
> **分からないこと**：本番の DNS 設計・ER 帯域・TLS 1.0（→ 後述の「検証環境と本番の差分」参照）

---

## 検証環境の構成

```
                    ┌──────────── VNet: 10.0.0.0/16 ────────────┐
                    │                                            │
  snet-source       │  ┌──────────────────┐                      │
  10.0.2.0/24       │  │ vm-source-sql    │ 移行元 SQL Server    │
                    │  │ Windows Server   │                      │
                    │  └────────▲─────────┘                      │
                    │           │ TCP 1433                       │
  snet-shir         │  ┌────────┴─────────┐                      │
  10.0.1.0/24       │  │ vm-shir          │ SHIR                 │
                    │  │ Windows Server   │                      │
                    │  └───┬──────────┬───┘                      │
                    │      │          │ TCP 1433（VNet内＝ER相当）│
                    │      │ 3128     ▼                          │
  snet-proxy        │  ┌───▼──────┐  ┌──────────────────┐        │
  10.0.4.0/24       │  │ vm-proxy │  │ PE (SQL Database)│        │
                    │  │ Squid    │  │ 10.0.3.x         │        │
                    │  └───┬──────┘  └────────┬─────────┘        │
                    └──────┼──────────────────┼──────────────────┘
                           │ TCP 443          │
                           ▼                  ▼
                    Azure DMS 制御プレーン   Azure SQL Database
                    Azure AD / Service Bus
```

### 本番環境との対応

| 本番 | 検証環境での代替 | 目的 |
|---|---|---|
| オンプレ SHIR サーバ | `vm-shir`（Windows Server VM） | SHIR の動作検証 |
| 社内プロキシ（FQDN ホワイトリスト） | `vm-proxy`（Squid） | **フェーズ1で全許可→ログ記録、フェーズ2で絞り込み** |
| ExpressRoute → Azure PE | VNet 内ルーティング | PE への 1433 到達性 |
| オンプレ SQL Server 2008 R2 | `vm-source-sql` | 移行元 |
| Azure SQL Database（本番） | Azure SQL Database（検証） | 移行先 |

> **Squid を使う理由**
> 本番の SHIR はプロキシを明示設定（`diahost.exe.config`）して通信します。
> Squid なら同じ構成を再現でき、かつ **access.log で通信先の FQDN を全て記録できます**。
> フェーズ1では全許可にしてログを取り、フェーズ2ではそのログから作った許可リストだけに絞る。
> この往復が本検証の核心です。

---

## 事前準備

| 項目 | 必要なもの |
|---|---|
| Azure サブスクリプション | 共同作成者以上の権限 |
| 作業端末 | Azure CLI または Azure Portal |
| （任意）本番プロキシの既存許可 FQDN リスト | あればフェーズ1で抽出した結果との**突き合わせ**に使える |

> 本手順はフェーズ1で必要 FQDN を実測するため、事前に本番のホワイトリストを入手できていなくても進められます。
> 入手できている場合は、フェーズ1の抽出結果と比較することで「ADF 許可分で足りるか／追加が要るか」も同時に判定できます。

---

## STEP 1｜リソースグループと VNet を作成

```bash
# 変数定義
RG="rg-dms-network-verify"
LOC="japaneast"
VNET="vnet-verify"

az group create --name $RG --location $LOC

az network vnet create \
  --resource-group $RG \
  --name $VNET \
  --address-prefix 10.0.0.0/16 \
  --subnet-name snet-shir \
  --subnet-prefix 10.0.1.0/24

az network vnet subnet create --resource-group $RG --vnet-name $VNET \
  --name snet-source --address-prefix 10.0.2.0/24

az network vnet subnet create --resource-group $RG --vnet-name $VNET \
  --name snet-pe --address-prefix 10.0.3.0/24

az network vnet subnet create --resource-group $RG --vnet-name $VNET \
  --name snet-proxy --address-prefix 10.0.4.0/24
```

### 1-2 Azure Bastion（Developer SKU）のデプロイ

各 VM は管理用のパブリック IP を持たせない構成にするため、踏み台として Bastion を使います。
Standard SKU は時間課金＋専用サブネット（`AzureBastionSubnet` /26 以上）が必要ですが、
**Developer SKU は無料・専用サブネット不要**なので検証用途に向いています。

> ⚠️ Developer SKU は 2026-08 時点で **Azure Portal からのみデプロイ可能**です
> （VM 作成後に手順を実施するため、このタイミングでは「後で使う」ことを把握しておくだけで OK です）。
> 実際のデプロイは STEP 2〜4 で VM を作成した後、以下の手順で行います。

**デプロイ手順（VM 作成後に実施）**

1. Azure Portal → 対象 VM（例：`vm-shir`）→「接続」→「Bastion」タブ
2. 「この仮想ネットワークに Bastion をデプロイする（無料の Developer SKU）」というリンクが表示される
3. クリックするだけで、`vnet-verify` に対して Developer SKU の Bastion が有効化される
4. 一度有効化すれば、**同じ VNet 内の他の VM（`vm-proxy`／`vm-source-sql`）でも同じ「接続」→「Bastion」タブから流用できる**

**Developer SKU の制約（再掲）**

| 制約 | 内容 |
|---|---|
| VNet ピアリング先への接続 | 不可（Bastion をデプロイした VNet 内のみ） |
| ネイティブクライアント（mstsc/ssh コマンド） | 非対応。ブラウザ経由のみ |
| 同時接続 | 複数セッション同時は非推奨 |

> 本検証の VNet（`vnet-verify`）は単体構成でピアリングを行わないため、上記制約は影響しません。

---

## STEP 2｜プロキシ VM（Squid）を構築

### 2-1 VM 作成

パブリック IP は付与しません（管理アクセスは Bastion 経由に統一するため）。

```bash
az vm create \
  --resource-group $RG \
  --name vm-proxy \
  --image Ubuntu2204 \
  --size Standard_B1s \
  --vnet-name $VNET \
  --subnet snet-proxy \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-address ""
```

### 2-2 Squid のインストール

Azure Portal → `vm-proxy` →「接続」→「Bastion」タブから SSH 接続し、ブラウザ上のターミナルで実行します。
（STEP 1-2 で Bastion を未デプロイの場合は、先にそちらを実施してください）

```bash
sudo apt update && sudo apt install -y squid
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak
```

### 2-3 フェーズ1用の設定（全許可＋ログ記録）

`/etc/squid/squid.conf` を以下の内容で作成します。
**この段階ではドメインを絞り込みません。** 目的は「何にアクセスしたか」を漏れなく記録することです。

```
# ===== フェーズ1: 全許可 + ログ記録 =====
http_port 3128

# 接続元（SHIR サブネット）
acl shir_net src 10.0.1.0/24

acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny CONNECT !SSL_ports
http_access allow shir_net
http_access deny all

# 通信先を漏れなく記録する
access_log /var/log/squid/access.log squid
```

```bash
sudo systemctl restart squid
sudo systemctl enable squid
```

### 2-4 ログ監視の準備

検証中は別ターミナルでログを流しておきます。

```bash
sudo tail -f /var/log/squid/access.log
```

> **ログの見方**
> - `TCP_TUNNEL/200` → 通過した通信（フェーズ1では基本的に全てこれになるはず）
> - `TCP_DENIED/403` → 拒否された通信（フェーズ1で出たら shir_net の設定ミスなどを疑う）
>
> フェーズ1のログが「実際に必要な FQDN の正解データ」になります。
> フェーズ2への絞り込みは STEP 9 で行います。

---

## STEP 3｜移行元 SQL Server VM を作成

```bash
az vm create \
  --resource-group $RG \
  --name vm-source-sql \
  --image MicrosoftSQLServer:sql2019-ws2022:sqldev-gen2:latest \
  --size Standard_B2s \
  --vnet-name $VNET \
  --subnet snet-source \
  --admin-username azureuser \
  --admin-password '（強いパスワード）' \
  --public-ip-address ""
```

> **サイズを `Standard_B2s`（バースト可能・2 vCPU/4GB）にしている理由**
> 通信要件の検証には性能は関係なく、テストデータも 3 行のみです。
> `Dsv3` 系の汎用 VM より安価なバースト可能シリーズで十分なため、コスト優先でこのサイズにしています。

---

> ⚠️ **SQL Server 2008 R2 は Marketplace に存在しません**
> 通信要件（ポート・FQDN）の検証には SQL Server のバージョンは影響しないため、
> 検証用途では 2019 で代替可能です。
> ただし **TLS 1.0 の挙動は再現できません**（後述の差分参照）。

### 検証用データベースの作成

Azure Portal → `vm-source-sql` →「接続」→「Bastion」タブから RDP 接続し、SSMS で実行します。

```sql
CREATE DATABASE TestDB1;
GO
USE TestDB1;
CREATE TABLE dbo.T1 (id INT IDENTITY PRIMARY KEY, val NVARCHAR(100));
INSERT INTO dbo.T1 (val) VALUES ('test1'), ('test2'), ('test3');
GO

-- 混合モード（SQL + Windows認証）を有効化（既定では Windows 認証のみ）
USE [master];
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2;
GO
```

レジストリの変更を反映させるため、SQL Server サービスを再起動します（`vm-source-sql` の PowerShell で実行）。

```powershell
Restart-Service MSSQLSERVER -Force
```

再起動後、SSMS で再接続し、混合モードが有効になったことを確認します。

```sql
-- 結果が 0 なら混合モード有効（1のままなら再起動できていない可能性）
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly');
```

混合モードを確認できたら、移行用ユーザーを作成します。

```sql
CREATE LOGIN migrateuser WITH PASSWORD = '（強いパスワード）';
USE TestDB1;
CREATE USER migrateuser FOR LOGIN migrateuser;
ALTER ROLE db_datareader ADD MEMBER migrateuser;
GO

-- DMS の公式最小要件：db_datareader に加えて VIEW ANY DEFINITION（サーバー権限）が必要
-- （参考: https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/database-migration-service）
GRANT VIEW ANY DEFINITION TO migrateuser;
GO
```

> SQL Server 構成マネージャーで **TCP/IP プロトコルを有効化**し、
> Windows ファイアウォールで **TCP 1433 の受信を許可**してください。
>
> ```powershell
> # TCP/IPが有効か確認（LISTENINGが出ればOK。出ない場合はSQL Server構成マネージャーで有効化しサービス再起動）
> netstat -an | findstr :1433
>
> # インバウンドルールを追加（SQL Serverのマーケットプレイスイメージには既定で入っていない）
> New-NetFirewallRule -DisplayName "SQL Server 1433" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
> ```
>
> ⚠️ `Get-NetFirewallRule -DisplayName "*SQL*"` で表示されるルールは既定では
> AppContainer（Rサービス/Pythonサービス用サンドボックス）の**アウトバウンド**ブロックルールのみで、
> **1433番へのインバウンド許可ルールは含まれていません**。上記コマンドで明示的に追加する必要があります。
>
> **本番適用時の確認事項**：本番の実機（現行のオンプレWindows Server／SQL Server 2008 R2）でも、
> 上記と同じ手順（`netstat`でのLISTENING確認・インバウンドルールの有無）を事前に確認すること。
> 検証環境（マーケットプレイスイメージ）で起きたのと同様に、1433のインバウンドルールが
> 既定で入っていない可能性がある。SHIRからの疎通を移行当日に初めて試すのではなく、
> 事前に本番機側でも `Test-NetConnection localhost -Port 1433` 等でLISTENING状態を確認しておく。

---

## STEP 4｜SHIR VM を作成（インターネット直結を遮断）

### 4-1 VM 作成

```bash
az vm create \
  --resource-group $RG \
  --name vm-shir \
  --image Win2022Datacenter \
  --size Standard_B2ms \
  --vnet-name $VNET \
  --subnet snet-shir \
  --admin-username azureuser \
  --admin-password '（強いパスワード）' \
  --public-ip-address ""
```

> **サイズを `Standard_B2ms`（バースト可能・2 vCPU/8GB）にしている理由**
> SHIR の公式推奨（2 コア／8GB メモリ）は満たしつつ、`Dsv3` 系の汎用 VM より安価な
> バースト可能シリーズを選んでいます。通信要件の検証自体には性能は影響しません。

### 4-2 NSG でインターネット直結を遮断（本番の閉域環境を再現）

これを設定しないと SHIR が Azure に直接出てしまい、**検証の意味がなくなります**。

```bash
# NSG 作成
az network nsg create --resource-group $RG --name nsg-shir

# ① プロキシ VM への 3128 のみ許可
az network nsg rule create --resource-group $RG --nsg-name nsg-shir \
  --name allow-proxy --priority 100 --direction Outbound --access Allow \
  --protocol Tcp --destination-address-prefixes 10.0.4.0/24 --destination-port-ranges 3128

# ② VNet 内通信を許可（PE への 1433・移行元 SQL への 1433 ＝ ER 相当）
az network nsg rule create --resource-group $RG --nsg-name nsg-shir \
  --name allow-vnet --priority 110 --direction Outbound --access Allow \
  --protocol Tcp --destination-address-prefixes VirtualNetwork --destination-port-ranges '*'

# ③ その他のインターネット向け通信を全遮断
az network nsg rule create --resource-group $RG --nsg-name nsg-shir \
  --name deny-internet --priority 4000 --direction Outbound --access Deny \
  --protocol '*' --destination-address-prefixes Internet --destination-port-ranges '*'

# サブネットに適用
az network vnet subnet update --resource-group $RG --vnet-name $VNET \
  --name snet-shir --network-security-group nsg-shir
```

### 4-3 遮断できていることを確認

Azure Portal → `vm-shir` →「接続」→「Bastion」タブから RDP 接続し、PowerShell で実行します。

```powershell
# 直接インターネットに出られないこと（失敗すれば OK）
Test-NetConnection login.microsoftonline.com -Port 443

# プロキシには到達できること（成功すれば OK）
Test-NetConnection 10.0.4.4 -Port 3128
```

> 1 つ目が **失敗**、2 つ目が **成功** なら、本番と同じ閉域状態が再現できています。

---

## STEP 5｜Azure SQL Database と Private Endpoint を作成

### 5-1 論理サーバーとデータベース

```bash
SQLSERVER="sqlsv-verify-$RANDOM"

az sql server create \
  --resource-group $RG \
  --name $SQLSERVER \
  --location $LOC \
  --admin-user sqladminuser \
  --admin-password '（強いパスワード）'

az sql db create \
  --resource-group $RG \
  --server $SQLSERVER \
  --name TestDB1 \
  --edition GeneralPurpose \
  --family Gen5 \
  --capacity 1 \
  --compute-model Serverless \
  --min-capacity 0.5 \
  --auto-pause-delay 60
```

> **Serverless（自動一時停止）にしている理由**
> 検証は数日にわたって断続的に実行するため、常時稼働の GP_Gen5_2（Provisioned）だと
> アイドル時間にも課金が発生します。Serverless なら 60 分未使用で自動一時停止し、
> 次に接続があると自動再開します（再開時に数十秒〜1分程度の遅延あり）。
> 通信要件の検証自体には影響しません。

### 5-2 パブリックアクセスを無効化（本番と同条件）

```bash
az sql server update --resource-group $RG --name $SQLSERVER \
  --enable-public-network false
```

### 5-3 Private Endpoint の作成

```bash
# PE 作成
az network private-endpoint create \
  --resource-group $RG \
  --name pe-sqldb \
  --vnet-name $VNET --subnet snet-pe \
  --private-connection-resource-id $(az sql server show -g $RG -n $SQLSERVER --query id -o tsv) \
  --group-id sqlServer \
  --connection-name pe-conn-sqldb

# Private DNS ゾーンの作成と VNet リンク
az network private-dns zone create --resource-group $RG \
  --name "privatelink.database.windows.net"

az network private-dns link vnet create --resource-group $RG \
  --zone-name "privatelink.database.windows.net" \
  --name link-vnet --virtual-network $VNET --registration-enabled false

# PE と DNS ゾーンの紐付け
az network private-endpoint dns-zone-group create \
  --resource-group $RG --endpoint-name pe-sqldb \
  --name zg-sqldb --private-dns-zone "privatelink.database.windows.net" \
  --zone-name sqlserver
```

### 5-4 移行用ユーザーの作成

パブリックアクセスを無効にしたため、VNet内から接続する必要があります。
**本番方針（SHIRに SQL クライアントツールを入れない）に合わせ、SSMS/sqlcmd は使いません。**
`vm-shir` の PowerShell から、Windows 標準の .NET Framework に含まれる
`System.Data.SqlClient`（追加インストール不要）を直接呼び出して実行します。

**事前確認：`System.Data.SqlClient` が利用できるか**

```powershell
try {
    $conn = New-Object System.Data.SqlClient.SqlConnection
    Write-Host "OK: System.Data.SqlClient は利用可能です（.NET Framework $([System.Environment]::Version)）"
} catch {
    Write-Host "NG: System.Data.SqlClient が見つかりません - $_"
}
```

> Windows Server 2016 以降なら .NET Framework 4.6 以上が標準搭載されており、通常はこれで確実に存在します。
> バージョンを直接確認したい場合は次を実行します（`461808` 以上なら .NET Framework 4.7.2 以上）。
>
> ```powershell
> Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release
> ```
>
> Serverless（STEP 5-1）は作成直後・アイドル後は一時停止状態のため、
> 最初の接続で自動再開が走り数十秒〜1分ほど待たされることがあります。
> タイムアウトした場合は再接続すれば通常つながります。

```powershell
$connStr = "Server=tcp:（論理サーバー名）.database.windows.net,1433;Database=master;User ID=sqladminuser;Password=（強いパスワード）;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

> `dmsuser`に必要な権限は **3階層**あります。1つでも欠けるとDMSの各フェーズ（登録テスト／
> スキーマ移行／データ移行）のどこかで失敗するため、まとめて設定します。
>
> | 階層 | 必要な権限 | 目的 |
> |---|---|---|
> | サーバーレベル | `##MS_DefinitionReader##` `##MS_DatabaseConnector##` `##MS_DatabaseManager##` `##MS_LoginManager##` | ノード登録・`master`接続・カタログ参照 |
> | `master`データベース内 | `dbmanager` `loginmanager`ロール | DB作成・ログイン管理（公式サンプルスクリプト通り） |
> | **ターゲットDB（`TestDB1`）内** | **`db_owner`** | スキーマ/データのデプロイ実行 |
>
> ⚠️ 3つ目（ターゲットDBでの`db_owner`）が漏れやすい理由：公式ドキュメントのサンプルスクリプトは
> 「DMS自身がターゲットDBを新規作成する」前提のため、`##MS_DatabaseManager##`メンバーが自動的に
> 作成したDBの所有者(dbo)になり、明示的な`db_owner`付与が書かれていません。しかし本手順のように
> **`TestDB1`をSTEP 5-1で事前に作成している場合**、`dmsuser`が作ったDBではないため自動付与されず、
> 明示的に`ALTER ROLE db_owner ADD MEMBER`が必要になります。

**① `master`データベースに対して実行**（`Database=master`のまま）

```powershell
$sql = @"
CREATE LOGIN dmsuser WITH PASSWORD = '（強いパスワード）';
ALTER SERVER ROLE ##MS_DefinitionReader##  ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_DatabaseManager##   ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_LoginManager##      ADD MEMBER [dmsuser];
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'dmsuser')
    CREATE USER dmsuser FOR LOGIN dmsuser;
IF IS_ROLEMEMBER('dbmanager', 'dmsuser') = 0
    EXEC sp_addrolemember 'dbmanager', 'dmsuser';
IF IS_ROLEMEMBER('loginmanager', 'dmsuser') = 0
    EXEC sp_addrolemember 'loginmanager', 'dmsuser';
"@

$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = $sql
$cmd.ExecuteNonQuery()
$conn.Close()
```

> `CREATE LOGIN`が既に存在する場合はエラーになるので、初回以降の再実行時はその行を削除してください。
> `IF NOT EXISTS`/`IS_ROLEMEMBER`のガードを付けているため、②以降の行は何度再実行しても安全です。

**② ターゲットDB（`TestDB1`）に対して実行**（`$connStr`の`Database=master`を`Database=TestDB1`に変更）

```powershell
$connStr = "Server=tcp:（論理サーバー名）.database.windows.net,1433;Database=TestDB1;User ID=sqladminuser;Password=（強いパスワード）;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

$sql = @"
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'dmsuser')
    CREATE USER dmsuser FOR LOGIN dmsuser;
ALTER ROLE db_owner ADD MEMBER dmsuser;
"@

$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = $sql
$cmd.ExecuteNonQuery()
$conn.Close()
```

> 接続に失敗する場合、Serverless の自動再開待ちの可能性があるので数十秒〜1分後に再実行してください。
> `sqladminuser` は STEP 5-1 で作成した論理サーバーの管理者アカウントです。
>
> **戻り値 `-1` について**：`ExecuteNonQuery()` は影響を受けた行数を返しますが、
> DDL 文は行を返さないため `-1` が正常な結果です。エラーではありません。

作成できたか確認する場合は、以下を実行します。

```powershell
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT name FROM sys.sql_logins WHERE name = 'dmsuser'"
$reader = $cmd.ExecuteReader()
while ($reader.Read()) { Write-Host $reader["name"] }
$conn.Close()
```

`dmsuser` が表示されれば作成済みです。

---

## STEP 6｜Azure DMS を作成

```bash
# リソースプロバイダー登録（初回のみ）
az provider register --namespace Microsoft.DataMigration
```

その後 Azure Portal で作成します。

1. 「Azure Database Migration Service」→「作成」
2. 設定値：

| 項目 | 必須/任意 | 検証での設定値 | 本番での考慮点 |
|---|---|---|---|
| サブスクリプション | 必須 | 検証用サブスクリプション | 本番用サブスクリプションを選択（検証と分けるのが一般的） |
| リソースグループ | 必須 | `rg-dms-network-verify` | 移行完了後にDMSインスタンス自体は不要になるため、削除しやすいよう専用のRGに分けておくと後片付けが楽 |
| 移行サービス名 | 必須（一意な名前） | 任意（例：`dms-verify`） | 命名規則に従う。他の値と違い変更不可なので付け直しは再作成が必要 |
| リージョン | 必須 | Japan East | **移行先の Azure SQL Database と同じリージョンを推奨**（DMSのコントロールプレーンとターゲット間の通信レイテンシを避けるため） |

> ソース：SQL Server／ターゲット：Azure SQL Database（オフライン）を選ぶ現行のポータル画面では、
> サービスモードや価格レベル（SKU）の選択項目自体が表示されません（無料・固定構成）。

---

## STEP 7｜フェーズ1：SHIR のインストールとプロキシ設定

### 7-1 SHIR のインストール

> ⚠️ **Bastion Developer SKU はファイル転送に対応していません**（ブラウザ経由の RDP/SSH のみ）。
> 作業端末からインストーラーをコピーする方法は使えないため、
> **VM 上から Squid プロキシ経由で直接ダウンロード**します。
> Squid はこの時点でフェーズ1（全許可）のため、`download.microsoft.com` 宛の通信も通過します。

Azure Portal → `vm-shir` →「接続」→「Bastion」タブから RDP 接続し、PowerShell で実行します。

```powershell
$proxy = "http://10.0.4.4:3128"
Invoke-WebRequest `
  -Uri "https://download.microsoft.com/download/E/4/7/E4771905-1079-445B-8BF9-8A1A075D8A10/IntegrationRuntime_5.<最新パッチ番号>.msi" `
  -Proxy $proxy `
  -OutFile "C:\Temp\IntegrationRuntime.msi"
```

> ⚠️ **ダウンロード URL は変わる可能性があります**
> 上記 URL は例です。実際の最新版 URL は作業端末のブラウザで
> https://www.microsoft.com/download/details.aspx?id=39717 を開き、
> 「ダウンロード」ボタンの実リンク（.msi の直接 URL）をコピーして使ってください。
> バージョン **5.37 以上** を使用します。

### 7-2 プロキシ設定

> ⚠️ **`diahost.exe.config` と `diawp.exe.config` の両方を編集する必要があります。**
> 公式ドキュメントも「両方を忘れずに更新してください」と明記しています。
> 片方だけだと、プロセスによってはプロキシ未設定＝直結を試みてしまい、
> NSGの`deny-internet`で失敗する原因になります。
>
> **2つのファイルの役割**
>
> | ファイル | 対応プロセス | 役割 |
> |---|---|---|
> | `diahost.exe.config` | `diahost.exe`（Windowsサービス `DIAHostService` の実体） | ノード登録・Azure Relayとの制御チャネル維持・ハートビート/状態報告 |
> | `diawp.exe.config` | `diawp.exe`（Worker Process） | `diahost`から起動され、実際のコピー処理（移行タスクの実行・対話型オーサリングの接続テスト等）を実行 |
>
> **片方だけ設定した場合の症状の違い**
>
> - `diahost.exe.config`だけ設定 → **登録自体は成功する**が、実際にタスクを実行するワーカープロセスが直結を試みて失敗。「登録済み・実行中に見えるのに移行やテスト接続だけ失敗/ハングする」という切り分けにくい形で出やすい
> - `diawp.exe.config`だけ設定 → **登録自体が失敗する**。後述のトラブルシューティングにある「Disconnected/Connecting状態が続く」「Unable to connect to the remote server」に該当し、比較的すぐ気づける
>
> つまり `diawp.exe.config` の設定漏れの方が発見しづらいため、両方揃えて編集することが重要です。

以下の2ファイルを**両方とも**同じ内容で編集します。

- `C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe.config`
- `C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diawp.exe.config`

```xml
<system.net>
  <defaultProxy enabled="true" useDefaultCredentials="false">
    <proxy
      usesystemdefault="false"
      proxyaddress="http://10.0.4.4:3128"
      bypassonlocal="true"
    />
  </defaultProxy>
</system.net>
```

> **移行元SQL Server（1433）やPE（1433）への通信にバイパス指定は不要**
> `<defaultProxy>`はHTTP(S)通信（`HttpWebRequest`/`HttpClient`系）にしか効かず、
> SQL Serverへの接続（`SqlClient`によるTDSプロトコル）は生のTCPソケット接続のため、
> **この設定を最初から一切参照しません**。実際、.NETの`SqlClient`にはHTTPプロキシ経由でSQL接続する機能自体が存在せず、
> [dotnet/SqlClientのIssue #315](https://github.com/dotnet/SqlClient/issues/315)でも未実装の機能要望として上がっている状態です。
> `bypassonlocal="true"`は「ドットを含まない単純なホスト名やループバック」が対象で、`10.0.2.4`や`10.0.3.x`のような
> IPアドレス宛の通信とは無関係です。1433の通信がプロキシを介さず届くのは、バイパス設定によるものではなく、
> NSGの`allow-vnet`ルール（VNet内は全ポート許可）による直接到達性によるものです。

編集後、サービスを再起動します。

```powershell
Restart-Service DIAHostService
```

> この時点で Squid はフェーズ1（全許可）のため、SHIR からのアクセスは全て通過します。
> 「NSG でインターネット直結を遮断しつつ、プロキシ経由なら何でも通る」＝
> これまで確認できていた「インターネットを開けた状態での成功」と同じ通信条件です。

---

## STEP 8｜フェーズ1：登録・移行を通しで実行し、必要 FQDN を確定

### 8-1 登録キーの取得と登録

1. Portal → DMS インスタンス → 「統合ランタイム」→ 認証キー1 をコピー
2. `Microsoft Integration Runtime Configuration Manager` を起動
3. キーを貼り付けて「登録」
4. 状態が「実行中」になることを確認

> **「イントラネットからのリモートアクセスを有効にする」チェックボックスについて**
> **チェックしない（無効のまま）で進めます。** これは同じネットワーク内の別マシンから
> `New-AzDataFactoryV2LinkedServiceEncryptedCredential` で資格情報をリモートプッシュしたり、
> 複数ノードでの高可用性（HA）クラスタを組む際に使う機能で、有効にするとローカルにポート8060
> （既定）で待ち受けを開始します（＝インバウンド関連の話で、これまでのプロキシ/NSGの
> アウトバウンド制御とは無関係）。
>
> 今回は単一ノード・資格情報はSTEP 8-4のDMS移行プロジェクト作成ウィザードで直接入力する方式のため不要です。
> なおSHIRセットアップ v3.3以降はインストーラーの既定でこの機能は無効化されています。

### 8-2 サービス URL の確認

1. 同 Configuration Manager の「診断」タブ →「接続のテスト」を実行
2. 同画面の **「サービス URL」** を開く（DMS インスタンス固有のエンドポイントが一覧表示される）

### 8-3 SQL Database PE への疎通確認（フェーズ1のうちに実施）

`vm-shir` の PowerShell / コマンドプロンプトで実行します。

```powershell
# DNS解決の確認（期待値: 10.0.3.x が返ること）
nslookup （論理サーバー名）.database.windows.net
nslookup 10.0.2.4  # 移行元SQL Server（名前解決不要ならスキップ可）

# ポート疎通の確認
Test-NetConnection （論理サーバー名）.database.windows.net -Port 1433
Test-NetConnection 10.0.2.4 -Port 1433
```

> **本番の SHIR には SQL クライアントツール（sqlcmd / SSMS）を入れない前提**のため、
> ここでは DNS 解決とポート疎通（ネットワーク層）までを `vm-shir` から確認します。
> **SQL 認証が実際に通るか**（ユーザー名・パスワードでログインできるか）は、
> STEP 8-4 で DMS の移行プロジェクト作成ウィザードにソース/ターゲットの接続情報を入力した際に、
> DMS が SHIR 経由で内部的に検証します。ここで失敗する場合、
> 本 STEP でネットワーク層（DNS・ポート）が OK であれば、原因は認証情報側に絞り込めます。

### 8-4 移行を最後まで実行する

1. Portal → DMS インスタンス → 「移行プロジェクトの新規作成」
2. ソース：`vm-source-sql`（10.0.2.4）／SQL 認証／`migrateuser`
3. ターゲット：`（論理サーバー名）.database.windows.net`／`dmsuser`
4. `TestDB1` を選択してマッピング
5. スキーマ移行 ✅ ／ データ移行 ✅
   - 「不足しているスキーマの移行」のオブジェクト種別一覧が表示されたら、**「Users」「Roles」のチェックを外す**
     （外さないと、ソース側専用の`migrateuser`をターゲットにも複製しようとして下記のようなエラーになる。
     データ移行自体は成功するため実害はないが、ログが汚れるため最初から対象外にしておくのが無難）
6. 「移行の開始」

```text
Deployed failure: Cannot alter the role 'db_datareader', because it does not exist
or you do not have permission. Object element: [db_datareader] ADD MEMBER [migrateuser].

Deployed failure: Cannot find the user 'dbo', because it does not exist or you do
not have permission. Object element: [migrateuser].
```

```sql
-- 移行先の Azure SQL Database で実行（3 件返れば成功）
SELECT COUNT(*) FROM dbo.T1;
```

### 8-5 実際にアクセスされた FQDN を確定する

登録〜移行が完走したら、Squid のログから通信先 FQDN を**全て**抽出します。

```bash
# 実際にアクセスされた FQDN の一覧（登録時〜移行完了時までの累積）
sudo awk '{print $7}' /var/log/squid/access.log | cut -d: -f1 | sort -u
```

> これが **「DMS のオフライン移行に実際に必要な FQDN の一覧」** です。
> STEP 11 の記録シートに書き写してください。
> （任意）本番のADF許可リストを入手済みなら、ここで突き合わせて過不足を確認できます。
>
> ⚠️ **`error`という行が出たら、それはFQDNではなくログのパース artifact です。**
> `Test-NetConnection`のようにTCP接続だけしてHTTPリクエストを送らない通信は、
> Squidのログに`error:transaction-end-before-headers`のような形で記録されます。
> これを`cut -d: -f1`で切ると`error`だけが残ってしまうため、リストからは除外してください。
>
> また `download.microsoft.com` はSHIRのMSIダウンロード・自動更新用で、**移行の実行自体には不要**です
> （運用上は許可推奨ですが、フェーズ2で「移行に必須か」だけを見るなら除外して試すこともできます）。

### 公式のSHIRネットワーク要件との差分

実測結果を、[公式のセルフホステッドIRネットワーク要件](https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime#ports-and-firewalls)と突き合わせた結果、**追加で必要なFQDNはありませんでした**（公式の一般的な要件表の範囲内）。

| 公式の要件（企業ファイアウォールレベル） | 本検証の実測結果 | 判定 |
|---|---|---|
| `*.servicebus.windows.net`（443） | 実測あり（複数の`g0`〜`g14`系ノード） | ✅ 一致 |
| `*.frontend.clouddatahub.net`（443） | 実測あり | ✅ 一致 |
| `download.microsoft.com`（443、自動更新無効なら不要） | 実測あり（SHIRインストール時） | ✅ 一致 |
| キーボールトURL（443、Key Vault使用時のみ） | 未使用（資格情報はローカル保存方式） | ✅ 該当なし |
| `*.core.windows.net`（443、ステージングコピー使用時） | 未使用 | ✅ 該当なし |
| `*.database.windows.net`（1433、SQL DB/Synapseとの間でコピーする場合） | Squidログには**現れない** | ⚠️ 下記参照 |

> **唯一の注意点：`*.database.windows.net:1433`はプロキシの話ではありません。**
> SQL Server接続（`SqlClient`のTDSプロトコル）は`<defaultProxy>`を経由しないため、
> Squidのログには一切記録されません（前述の通り）。公式要件表では他のFQDNと同列に
> 記載されていますが、実態は「プロキシの許可リストに入れるもの」ではなく
> 「**プロキシとは別に、NSG/ExpressRoute/ファイアウォールで直接到達性を確保すべきもの**」です。
> 本番申請時は、443系（プロキシの許可リスト）と`*.database.windows.net:1433`
> （ファイアウォール/ルーティング側の直接許可）を分けて依頼する必要があります。

---

## STEP 9｜フェーズ2：Squid をフェーズ1で確定した FQDN だけに絞り込む

STEP 8-5 で確定したリストだけを許可するよう、Squid の設定を書き換えます。

```
# ===== フェーズ2: 絞り込み後の許可リスト =====
http_port 3128

acl shir_net src 10.0.1.0/24

# ▼▼▼ STEP 8-5 で確定した FQDN（本検証ではワイルドカードで許可） ▼▼▼
acl dms_required dstdomain .servicebus.windows.net
acl dms_required dstdomain .frontend.clouddatahub.net
# `error`（ログのパースartifact）は除外。download.microsoft.comは運用上許可推奨（任意）
# ▲▲▲

acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny CONNECT !SSL_ports
http_access allow shir_net dms_required
http_access deny all

access_log /var/log/squid/access.log squid
```

```bash
sudo systemctl restart squid
```

> ログを引き継ぎたくない場合は `sudo truncate -s 0 /var/log/squid/access.log` で一度クリアしておくと、
> フェーズ2の結果だけを見やすくできます。

---

## STEP 10｜フェーズ2：SHIR を再登録し、移行を再実行して過不足を確認

### 10-1 SHIR の再登録

プロキシ設定（`diahost.exe.config`）は STEP 7-2 のまま変更不要です。Squid 側を絞ったため、
サービス再起動後に改めて疎通・登録状態を確認します。

```powershell
Restart-Service DIAHostService
```

`Microsoft Integration Runtime Configuration Manager` の「診断」タブで「接続のテスト」を再実行し、
全項目が成功することを確認します。

### 10-2 移行を再実行する

STEP 8-4 と同じ手順で、**別のターゲット DB（`TestDB2`）** に対して移行を実行します。
同じ `TestDB1` を使い回すと結果の切り分けが難しくなるため、フェーズ2専用に新規作成しておくと明確です。

```bash
az sql db create --resource-group $RG --server $SQLSERVER --name TestDB2 \
  --edition GeneralPurpose --family Gen5 --capacity 1 \
  --compute-model Serverless --min-capacity 0.5 --auto-pause-delay 60
```

1. Portal → DMS インスタンス → 「移行プロジェクトの新規作成」
2. ソース：`vm-source-sql`（10.0.2.4）
3. ターゲット：`（論理サーバー名）.database.windows.net` の `TestDB2`
4. 「移行の開始」

```sql
-- 移行先 TestDB2 で実行（3 件返れば成功）
SELECT COUNT(*) FROM dbo.T1;
```

### 10-3 判定

```bash
# フェーズ2で拒否が出ていないか確認
sudo grep TCP_DENIED /var/log/squid/access.log
```

| 結果 | 意味 | 対応 |
|---|---|---|
| 登録「実行中」＋移行「完了」＋拒否ログなし | **絞り込んだリストで過不足なく動作する** | ✅ このリストを申請すればよい |
| `TCP_DENIED` が出た | フェーズ1で拾いきれなかった FQDN がある（時限的な通信など） | 拒否された FQDN を acl に追加 → 再起動 → 再実行 |
| 登録・移行自体が失敗した | ネットワーク以外の要因の可能性 | プロキシ設定・PE疎通を STEP 8-3 の内容で再確認 |

> フェーズ1は1回の実行で全通信パターンを拾いきれない場合があります
> （初回のみ発生する証明書検証や、時間経過後にだけ発生する通信など）。
> フェーズ2で拒否が出ても異常ではなく、**それこそがフェーズ2を行う意味**です。
> 出なくなるまで追加→再実行を繰り返し、最終的なリストを確定させてください。

---

## STEP 10.5｜証跡（ログ）の持ち出し

Bastion Developer SKU はファイル転送に対応していないため、`.evtx`や`.log`ファイルをそのまま
ダウンロードすることはできません。**テキストのコピー＆ペースト**（Bastionの全SKUで既定有効）を使って、
必要な内容をテキストとして抜き出します。

### vm-shir のイベントビューアーログ

`vm-shir` の PowerShell で実行し、出力されたテキストを選択して `Ctrl+C` → ローカル側で `Ctrl+V` します。

```powershell
Get-WinEvent -LogName "Microsoft Integration Runtime/Admin" -MaxEvents 50 |
    Format-List TimeCreated, LevelDisplayName, Message |
    Out-String
```

> エラーだけに絞りたい場合は `Where-Object {$_.LevelDisplayName -eq "Error"}` を挟みます。

### vm-proxy の Squid ログ

`vm-proxy` の Bastion SSH セッションで実行します。

```bash
# 記録シート（STEP 11）用：確定したFQDN一覧だけを抜き出す（STEP 8-5と同じコマンド）
sudo awk '{print $7}' /var/log/squid/access.log | cut -d: -f1 | sort -u

# 生ログそのものを見たい場合
cat /var/log/squid/access.log
```

表示されたテキストを選択して `Ctrl+C` → ローカル側で `Ctrl+V` します。
ブラウザがClipboard API非対応の場合は、Bastionセッション画面の `>>`（二重矢印アイコン）から
クリップボードパレットを開いて操作してください。

> ログが長くて画面に収まらない場合は、`sudo tail -n 200 /var/log/squid/access.log` のように
> 件数を絞ってから同様にコピーしてください。

---

## STEP 11｜検証結果の記録シート

検証しながら以下を埋めてください。そのまま申請資料になります。

### フェーズ1で確定した必要 FQDN（＝申請リストの元データ）

| # | FQDN | ポート | 用途（推定） | 本番 ADF で許可済みか |
|---|---|---|---|---|
| 1 | | 443 | | ✅ / ❌ / 未確認 |
| 2 | | 443 | | |
| 3 | | 443 | | |
| 4 | | 443 | | |
| 5 | | 443 | | |

> 「本番 ADF で許可済みか」列は、本番のホワイトリストを入手できている場合のみ埋めます。
> ❌ が付いた行が「DMS 用に新規で申請すべき FQDN」です。

### フェーズ2の結果（絞り込みリストの妥当性）

| 項目 | 結果 |
|---|---|
| 再登録が「実行中」になったか | ☐ なった ☐ ならなかった |
| 移行（TestDB2）が「完了」したか | ☐ 完了 ☐ 失敗 |
| フェーズ2実行中に TCP_DENIED が出たか | ☐ 出た（右に追記）☐ 出なかった |
| 追加で許可した FQDN（出た場合） | |
| 最終的に確定した FQDN 数 | 件 |

### ポート要件

| 通信 | ポート | 経路 | 疎通結果 |
|---|---|---|---|
| SHIR → プロキシ | 3128 | — | ☐ OK ☐ NG |
| SHIR → 移行元 SQL Server | 1433 | 社内 NW | ☐ OK ☐ NG |
| SHIR → SQL Database PE | 1433 | ER | ☐ OK ☐ NG |

### 総合判定

| 検証項目 | 結果 |
|---|---|
| ① フェーズ1（オープン）で登録〜移行が成功したか | ☐ 成功 ☐ 失敗 |
| ② フェーズ1のログから必要 FQDN を確定できたか | ☐ できた（件） |
| ③ PE への 1433 が通ったか | ☐ 通った ☐ 要 FW 申請 |
| ④ フェーズ2（絞り込み後）で同じ結果が再現したか | ☐ 再現した ☐ 追加が必要だった |

---

## STEP 12｜後片付け

### 12-1 自動シャットダウンの設定（推奨・検証中のコスト削減）

VM の消し忘れによる課金を防ぐため、各 VM 作成後に自動シャットダウンを設定しておきます
（Azure SQL Database は STEP 5-1／STEP 10-2 で Serverless にしているため未使用時は自動一時停止し、
この設定は不要です）。

```bash
# 例：日本時間 20:00 に自動シャットダウン（3台とも同様に設定）
az vm auto-shutdown --resource-group $RG --name vm-shir       --time 2000 --timezone "Tokyo Standard Time"
az vm auto-shutdown --resource-group $RG --name vm-source-sql --time 2000 --timezone "Tokyo Standard Time"
az vm auto-shutdown --resource-group $RG --name vm-proxy      --time 2000 --timezone "Tokyo Standard Time"
```

> 翌日の検証再開時は Azure Portal または `az vm start` で起動してください。
> 自動シャットダウンは「割り当て解除（deallocate）」相当のため、停止中は VM 分の課金は発生しません。

### 12-2 検証完了後の削除

検証完了後、**リソースグループごと削除**します。

```bash
az group delete --name $RG --yes --no-wait
```

### 課金対象リソース

| リソース | 課金 |
|---|---|
| vm-shir（B2ms・バースト可能） | 稼働時間課金（D2s_v3 比で低コスト。自動シャットダウン推奨） |
| vm-source-sql（B2s・バースト可能・SQL Developer） | VM 分のみ（Developer エディションのライセンスは無償。自動シャットダウン推奨） |
| vm-proxy（B1s） | 稼働時間課金（少額。自動シャットダウン推奨） |
| Azure SQL Database（GP Serverless・1 vCore） | 使用量課金＋60分未使用で自動一時停止（アイドル時はほぼ無課金） |
| Azure DMS（Standard） | Standard SKU は課金なし |
| Private Endpoint | 時間課金＋データ処理課金（少額） |
| Azure Bastion（Developer SKU） | **無料** |

> 検証は数日で終わる想定です。VM は自動シャットダウンを設定していても、
> **リソースグループ自体は残っているとその他の少額課金（PE 等）が積み上がる**ため、
> 検証が完全に終わったら STEP 12-2 で削除してください。

---

## ⚠️ 検証環境と本番の差分（重要）

**この検証で確認できないもの**を明示します。本番適用前に別途検討してください。

| 項目 | 検証環境 | 本番 | 影響 |
|---|---|---|---|
| **DNS 解決** | Private DNS ゾーンが自動で解決 | オンプレ DNS → 条件付きフォワーダー → DNS Private Resolver が必要 | **本検証では DNS 設計を検証できない**。別途確認が必要 |
| **TLS 1.0** | SQL Server 2019（TLS 1.2） | SQL Server 2008 R2（TLS 1.0） | SHIR → 移行元の TLS 挙動は再現されない |
| **プロキシの TLS 傍受** | Squid は素通し（CONNECT のみ） | 社内プロキシが SSL Bump している可能性 | 傍受環境では SHIR が証明書エラーになる場合あり。**本番プロキシの方式を要確認** |
| **プロキシ認証** | 認証なし | 社内プロキシは認証ありの可能性 | 認証ありの場合 `diahost.exe.config` に資格情報の設定が追加で必要 |
| **回線帯域** | Azure 内部（広帯域） | ExpressRoute の契約帯域 | 2TB の所要時間は本検証では測れない |
| **SHIR の同居** | 新規 VM に単独インストール | ADF 用 SHIR が稼働中 | **1 台 1 インスタンス制約**は別途対処が必要 |

> **特に「プロキシの TLS 傍受・認証の有無」は本番プロキシの仕様を先に確認してください。**
> ここが異なると、検証で通っても本番で通らないケースが起こり得ます。

---

## チェックリスト

| 項目 | 確認 |
|---|---|
| Azure Bastion（Developer SKU）をデプロイした | ☐ |
| NSG で SHIR VM のインターネット直結を遮断した | ☐ |
| 遮断できていることを Test-NetConnection で確認した | ☐ |
| Squid をフェーズ1（全許可＋ログ記録）で起動した | ☐ |
| **フェーズ1**：SHIR が「実行中」になった | ☐ |
| **フェーズ1**：「サービス URL」の内容を確認した | ☐ |
| **フェーズ1**：PE の DNS がプライベート IP を返した | ☐ |
| **フェーズ1**：PE へ TCP 1433 で接続できた | ☐ |
| **フェーズ1**：移行（TestDB1）が完走し件数が一致した | ☐ |
| **フェーズ1**：access.log から必要 FQDN を全件抽出した | ☐ |
| Squid をフェーズ2（絞り込みリスト）に切り替えた | ☐ |
| **フェーズ2**：SHIR が再度「実行中」になった | ☐ |
| **フェーズ2**：移行（TestDB2）が完走し件数が一致した | ☐ |
| **フェーズ2**：TCP_DENIED が出なかった（出た場合は追記して再実行） | ☐ |
| 記録シートを埋めた | ☐ |
| 検証環境を削除した | ☐ |

---

## トラブルシューティング

### SHIR の登録が「認証キーが無効」で失敗する

```
確認項目：
① Squid のログに TCP_DENIED が出ていないか（フェーズ1では基本的に出ないはず）
② キーをコピーミスしていないか（前後の空白）
③ DIAHostService を再起動したか（プロキシ設定変更後は必須）
```

### フェーズ2でだけ登録・移行が失敗する

```
確認項目：
① sudo grep TCP_DENIED /var/log/squid/access.log で拒否FQDNを特定する
② そのFQDNをacl dms_requiredに追加し、Squidを再起動する
③ フェーズ1で1回の実行では拾いきれなかった通信（初回のみの証明書検証等）の可能性が高いため、
   Squidの設定を更新して再実行すればよい（異常ではない）
```

### プロキシ設定が効いていない（NSG で遮断されて通信できない）

```powershell
# SHIR のプロキシ設定を確認
Get-Content "C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe.config"

# サービス再起動
Restart-Service DIAHostService
```

`usesystemdefault="false"` と `proxyaddress` の指定を確認してください。

### nslookup がグローバル IP を返す

```
確認項目：
① Private DNS ゾーン privatelink.database.windows.net が作成されているか
② VNet リンクが張られているか
③ PE の dns-zone-group が設定されているか
```

### 移行は成功するが Squid ログに拒否が残っている

登録・移行に必須ではない通信（自動更新など）が拒否されている可能性があります。
`download.microsoft.com` の拒否は SHIR の自動更新が効かないだけで移行自体は成功します。
ただし**運用上は許可を推奨**します。

---

*作成日：2026-08-20*
*参考：https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime*
