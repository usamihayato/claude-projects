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
  --size Standard_D2s_v3 \
  --vnet-name $VNET \
  --subnet snet-source \
  --admin-username azureuser \
  --admin-password '（強いパスワード）' \
  --public-ip-address ""
```

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

-- SQL 認証を有効化（混合モード）してから移行用ユーザーを作成
CREATE LOGIN migrateuser WITH PASSWORD = '（強いパスワード）';
USE TestDB1;
CREATE USER migrateuser FOR LOGIN migrateuser;
ALTER ROLE db_datareader ADD MEMBER migrateuser;
GO
```

> SQL Server 構成マネージャーで **TCP/IP プロトコルを有効化**し、
> Windows ファイアウォールで **TCP 1433 の受信を許可**してください。

---

## STEP 4｜SHIR VM を作成（インターネット直結を遮断）

### 4-1 VM 作成

```bash
az vm create \
  --resource-group $RG \
  --name vm-shir \
  --image Win2022Datacenter \
  --size Standard_D2s_v3 \
  --vnet-name $VNET \
  --subnet snet-shir \
  --admin-username azureuser \
  --admin-password '（強いパスワード）' \
  --public-ip-address ""
```

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
  --service-objective GP_Gen5_2
```

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

パブリックアクセスを無効にしたため、`vm-shir` から SSMS で接続して実行します。

```sql
-- master で実行
CREATE LOGIN dmsuser WITH PASSWORD = '（強いパスワード）';
ALTER SERVER ROLE ##MS_DatabaseManager##  ADD MEMBER [dmsuser];
ALTER SERVER ROLE ##MS_LoginManager##     ADD MEMBER [dmsuser];
GO
```

---

## STEP 6｜Azure DMS を作成

```bash
# リソースプロバイダー登録（初回のみ）
az provider register --namespace Microsoft.DataMigration
```

その後 Azure Portal で作成します。

1. 「Azure Database Migration Service」→「作成」
2. 設定値：

| 項目 | 設定値 |
|---|---|
| リソースグループ | `rg-dms-network-verify` |
| 移行サービス名 | 任意 |
| リージョン | Japan East |
| サービスモード | Azure |
| 価格レベル | Standard |

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

`C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe.config` を編集：

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

### 8-2 サービス URL の確認

1. 同 Configuration Manager の「診断」タブ →「接続のテスト」を実行
2. 同画面の **「サービス URL」** を開く（DMS インスタンス固有のエンドポイントが一覧表示される）

### 8-3 SQL Database PE への疎通確認（フェーズ1のうちに実施）

`vm-shir` の PowerShell / コマンドプロンプトで実行します。

```powershell
# DNS解決の確認（期待値: 10.0.3.x が返ること）
nslookup （論理サーバー名）.database.windows.net

# ポート疎通の確認
Test-NetConnection （論理サーバー名）.database.windows.net -Port 1433
```

```cmd
REM SQL接続の確認
sqlcmd -S （論理サーバー名）.database.windows.net -U dmsuser -P （パスワード） -Q "SELECT @@VERSION"

REM 移行元SQL Serverへの疎通も確認
sqlcmd -S 10.0.2.4 -U migrateuser -P （パスワード） -Q "SELECT @@VERSION"
```

### 8-4 移行を最後まで実行する

1. Portal → DMS インスタンス → 「移行プロジェクトの新規作成」
2. ソース：`vm-source-sql`（10.0.2.4）／SQL 認証／`migrateuser`
3. ターゲット：`（論理サーバー名）.database.windows.net`／`dmsuser`
4. `TestDB1` を選択してマッピング
5. スキーマ移行 ✅ ／ データ移行 ✅
6. 「移行の開始」

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

---

## STEP 9｜フェーズ2：Squid をフェーズ1で確定した FQDN だけに絞り込む

STEP 8-5 で確定したリストだけを許可するよう、Squid の設定を書き換えます。

```
# ===== フェーズ2: 絞り込み後の許可リスト =====
http_port 3128

acl shir_net src 10.0.1.0/24

# ▼▼▼ STEP 8-5 で確定した FQDN をここに列挙する（例） ▼▼▼
acl dms_required dstdomain .servicebus.windows.net
acl dms_required dstdomain .frontend.clouddatahub.net
acl dms_required dstdomain login.microsoftonline.com
# 実際に確定したリストに置き換えること
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
az sql db create --resource-group $RG --server $SQLSERVER --name TestDB2 --service-objective GP_Gen5_2
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

検証完了後、**リソースグループごと削除**します。

```bash
az group delete --name $RG --yes --no-wait
```

### 課金対象リソース

| リソース | 課金 |
|---|---|
| vm-shir（D2s_v3） | 稼働時間課金 |
| vm-source-sql（D2s_v3・SQL Developer） | VM 分のみ（Developer エディションのライセンスは無償） |
| vm-proxy（B1s） | 稼働時間課金（少額） |
| Azure SQL Database（GP_Gen5_2） | 稼働時間課金 |
| Azure DMS（Standard） | Standard SKU は課金なし |
| Private Endpoint | 時間課金＋データ処理課金（少額） |
| Azure Bastion（Developer SKU） | **無料** |

> 検証は数日で終わる想定です。**放置すると VM のコストが積み上がる**ため、
> 中断する場合は VM を停止（割り当て解除）してください。

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
