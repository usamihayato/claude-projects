# DMS オフライン移行 通信要件 検証手順書
### Azure 検証環境（SHIR VM + Azure DMS）で ADF 既存許可の流用可否を確認する

---

## 検証の目的

本番の SHIR は **ADF 用に構築済みのオンプレサーバ**に相乗りする想定です。
そこで許可済みの通信要件だけで DMS が動作するかを、Azure 検証環境で事前に確認します。

| # | 検証したいこと | 判定基準 |
|---|---|---|
| ① | ADF 用に許可済みの FQDN だけで SHIR が DMS に登録できるか | 登録が「実行中」になる |
| ② | DMS が追加で要求する FQDN は何か | プロキシのログに拒否記録が出るか |
| ③ | SQL Database の PE へ TCP 1433 で到達できるか | sqlcmd で接続できる |
| ④ | 上記の状態で移行が完走するか | DMS の移行が「完了」になる |

> **この検証で分かること**：DMS 用に追加申請すべき FQDN の**具体的なリスト**
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
| 社内プロキシ（FQDN ホワイトリスト） | `vm-proxy`（Squid） | **許可 FQDN を本番と同じにして再現** |
| ExpressRoute → Azure PE | VNet 内ルーティング | PE への 1433 到達性 |
| オンプレ SQL Server 2008 R2 | `vm-source-sql` | 移行元 |
| Azure SQL Database（本番） | Azure SQL Database（検証） | 移行先 |

> **Squid を使う理由**
> 本番の SHIR はプロキシを明示設定（`diahost.exe.config`）して通信します。
> Squid なら同じ構成を再現でき、かつ **access.log で拒否された FQDN が特定できます**。
> これが本検証の核心です。

---

## 事前準備

| 項目 | 必要なもの |
|---|---|
| Azure サブスクリプション | 共同作成者以上の権限 |
| ADF 用の許可 FQDN リスト | **本番のプロキシ設定から現物を入手**（推測しない） |
| 作業端末 | Azure CLI または Azure Portal |

> ⚠️ **最重要**：本検証の価値は「本番と同じホワイトリスト」を Squid に入れる点にあります。
> 本番プロキシの設定を必ず先に入手してください。

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

---

## STEP 2｜プロキシ VM（Squid）を構築

### 2-1 VM 作成

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
  --public-ip-sku Standard
```

### 2-2 Squid のインストール

VM に SSH でログインして実行します。

```bash
sudo apt update && sudo apt install -y squid
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak
```

### 2-3 ホワイトリストの設定

`/etc/squid/squid.conf` を以下の内容で作成します。

```
# ===== 検証用 Squid 設定 =====
http_port 3128

# 接続元（SHIR サブネット）
acl shir_net src 10.0.1.0/24

# ▼▼▼ ここに「ADF 用に本番で許可済みの FQDN」だけを列挙する ▼▼▼
# 先頭のドットはサブドメイン全体（ワイルドカード相当）を意味する
acl adf_allowed dstdomain .servicebus.windows.net
acl adf_allowed dstdomain .frontend.clouddatahub.net
acl adf_allowed dstdomain download.microsoft.com
acl adf_allowed dstdomain login.microsoftonline.com
acl adf_allowed dstdomain .datafactory.azure.net
# ▲▲▲ 本番の設定に合わせて必ず修正すること ▲▲▲

acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny CONNECT !SSL_ports
http_access allow shir_net adf_allowed
http_access deny all

# 拒否内容を追跡するためログを詳細化
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
> - `TCP_TUNNEL/200` → 許可されて通った
> - `TCP_DENIED/403` → **ホワイトリストにないため拒否された＝追加申請が必要な FQDN**

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

VM に RDP して SSMS で実行します。

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

`vm-shir` に RDP（Bastion 経由推奨）してから PowerShell で実行します。

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

## STEP 7｜検証①：ADF 許可 FQDN だけで SHIR が登録できるか

### 7-1 SHIR のインストール

`vm-shir` にインターネット直結がないため、**作業端末でダウンロードしてから VM にコピー**します。

```
https://www.microsoft.com/download/details.aspx?id=39717
```

バージョン **5.37 以上** を使用します。

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

### 7-3 登録キーの取得と登録

1. Portal → DMS インスタンス → 「統合ランタイム」→ 認証キー1 をコピー
2. `Microsoft Integration Runtime Configuration Manager` を起動
3. キーを貼り付けて「登録」

### 7-4 判定

**Squid のログを見ながら**登録を実行します。

| 結果 | 意味 | 対応 |
|---|---|---|
| 状態が「実行中」になった | ADF 許可分で足りている | ✅ 追加申請不要（STEP 8 でさらに確認） |
| 登録が失敗した | 不足 FQDN がある | Squid ログの `TCP_DENIED` を確認 → 記録 |

```bash
# 拒否された FQDN だけを抽出
sudo grep TCP_DENIED /var/log/squid/access.log | awk '{print $7}' | sort -u
```

> **ここで出力された FQDN が「DMS 用に追加申請が必要なもの」です。**
> 1 つずつ squid.conf に追加 → 再起動 → 再登録 を繰り返し、登録が通るまで確認します。
> 追加した FQDN は必ず記録してください（STEP 11 の記録シートへ）。

