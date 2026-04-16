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

**展開後のディレクトリ構造（例）:**

```
dq/
├── setup.sh          # セットアップスクリプト（5章で実行）
├── owlmanage.sh      # 起動・停止・暗号化スクリプト
├── owlcheck.sh       # 動作確認スクリプト
├── bin/              # DQ アプリケーション JAR ファイル
├── config/           # 設定ファイルテンプレート
├── spark/            # Spark バイナリ（同梱版）
└── lib/              # 依存ライブラリ
```

### 4.4 スクリプトへの実行権限付与

```bash
chmod +x setup.sh owlmanage.sh owlcheck.sh

# 確認
ls -la setup.sh owlmanage.sh owlcheck.sh
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

**期待されるディレクトリ構造:**

```
/opt/owl/
├── owlmanage.sh          # 起動・停止スクリプト
├── owlcheck.sh           # 動作確認スクリプト
├── bin/                  # DQ アプリケーション JAR
├── config/
│   ├── owl-env.sh        # 環境変数・起動設定（6章で編集）
│   ├── owl.properties    # メタストア接続設定（8章で編集）
│   └── agent.properties  # Agent・Spark 設定（11章で編集）
├── logs/                 # ログ出力先
└── spark/                # Spark バイナリ
    ├── bin/
    ├── sbin/
    └── conf/
```

```bash
# 主要ファイルの存在確認
ls -la "${OWL_BASE}/owlmanage.sh" \
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

```bash
# owl-env.sh を編集
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

以下の行を追記・編集する:

```bash
# ===== ライセンス =====
export OWL_LICENSE_KEY="<Collibraから提供されたライセンスキー>"
export OWL_LICENSE_NAME="<Collibraから提供されたライセンス名>"
```

### 6.2 パスワードの暗号化

`owl.properties` に記載するメタストアのパスワードは、平文ではなく `owlmanage.sh encrypt` で暗号化した値を使用する。

```bash
cd "${OWL_BASE}"

# パスワードを暗号化（出力された文字列をコピーしておく）
./owlmanage.sh encrypt="${METASTORE_PASS}"
# 出力例: ENC(XXXXXXXXXXXXXXXXXXXXXXXXX)
```

> 出力された `ENC(...)` 形式の文字列を次節の `owl.properties` に設定する。

### 6.3 owl-env.sh の主要設定

`owl-env.sh` は DQ の起動パラメータを一元管理する設定ファイルである。以下を参考に必要な項目を設定する。

```bash
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

```bash
# ===== ライセンス =====
export OWL_LICENSE_KEY="<ライセンスキー>"
export OWL_LICENSE_NAME="<ライセンス名>"

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

**HEAP サイズの目安（VM RAM の 25〜30% を目安に設定）:**

| VM RAM | HEAP_MAX_SIZE の目安 |
|---|---|
| 128 GB（Standard_E16s_v5） | 32g |
| 256 GB（Standard_E32s_v5） | 64g |
| 512 GB（Standard_E64s_v5） | 128g |

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

```bash
cd "${OWL_BASE}"

# 起動
./owlmanage.sh start

# 停止
./owlmanage.sh stop

# 再起動
./owlmanage.sh restart
```

**起動ログのリアルタイム確認:**

```bash
tail -f "${OWL_BASE}/logs/owl-web.log"
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
ExecStart=${OWL_BASE}/owlmanage.sh start
ExecStop=${OWL_BASE}/owlmanage.sh stop
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

### 9.4 Active-Standby 2台構成の起動手順（冗長化オプション A）

2台構成を採用する場合、通常は vm-collibra-dq-1 のみ起動した状態で運用し、障害時に vm-collibra-dq-2 を起動する。

```bash
# ---- vm-collibra-dq-1（Active）で実施 ----
sudo systemctl start collibra-dq
sudo systemctl status collibra-dq

# ---- vm-collibra-dq-2（Standby）で実施 ----
# Standby では DQ サービスを停止状態にしておく
sudo systemctl stop collibra-dq
sudo systemctl disable collibra-dq   # 自動起動は無効（手動フェイルオーバー時のみ起動）
```

> Azure Internal Load Balancer の Health Probe（TCP 9000）により、Active VM がダウンした際にトラフィックが自動的に Standby へ切り替わる。切り替わり後、Standby VM 上で `sudo systemctl start collibra-dq` を手動実行すること。

---

## 10. ネットワーク・外部アクセスの設定

### 10.1 ポート開放の最終確認

DQ 起動後、必要なポートが LISTEN 状態になっていることを確認する。

```bash
# LISTEN ポートの確認
ss -tlnp | grep -E "9000|8080|7077"
```

**期待される出力:**

```
LISTEN  0  128  0.0.0.0:9000   0.0.0.0:*  users:(("java",pid=XXXX,...))
LISTEN  0  128  0.0.0.0:8080   0.0.0.0:*  users:(("java",pid=XXXX,...))  # Spark Cluster UI
LISTEN  0  128  0.0.0.0:7077   0.0.0.0:*  users:(("java",pid=XXXX,...))  # Spark Master
```

**VM 自身からのヘルスチェック:**

```bash
# HTTP の場合
curl -s http://localhost:${DQ_WEB_PORT}/dq/api/v1/health

# HTTPS の場合（7章で SSL を有効化した場合）
curl -sk https://localhost:${DQ_WEB_PORT}/dq/api/v1/health
# 期待値: {"status":"UP"} または 200 OK
```

### 10.2 社内端末からのアクセス確認

#### VM の IP アドレス・FQDN 確認

