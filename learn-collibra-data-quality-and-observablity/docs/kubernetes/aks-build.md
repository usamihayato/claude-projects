# AKS 構築手順書（Collibra DQ 導入用）

> **作成日**: 2026-04-14  
> **前提**: [aks-design.md](aks-design.md) の設計に基づく  
> **実施環境**: 管理用 Linux VM または作業用端末（az CLI・kubectl・helm インストール済み）

---

## 目次

1. [事前準備](#1-事前準備)
2. [Spoke VNET・サブネット作成](#2-spoke-vnetサブネット作成)
3. [VNET Peering 設定](#3-vnet-peering-設定)
4. [UDR・NSG 設定](#4-udrnsg-設定)
5. [Azure Firewall ルール追加](#5-azure-firewall-ルール追加)
6. [管理用 Linux VM 構築](#6-管理用-linux-vm-構築)
7. [ACR 構築](#7-acr-構築)
8. [AKS クラスター構築](#8-aks-クラスター構築)
9. [Private Endpoint 設定（metastore）](#9-private-endpoint-設定metastore)
10. [Defender for Cloud・セキュリティ設定](#10-defender-for-cloudセキュリティ設定)
11. [AKS 自動アップグレード設定](#11-aks-自動アップグレード設定)
12. [Linux VM パッチ自動適用設定](#12-linux-vm-パッチ自動適用設定)
13. [管理 VM への kubectl・helm セットアップ](#13-管理-vm-への kubectlhelm-セットアップ)
14. [動作確認](#14-動作確認)

---

## 1. 事前準備

### 変数定義（以降の手順で共通使用）

```bash
# ---- 基本情報 ----
SUBSCRIPTION_ID="<サブスクリプションID>"
LOCATION="japaneast"
RG_NAME="rg-collibra-dq"

# ---- ネットワーク ----
VNET_NAME="vnet-collibra-dq"
VNET_CIDR="10.1.0.0/22"
SNET_AKS_NODE="snet-aks-node"
SNET_AKS_CIDR="10.1.0.0/24"
SNET_MGMT="snet-mgmt"
SNET_MGMT_CIDR="10.1.1.0/28"
SNET_PE="snet-pe"
SNET_PE_CIDR="10.1.2.0/27"

HUB_VNET_NAME="<Hubの VNET 名>"
HUB_VNET_RG="<Hub の リソースグループ名>"
HUB_FW_IP="<Azure Firewall のプライベート IP>"

# ---- AKS ----
AKS_NAME="aks-collibra-dq"
AKS_VERSION="1.32"
NODE_VM_SIZE="Standard_D16s_v5"

# ---- ACR ----
ACR_NAME="acrcollibradq"

# ---- 管理 VM ----
VM_NAME="vm-aks-mgmt"
VM_SIZE="Standard_B2s"
ADMIN_USER="azureuser"
SSH_KEY_PATH="~/.ssh/id_rsa.pub"

# ---- Log Analytics ----
LAW_NAME="law-collibra-dq"
```

### ログイン・サブスクリプション設定

```bash
az login
az account set --subscription $SUBSCRIPTION_ID
```

### リソースグループ作成

```bash
az group create \
  --name $RG_NAME \
  --location $LOCATION
```

---

## 2. Spoke VNET・サブネット作成

### VNET 作成

```bash
az network vnet create \
  --resource-group $RG_NAME \
  --name $VNET_NAME \
  --address-prefix $VNET_CIDR \
  --location $LOCATION
```

### サブネット作成

```bash
# AKS ノードサブネット
az network vnet subnet create \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_AKS_NODE \
  --address-prefix $SNET_AKS_CIDR

# 管理 VM サブネット
az network vnet subnet create \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_MGMT \
  --address-prefix $SNET_MGMT_CIDR

# Private Endpoint サブネット
# Private Endpoint はポリシーを無効にする必要がある
az network vnet subnet create \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_PE \
  --address-prefix $SNET_PE_CIDR \
  --disable-private-endpoint-network-policies true
```

---

## 3. VNET Peering 設定

```bash
# Spoke VNET の Resource ID を取得
SPOKE_VNET_ID=$(az network vnet show \
  --resource-group $RG_NAME \
  --name $VNET_NAME \
  --query id -o tsv)

# Hub VNET の Resource ID を取得
HUB_VNET_ID=$(az network vnet show \
  --resource-group $HUB_VNET_RG \
  --name $HUB_VNET_NAME \
  --query id -o tsv)

# Spoke → Hub Peering（リモートゲートウェイ使用を有効化）
az network vnet peering create \
  --resource-group $RG_NAME \
  --name peer-spoke-to-hub \
  --vnet-name $VNET_NAME \
  --remote-vnet $HUB_VNET_ID \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --use-remote-gateways true       # Hub の ER Gateway を使用

# Hub → Spoke Peering（ゲートウェイ転送を許可）
az network vnet peering create \
  --resource-group $HUB_VNET_RG \
  --name peer-hub-to-spoke \
  --vnet-name $HUB_VNET_NAME \
  --remote-vnet $SPOKE_VNET_ID \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --allow-gateway-transit true     # ER Gateway を Spoke に転送
```

> **注意**: `--use-remote-gateways` は Hub 側に Gateway が存在し、かつ Hub→Spoke の Peering で `--allow-gateway-transit` が有効な場合のみ設定できる。

---

## 4. UDR・NSG 設定

### UDR 作成と AKS ノードサブネットへの適用

```bash
# ルートテーブル作成
az network route-table create \
  --resource-group $RG_NAME \
  --name rt-aks-node \
  --disable-bgp-route-propagation false   # ER からの BGP ルートも受け取る場合は false

# デフォルトルート → Azure Firewall
az network route-table route create \
  --resource-group $RG_NAME \
  --route-table-name rt-aks-node \
  --name route-default-to-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $HUB_FW_IP

# ルートテーブルをサブネットに適用
AKS_SNET_ID=$(az network vnet subnet show \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_AKS_NODE \
  --query id -o tsv)

az network vnet subnet update \
  --ids $AKS_SNET_ID \
  --route-table rt-aks-node
```

### 管理 VM サブネット用 UDR

```bash
az network route-table create \
  --resource-group $RG_NAME \
  --name rt-mgmt

az network route-table route create \
  --resource-group $RG_NAME \
  --route-table-name rt-mgmt \
  --name route-default-to-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $HUB_FW_IP

MGMT_SNET_ID=$(az network vnet subnet show \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_MGMT \
  --query id -o tsv)

az network vnet subnet update \
  --ids $MGMT_SNET_ID \
  --route-table rt-mgmt
```

### NSG 作成・設定

```bash
# ---- 管理 VM 用 NSG ----
az network nsg create \
  --resource-group $RG_NAME \
  --name nsg-mgmt

# SSH を社内 IP からのみ許可
az network nsg rule create \
  --resource-group $RG_NAME \
  --nsg-name nsg-mgmt \
  --name allow-ssh-from-onprem \
  --priority 100 \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes "<社内ネットワークのCIDR>" \
  --access Allow

# NSG をサブネットに適用
az network vnet subnet update \
  --ids $MGMT_SNET_ID \
  --network-security-group nsg-mgmt

# ---- AKS ノード用 NSG ----
az network nsg create \
  --resource-group $RG_NAME \
  --name nsg-aks-node

# AKS ヘルスプローブ許可（LoadBalancer）
az network nsg rule create \
  --resource-group $RG_NAME \
  --nsg-name nsg-aks-node \
  --name allow-aks-lb-probe \
  --priority 100 \
  --protocol Tcp \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges 10250 \
  --access Allow

az network vnet subnet update \
  --ids $AKS_SNET_ID \
  --network-security-group nsg-aks-node
```

---

## 5. Azure Firewall ルール追加

Hub VNET の Azure Firewall に、AKS および管理 VM が必要とする通信を許可するルールを追加する。

```bash
# Hub の Firewall Policy 名を事前に確認
HUB_FW_POLICY="<Azure Firewall Policy 名>"
HUB_RG="<Hub リソースグループ名>"

# ---- ネットワークルールコレクション追加 ----
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group $HUB_RG \
  --policy-name $HUB_FW_POLICY \
  --rule-collection-group-name "DefaultNetworkRuleCollectionGroup" \
  --name "allow-collibra-dq-network" \
  --collection-priority 200 \
  --action Allow \
  --rule-name "allow-aks-ntp" \
  --rule-type NetworkRule \
  --source-addresses "$SNET_AKS_CIDR" \
  --destination-fqdns "ntp.ubuntu.com" \
  --ip-protocols UDP \
  --destination-ports 123

# AKS → 社内システム（DQ スキャン対象）
az network firewall policy rule-collection-group collection rule add \
  --resource-group $HUB_RG \
  --policy-name $HUB_FW_POLICY \
  --rule-collection-group-name "DefaultNetworkRuleCollectionGroup" \
  --collection-name "allow-collibra-dq-network" \
  --name "allow-aks-to-onprem-db" \
  --rule-type NetworkRule \
  --source-addresses "$SNET_AKS_CIDR" \
  --destination-addresses "<社内 DB のアドレス帯>" \
  --ip-protocols TCP \
  --destination-ports 1433 5432 1521   # SQL Server / PostgreSQL / Oracle

# ---- アプリケーションルールコレクション追加 ----
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group $HUB_RG \
  --policy-name $HUB_FW_POLICY \
  --rule-collection-group-name "DefaultApplicationRuleCollectionGroup" \
  --name "allow-collibra-dq-app" \
  --collection-priority 200 \
  --action Allow \
  --rule-name "allow-aks-fqdn-tag" \
  --rule-type ApplicationRule \
  --source-addresses "$SNET_AKS_CIDR" \
  --fqdn-tags "AzureKubernetesService"

# Ubuntu パッケージ更新（管理 VM・ノード）
az network firewall policy rule-collection-group collection rule add \
  --resource-group $HUB_RG \
  --policy-name $HUB_FW_POLICY \
  --rule-collection-group-name "DefaultApplicationRuleCollectionGroup" \
  --collection-name "allow-collibra-dq-app" \
  --name "allow-ubuntu-updates" \
  --rule-type ApplicationRule \
  --source-addresses "$SNET_AKS_CIDR" "$SNET_MGMT_CIDR" \
  --protocols "Https=443" "Http=80" \
  --target-fqdns "*.ubuntu.com" "security.ubuntu.com" "archive.ubuntu.com"
```

---

## 6. 管理用 Linux VM 構築

```bash
# SSH キーペアの生成（未作成の場合）
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_aksmgmt -N ""

# VM 作成
az vm create \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size $VM_SIZE \
  --vnet-name $VNET_NAME \
  --subnet $SNET_MGMT \
  --admin-username $ADMIN_USER \
  --ssh-key-values ~/.ssh/id_rsa_aksmgmt.pub \
  --public-ip-address "" \
  --nsg ""                            # NSG はサブネットレベルで適用済み
  --storage-sku Premium_LRS \
  --os-disk-size-gb 64 \
  --assign-identity                   # System-assigned Managed Identity を有効化

# VM の Managed Identity に AKS Cluster Admin ロールを付与
VM_IDENTITY=$(az vm show \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --query identity.principalId -o tsv)

AKS_ID=$(az aks show \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --query id -o tsv)

# ※ AKS 作成後に実施
az role assignment create \
  --assignee $VM_IDENTITY \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope $AKS_ID
```

---

## 7. ACR 構築

```bash
# ACR 作成（Public Access 無効）
az acr create \
  --resource-group $RG_NAME \
  --name $ACR_NAME \
  --location $LOCATION \
  --sku Premium \
  --public-network-enabled false

# ACR の Private Endpoint 作成
ACR_ID=$(az acr show \
  --resource-group $RG_NAME \
  --name $ACR_NAME \
  --query id -o tsv)

az network private-endpoint create \
  --resource-group $RG_NAME \
  --name pe-acr \
  --vnet-name $VNET_NAME \
  --subnet $SNET_PE \
  --private-connection-resource-id $ACR_ID \
  --group-ids registry \
  --connection-name conn-acr

# プライベート DNS ゾーン作成・VNET リンク
az network private-dns zone create \
  --resource-group $RG_NAME \
  --name privatelink.azurecr.io

az network private-dns link vnet create \
  --resource-group $RG_NAME \
  --zone-name privatelink.azurecr.io \
  --name link-acr-spoke \
  --virtual-network $VNET_NAME \
  --registration-enabled false

# DNS ゾーングループ（Private Endpoint と DNS を自動紐付け）
az network private-endpoint dns-zone-group create \
  --resource-group $RG_NAME \
  --endpoint-name pe-acr \
  --name acr-dns-group \
  --private-dns-zone privatelink.azurecr.io \
  --zone-name registry

# Collibra コンテナイメージを ACR にインポート（ライセンス取得後）
# az acr import \
#   --name $ACR_NAME \
#   --source <collibra-registry-host>/dq:<version> \
#   --image dq:<version>
```

---

## 8. AKS クラスター構築

```bash
# AKS ノードサブネットの Resource ID
AKS_SNET_ID=$(az network vnet subnet show \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name $SNET_AKS_NODE \
  --query id -o tsv)

# ACR の Resource ID
ACR_ID=$(az acr show \
  --resource-group $RG_NAME \
  --name $ACR_NAME \
  --query id -o tsv)

# AKS クラスター作成
az aks create \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --location $LOCATION \
  --kubernetes-version $AKS_VERSION \
  \
  # ネットワーク設定
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-policy azure \
  --vnet-subnet-id $AKS_SNET_ID \
  --pod-cidr "192.168.0.0/16" \
  --service-cidr "172.16.0.0/16" \
  --dns-service-ip "172.16.0.10" \
  \
  # プライベートクラスター設定
  --enable-private-cluster \
  --private-dns-zone system \
  \
  # ノードプール設定（systemプール）
  --nodepool-name system \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --os-sku Ubuntu \
  \
  # セキュリティ・認証
  --enable-managed-identity \
  --enable-azure-rbac \
  --enable-oidc-issuer \
  --enable-workload-identity \
  \
  # ACR 統合
  --attach-acr $ACR_ID \
  \
  # 監視
  --enable-addons monitoring \
  --workspace-resource-id $(az monitor log-analytics workspace show \
    --resource-group $RG_NAME \
    --workspace-name $LAW_NAME \
    --query id -o tsv) \
  \
  # アップグレード設定（後の手順でも設定可能）
  --auto-upgrade-channel patch \
  --node-os-upgrade-channel NodeImage

# DQ 用ノードプール追加
az aks nodepool add \
  --resource-group $RG_NAME \
  --cluster-name $AKS_NAME \
  --name dqpool \
  --node-count 3 \
  --node-vm-size $NODE_VM_SIZE \
  --os-sku Ubuntu \
  --vnet-subnet-id $AKS_SNET_ID \
  --enable-cluster-autoscaler \
  --min-count 3 \
  --max-count 6 \
  --mode User
```

> **注意**: プライベートクラスターの作成は通常 5〜10分かかる。  
> 作成後は **管理 VM 上から** `az aks get-credentials` を実行しないとアクセスできない。

---

## 9. Private Endpoint 設定（metastore）

別テナントの PostgreSQL への Private Endpoint を作成する。**クロステナントのため手動承認が必要**。

```bash
# metastore の Resource ID（別テナント側から確認して取得）
METASTORE_RESOURCE_ID="<別テナントの PostgreSQL の Resource ID>"
# 例: /subscriptions/<別テナントのサブスクリプションID>/resourceGroups/<RG>/providers/
#     Microsoft.DBforPostgreSQL/flexibleServers/<server-name>

# Private Endpoint 作成（手動承認モード）
az network private-endpoint create \
  --resource-group $RG_NAME \
  --name pe-metastore-postgres \
  --vnet-name $VNET_NAME \
  --subnet $SNET_PE \
  --private-connection-resource-id $METASTORE_RESOURCE_ID \
  --group-ids postgresqlServer \
  --connection-name conn-metastore \
  --manual-request true \
  --request-message "Collibra DQ metastore connection from <会社名> Japan tenant"
```

### 別テナント側での承認手順

別テナントの管理者に以下を依頼する:

```bash
# 別テナント側での操作
# 1. 保留中の接続を確認
az network private-endpoint-connection list \
  --resource-group <別テナント RG> \
  --name <PostgreSQL server 名> \
  --type Microsoft.DBforPostgreSQL/flexibleServers

# 2. 接続を承認
az network private-endpoint-connection approve \
  --resource-group <別テナント RG> \
  --resource-name <PostgreSQL server 名> \
  --name <connection 名> \
  --type Microsoft.DBforPostgreSQL/flexibleServers \
  --description "Approved for Collibra DQ"
```

### プライベート DNS ゾーン設定

```bash
# プライベート DNS ゾーン作成
az network private-dns zone create \
  --resource-group $RG_NAME \
  --name privatelink.postgres.database.azure.com

# Spoke VNET にリンク
az network private-dns link vnet create \
  --resource-group $RG_NAME \
  --zone-name privatelink.postgres.database.azure.com \
  --name link-postgres-spoke \
  --virtual-network $VNET_NAME \
  --registration-enabled false

# DNS ゾーングループ（承認後に作成）
az network private-endpoint dns-zone-group create \
  --resource-group $RG_NAME \
  --endpoint-name pe-metastore-postgres \
  --name postgres-dns-group \
  --private-dns-zone privatelink.postgres.database.azure.com \
  --zone-name postgresqlServer
```

### 接続確認

```bash
# Private Endpoint の IP アドレス確認
az network private-endpoint show \
  --resource-group $RG_NAME \
  --name pe-metastore-postgres \
  --query customDnsConfigs

# 管理 VM から疎通確認
# ssh azureuser@<vm-private-ip>
psql "host=<server-name>.privatelink.postgres.database.azure.com \
  port=5432 dbname=owlmetastore user=owl sslmode=require"
```

---

## 10. Defender for Cloud・セキュリティ設定

```bash
# Defender for Containers 有効化
az security pricing create \
  --name Containers \
  --tier Standard

# Defender for Servers 有効化
az security pricing create \
  --name VirtualMachines \
  --tier Standard

# AKS に Defender プロファイルを有効化
az aks update \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --enable-defender

# Azure Policy アドオンの有効化
az aks update \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --enable-azure-policy
```

### AKS セキュリティポリシーの割当（Azure Portal 推奨）

以下のビルトインポリシーイニシアティブを AKS クラスターのスコープに割り当てる:

| ポリシーイニシアティブ | 目的 |
|---------------------|------|
| `Kubernetes cluster pod security restricted standards for Linux-based workloads` | 特権コンテナ・ホスト共有の禁止等 |
| `[Preview]: Ensure only allowed container images in Kubernetes cluster` | 承認済み ACR のみ許可 |

```bash
# 承認済みレジストリのみ許可するポリシー割当（az CLI）
az policy assignment create \
  --name "allow-acr-only" \
  --display-name "ACR のみからのイメージ Pull を許可" \
  --policy "/providers/Microsoft.Authorization/policyDefinitions/<policyDefinitionId>" \
  --scope $(az aks show --resource-group $RG_NAME --name $AKS_NAME --query id -o tsv) \
  --params '{"allowedContainerImagesRegex": {"value": "^acrcollibradq\\.azurecr\\.io/.+$"}}'
```

---

## 11. AKS 自動アップグレード設定

```bash
# 自動アップグレードチャネルを patch に設定
az aks update \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --auto-upgrade-channel patch \
  --node-os-upgrade-channel NodeImage

# メンテナンスウィンドウの設定（毎週土曜 2:00〜5:00 JST = UTC 17:00〜20:00 金曜）
az aks maintenanceconfiguration add \
  --resource-group $RG_NAME \
  --cluster-name $AKS_NAME \
  --name default \
  --weekday Friday \
  --start-hour 17    # UTC（JST-9）
```

### kured（ノード自動再起動）のインストール

AKS ノードの OS パッチ後に再起動が必要な場合、kured で自動的にローリング再起動する。

```bash
# kured の Helm インストール（管理 VM 上で実施）
helm repo add kubereboot https://kubereboot.github.io/charts
helm repo update

helm upgrade --install kured kubereboot/kured \
  --namespace kube-system \
  --set configuration.rebootDays="{sat}" \
  --set configuration.startTime="02:00" \
  --set configuration.endTime="05:00" \
  --set configuration.timeZone="Asia/Tokyo"
```

---

## 12. Linux VM パッチ自動適用設定

Azure Update Manager を使用して管理 VM のセキュリティパッチを自動適用する。

```bash
# Update Manager でのパッチ評価を有効化
az maintenance configuration create \
  --resource-group $RG_NAME \
  --name "mc-vm-security-patch" \
  --maintenance-scope "InGuestPatch" \
  --location $LOCATION \
  --install-patches-windows-parameters '{}' \
  --install-patches-linux-parameters \
    '{"classificationsToInclude":["Security","Critical"],"packageNameMasksToExclude":[]}' \
  --recur-every "Week Saturday" \
  --duration "02:00" \
  --start-date-time "2026-04-19 02:00" \
  --time-zone "Tokyo Standard Time" \
  --reboot-setting "IfRequired"

# VM にメンテナンス設定を割当
az maintenance assignment create \
  --resource-group $RG_NAME \
  --location $LOCATION \
  --resource-name $VM_NAME \
  --resource-type virtualMachines \
  --provider-name Microsoft.Compute \
  --configuration-assignment-name "assign-mc-vm-security-patch" \
  --maintenance-configuration-id $(az maintenance configuration show \
    --resource-group $RG_NAME \
    --name "mc-vm-security-patch" \
    --query id -o tsv)
```

### パッケージ更新経路の確認

Azure FW の FQDN ルール（`*.ubuntu.com`）が有効であることを確認後、管理 VM で疎通を確認する。

```bash
# 管理 VM 上で実施
curl -I https://security.ubuntu.com
sudo apt-get update
```

---

## 13. 管理 VM への kubectl・helm セットアップ

管理 VM（`vm-aks-mgmt`）に SSH でログインして実施する。

```bash
# ----- 以下、管理 VM 上で実施 -----

# az CLI インストール
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# kubectl インストール
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl

# helm インストール
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

# psql クライアントインストール（metastore 接続確認用）
sudo apt-get install -y postgresql-client

# az aks get-credentials（Managed Identity でログイン）
az login --identity
az account set --subscription $SUBSCRIPTION_ID

az aks get-credentials \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --overwrite-existing

# 接続確認
kubectl get nodes
kubectl get namespaces
```

---

## 14. 動作確認

### ネットワーク疎通確認

```bash
# ---- 管理 VM から AKS API Server（kubectl） ----
kubectl cluster-info
kubectl get nodes -o wide

# ---- AKS Pod から metastore（Private Endpoint 経由）----
kubectl run pg-test --rm -it --image=postgres:15 -- \
  psql "host=<server-name>.privatelink.postgres.database.azure.com \
        port=5432 dbname=owlmetastore user=owl sslmode=require"

# ---- AKS ノードから社内システム（ER 経由・FW 通過）----
kubectl run net-test --rm -it --image=alpine -- \
  sh -c "nc -zv <社内DBホスト> 1433"

# ---- AKS → ACR（Private Endpoint 経由）----
kubectl run acr-test --rm -it \
  --image=$ACR_NAME.azurecr.io/hello-world:latest \
  -- echo "ACR Pull 成功"
```

### Defender・ポリシー確認

```bash
# Defender プロファイルの確認
az aks show \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --query securityProfile

# Azure Policy アドオンの確認
az aks show \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --query addonProfiles.azurepolicy
```

### アップグレード設定確認

```bash
# 自動アップグレードチャネル確認
az aks show \
  --resource-group $RG_NAME \
  --name $AKS_NAME \
  --query "autoUpgradeProfile"

# メンテナンスウィンドウ確認
az aks maintenanceconfiguration show \
  --resource-group $RG_NAME \
  --cluster-name $AKS_NAME \
  --name default
```

### Log Analytics 確認

Azure Portal → Log Analytics ワークスペース（`law-collibra-dq`）→ Logs で以下のクエリを実行して収集を確認する。

```kusto
// AKS ノードのメトリクスが収集されているか確認
Perf
| where Computer contains "aks"
| take 10

// コンテナログの確認
ContainerLog
| take 10
```
