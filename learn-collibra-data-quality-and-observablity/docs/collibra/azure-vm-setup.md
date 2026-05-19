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
6. [認証・シークレットの設定](#6-認証シークレットの設定)
7. [SSL/HTTPS 設定](#7-sslhttps-設定)
8. [外部メタストア（PostgreSQL）接続設定](#8-外部メタストアpostgresql接続設定)
9. [サービスの起動設定](#9-サービスの起動設定)
10. [ネットワーク・外部アクセスの設定](#10-ネットワーク外部アクセスの設定)
11. [DQ Agent の設定](#11-dq-agent-の設定)
12. [動作確認](#12-動作確認)
13. [トラブルシューティング](#13-トラブルシューティング)
14. [アップグレード手順](#14-アップグレード手順)
15. [参考リンク](#参考リンク)

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
| 冗長化 | 複数 Agent VM 独立動作（ILB 不要）。DQ Web あり構成では Active-Standby + ILB も可 | Deployment の replicaCount |
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

# ---- ネットワーク ----
VNET_NAME="vnet-collibra-dq"
SUBNET_NAME="snet-collibra-dq"
NSG_NAME="nsg-collibra-dq"
```

> **注意**: パスワード類はシェル変数に直接書かず、Azure Key Vault や `.env` ファイル（Git 管理外）から読み込むことを推奨する。

### 2.2 Azure VM サイズ選定

本プロジェクトのスコープは **DQ Agent + Spark のみ**。DQ Web は不要のため、VM サイズは Agent + Spark の最小要件で選定する。

| 規模 | CPU | RAM | Azure VM SKU | 並行ジョブ数目安 |
|---|---|---|---|---|
| 小（PoC） | 16 コア | 128 GB | `Standard_E16s_v5` | ~4 jobs |
| **中（標準・推奨）** | **32 コア** | **256 GB** | **`Standard_E32s_v5`** | **~9 jobs** |
| 大（高負荷） | 64 コア | 512 GB | `Standard_E64s_v5` | ~18 jobs |

> 並行ジョブ数の目安は `(RAM_GB / 28) - 1` を参考にすること（公式ドキュメントより）。  
> Agent Only 構成（DQ Web なし）の場合は 1〜2 ランク下の SKU でも運用可能。

### 2.3 ディスク構成の考え方

Linux では Windows のような OS/データディスク分離は必須ではなく、Collibra DQ としても特に要件はない。  
ただし、Agent + Spark 構成では以下の理由から**データディスクの分離を推奨**する。

| 観点 | 説明 |
|---|---|
| Spark シャッフルデータ | スキャン実行中に `/opt/owl/spark/work/` 配下に一時ファイルが生成される（スキャン対象データ量に比例）。デフォルトでは自動削除されない（→ Todo A-9 参照） |
| ログの肥大化 | `${OWL_BASE}/log/` が長期運用で数 GB 〜 数十 GB に達することがある |
| OS ディスク保護 | ログや一時ファイルで OS ディスクが満杯になるとシステム全体が停止するリスクがある |

**推奨マウント構成:**

```
/          ← OS Disk (P10 128 GB)  OS・パッケージ
/opt/owl   ← Data Disk (P20 512 GB)  OWL_BASE・ログ・Spark 一時領域
```

**データディスクのマウント手順（VM 起動後に実施）:**

```bash
# データディスクのデバイス名を確認（通常 /dev/sdc または /dev/disk/azure/scsi1/lun0）
lsblk
DISK_DEV="/dev/sdc"   # 実際のデバイス名に合わせること

# パーティション作成・フォーマット
sudo parted "${DISK_DEV}" --script mklabel gpt mkpart primary xfs 0% 100%
sudo mkfs.xfs "${DISK_DEV}1"

# マウントポイント作成
sudo mkdir -p /opt/owl

# /etc/fstab に追記（UUID を使って永続マウント）
DISK_UUID=$(sudo blkid -s UUID -o value "${DISK_DEV}1")
echo "UUID=${DISK_UUID}  /opt/owl  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab

# マウント確認
sudo mount -a
df -h /opt/owl
```

> **PoC・検証環境の場合**: 単一 OS ディスク（P30 1 TB 以上）でも動作する。  
> ただし `/opt/owl/spark/work/` 配下の Spark 一時ファイルはデフォルト自動削除されないため、定期削除を運用で担保すること（→ Todo A-9）。  
> **出典**: [Directory structure](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_directory-structure.htm) — `spark/work/` はインストール後の公式構造で確認済み

### 2.4 冗長化オプション

本手順書はシングル VM（単一台）構成を基本とする。

> **Agent Only 構成における冗長化の考え方**:  
> DQ Agent は DQ Web へ直接通信しない。Metastore（グループ会社管理）を JDBC でポーリングするだけのため、  
> **DQ Web フロントエンド用の Azure Internal Load Balancer は不要**。  
> 冗長化が必要な場合は以下を参照すること。

| オプション | 構成 | 特徴 | 推奨度 |
|---|---|---|---|
| **A. 複数 Agent（Datasource 分散）** | 複数 VM に Agent + Spark をインストール。各 VM が異なる Datasource を担当 | ILB 不要。各 Agent が独立して Metastore をポーリング。同一 Datasource を複数 Agent が担当しないよう運用管理が必要 | ★★★ |
| B. Availability Zone 単一 VM | `--zone 1` 指定でデプロイ | 冗長化ではなくゾーン障害からの保護のみ。最小コスト | ★★ |

> VM Scale Sets・Active-Standby + ILB はいずれも Agent Only 構成には不要。ILB は DQ Web（HTTP/9000）の負荷分散用であり、Agent には該当しない。

### 2.5 NSG（ネットワークセキュリティグループ）設定

VM にアタッチされた NSG に以下のルールを追加する。

> **Agent Only 構成の通信フロー**:  
> `[DQ Agent] → [Metastore PostgreSQL :5432]`（JDBC ポーリング）  
> `[DQ Agent] → [接続先データソース]`（スキャン対象 DB への JDBC 接続）  
> DQ Agent は DQ Web へ直接通信しない。ポート 9000 のインバウンド開放は不要。

#### インバウンドルール

```bash
# Spark Cluster UI（管理者のみ・必要に応じて）
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-Spark-UI" \
  --priority 100 \
  --direction Inbound \
  --protocol Tcp \
  --destination-port-ranges 8080 \
  --source-address-prefixes "<管理者端末のIPアドレス>" \
  --access Allow
```

#### アウトバウンドルール

```bash
# Metastore（PostgreSQL）への接続 ← Agent が JDBC でポーリングするため必須
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

# 接続先データソースへの JDBC 接続（スキャン対象 DB のポートに応じて追加）
# 例: SQL Server の場合
az network nsg rule create \
  --resource-group "${RG_NAME}" \
  --nsg-name "${NSG_NAME}" \
  --name "Allow-DataSource" \
  --priority 110 \
  --direction Outbound \
  --protocol Tcp \
  --destination-port-ranges 1433 \
  --destination-address-prefixes "<データソースのIPアドレスまたはCIDR>" \
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

### 2.6 SSH 接続確認

VM へ SSH 接続し、以降の作業を VM 上で実施する。

```bash
# ローカル端末から VM へ SSH 接続
ssh <adminUser>@<VM_IPアドレスまたはFQDN>

# 接続後：ホスト名・OS バージョン確認
hostname
cat /etc/redhat-release
# 期待値例: Red Hat Enterprise Linux release 9.x (Plow)
```

### 2.7 OS 初期設定

#### ULIMIT 設定

DQ のスレッド管理に必要なファイルディスクリプタ上限を設定する。

> **ULIMIT（nofile）とは**: プロセスが同時に開けるファイルディスクリプタ（ファイル・ソケット等）の上限値。  
> **過剰設定の影響は基本なし**: nofile は「予約」ではなく「上限の天井」のため、高めに設定してもメモリを消費しない。メモリは `owl-env.sh` の HEAP 設定で別途管理する。  
> Collibra 公式の最低要件は 4096。本手順では余裕を取り 65536 を推奨する。

> **出典**: [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) — "ULIMIT setting to be configured to 4096 or higher"

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

> **SELinux（Security-Enhanced Linux）とは**: Linux カーネルに組み込まれた強制アクセス制御（MAC）モジュール。プロセスごとにアクセスできるファイル・ネットワーク・システムコールを厳密に制限する。  
> **Collibra DQ への影響**: SELinux が `Enforcing` モードの場合、Java プロセス（DQ Agent・Spark）が以下の操作をブロックされる可能性がある。  
> - `${OWL_BASE}` 配下のファイル書き込み（ログ出力・JAR 展開）  
> - ネットワーク接続（Metastore への JDBC、Spark 内部通信）  
> 本番環境では `Enforcing` のままで適切な SELinux ポリシーを作成するか、インフラチームへ設定方針を確認すること（→ Todo A-10）。

```bash
# SELinux の状態確認
getenforce
# Enforcing / Permissive / Disabled のいずれかが返る

# Enforcing の場合、${OWL_BASE} 配下に正しいコンテキストを付与（要 sudo）
sudo restorecon -Rv "${OWL_BASE}"

# PoC 環境のみ: Permissive（警告ログのみ、ブロックしない）に変更
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

---

## 4. Collibra DQ パッケージの準備

### 4.1 Collibra Product Resource Center からのダウンロード

Collibra 社から提供されたアカウントで [Collibra Product Resource Center](https://productresources.collibra.com/) にログインし、インストールパッケージを取得する。

**ダウンロード対象ファイル:**

| ファイル | 説明 |
|---|---|
| `dq-full-package-2026.02.tar.gz` | DQ Web / DQ Agent / Spark を含むフルパッケージ |

> パッケージのダウンロード URL・認証情報は Collibra ライセンスメールに記載されている。

### 4.2 VM へのファイル転送

ダウンロードしたパッケージを VM に転送する。方法は環境に応じて選択すること。

#### 方法 A: scp で直接転送（推奨）

```bash
# ローカル端末から VM へ転送
scp dq-full-package-${DQ_VERSION}.tar.gz \
  <adminUser>@<VM_IPアドレス>:/tmp/
```

#### 方法 B: Azure Blob Storage 経由（大容量・帯域制限がある場合）

```bash
# ---- ローカル端末で実施 ----
# Blob Storage へアップロード
STORAGE_ACCOUNT="<ストレージアカウント名>"
CONTAINER_NAME="collibra-packages"

az storage container create \
  --account-name "${STORAGE_ACCOUNT}" \
  --name "${CONTAINER_NAME}" \
  --auth-mode login

az storage blob upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --container-name "${CONTAINER_NAME}" \
  --name "dq-full-package-${DQ_VERSION}.tar.gz" \
  --file "dq-full-package-${DQ_VERSION}.tar.gz" \
  --auth-mode login

# SAS URL を生成（有効期限: 1時間）
EXPIRY=$(date -u -d "1 hour" '+%Y-%m-%dT%H:%MZ')
SAS_URL=$(az storage blob generate-sas \
  --account-name "${STORAGE_ACCOUNT}" \
  --container-name "${CONTAINER_NAME}" \
  --name "dq-full-package-${DQ_VERSION}.tar.gz" \
  --permissions r \
  --expiry "${EXPIRY}" \
  --full-uri \
  --auth-mode login \
  --as-user \
  --output tsv)

echo "${SAS_URL}"

# ---- VM 上で実施 ----
# SAS URL でダウンロード
cd /tmp
curl -o "dq-full-package-${DQ_VERSION}.tar.gz" "${SAS_URL}"
```

### 4.3 パッケージの展開

```bash
# 作業ディレクトリに移動
cd /tmp

# ファイルの整合性確認（SHA256 チェックサムが Collibra から提供されている場合）
# sha256sum -c dq-full-package-${DQ_VERSION}.tar.gz.sha256

# 展開
tar -xvf dq-full-package-${DQ_VERSION}.tar.gz

# 展開後のディレクトリへ移動
cd dq

# ディレクトリ構造の確認
ls -la
```

**展開後のディレクトリ構造（インストーラーパッケージ）:**

> **出典**: [Directory structure](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_directory-structure.htm) — インストール後の公式ディレクトリ構造

```
dq/                    ← 展開したインストーラーパッケージ（作業用）
├── setup.sh           # セットアップスクリプト（5章で実行）
├── owlmanage.sh       # 起動・停止・暗号化スクリプト（→ インストール後は bin/ 内に配置）
├── owlcheck           # 動作確認バイナリ（→ インストール後は bin/ 内に配置）
├── bin/               # DQ アプリケーション JAR ファイル
├── config/            # 設定ファイルテンプレート
├── spark/             # Spark バイナリ（同梱版）
└── lib/               # 依存ライブラリ
```

### 4.4 スクリプトへの実行権限付与

```bash
chmod +x setup.sh owlmanage.sh owlcheck

# 確認
ls -la setup.sh owlmanage.sh owlcheck
# -rwxr-xr-x が付いていること
```

---

## 5. インストール（setup.sh の実行）

### 5.1 インストールコマンド

`setup.sh` は `-options` パラメータで構成するコンポーネントを指定する。本プロジェクトでは **Agent Only 構成を推奨**するが、フルインストールのコマンドも記載する。

#### パターン A: Agent Only 構成（本プロジェクト推奨）

グループ会社の DQ Web に接続し、Agent と Spark のみを自社 VM に構築する。

```bash
cd /tmp/dq

./setup.sh \
  -owlbase="${OWL_BASE}" \
  -options=spark,owlagent \
  -pguser="${METASTORE_USER}" \
  -pgpassword="${METASTORE_PASS}" \
  -pgserver="${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}"
```

#### パターン B: フルインストール（DQ Web も自社 VM に構築する場合）

```bash
cd /tmp/dq

./setup.sh \
  -owlbase="${OWL_BASE}" \
  -options=spark,owlweb,owlagent \
  -pguser="${METASTORE_USER}" \
  -pgpassword="${METASTORE_PASS}" \
  -pgserver="${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}"
```

### 5.2 setup.sh オプション引数一覧

> **出典**: [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm) — `setup.sh` の全オプション引数仕様

| パラメータ | 例 | 説明 |
|---|---|---|
| `-owlbase=` | `/opt/owl` | インストール先ディレクトリ（デフォルト: `/opt/owl`） |
| `-options=` | `spark,owlweb,owlagent` | インストールするコンポーネント（カンマ区切り） |
| `-pguser=` | `owluser` | メタストア PostgreSQL のユーザー名 |
| `-pgpassword=` | `<password>` | メタストア PostgreSQL のパスワード |
| `-pgserver=` | `host:5432/owlmetastore` | 外部 PostgreSQL の接続先（`ホスト:ポート/DB名` 形式） |
| `-port=` | `9000` | DQ Web のポート番号（デフォルト: `9000`） |
| `-user=` | `ec2-user` | インストール実行ユーザー（デフォルト: 現在のユーザー） |

**`-options=` に指定できる値:**

| 値 | コンポーネント | 説明 |
|---|---|---|
| `spark` | Spark | データ品質処理基盤（Spark Standalone Master + Worker）。Agent と組み合わせて使用 |
| `owlagent` | DQ Agent | ジョブ実行エンジン。メタストアをポーリングしてジョブを取得・実行 |
| `owlweb` | DQ Web | Web UI / REST API サーバー（フルインストール時のみ指定） |
| `postgres` | 内部 PostgreSQL | VM 内に PostgreSQL を構築する場合（外部 Metastore を使用する本手順では**不要**） |

### 5.3 インストール完了の確認

```bash
# インストール先ディレクトリの構造確認
ls -la "${OWL_BASE}/"
```

**期待されるディレクトリ構造（公式）:**

> **出典**: [Directory structure](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_directory-structure.htm)

```
/opt/owl/                          ← OWL_BASE
├── bin/                           # DQ バイナリ・JAR・管理スクリプト
│   ├── owlmanage.sh               # 起動・停止・暗号化スクリプト
│   ├── owlcheck                   # 動作確認バイナリ（.sh なし）
│   ├── owl-core-*-jar-with-dependencies.jar
│   ├── owl-agent-*.jar
│   ├── owl-webapp-*.jar
│   └── demo/
├── config/
│   ├── owl-env.sh                 # 環境変数・起動設定（6章で編集）
│   ├── owl.properties             # メタストア接続設定（8章で編集）
│   ├── agent.properties           # Agent・Spark 設定（11章で編集）
│   └── log4j*.properties
├── drivers/                       # 追加 JDBC ドライバー格納先
├── log/                           # ログ出力先（owl-web.log, owl-agent.log 等）
├── pids/                          # プロセス ID ファイル（*.pid）
├── spark/
│   ├── bin/
│   ├── sbin/
│   ├── conf/
│   ├── jars/
│   └── work/                      # Spark 一時ファイル（自動削除されない）
└── owl-postgres/                   # 内部 PostgreSQL（Agent Only では未使用）
```

```bash
# 主要ファイルの存在確認
ls -la "${OWL_BASE}/bin/owlmanage.sh" \
       "${OWL_BASE}/bin/owlcheck" \
       "${OWL_BASE}/config/owl-env.sh" \
       "${OWL_BASE}/config/owl.properties"

# Spark バイナリの確認
"${OWL_BASE}/spark/bin/spark-submit" --version
# 期待値例: version 4.1.0
```

### 5.4 インストール後の注意事項

> **パスワードについて**: `setup.sh` の `-pgpassword` に指定したパスワードは `owl.properties` に平文で記録される場合がある。6章の手順に従い、`owlmanage.sh encrypt` で必ず暗号化すること。

> **SELinux について**: SELinux が `Enforcing` の場合、`${OWL_BASE}` 配下のファイルに適切なコンテキストを付与する必要がある。
> ```bash
> sudo restorecon -Rv "${OWL_BASE}"
> ```

---

## 6. 認証・シークレットの設定

### 6.1 ライセンスキーの設定

`owl-env.sh` にライセンス情報を設定する。ライセンスキー・ライセンス名は Collibra ライセンスメールに記載されている。

> **出典**: [Complete the initial setup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) — "configure credentials by exporting `LICENSE_KEY` and `LICENSE_NAME` to the owl-env.sh file, then restart the DQ Web service"

```bash
# owl-env.sh を編集
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

以下の行を追記・編集する:

```bash
# ===== ライセンス =====
export LICENSE_KEY="<Collibraから提供されたライセンスキー>"
export LICENSE_NAME="<Collibraから提供されたライセンス名>"
```

### 6.2 パスワードの暗号化

`owl.properties` に記載するメタストアのパスワードは、平文ではなく `owlmanage.sh encrypt` で暗号化した値を使用する。

> ⚠️ **平文が残る問題**: `setup.sh` の `-pgpassword` オプションで指定したパスワードは `owl.properties` に**平文で書き込まれている**。必ず以下の手順で暗号化し、平文を ENC() に上書きすること。

```bash
cd "${OWL_BASE}"

# パスワードを暗号化（出力された文字列をコピーしておく）
./bin/owlmanage.sh encrypt="${METASTORE_PASS}"
# 出力例: ENC(XXXXXXXXXXXXXXXXXXXXXXXXX)
ENCRYPTED_PASS="ENC(XXXXXXXXXXXXXXXXXXXXXXXXX)"   # 上の出力値を変数に保存
```

> **次のステップ**: 出力された `ENC(...)` 形式の文字列で `owl.properties` 内の**既存の平文パスワードを上書き**する（8.3 節参照）。  
> このステップを忘れると `owl.properties` に平文パスワードが残った状態になるため必ず実施すること。

### 6.3 owl-env.sh の主要設定

`owl-env.sh` は DQ の起動パラメータを一元管理する設定ファイルである。以下を参考に必要な項目を設定する。

> **出典**: [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) — `owl-env.sh` / `owl.properties` の全パラメータ一覧

```bash
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

```bash
# ===== ライセンス =====
export LICENSE_KEY="<ライセンスキー>"
export LICENSE_NAME="<ライセンス名>"

# ===== パス =====
export OWL_BASE=/opt/owl
export SPARK_HOME="${OWL_BASE}/spark"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk   # 3章で確認したパスを設定

# ===== Java 17 対応オプション（2025.02 以降必須） =====
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"

# ===== DQ Web ポート =====
export SERVER_PORT=9000

# ===== メモリ（VM サイズに応じて調整） =====
export HEAP_MIN_SIZE=2g
export HEAP_MAX_SIZE=8g

# ===== ログ =====
export LOG_DIR="${OWL_BASE}/logs"
export LOG_LEVEL=INFO

# ===== コネクションプーリング =====
export SPRING_DATASOURCE_TOMCAT_MAXACTIVE=20
export SPRING_DATASOURCE_TOMCAT_MAXIDLE=10
export SPRING_DATASOURCE_TOMCAT_MAXWAIT=30000

# ===== マルチテナント（デフォルト: 無効） =====
export MULTITENANTMODE=FALSE
```

**HEAP サイズとは:**

> **Java Heap（ヒープ）**: JVM（Java 仮想マシン）が DQ アプリケーション（DQ Web / DQ Agent）のオブジェクトを格納するメモリ領域。  
> - 小さすぎると `OutOfMemoryError` が発生し、DQ サービスがクラッシュする  
> - 大きすぎると GC（ガベージコレクション）の停止時間が長くなり、レスポンスが悪化する  
> - **Spark Executor のメモリとは別管理**: Spark のメモリは `agent.properties` の `executorMemory` で設定する  
> - 目安: VM の RAM の **25〜30%** を DQ Web / Agent のヒープに割り当て、残りを Spark Executor に残す

**HEAP サイズの目安（VM RAM の 25〜30% を目安に設定）:**

| VM RAM | HEAP_MAX_SIZE の目安 | Spark Executor の残り RAM |
|---|---|---|
| 128 GB（Standard_E16s_v5） | 32g | ~96 GB（Executor × numExecutors） |
| 256 GB（Standard_E32s_v5） | 64g | ~192 GB |
| 512 GB（Standard_E64s_v5） | 128g | ~384 GB |

### 6.4 Azure Key Vault との統合（推奨）

本番環境では、ライセンスキーやパスワード類を Azure Key Vault で管理し、起動時にシェルスクリプトで取得する構成を推奨する。

#### Managed Identity の割り当て

```bash
# VM にシステム割り当て Managed Identity を有効化
az vm identity assign \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}"

# Managed Identity の Principal ID を取得
PRINCIPAL_ID=$(az vm show \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}" \
  --query identity.principalId \
  --output tsv)

echo "Principal ID: ${PRINCIPAL_ID}"
```

#### Key Vault へのアクセス権限付与

```bash
KEY_VAULT_NAME="<Key Vault 名>"

# Managed Identity に Key Vault シークレット読み取り権限を付与
az keyvault set-policy \
  --name "${KEY_VAULT_NAME}" \
  --object-id "${PRINCIPAL_ID}" \
  --secret-permissions get list
```

#### Key Vault へのシークレット登録

```bash
# ライセンスキーの登録
az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "dq-license-key" \
  --value "<ライセンスキー>"

# ライセンス名の登録
az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "dq-license-name" \
  --value "<ライセンス名>"

# メタストアパスワードの登録（平文で登録し、VM 上で暗号化する）
az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "dq-metastore-pass" \
  --value "<メタストアパスワード>"
```

#### 起動前スクリプトで Key Vault から取得

DQ 起動前に Key Vault からシークレットを取得し `owl-env.sh` に反映するラッパースクリプトを作成する。

```bash
sudo tee /opt/owl/start-with-keyvault.sh <<'SCRIPT'
#!/bin/bash
KEY_VAULT_NAME="<Key Vault 名>"

# Key Vault からシークレットを取得して環境変数に設定
export OWL_LICENSE_KEY=$(az keyvault secret show \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "dq-license-key" \
  --query value --output tsv)

export OWL_LICENSE_NAME=$(az keyvault secret show \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "dq-license-name" \
  --query value --output tsv)

# DQ を起動
/opt/owl/owlmanage.sh start
SCRIPT

sudo chmod +x /opt/owl/start-with-keyvault.sh
```

---

## 7. SSL/HTTPS 設定

> ⚠️ **Agent Only 構成（本プロジェクト）では本セクションは不要**  
> DQ Web は本 VM にインストールしないため、SSL/HTTPS の設定対象プロセスが存在しない。  
> **フルインストール（DQ Web も自社 VM に構築する）場合のみ実施すること。**  
> 本セクションは参考情報として残す。

---

DQ Web はデフォルトで HTTP（ポート 9000）で起動する。社内通信であっても HTTPS を有効化することを推奨する。

> **AKS / ARO との違い**: AKS では NGINX Ingress Controller が TLS 終端を担うが、スタンドアロンでは **VM の DQ Web プロセス自身が直接 TLS 終端を行う**。Ingress や Route の設定は不要。

### 7.1 証明書ディレクトリの作成

```bash
sudo mkdir -p "${OWL_BASE}/certs"
sudo chmod 750 "${OWL_BASE}/certs"
```

### 7.2 キーストアの作成

#### パターン A: 自己署名証明書（PoC・検証環境向け）

```bash
sudo keytool -genkey \
  -alias dq-server \
  -keystore "${OWL_BASE}/certs/keystore.p12" \
  -storetype PKCS12 \
  -keyalg RSA \
  -keysize 2048 \
  -validity 365 \
  -storepass "<キーストアパスワード>" \
  -dname "CN=<VMのFQDNまたはIPアドレス>, OU=IT, O=<組織名>, L=Tokyo, ST=Tokyo, C=JP"

# 確認
sudo keytool -list \
  -keystore "${OWL_BASE}/certs/keystore.p12" \
  -storetype PKCS12 \
  -storepass "<キーストアパスワード>"
```

#### パターン B: CA 署名済み証明書（本番環境向け）

社内 CA または公的 CA から発行された証明書（PEM 形式）を PKCS12 形式に変換する。

```bash
# PEM 形式の証明書・秘密鍵を PKCS12 に変換
sudo openssl pkcs12 -export \
  -in /path/to/server.crt \
  -inkey /path/to/server.key \
  -certfile /path/to/ca-chain.crt \
  -out "${OWL_BASE}/certs/keystore.p12" \
  -name "dq-server" \
  -passout pass:"<キーストアパスワード>"

# ファイルのパーミッション設定
sudo chmod 640 "${OWL_BASE}/certs/keystore.p12"
```

### 7.3 owl-env.sh への SSL 設定追記

```bash
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

以下を追記する:

```bash
# ===== SSL/HTTPS =====
export SERVER_HTTPS_ENABLED=true
export SERVER_HTTP_ENABLED=false            # HTTP を完全に無効化する場合は false
export SERVER_SSL_KEY_TYPE=PKCS12
export SERVER_SSL_KEY_STORE="${OWL_BASE}/certs/keystore.p12"
export SERVER_SSL_KEY_STORE_PASSWORD="<キーストアパスワード>"
export SERVER_SSL_KEY_ALIAS=dq-server
```

> `SERVER_HTTP_ENABLED=true` のままにすると HTTP と HTTPS の両方が有効になる。本番環境では `false` を推奨する。

### 7.4 設定後の確認コマンド

DQ 起動後（9章参照）に以下で HTTPS 接続を確認する。

```bash
# HTTPS でのヘルスチェック（自己署名証明書の場合は -k オプションが必要）
curl -sk https://localhost:${DQ_WEB_PORT}/dq/api/v1/health
# 期待値: {"status":"UP"} または 200 OK のレスポンス

# 証明書の詳細確認
echo | openssl s_client \
  -connect localhost:${DQ_WEB_PORT} \
  -showcerts 2>/dev/null \
  | openssl x509 -noout -dates -subject
```

---

## 8. 外部メタストア（PostgreSQL）接続設定

### 8.1 疎通確認

設定前に VM から Metastore への接続が可能であることを確認する。

```bash
# TCP 接続確認
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"
# 期待値: Connection to <host> 5432 port [tcp/postgresql] succeeded!

# psql でログイン確認（postgresql クライアントが必要）
sudo dnf install -y postgresql
psql \
  "host=${METASTORE_HOST} port=${METASTORE_PORT} dbname=${METASTORE_DB} \
   user=${METASTORE_USER} sslmode=require" \
  -c "\conninfo"
# 期待値: 接続情報が表示されること
```

### 8.2 フルインストール時のみ: Metastore DB・ユーザーの初期作成

**Agent Only 構成の場合、グループ会社側で Metastore が既に存在するためこの手順は不要。**

フルインストールで新規に Metastore を作成する場合のみ実施する。

```sql
-- Azure DB for PostgreSQL に接続して実行
-- ロールの作成
CREATE ROLE owluser WITH LOGIN PASSWORD '<平文パスワード>';
ALTER ROLE owluser CREATEDB;
ALTER ROLE owluser CREATEROLE;

-- データベースの作成
CREATE DATABASE owlmetastore OWNER owluser;

-- 権限付与
GRANT ALL PRIVILEGES ON DATABASE owlmetastore TO owluser;
\c owlmetastore
GRANT ALL PRIVILEGES ON SCHEMA public TO owluser;
```

### 8.3 owl.properties の接続設定

> **出典**:
> - [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) — Agent の Metastore 接続設定（パスワード暗号化コマンド `owlmanage.sh encrypt`、`spring.agent.datasource` パラメータ）
> - [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) — `owl.properties` 全パラメータ仕様

```bash
sudo vi "${OWL_BASE}/config/owl.properties"
```

**Agent Only 構成（本プロジェクト推奨）の設定:**

```properties
# ライセンス（owl-env.sh の OWL_LICENSE_NAME と同じ値）
owldomain=<ライセンス名>

# DQ Agent のメタストア接続
spring.agent.datasource.url=jdbc:postgresql://<METASTORE_HOST>:5432/owlmetastore\
?currentSchema=public&sslmode=require
spring.agent.datasource.username=<METASTORE_USER>
spring.agent.datasource.password=ENC(<6章で暗号化したパスワード>)
spring.agent.datasource.driver-class-name=org.postgresql.Driver
```

**フルインストール構成（DQ Web も自社 VM の場合）の追加設定:**

```properties
# DQ Web のメタストア接続（フルインストール時は DQ Web 用も設定）
spring.datasource.url=jdbc:postgresql://<METASTORE_HOST>:5432/owlmetastore\
?currentSchema=public&sslmode=require
spring.datasource.username=<METASTORE_USER>
spring.datasource.password=ENC(<6章で暗号化したパスワード>)
spring.datasource.driver-class-name=org.postgresql.Driver
```

**JDBC 接続文字列の `sslmode` 値:**

| sslmode | 説明 | 推奨場面 |
|---|---|---|
| `require` | SSL 必須（証明書検証なし） | Azure DB for PostgreSQL（**本手順での推奨値**） |
| `verify-ca` | CA 証明書を検証 | 社内 CA を使用する場合 |
| `verify-full` | CA 証明書 + ホスト名を検証 | より厳格なセキュリティが必要な場合 |
| `disable` | SSL 無効 | ローカル開発環境のみ |

### 8.4 Managed Identity によるパスワードレス認証（オプション）

Azure DB for PostgreSQL Flexible Server は Microsoft Entra ID（旧 Azure AD）認証に対応している。Managed Identity を使用することで、パスワードをファイルに保存せずに接続できる。

```bash
# VM の Managed Identity に PostgreSQL へのアクセスを許可（Azure Portal または az CLI）
az postgres flexible-server ad-admin set \
  --resource-group "${RG_NAME}" \
  --server-name "<PostgreSQL サーバー名>" \
  --display-name "${VM_NAME}" \
  --object-id "${PRINCIPAL_ID}"
```

> Managed Identity 認証を使用する場合、`owl.properties` のパスワード設定は不要になるが、JDBC ドライバの設定変更が別途必要。詳細は [Azure Database for PostgreSQL - Microsoft Entra 認証](https://learn.microsoft.com/ja-jp/azure/postgresql/flexible-server/how-to-configure-sign-in-azure-ad-authentication) を参照すること。

### 8.5 設定の確認

DQ 起動前に設定ファイルを最終確認する。

```bash
# owl.properties の確認（パスワードが ENC(...) 形式になっていること）
grep -E "datasource\.(url|username|password)" "${OWL_BASE}/config/owl.properties"

# owl-env.sh の確認（ライセンスキーが設定されていること）
grep -E "OWL_LICENSE|SERVER_PORT|HEAP" "${OWL_BASE}/config/owl-env.sh"
```

---

## 9. サービスの起動設定

### 9.1 初回起動

すべての設定ファイルが整ったら DQ を起動する。

> **出典**: [Troubleshooting](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-troubleshooting.htm) — `owlmanage.sh` のコンポーネント別コマンド体系

```bash
cd "${OWL_BASE}"

# 全コンポーネントを一括起動
./bin/owlmanage.sh start

# 全コンポーネントを一括停止
./bin/owlmanage.sh stop

# 全コンポーネントを再起動
./bin/owlmanage.sh restart
```

**コンポーネント個別の起動・停止（アップグレード時や障害対応で使用）:**

```bash
# DQ Web のみ停止 / 起動
./bin/owlmanage.sh stop=owlweb
./bin/owlmanage.sh start=owlweb

# DQ Agent のみ停止 / 起動
./bin/owlmanage.sh stop=owlagent
./bin/owlmanage.sh start=owlagent

# PostgreSQL（内部 Metastore を使用している場合のみ）
./bin/owlmanage.sh stop=postgres
./bin/owlmanage.sh start=postgres
```

**起動ログのリアルタイム確認:**

```bash
tail -f "${OWL_BASE}/log/owl-web.log"
```

**起動完了の目安となるログ出力:**

```
Started OwlApplication in XX.XXX seconds (JVM running for XX.XXX)
```

> 初回起動時はメタストアのスキーマ初期化が実行されるため、通常より時間がかかる（2〜5分程度）。

**Spark Master / Worker の起動確認:**

```bash
# Spark Master プロセス確認
ps -ef | grep -i "spark.*Master" | grep -v grep

# Spark Worker プロセス確認
ps -ef | grep -i "spark.*Worker" | grep -v grep
```

### 9.2 agent.properties の確認・設定

`agent.properties` は初回起動時に自動生成される。必要に応じて以下を確認・編集する。

```bash
# 初回起動後に生成されたことを確認
ls -la "${OWL_BASE}/config/agent.properties"

# 内容を確認・編集
sudo vi "${OWL_BASE}/config/agent.properties"
```

**主要設定項目:**

```properties
# Spark 実行設定
sparksubmitmode=native
sparkhome=/opt/owl/spark
sparkmaster=spark://<VMのIPアドレス>:7077

# Spark Executor リソース設定（VM サイズに応じて調整）
numExecutors=4
executorMemory=16g
executorCores=4
driverMemory=4g

# メタストア接続（owl.properties と同じ値）
metastorehost=<METASTORE_HOST>
metastoreport=5432
metastoredb=owlmetastore
metastoreuser=<METASTORE_USER>
metastorepassword=ENC(<暗号化済みパスワード>)

# Agent 識別子（複数 Agent を使用する場合は一意の値を設定）
agentid=1
```

**Executor リソース設定の目安（`Standard_E32s_v5` / 32 vCPU・256 GB RAM の場合）:**

| 設定項目 | 値 | 説明 |
|---|---|---|
| `numExecutors` | 4 | 同時起動する Spark Executor 数 |
| `executorMemory` | 16g | Executor 1つあたりのメモリ |
| `executorCores` | 4 | Executor 1つあたりのコア数 |
| `driverMemory` | 4g | Spark Driver のメモリ |

> `numExecutors × executorMemory` が VM の使用可能メモリを超えないように設定すること。

### 9.3 systemd サービスへの登録

> **sudo（root 権限）が必要な作業**  
> systemd への登録（`daemon-reload`・`enable`・`start`）はすべて root 権限が必要。  
> 本番環境ではインフラ担当チームへ作業依頼・確認を行うこと。

OS 再起動時に DQ が自動起動するよう systemd に登録する。

```bash
# サービスファイルを作成
sudo tee /etc/systemd/system/collibra-dq.service <<EOF
[Unit]
Description=Collibra DQ Service
After=network.target

[Service]
Type=forking
User=$(whoami)
WorkingDirectory=${OWL_BASE}
ExecStart=${OWL_BASE}/bin/owlmanage.sh start
ExecStop=${OWL_BASE}/bin/owlmanage.sh stop
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# systemd に登録・自動起動を有効化
sudo systemctl daemon-reload
sudo systemctl enable collibra-dq

# 手動で起動テスト
sudo systemctl start collibra-dq

# ステータス確認
sudo systemctl status collibra-dq
```

**期待される出力（起動成功時）:**

```
● collibra-dq.service - Collibra DQ Service
   Loaded: loaded (/etc/systemd/system/collibra-dq.service; enabled; ...)
   Active: active (running) since ...
```

### 9.4 複数 Agent 構成の起動手順（冗長化オプション A）

Agent Only 構成では ILB は不要。複数 VM をデプロイする場合、各 Agent が独立して Metastore をポーリングするため、それぞれ通常起動するだけでよい。

```bash
# ---- 各 Agent VM（vm-collibra-dq-1、vm-collibra-dq-2 等）で個別に実施 ----
sudo systemctl start collibra-dq
sudo systemctl status collibra-dq
```

各 Agent VM をデプロイ後、グループ会社の DQ Web UI（Admin Console → Agent Configuration）で  
それぞれの Agent を登録し、担当する Datasource を重複しないよう割り当てること（11章参照）。

### 9.5 オンデマンド起動パターン（推奨）

#### 考え方

DQ Agent はジョブ実行中のみ起動していればよい。ジョブ設定・結果参照は DQ Web と Metastore（グループ会社管理）だけで完結するため、**Agent VM は週1回のスキャン時間帯のみ起動**し、それ以外は Azure の **Deallocate（停止済み/割り当て解除）状態**に保つことで、コンピュート料金を大幅に削減できる。

> **Deallocate と Stop の違い**:  
> `az vm stop`（OS シャットダウン）はコンピュート料金が継続して発生する。  
> `az vm deallocate` はコンピュート料金が停止する（ディスク料金のみ発生）。

**コスト比較（Standard_E16s_v5・週1回スキャン想定）:**

```
【常時起動】
  ¥179.96/hr × 730 hr/月 = ¥131,371/月（VM のみ）

【オンデマンド起動】
  起動時間の目安: 起動バッファ 0.5h + スキャン 4h + 停止バッファ 0.5h = 5h/回
  月間稼働: 5h × 4.3回 = 約 22h/月
  ¥179.96/hr × 22h = ¥3,959/月（VM のみ）

VM コスト削減: ¥131,371 − ¥3,959 = ¥127,412/月（▲97%）
ディスク料金（OS + データ）は Deallocate 中も発生: ¥10,075/月（変化なし）

月額合計（オンデマンド）: ¥3,959 + ¥10,075 = ¥14,034/月
```

#### 前提：VM 起動時に DQ Agent が自動起動する設定

9.3 で `sudo systemctl enable collibra-dq` を設定済みであれば、VM 起動時に DQ Agent と Spark が自動起動する。Runbook / Logic Apps から VM を起動するだけで Agent が稼働状態になる。

---

#### パターン A：Azure Automation Runbook（推奨）

コード（PowerShell）でスケジュール実行・エラー時の自動停止まで制御できる最も柔軟な方法。

**セットアップ手順:**

```bash
# 1. Automation Account の作成
az automation account create \
  --resource-group "${RG_NAME}" \
  --name "aa-collibra-dq" \
  --location "${LOCATION}" \
  --sku Basic

# 2. Automation Account にシステム割り当て Managed Identity を有効化
az automation account update \
  --resource-group "${RG_NAME}" \
  --name "aa-collibra-dq" \
  --assign-identity "[system]"

# 3. Managed Identity の Principal ID を取得
AA_PRINCIPAL_ID=$(az automation account show \
  --resource-group "${RG_NAME}" \
  --name "aa-collibra-dq" \
  --query identity.principalId \
  --output tsv)

# 4. VM の起動・停止権限を付与（Virtual Machine Contributor）
SUBSCRIPTION_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"
az role assignment create \
  --assignee "${AA_PRINCIPAL_ID}" \
  --role "Virtual Machine Contributor" \
  --scope "${SUBSCRIPTION_SCOPE}"
```

**Runbook スクリプト（PowerShell）:**

```powershell
# DQ Agent VM オンデマンド起動・停止 Runbook
# Azure Automation で週次スケジュール実行する

param(
    [string]$ResourceGroupName = "rg-collibra-dq",
    [string]$VMName            = "vm-collibra-dq",
    [int]$AgentStartupWaitSec  = 120,     # VM 起動後 Agent 安定待機（秒）
    [int]$ScanDurationSec      = 14400    # スキャン所要時間の見込み（秒）= 4時間
)

# Managed Identity で Azure 認証
Connect-AzAccount -Identity

try {
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] VM 起動: $VMName"
    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] VM 起動完了"

    Write-Output "DQ Agent 起動待機 (${AgentStartupWaitSec}秒)..."
    Start-Sleep -Seconds $AgentStartupWaitSec

    Write-Output "スキャン実行中... $($ScanDurationSec / 3600) 時間待機"
    Start-Sleep -Seconds $ScanDurationSec

    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] VM を deallocate: $VMName"
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
    Write-Output "完了"
}
catch {
    Write-Error "エラー: $_"
    # エラー時もコスト防止のため強制 deallocate
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
    throw
}
```

**Runbook の登録とスケジュール設定:**

```bash
# Runbook を作成（PowerShell ファイルをアップロード）
az automation runbook create \
  --resource-group "${RG_NAME}" \
  --automation-account-name "aa-collibra-dq" \
  --name "Start-CollibraDQScan" \
  --type PowerShell

# スクリプトの内容を更新
az automation runbook replace-content \
  --resource-group "${RG_NAME}" \
  --automation-account-name "aa-collibra-dq" \
  --name "Start-CollibraDQScan" \
  --content @/path/to/Start-CollibraDQScan.ps1

# Runbook を発行
az automation runbook publish \
  --resource-group "${RG_NAME}" \
  --automation-account-name "aa-collibra-dq" \
  --name "Start-CollibraDQScan"

# 週次スケジュールの作成（例: 毎週日曜 01:00 JST = 16:00 UTC）
az automation schedule create \
  --resource-group "${RG_NAME}" \
  --automation-account-name "aa-collibra-dq" \
  --name "weekly-sunday-0100jst" \
  --frequency Week \
  --interval 1 \
  --start-time "2026-04-20T16:00:00+00:00" \
  --time-zone "UTC"
```

> スケジュールと Runbook のリンクは Azure Portal（Automation Account → Runbook → スケジュール）から設定する。

---

#### パターン B：Azure Logic Apps（ノーコード）

コードを書かずに設定できる簡易な方法。小規模・PoC 向け。

**フロー設計:**

```
[Recurrence（毎週日曜 01:00）]
    ↓
[Azure VM を起動]（Connector: Azure VM）
    ↓
[遅延：2 分]（DQ Agent 起動待機）
    ↓
[遅延：4 時間]（スキャン実行待機）
    ↓
[Azure VM を停止（Deallocate）]
```

Azure Portal → Logic Apps → 新規作成 → トリガー「Recurrence」→ アクション「Start virtual machine」→「Delay」→「Deallocate virtual machine」の順で構成する。

---

#### パターン比較

| 観点 | Automation Runbook | Logic Apps |
|---|---|---|
| 設定方法 | PowerShell コード | ノーコード（GUI） |
| エラー時の自動停止 | ✓（try/catch で実装） | 別途エラーハンドリングが必要 |
| スキャン完了の動的検知 | 拡張可能（API ポーリング追加） | 困難 |
| コスト | 月500分まで無料（Basic） | 実行ごとに課金（~¥0.002/アクション） |
| 推奨場面 | 本番・柔軟な制御が必要な場合 | PoC・簡易確認 |

---

#### 補足：スキャン完了を動的に検知する場合

`ScanDurationSec` に固定値を設定するのではなく、グループ会社の DQ Web REST API でジョブ状態をポーリングして完了を検知することも可能。

```powershell
# スキャン完了をポーリングで検知する拡張例（PowerShell 追記部分）
$DQWebHost  = "<グループ会社 DQ Web のホスト名>"
$DQJobName  = "<監視対象のジョブ名>"
$MaxWaitSec = 21600   # 最大 6 時間待機
$PollSec    = 300     # 5 分ごとにポーリング
$elapsed    = 0

while ($elapsed -lt $MaxWaitSec) {
    Start-Sleep -Seconds $PollSec
    $elapsed += $PollSec

    $response = Invoke-RestMethod `
        -Uri "https://${DQWebHost}:9000/dq/api/v1/jobs?jobName=${DQJobName}" `
        -Method Get `
        -Headers @{ Authorization = "Bearer <TOKEN>" }

    $latestStatus = $response | Sort-Object -Property startTime -Descending | Select-Object -First 1

    Write-Output "[$elapsed 秒経過] ジョブ状態: $($latestStatus.status)"

    if ($latestStatus.status -in @("PASSED", "FAILED", "ALERT")) {
        Write-Output "ジョブ完了: $($latestStatus.status)"
        break
    }
}
```

---

## 10. ネットワーク・外部アクセスの設定

### 10.1 ポート開放の最終確認

DQ 起動後、必要なポートが LISTEN 状態になっていることを確認する。

```bash
# LISTEN ポートの確認（DQ Agent + Spark のみ）
ss -tlnp | grep -E "8080|7077"
```

**期待される出力（Agent Only 構成）:**

```
LISTEN  0  128  0.0.0.0:8080   0.0.0.0:*  users:(("java",pid=XXXX,...))  # Spark Cluster UI
LISTEN  0  128  0.0.0.0:7077   0.0.0.0:*  users:(("java",pid=XXXX,...))  # Spark Master
```

> DQ Web は本 VM には存在しないため、ポート 9000 は LISTEN しない（正常）。

### 10.2 VM の IP アドレス確認

```bash
# Azure CLI で VM のプライベート IP を確認
az vm show \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}" \
  --show-details \
  --query privateIps \
  --output tsv
```

### 10.3 Metastore への疎通再確認

```bash
# Private Endpoint 経由での接続確認
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"
# 期待値: succeeded!

# DNS 解決確認（Private Endpoint の場合、プライベート IP に解決されること）
nslookup "${METASTORE_HOST}"
# 期待値: プライベート IP アドレス（10.x.x.x 等）が返ること
```

### 10.4 DQ Agent の動作確認（Metastore ポーリング確認）

DQ Agent は Metastore を JDBC でポーリングしてジョブを取得する。Agent が正常に動作していることを  
ログで確認する。

```bash
# Agent が Metastore への接続に成功しているかログで確認
grep -E "agent|metastore|polling" "${OWL_BASE}/log/owl-agent.log" | tail -20

# Metastore への疎通確認（Agent 側から実施）
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"
# 期待値: Connection succeeded
```

> DQ Agent から DQ Web（グループ会社）への直接通信は発生しない。Agent は Metastore を介して  
> ジョブ定義・実行結果を読み書きし、DQ Web は Metastore を介して状態を参照する。

---

## 11. DQ Agent の設定

DQ Agent は PostgreSQL メタストアを JDBC でポーリングしてジョブを取得・実行するコンポーネント。  
**Agent は DQ Web へ直接通信しない**。DQ Web・Agent ともに Metastore を経由して情報を共有する構成である。

Agent を DQ Web（グループ会社）に認識させるには、Admin Console でのレジストレーションが必要。

### 11.1 Agent の接続先確認

`owl.properties` の `spring.agent.datasource` がグループ会社管理の Metastore を指していることを確認する。

```bash
grep "spring.agent.datasource" "${OWL_BASE}/config/owl.properties"
# 期待値: グループ会社の METASTORE_HOST が設定されていること
```

### 11.2 Admin Console での Agent 登録

> **出典**: [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) — Admin Console からの Agent 登録手順（Base Path・Spark Deployment Mode・Executor 設定）

DQ Web UI（グループ会社、またはフルインストール時は自社 VM）にブラウザでログインし、Agent を登録する。

**操作手順:**

1. DQ Web UI にログイン（管理者アカウント）
2. 右上の歯車アイコン → **Settings** をクリック
3. 左メニューから **Admin Console** → **Agent Configuration** を選択
4. **Add Agent** をクリックし、以下を入力する

| 設定項目 | 入力値 | 説明 |
|---|---|---|
| Agent Display Name | `agent-vm-collibra-dq` | 任意の表示名（VM 名を含めると識別しやすい） |
| Base Path | `/opt/owl` | VM 上のインストールディレクトリ（`OWL_BASE` の値） |
| Spark Deployment Mode | `Client` | スタンドアロン構成では `Client` を選択 |
| Number of Executors | `4` | `agent.properties` の `numExecutors` と合わせる |
| Executor Memory (GB) | `16` | `agent.properties` の `executorMemory` と合わせる |
| Driver Memory (GB) | `4` | `agent.properties` の `driverMemory` と合わせる |
| Executor Cores | `4` | `agent.properties` の `executorCores` と合わせる |

5. **Save** をクリック
6. Agent Status が **Online** になることを確認する（数十秒〜1分程度かかる）

> ⚠️ **VM のリソース上限を超える値を入力した場合**: Spark Executor の起動に失敗し、ジョブが `WAITING` のまま進まないか `FAILED` になる。  
> 設定値の合計が VM の利用可能 RAM 以内に収まるよう確認すること。  
> 計算式: `numExecutors × executorMemory + driverMemory ≤ VM RAM − HEAP_MAX_SIZE − OS 予約（数 GB）`

### 11.3 Datasource の割り当て

Agent に Datasource（接続先データベース）を割り当てる。

**操作手順（Admin Console 画面から）:**

1. **Admin Console** → **Agent Configuration** で登録済み Agent を選択
2. 左パネル（未割り当ての Datasource 一覧）から使用する Datasource を選択
3. 中央の **→** ボタンをクリックして右パネル（割り当て済み）に移動
4. **Save** をクリック

### 11.4 Agent Online 確認

> **どの端末で実行するか**:  
> - **Agent Only 構成（本プロジェクト）**: Agent VM 上に DQ Web REST API は存在しない。REST API コマンドはグループ会社の DQ Web に向けて実行するか、DQ Web UI でブラウザから確認する。  
> - Agent VM 上では REST API コマンドは使えないため、ログ・プロセスで動作を確認する（下記参照）。

```bash
# ---- Agent VM 上での確認（Agent Only 構成） ----

# Agent プロセスが起動していること
ps -ef | grep owl-agent | grep -v grep

# Agent ログで Metastore ポーリングが動作していること
tail -20 "${OWL_BASE}/log/owl-agent.log"
# → "Polling metastore..." のような行が出力されていること

# ---- グループ会社 DQ Web または管理端末からの REST API 確認（フルインストール時・管理端末経由） ----
# フルインストール時（自社 VM の DQ Web に向けて）
curl -sk -u admin:<パスワード> \
  "https://localhost:${DQ_WEB_PORT}/dq/api/v1/agents" \
  | python3 -m json.tool | grep -E "name|status"

# Agent Only 構成時（グループ会社の DQ Web に向けて。DQ Web に疎通できる端末から実行）
curl -sk -u admin:<パスワード> \
  "https://${DQ_WEB_HOST}:${DQ_WEB_PORT}/dq/api/v1/agents" \
  | python3 -m json.tool | grep -E "name|status"
```

**期待される出力（Agent が Online の場合）:**

```json
"name": "agent-vm-collibra-dq",
"status": "ONLINE"
```

---

## 12. 動作確認

### 12.1 プロセス確認

```bash
# DQ Web / Agent プロセスの確認
ps -ef | grep owl | grep -v grep

# Spark Master / Worker プロセスの確認
ps -ef | grep spark | grep -v grep

# Java プロセス一覧（DQ Web・Spark が含まれること）
jps -l
```

**期待される出力例（フルインストール時）:**

```
XXXX org.springframework.boot.loader.JarLauncher       # DQ Web
XXXX org.apache.spark.deploy.master.Master             # Spark Master
XXXX org.apache.spark.deploy.worker.Worker             # Spark Worker
```

### 12.2 DQ Web UI へのアクセス確認

ブラウザで以下の URL にアクセスし、ログイン画面が表示されることを確認する。

| 構成 | URL |
|---|---|
| フルインストール（自社 VM） | `https://<VMのプライベートIP>:9000` |
| 冗長化（ILB 経由） | `https://<ILBのフロントエンドIP>:9000` |
| Agent Only（グループ会社 DQ Web） | `https://<DQ_WEB_HOST>:9000` |

**管理者パスワード要件（初回ログイン時に変更を求められる場合）:**

> **出典**: [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm) — パスワードポリシー要件

- 8〜72 文字
- 大文字を 1 文字以上含む
- 数字を 1 文字以上含む
- 特殊文字（`!`, `%`, `&`, `@`, `#`, `$`, `^`, `?`, `_`, `~`）を 1 文字以上含む

### 12.3 サンプルジョブの実行テスト

Agent が正常に動作していることを確認するため、テスト用の DQ ジョブを実行する。

**操作手順（DQ Web UI から）:**

1. DQ Web UI にログイン
2. 左メニューから **Profile** → **+ New Profile** をクリック
3. Datasource を選択し、テスト用のテーブル・カラムを指定
4. **Run** をクリックしてジョブを実行
5. ジョブが **PASSED** または **FAILED**（データ品質問題あり）で完了することを確認  
   ※ジョブが `RUNNING` のまま終わらない場合はトラブルシューティング（13章）を参照

**ジョブ実行中の Spark Worker プロセス確認:**

```bash
# Spark Executor が起動していることを確認
ps -ef | grep -i "CoarseGrainedExecutorBackend" | grep -v grep
```

### 12.4 ログの確認

```bash
# DQ Web ログ（起動・リクエスト処理）
tail -100 "${OWL_BASE}/log/owl-web.log"

# DQ Agent ログ（ジョブ取得・実行）
tail -100 "${OWL_BASE}/log/owl-agent.log"

# Spark Master ログ
tail -100 "${OWL_BASE}/spark/logs/spark-*-org.apache.spark.deploy.master.Master-*.out"

# エラーログの抽出
grep -E "ERROR|WARN" "${OWL_BASE}/log/owl-web.log" | tail -50
```

### 12.5 Spark Cluster UI の確認

ブラウザで `http://<VMのプライベートIP>:8080` にアクセスし、以下を確認する。

| 確認項目 | 期待値 |
|---|---|
| Workers | 1 以上が `ALIVE` 状態 |
| Status | `ALIVE` |
| Cores | VM の vCPU 数以下 |
| Memory | VM の RAM に近い値 |

### 12.6 Azure Monitor によるメトリクス確認

Azure Portal → 対象 VM → **監視** → **メトリック** で以下を確認する。

| メトリクス | 確認内容 |
|---|---|
| CPU 使用率 | 通常時は 20〜40%、ジョブ実行時に上昇すること |
| 使用可能メモリ | HEAP_MAX_SIZE の設定値より十分な空きがあること |
| ディスク IOPS | ログ・Spark 一時領域の書き込みが確認できること |

```bash
# VM 上からのリソース確認（コマンドライン）
# CPU・メモリの使用状況
top -b -n 1 | head -20

# ディスク使用量
df -h "${OWL_BASE}"

# ログディレクトリのサイズ
du -sh "${OWL_BASE}/log/"
```

---

## 13. トラブルシューティング

### 13.1 症状別対処表

> **出典**: [Troubleshooting](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-troubleshooting.htm) / [Troubleshooting upgrade (Standalone)](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/co_troubleshooting-upgrade.htm#tab-Standalone)

| 症状 | 主な原因 | 確認コマンド・対処法 |
|---|---|---|
| DQ Web が起動しない | ポート競合 / ライセンスキー不正 / HEAP 不足 | `ss -tlnp \| grep 9000`、`tail -50 ${OWL_BASE}/log/owl-web.log` |
| Agent が Offline のまま | Metastore 疎通不可 / パスワード暗号化ミス / agentid 重複 | `nc -zv ${METASTORE_HOST} 5432`、`grep password ${OWL_BASE}/config/owl.properties` |
| Spark ジョブが FAILED | Java/Spark バージョン不整合 / Executor メモリ不足 | `${OWL_BASE}/spark/bin/spark-submit --version`、`grep executorMemory ${OWL_BASE}/config/agent.properties` |
| HTTPS 接続エラー | 証明書パス誤り / キーストアパスワード誤り | `grep SERVER_SSL ${OWL_BASE}/config/owl-env.sh`、`keytool -list -keystore ${OWL_BASE}/certs/keystore.p12` |
| Metastore 接続エラー | NSG ブロック / Private Endpoint 未設定 / sslmode 不一致 | `nc -zv ${METASTORE_HOST} ${METASTORE_PORT}`、`nslookup ${METASTORE_HOST}` |
| OutOfMemoryError | HEAP_MAX_SIZE 不足 | `grep HEAP ${OWL_BASE}/config/owl-env.sh`、JVM ログ確認 |
| ULIMIT エラー（too many open files） | ファイルディスクリプタ上限超過 | `ulimit -n`（4096 以上であること）、2章の ULIMIT 設定を再実施 |
| `java.lang.reflect.*` 系エラー | EXTRA_JVM_OPTIONS 未設定 | `grep EXTRA_JVM ${OWL_BASE}/config/owl-env.sh` |
| ジョブが RUNNING のまま停止 | Spark Executor が起動失敗 / メモリ不足 | `ps -ef \| grep CoarseGrained`、Spark Master UI（:8080）でジョブ状態を確認 |
| ジョブが **Staged のままスタック** | スレッドプール上限不足 | `owl-env.sh` に以下を追加: `export SPRING_DATASOURCE_POOL_MAX_SIZE=1000` / `export SPRING_DATASOURCE_POOL_INITIAL_SIZE=150` |
| アップグレード後にログインできない | Spring Boot ヘッダー処理の問題 | `owl-env.sh` に `export SERVER_FORWARD_HEADERS_STRATEGY=FRAMEWORK` を追加して再起動 |
| `/opt/owl/bin/owlcheck: No such file` | `agent.properties` の `sparksubmitmode` 設定誤り | `grep sparksubmitmode ${OWL_BASE}/config/agent.properties` → `sparksubmitmode=native` であることを確認 |
| Spark ワーカーのディスク逼迫 | Spark 実行ログ・シャッフルファイルの蓄積 | `spark-env.sh` にワーカークリーンアップ設定を追加 / `sudo find ${OWL_BASE}/spark/work/* -mtime +1 -type f -delete` |

### 13.2 デバッグコマンド集

```bash
# ----- ログ確認 -----
# DQ Web のリアルタイムログ
tail -f "${OWL_BASE}/log/owl-web.log"

# DQ Agent のリアルタイムログ
tail -f "${OWL_BASE}/log/owl-agent.log"

# エラーのみ抽出
grep -n "ERROR" "${OWL_BASE}/log/owl-web.log" | tail -30

# ----- プロセス確認 -----
# DQ 関連プロセス一覧
ps -ef | grep -E "owl|spark" | grep -v grep

# Java プロセス（PID とクラス名）
jps -l

# ----- ネットワーク確認 -----
# LISTEN ポートの確認
ss -tlnp | grep -E "9000|8080|7077|5432"

# Metastore への疎通
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"

# ----- 設定ファイル確認 -----
# owl-env.sh の主要設定
grep -E "LICENSE|PORT|HEAP|SSL|JAVA_HOME" "${OWL_BASE}/config/owl-env.sh"

# owl.properties のデータソース設定
grep -E "datasource\.(url|username|password)" "${OWL_BASE}/config/owl.properties"

# agent.properties の Spark 設定
grep -E "spark|executor|driver|agentid" "${OWL_BASE}/config/agent.properties"

# ----- リソース確認 -----
# メモリ使用状況
free -h

# ディスク使用量
df -h

# ログディレクトリのサイズ（肥大化していないか確認）
du -sh "${OWL_BASE}/log/"*

# ----- systemd 確認 -----
sudo systemctl status collibra-dq
sudo journalctl -u collibra-dq --since "1 hour ago"
```

### 13.3 ログローテーションの設定

長期運用でログが肥大化しないよう logrotate を設定する。

```bash
sudo tee /etc/logrotate.d/collibra-dq <<EOF
${OWL_BASE}/log/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# 動作確認
sudo logrotate --debug /etc/logrotate.d/collibra-dq
```

---

## 14. アップグレード手順

> **出典**:
> - [Prepare environment for upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_prepare-environment-for-upgrade.htm) — アップグレード前チェックリスト
> - [Create a backup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_create-backup.htm) — バックアップ手順
> - [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) — アップグレード手順

> ⚠️ **重要**: アップグレード前に **VM ディスクのスナップショット**と **DQ Metastore のバックアップ**の両方を必ず取得すること。  
> Metastore は外部（グループ会社管理）のため、**事前にグループ会社へバックアップ取得を依頼すること**（公式必須要件）。  
>
> ⚠️ **ロールバックは公式非サポート**: 公式ドキュメントで "Rolling back Collibra DQ to an older version is not supported" と明記されている。復旧は Disk Snapshot からの VM 復元、または Metastore バックアップからの復元のみ対応可能。

### 14.0 定期バックアップ（運用設計）

アップグレード前だけでなく、定期的なバックアップを Azure Backup または Disk Snapshot で実施すること。

#### Azure Backup による自動バックアップ（推奨）

```bash
# Recovery Services ボールトの作成
az backup vault create \
  --resource-group "${RG_NAME}" \
  --name "vault-collibra-dq" \
  --location "${LOCATION}"

# VM バックアップの有効化（日次・保持 30日）
az backup protection enable-for-vm \
  --resource-group "${RG_NAME}" \
  --vault-name "vault-collibra-dq" \
  --vm "${VM_NAME}" \
  --policy-name "DefaultPolicy"
```

> `DefaultPolicy` はデフォルトで「日次バックアップ・30日保持」。  
> 週次・長期保持が必要な場合は Azure Portal でカスタムポリシーを作成すること。

#### 手動 Disk Snapshot（アップグレード直前など任意のタイミング）

```bash
# OS ディスクの Snapshot 取得
OS_DISK_ID=$(az vm show \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}" \
  --query "storageProfile.osDisk.managedDisk.id" \
  --output tsv)

az snapshot create \
  --resource-group "${RG_NAME}" \
  --name "snap-os-${VM_NAME}-$(date +%Y%m%d)" \
  --source "${OS_DISK_ID}"

# データディスクの Snapshot 取得（データディスクが存在する場合）
DATA_DISK_ID=$(az vm show \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}" \
  --query "storageProfile.dataDisks[0].managedDisk.id" \
  --output tsv)

az snapshot create \
  --resource-group "${RG_NAME}" \
  --name "snap-data-${VM_NAME}-$(date +%Y%m%d)" \
  --source "${DATA_DISK_ID}"

# スナップショット確認
az snapshot list \
  --resource-group "${RG_NAME}" \
  --query "[].{Name:name, Size:diskSizeGb, Time:timeCreated}" \
  --output table
```

### 14.1 アップグレード前の準備

> **出典**: [Prepare environment for upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_prepare-environment-for-upgrade.htm) — "Review all release notes after the version from which you are upgrading for any changes to critical areas (Helm charts, security updates, property changes, driver updates, API changes)"

#### バージョン確認

```bash
# 現在の DQ バージョンを確認（グループ会社 DQ Web UI → 右上の ? → About で Agent バージョンも確認可能）
# または owl-env.sh・パッケージ名から確認
ls "${OWL_BASE}/bin/" | grep -i owl | head -5
```

#### Java・Spark バージョン互換性の確認

| DQ バージョン | Java | Spark |
|---|---|---|
| **2026.02 以降** | **17** | **4.1.0** |
| 2025.08 〜 2026.01 | 17 | 3.5.6 |
| 2025.02 〜 2025.07 | 17 | 3.5.3 |
| 2025.01 以前 | 8 / 11 | 2.3.0 〜 3.4.1 |

アップグレード先のバージョンで Java・Spark の要件が変わる場合は、先に Java・Spark をアップグレードすること。

```bash
# 現在の Java バージョン確認
java -version

# 現在の Spark バージョン確認
"${OWL_BASE}/spark/bin/spark-submit" --version
```

#### アップグレード直前の Disk Snapshot 取得

```bash
# サービス停止前に Snapshot を取得しておく（14.0 の手動 Snapshot 手順を参照）
# スナップショット名にバージョンを含めると管理しやすい
az snapshot create \
  --resource-group "${RG_NAME}" \
  --name "snap-os-${VM_NAME}-pre-upgrade-$(date +%Y%m%d)" \
  --source "${OS_DISK_ID}"

az snapshot create \
  --resource-group "${RG_NAME}" \
  --name "snap-data-${VM_NAME}-pre-upgrade-$(date +%Y%m%d)" \
  --source "${DATA_DISK_ID}"
```

> **Metastore バックアップが必須な理由（技術的背景）**:  
> アップグレード実行時、DQ は Metastore（PostgreSQL）に対して **DB スキーママイグレーション**（テーブルの追加・カラムの変更・インデックス追加等）を自動実行する。  
> マイグレーション後のスキーマは新バージョン専用の構造になり、**旧バージョンの DQ バイナリとは非互換**になる。  
> これがロールバック公式非サポートの技術的理由であり、バックアップはこのマイグレーション**前**の状態を保存するものである。  
> バックアップがない状態でアップグレードが失敗した場合、旧バイナリに戻しても Metastore が動作せず、サービス復旧が困難になる。  
>
> Metastore はグループ会社管理のため、**アップグレード作業日の前日までにグループ会社へバックアップ取得を依頼し、完了確認を得てから作業を開始すること**。

### 14.2 サービスの停止

> **出典**: [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) — コンポーネント別停止コマンド

```bash
cd "${OWL_BASE}"

# DQ Agent を停止
./bin/owlmanage.sh stop=owlagent

# DQ Web を停止（フルインストール時）
./bin/owlmanage.sh stop=owlweb

# プロセスが完全に停止したことを確認
sleep 10
ps -ef | grep -E "owl|spark" | grep -v grep
# → 出力がないこと
```

### 14.3 旧バイナリのバックアップ

```bash
# 旧 bin/ をバックアップ（ロールバック用）
mv "${OWL_BASE}/bin" "${OWL_BASE}/bin.backup.$(date +%Y%m%d)"

# 旧 spark/ をバックアップ（Spark バージョンが変わる場合）
mv "${OWL_BASE}/spark" "${OWL_BASE}/spark.backup.$(date +%Y%m%d)"
```

### 14.4 新パッケージの展開と差し替え

```bash
# 新パッケージを /tmp に転送・展開（4章と同様の手順）
cd /tmp
tar -xvf dq-full-package-<NEW_VERSION>.tar.gz
cd dq

# bin/ を差し替え
mkdir -p "${OWL_BASE}/bin"
cp -r bin/* "${OWL_BASE}/bin/"

# spark/ を差し替え（Spark バージョンが変わる場合のみ）
cp -r spark "${OWL_BASE}/spark"

# 管理スクリプトを更新
cp owlmanage.sh "${OWL_BASE}/bin/owlmanage.sh"
cp owlcheck "${OWL_BASE}/bin/owlcheck"
chmod +x "${OWL_BASE}/bin/owlmanage.sh" "${OWL_BASE}/bin/owlcheck"
```

### 14.5 サービスの起動と動作確認

```bash
cd "${OWL_BASE}"

# 起動
./bin/owlmanage.sh start

# 起動ログの確認
tail -f "${OWL_BASE}/log/owl-web.log"
# → "Started OwlApplication in XX seconds" が出力されること
```

DQ Web UI にログインし、**右上の ? → About** でバージョンが新バージョンになっていることを確認する。

### 14.6 ロールバック手順

> ⚠️ **公式非サポート**: Collibra 公式ドキュメントで **"Rolling back Collibra DQ to an older version is not supported"** と明記されている。
> 出典: [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm)
>
> 以下の方法は公式サポート外の緊急対応手順である。**Disk Snapshot（方法 A）を強く推奨**する。
> 方法 B（bin.backup 差し替え）は Metastore スキーマとの不整合が発生するリスクがあり、最終手段として位置づける。

#### 方法 A: Disk Snapshot からディスクを復元（推奨）

```bash
# DQ サービスを停止
sudo systemctl stop collibra-dq

# Snapshot からディスクを復元
SNAP_DATE="<スナップショット取得日 例: 20260416>"

# OS ディスクの復元
az disk create \
  --resource-group "${RG_NAME}" \
  --name "disk-os-${VM_NAME}-restored" \
  --source "snap-os-${VM_NAME}-pre-upgrade-${SNAP_DATE}"

# データディスクの復元
az disk create \
  --resource-group "${RG_NAME}" \
  --name "disk-data-${VM_NAME}-restored" \
  --source "snap-data-${VM_NAME}-pre-upgrade-${SNAP_DATE}"

# VM のディスクを復元したものに差し替え（Azure Portal または az コマンド）
# → Azure Portal: VM → ディスク → OS ディスクのスワップ
```

> Metastore（グループ会社管理）のロールバックが必要な場合は、グループ会社の DBA に依頼すること。

#### 方法 B: bin.backup からの差し替え（軽微な問題の場合）

```bash
cd "${OWL_BASE}"

# DQ サービスを停止
./bin/owlmanage.sh stop

# 新バイナリを削除して旧バイナリに戻す
BACKUP_DATE="<バックアップ時の日付 例: 20260416>"
rm -rf "${OWL_BASE}/bin"
mv "${OWL_BASE}/bin.backup.${BACKUP_DATE}" "${OWL_BASE}/bin"

# Spark バージョンが変わっていた場合
rm -rf "${OWL_BASE}/spark"
mv "${OWL_BASE}/spark.backup.${BACKUP_DATE}" "${OWL_BASE}/spark"

# サービスを再起動
./bin/owlmanage.sh start
```

---

## 参考リンク

### Collibra 公式ドキュメント（Standalone）

| ドキュメント | URL | 参照章 |
|---|---|---|
| インストール前提条件 | [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm) | §1.3, §12.2 |
| スタンドアロンインストール | [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm) | §5 |
| 初期セットアップ完了 | [Complete the initial setup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) | §6.1, §9 |
| 設定オプション一覧 | [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) | §6.3, §8.3 |
| Spark スクリプト一覧 | [Spark scripts](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-spark-scripts.htm) | §9 |
| Agent 設定 | [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) | §8.3, §11 |
| FIPS 設定 | [Configure FIPS](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-fips.htm) | （FIPS 要件がある場合） |
| トラブルシューティング | [Troubleshooting](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-troubleshooting.htm) | §13 |
| システム要件 | [System requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm) | §1.3, §2.2 |
| アップグレード前準備 | [Prepare environment for upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_prepare-environment-for-upgrade.htm) | §14.1 |
| バックアップ作成 | [Create a backup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_create-backup.htm) | §14.0, §14.1 |
| アップグレード要件 | [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) | §2.2, §2.6, §14.1 |
| Spark アップグレード | [Upgrade Spark](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-spark.htm) | §14.4 |
| DQ アップグレード手順 | [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) | §14.2〜14.5 |
| アップグレード後トラブルシューティング | [Troubleshooting upgrade (Standalone)](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/co_troubleshooting-upgrade.htm#tab-Standalone) | §13.1 |

### Azure 公式ドキュメント

| ドキュメント | URL | 参照章 |
|---|---|---|
| Azure DB for PostgreSQL Entra 認証 | [Microsoft Entra 認証の設定](https://learn.microsoft.com/ja-jp/azure/postgresql/flexible-server/how-to-configure-sign-in-azure-ad-authentication) | §8.4 |
| Azure Key Vault シークレット管理 | [Azure Key Vault のクイックスタート](https://learn.microsoft.com/ja-jp/azure/key-vault/secrets/quick-create-cli) | §6.4 |