```bash
# Azure CLI で VM のプライベート IP を確認
az vm show \
  --resource-group "${RG_NAME}" \
  --name "${VM_NAME}" \
  --show-details \
  --query privateIps \
  --output tsv
```

#### 社内端末からの接続確認

```bash
# 社内端末（Windows PowerShell / Mac ターミナル）から実行
# HTTP の場合
curl http://<VMのプライベートIP>:9000/dq/api/v1/health

# HTTPS の場合
curl -sk https://<VMのプライベートIP>:9000/dq/api/v1/health
```

ブラウザで `https://<VMのプライベートIP>:9000` にアクセスし、DQ Web のログイン画面が表示されることを確認する。

### 10.3 Metastore への疎通再確認

```bash
# Private Endpoint 経由での接続確認
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"
# 期待値: succeeded!

# DNS 解決確認（Private Endpoint の場合、プライベート IP に解決されること）
nslookup "${METASTORE_HOST}"
# 期待値: プライベート IP アドレス（10.x.x.x 等）が返ること
```

### 10.4 グループ会社 DQ Web への接続確認（Agent Only 構成時）

Agent Only 構成では、VM 上の DQ Agent がグループ会社の DQ Web のメタストアをポーリングする。

```bash
# グループ会社 DQ Web へのネットワーク疎通確認
nc -zv "${DQ_WEB_HOST}" "${DQ_WEB_PORT}"

# HTTPS でのヘルスチェック
curl -sk "https://${DQ_WEB_HOST}:${DQ_WEB_PORT}/dq/api/v1/health"
# 期待値: 200 OK
```

### 10.5 Azure Internal Load Balancer の設定（冗長化オプション A のみ）

Active-Standby 2台構成を採用する場合のみ実施する。

```bash
# Internal Load Balancer の作成
az network lb create \
  --resource-group "${RG_NAME}" \
  --name "lb-collibra-dq" \
  --sku Standard \
  --vnet-name "${VNET_NAME}" \
  --subnet "${SUBNET_NAME}" \
  --frontend-ip-name "fe-collibra-dq" \
  --backend-pool-name "be-collibra-dq"

# ヘルスプローブの作成（TCP 9000 で死活監視）
az network lb probe create \
  --resource-group "${RG_NAME}" \
  --lb-name "lb-collibra-dq" \
  --name "probe-dq-web" \
  --protocol Tcp \
  --port "${DQ_WEB_PORT}" \
  --interval 15 \
  --threshold 2

# 負荷分散ルールの作成
az network lb rule create \
  --resource-group "${RG_NAME}" \
  --lb-name "lb-collibra-dq" \
  --name "rule-dq-web" \
  --protocol Tcp \
  --frontend-port "${DQ_WEB_PORT}" \
  --backend-port "${DQ_WEB_PORT}" \
  --frontend-ip-name "fe-collibra-dq" \
  --backend-pool-name "be-collibra-dq" \
  --probe-name "probe-dq-web"

# 両 VM の NIC をバックエンドプールに追加
for VM in "vm-collibra-dq-1" "vm-collibra-dq-2"; do
  NIC_ID=$(az vm show \
    --resource-group "${RG_NAME}" \
    --name "${VM}" \
    --query "networkProfile.networkInterfaces[0].id" \
    --output tsv)

  az network nic ip-config update \
    --resource-group "${RG_NAME}" \
    --nic-name "$(basename ${NIC_ID})" \
    --name ipconfig1 \
    --lb-name "lb-collibra-dq" \
    --lb-address-pools "be-collibra-dq"
done

# ILB のフロントエンド IP 確認
az network lb frontend-ip show \
  --resource-group "${RG_NAME}" \
  --lb-name "lb-collibra-dq" \
  --name "fe-collibra-dq" \
  --query privateIpAddress \
  --output tsv
```

> 社内端末からは ILB のフロントエンド IP（プライベート IP）を使って DQ Web にアクセスする。

---

## 11. DQ Agent の設定

DQ Agent は PostgreSQL メタストアをポーリングしてジョブを取得・実行するコンポーネント。Agent が DQ Web に認識されるよう Admin Console から登録を行う。

### 11.1 Agent の接続先確認（Agent Only 構成）

Agent Only 構成では、`owl.properties` の `spring.agent.datasource` がグループ会社のメタストアを指していることを確認する。

```bash
grep "spring.agent.datasource" "${OWL_BASE}/config/owl.properties"
# 期待値: グループ会社の METASTORE_HOST が設定されていること
```

### 11.2 Admin Console での Agent 登録

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

### 11.3 Datasource の割り当て

Agent に Datasource（接続先データベース）を割り当てる。

**操作手順（Admin Console 画面から）:**

1. **Admin Console** → **Agent Configuration** で登録済み Agent を選択
2. 左パネル（未割り当ての Datasource 一覧）から使用する Datasource を選択
3. 中央の **→** ボタンをクリックして右パネル（割り当て済み）に移動
4. **Save** をクリック

### 11.4 Agent Online 確認

```bash
# DQ REST API で Agent の状態を確認
# フルインストール時（自社 VM の DQ Web）
curl -sk -u admin:<パスワード> \
  "https://localhost:${DQ_WEB_PORT}/dq/api/v1/agents" \
  | python3 -m json.tool | grep -E "name|status"

# Agent Only 構成時（グループ会社の DQ Web）
curl -sk -u admin:<パスワード> \
  "https://${DQ_WEB_HOST}:${DQ_WEB_PORT}/dq/api/v1/agents" \
  | python3 -m json.tool | grep -E "name|status"
```

**期待される出力（Agent が Online の場合）:**

```json
"name": "agent-vm-collibra-dq",
"status": "ONLINE"
```