---

## STEP 8｜検証②：サービス URL と接続テスト

登録成功後、SHIR が実際に必要とするエンドポイントを確認します。

1. `Microsoft Integration Runtime Configuration Manager` を起動
2. 「診断」タブ →「接続のテスト」を実行
3. 同画面の **「サービス URL」** を開く

> **サービス URL には DMS インスタンス固有のエンドポイントが表示されます。**
> ワイルドカード（`*.servicebus.windows.net` 等）でカバーされているか確認し、
> カバーされていないものは追加申請リストに加えてください。

さらに Squid ログで実通信を確認します。

```bash
# 実際にアクセスされた FQDN の一覧（許可・拒否問わず）
sudo awk '{print $7}' /var/log/squid/access.log | cut -d: -f1 | sort -u
```

---

## STEP 9｜検証③：SQL Database PE への TCP 1433

`vm-shir` の PowerShell / コマンドプロンプトで実行します。

### 9-1 DNS 解決の確認

```powershell
nslookup （論理サーバー名）.database.windows.net
```

> **期待値**：`10.0.3.x`（PE のプライベート IP）が返ること
> グローバル IP が返る場合は Private DNS ゾーンの紐付けを見直してください。

### 9-2 ポート疎通の確認

```powershell
Test-NetConnection （論理サーバー名）.database.windows.net -Port 1433
```

> `TcpTestSucceeded : True` であれば OK

### 9-3 SQL 接続の確認

```cmd
sqlcmd -S （論理サーバー名）.database.windows.net -U dmsuser -P （パスワード） -Q "SELECT @@VERSION"
```

### 9-4 移行元 SQL Server への疎通も確認

```cmd
sqlcmd -S 10.0.2.4 -U migrateuser -P （パスワード） -Q "SELECT @@VERSION"
```

---

## STEP 10｜検証④：実際に移行を実行

1. Portal → DMS インスタンス → 「移行プロジェクトの新規作成」
2. ソース：`vm-source-sql`（10.0.2.4）／SQL 認証／`migrateuser`
3. ターゲット：`（論理サーバー名）.database.windows.net`／`dmsuser`
4. `TestDB1` を選択してマッピング
5. スキーマ移行 ✅ ／ データ移行 ✅
6. 「移行の開始」

### 判定

```sql
-- 移行先の Azure SQL Database で実行（3 件返れば成功）
SELECT COUNT(*) FROM dbo.T1;
```

> **移行実行中も Squid のログを監視してください。**
> 登録時には現れなかった FQDN が、移行実行時に初めて要求される可能性があります。

---

## STEP 11｜検証結果の記録シート

検証しながら以下を埋めてください。そのまま申請資料になります。

### 追加申請が必要な FQDN

| # | FQDN | ポート | 検出タイミング | ADF 許可済みか | 備考 |
|---|---|---|---|---|---|
| 1 | | 443 | SHIR 登録時 / 移行実行時 | ✅ / ❌ | |
| 2 | | 443 | | | |
| 3 | | 443 | | | |

### ポート要件

| 通信 | ポート | 経路 | 疎通結果 |
|---|---|---|---|
| SHIR → プロキシ | 3128 | — | ☐ OK ☐ NG |
| SHIR → 移行元 SQL Server | 1433 | 社内 NW | ☐ OK ☐ NG |
| SHIR → SQL Database PE | 1433 | ER | ☐ OK ☐ NG |

### 総合判定

| 検証項目 | 結果 |
|---|---|
| ① ADF 許可分だけで SHIR 登録できたか | ☐ できた ☐ 追加必要 |
| ② サービス URL がワイルドカードでカバーされるか | ☐ カバー済 ☐ 追加必要 |
| ③ PE への 1433 が通ったか | ☐ 通った ☐ 要 FW 申請 |
| ④ 移行が完走したか | ☐ 完走 ☐ 失敗 |

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
| 本番プロキシの許可 FQDN リストを入手した | ☐ |
| Squid のホワイトリストを本番と同じ内容にした | ☐ |
| NSG で SHIR VM のインターネット直結を遮断した | ☐ |
| 遮断できていることを Test-NetConnection で確認した | ☐ |
| Squid の access.log を監視しながら検証した | ☐ |
| SHIR が「実行中」になった | ☐ |
| 拒否された FQDN を全て記録した | ☐ |
| 「サービス URL」の内容を確認した | ☐ |
| PE の DNS がプライベート IP を返した | ☐ |
| PE へ TCP 1433 で接続できた | ☐ |
| 移行が完走し件数が一致した | ☐ |
| 移行実行中のログも確認した | ☐ |
| 記録シートを埋めた | ☐ |
| 検証環境を削除した | ☐ |

---

## トラブルシューティング

### SHIR の登録が「認証キーが無効」で失敗する

```
確認項目：
① Squid のログに TCP_DENIED が出ていないか
② キーをコピーミスしていないか（前後の空白）
③ DIAHostService を再起動したか（プロキシ設定変更後は必須）
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
