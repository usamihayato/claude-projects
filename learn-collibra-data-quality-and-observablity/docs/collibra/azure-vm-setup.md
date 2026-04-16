# Collibra DQ Azure VM スタンドアロン セットアップ手順書

> **対象バージョン**: Collibra DQ 2026.02  
> **対象 OS**: RHEL 9.x（Azure Marketplace イメージ）  
> **公式ドキュメント**: [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm)

---

## 目次

1. [はじめに](#1-はじめに)
2. [事前準備](#2-事前準備)
3. [Java 17 のインストール](#3-java-17-のインストール)
4. [Collibra DQ パッケージの準備](#4-collibra-dq-パッケージの準備)
5. [インストール（setup.sh の実行）](#5-インストールsetupsh-の実行)
6. 認証・シークレットの設定 *(作成中)*
7. SSL/HTTPS 設定 *(作成中)*
8. 外部メタストア（PostgreSQL）接続設定 *(作成中)*
9. サービスの起動設定 *(作成中)*
10. ネットワーク・外部アクセスの設定 *(作成中)*
11. DQ Agent の設定 *(作成中)*
12. 動作確認 *(作成中)*
13. トラブルシューティング *(作成中)*
14. アップグレード手順 *(作成中)*

---

## 1. はじめに

### 1.1 ドキュメントの目的と範囲

本ドキュメントは、Azure VM（RHEL 9.x）上に Collibra DQ (Data Quality) をスタンドアロン方式でインストール・設定するための詳細手順を記載する。

**対象読者**: Linux サーバー管理の基本操作（SSH・systemd・ファイル編集）を理解しているインフラエンジニア・システムエンジニア

**対象範囲**:

| スコープ | 本ドキュメントの扱い |
|---|---|
| Azure VNet / VM 自体のインフラ構築 | 対象外（Azure Portal / Terraform 等で別途実施） |
| Collibra DQ アプリケーションのインストール・設定 | **対象** |
| DQ Agent の接続・Spark 設定 | **対象** |
| グループ会社側 DQ Web の設定 | 対象外（Agent Only 構成の場合） |
| 日常運用・監視 | 一部対象（動作確認・アップグレードのみ） |

**デプロイ対象コンポーネント（2パターン）**:

| パターン | DQ Web | DQ Agent | Spark | 用途 |
|---|:---:|:---:|:---:|---|
| **Agent Only（本プロジェクト推奨）** | — | ✓ | ✓ | グループ会社の DQ Web に接続し、Agent と Spark のみ自社 VM で稼働させる |
| **フルインストール** | ✓ | ✓ | ✓ | DQ Web も含めてすべて自社 VM で稼働させる |

### 1.2 AKS / ARO との違い

スタンドアロン方式は Kubernetes を使用しないため、操作が大幅に簡素化される。

| 項目 | スタンドアロン（本ドキュメント） | AKS / ARO |
|---|---|---|
| コンテナ | 不要（JVM プロセスとして直接起動） | Docker / OCI イメージ必須 |
| オーケストレーション | 不要（systemd で管理） | kubectl / Helm 必須 |
| 設定管理 | テキストファイル編集（`owl-env.sh` / `owl.properties`） | values.yaml / ConfigMap / Secret |
| TLS 終端 | VM 自身が直接処理（NGINX Ingress 不要） | Ingress Controller / Route |
| 冗長化 | Active-Standby 2台構成（Azure ILB） | Deployment の replicaCount |
| スケールアウト | 手動（VM 追加） | kubectl scale / HPA |
| 監視 | Azure Monitor + Log Analytics | Azure Monitor for containers |
| 難易度 | 低（Linux・設定ファイル操作のみ） | 高（Kubernetes 知識が必要） |

### 1.3 前提条件チェックリスト

本手順を実施する前に、以下がすべて完了していることを確認すること。

#### インフラ層（Azure Portal / Terraform 等で事前に構築済み）

| 項目 | 確認方法 |
|---|---|
| RHEL 9.x VM が Running 状態 | `az vm show -g ${RG_NAME} -n ${VM_NAME} --query provisioningState` |
| VM に SSH 接続可能 | `ssh <adminUser>@<VM_IP>` |
| VM の VNet から Metastore（PostgreSQL）への Private Endpoint 疎通確認済み | `nc -zv ${METASTORE_HOST} 5432` |
| グループ会社 DQ Web への HTTPS 疎通確認済み（Agent Only 構成時） | `curl -sk https://${DQ_WEB_HOST}:9000` |
| OS ディスクに 100 GB 以上の空き容量 | `df -h /` |

#### ライセンス・認証情報（Collibra 社から取得済み）

| 項目 | 取得先 |
|---|---|
| ライセンスキー（`license_key`） | Collibra ライセンスメール |
| ライセンス名（`license_name`） | Collibra ライセンスメール |
| インストールパッケージ（`dq-full-package-2026.02.tar.gz`） | Collibra Product Resource Center |

#### バージョン要件

| ソフトウェア | 要件 | 本環境の値 |
|---|---|---|
| Collibra DQ | 2026.02 | 2026.02 |
| Spark | 4.1.0（DQ 2026.02 必須） | 4.1.0（パッケージに同梱） |
| Java | 17（DQ 2026.02 必須） | 本手順でインストール |
| OS | RHEL 8.x / 9.x | RHEL 9.x |
| PostgreSQL | 13 以上 | Azure DB for PostgreSQL Flexible Server |

### 1.4 関連ドキュメント一覧

| ドキュメント | 内容 | 参照タイミング |
|---|---|---|
| `docs/collibra/report.md` | Collibra DQ 製品概要・システム要件 | 製品仕様確認時 |
| `docs/collibra/deployment-comparison.md` | デプロイ構成比較（AKS / ARO / VM の選定根拠） | 構成検討時 |
| `docs/collibra/setup.md` | スタンドアロン・Kubernetes インストール概要コマンド | 構成概要の確認時 |
| `docs/collibra/aks-setup.md` | AKS 上への Collibra DQ デプロイ手順 | AKS 構成選択時 |
| `docs/collibra/aro-setup.md` | ARO 上への Collibra DQ デプロイ手順 | ARO 構成選択時 |

---

## 2. 事前準備

### 2.1 変数定義

本手順全体で使用する環境変数を定義する。SSH ログイン後、作業セッション開始時に毎回実行すること。

```bash
# ---- Azure 基本情報 ----
SUBSCRIPTION_ID="<サブスクリプションID>"
LOCATION="japaneast"
RG_NAME="rg-collibra-dq"
VM_NAME="vm-collibra-dq"

# ---- Collibra DQ アプリケーション ----
OWL_BASE="/opt/owl"
DQ_VERSION="2026.02"
SPARK_VERSION="4.1.0"
DQ_WEB_PORT="9000"

# ---- ライセンス情報（Collibra 社提供） ----
DQ_LICENSE_KEY="<Collibraから提供されたライセンスキー>"
DQ_LICENSE_NAME="<Collibraから提供されたライセンス名>"

# ---- メタストア（Azure DB for PostgreSQL） ----
METASTORE_HOST="<ホスト名>.postgres.database.azure.com"
METASTORE_PORT="5432"
METASTORE_DB="owlmetastore"
METASTORE_USER="<DBユーザー名>"
METASTORE_PASS="<DBパスワード>"   # 後で owlmanage.sh encrypt で暗号化して使用

# ---- グループ会社 DQ Web（Agent Only 構成時） ----
DQ_WEB_HOST="<グループ会社の DQ Web ホスト名>"

# ---- ネットワーク ----
VNET_NAME="vnet-collibra-dq"
SUBNET_NAME="snet-collibra-dq"
NSG_NAME="nsg-collibra-dq"
```

> **注意**: パスワード類はシェル変数に直接書かず、Azure Key Vault や `.env` ファイル（Git 管理外）から読み込むことを推奨する。

### 2.2 Azure VM サイズ選定

スタンドアロン構成では VM 1台にすべてのプロセス（DQ Web / DQ Agent / Spark）が同居するため、十分なリソースが必要。

| 規模 | CPU | RAM | Azure VM SKU | 並行ジョブ数目安 |
|---|---|---|---|---|
| 小（PoC） | 16 コア | 128 GB | `Standard_E16s_v5` | ~4 jobs |
| **中（標準・推奨）** | **32 コア** | **256 GB** | **`Standard_E32s_v5`** | **~9 jobs** |
| 大（高負荷） | 64 コア | 512 GB | `Standard_E64s_v5` | ~18 jobs |

> 並行ジョブ数の目安は `(RAM_GB / 28) - 1` を参考にすること（公式ドキュメントより）。  
> Agent Only 構成（DQ Web なし）の場合は 1〜2 ランク下の SKU でも運用可能。

### 2.3 冗長化オプション

本手順書はシングル VM（単一台）構成を基本とする。冗長化が必要な場合は以下を参照すること。

| オプション | 構成 | 特徴 | 推奨度 |
|---|---|---|---|
| **A. Active-Standby 2台** | Azure Internal Load Balancer + 2VM（Availability Zone 分散） | フェイルオーバー対応。両 VM が同一 Metastore を参照 | ★★★ |
| B. Active-Active 複数 Agent | 複数 VM に Agent のみインストール。各 Agent が異なる Datasource を担当 | 負荷分散向き。同一 Datasource の重複実行を防ぐ運用規律が必要 | ★★ |
| C. Availability Zone 単一 VM | `--zone 1` 指定でデプロイ | 冗長化ではなくゾーン障害からの保護のみ | ★ |

> VM Scale Sets は Collibra DQ のような状態を持つアプリには不向き（ジョブ重複実行の問題）のため非推奨。

### 2.4 NSG（ネットワークセキュリティグループ）設定

VM にアタッチされた NSG に以下のルールを追加する。

#### インバウンドルール

```bash
# DQ Web UI / REST API（社内端末 → VM）
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-DQ-Web" \
  --priority 100 \
  --direction Inbound \
  --protocol Tcp \
  --destination-port-ranges "${DQ_WEB_PORT}" \
  --source-address-prefixes "<社内ネットワークのCIDR>" \
  --access Allow

# Spark Cluster UI（管理者のみ・必要に応じて）
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-Spark-UI" \
  --priority 110 \
  --direction Inbound \
  --protocol Tcp \
  --destination-port-ranges 8080 \
  --source-address-prefixes "<管理者端末のIPアドレス>" \
  --access Allow
```

#### アウトバウンドルール

```bash
# Metastore（PostgreSQL）への接続
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-Metastore" \
  --priority 100 \
  --direction Outbound \
  --protocol Tcp \
  --destination-port-ranges "${METASTORE_PORT}" \
  --destination-address-prefixes "<MetastoreのIPアドレスまたはCIDR>" \
  --access Allow

# グループ会社 DQ Web への接続（Agent Only 構成時）
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-DQ-Web-Out" \
  --priority 110 \
  --direction Outbound \
  --protocol Tcp \
  --destination-port-ranges "${DQ_WEB_PORT}" \
  --destination-address-prefixes "<グループ会社DQ WebのIPアドレスまたはCIDR>" \
  --access Allow

# Collibra Platform への HTTPS 接続（ライセンス認証等）
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-Collibra-Platform" \
  --priority 120 \
  --direction Outbound \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --access Allow
```

### 2.5 SSH 接続確認

VM へ SSH 接続し、以降の作業を VM 上で実施する。

```bash
# ローカル端末から VM へ SSH 接続
ssh <adminUser>@<VM_IPアドレスまたはFQDN>

# 接続後：ホスト名・OS バージョン確認
hostname
cat /etc/redhat-release
# 期待値例: Red Hat Enterprise Linux release 9.x (Plow)
```

### 2.6 OS 初期設定

#### ULIMIT 設定

DQ のスレッド管理に必要なファイルディスクリプタ上限を設定する。

```bash
# 現在の ULIMIT 値を確認
ulimit -n
# → 4096 未満の場合は以下を実行

# /etc/security/limits.conf に追記（恒久設定）
sudo tee -a /etc/security/limits.conf <<'EOF'
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF

# 設定を反映するためにシェルを再起動
exec bash -l

# 確認
ulimit -n
# → 65536 であること
```

#### firewalld ポート開放

```bash
# firewalld が有効な場合のみ実施
sudo systemctl status firewalld

# DQ Web ポートを開放
sudo firewall-cmd --permanent --add-port="${DQ_WEB_PORT}/tcp"

# Spark Cluster UI ポートを開放（管理者アクセス用）
sudo firewall-cmd --permanent --add-port=8080/tcp

# 設定を反映
sudo firewall-cmd --reload

# 確認
sudo firewall-cmd --list-ports
```

#### SELinux の確認

```bash
# SELinux の状態確認
getenforce
# Enforcing の場合、Java プロセスの起動に影響することがある
# 本番環境では SELinux ポリシーのカスタマイズを推奨
# PoC 環境では Permissive への変更も可（要セキュリティポリシー確認）
# sudo setenforce 0   # ← PoC 時のみ。本番では使用しないこと
```

---

## 3. Java 17 のインストール

Collibra DQ 2026.02 は **Java 17 が必須**である。Java 8 / 11 では動作しないため、必ずバージョンを確認すること。

### 3.1 Java 17 インストール

```bash
# Java 17 のインストール（OpenJDK）
sudo dnf install -y java-17-openjdk-devel

# インストール確認
java -version
# 期待値例:
# openjdk version "17.x.x" ...
# OpenJDK Runtime Environment ...
# OpenJDK 64-Bit Server VM ...

# javac バージョン確認
javac -version
# 期待値例: javac 17.x.x
```

> **複数バージョンが混在する場合**:  
> `sudo alternatives --config java` で Java 17 をデフォルトに設定すること。

### 3.2 JAVA_HOME の設定

DQ の起動スクリプトが参照する `JAVA_HOME` 環境変数を設定する。

```bash
# Java 17 のインストールパスを確認
JAVA_PATH=$(dirname $(dirname $(readlink -f $(which java))))
echo "${JAVA_PATH}"
# 例: /usr/lib/jvm/java-17-openjdk-17.x.x.x-x.x.el9.x86_64

# /etc/profile.d/java.sh に恒久設定
sudo tee /etc/profile.d/java.sh <<EOF
export JAVA_HOME=${JAVA_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

# 現在のシェルに反映
source /etc/profile.d/java.sh

# 確認
echo \$JAVA_HOME
# 例: /usr/lib/jvm/java-17-openjdk-17.x.x.x-x.x.el9.x86_64
```

### 3.3 Java 17 用 JVM オプションの確認

Collibra DQ 2025.02 以降では Java 17 のモジュールシステム制限を回避するための JVM オプションが必要。このオプションは後述の `owl-env.sh` で設定するが、内容を確認しておく。

```bash
# 設定が必要な EXTRA_JVM_OPTIONS（owl-env.sh に記載する値）
cat <<'EOF'
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"
EOF
```

> 上記は確認用の表示コマンドである。実際の設定は [6章 認証・シークレットの設定](#6-認証シークレットの設定) の `owl-env.sh` 編集で行う。
