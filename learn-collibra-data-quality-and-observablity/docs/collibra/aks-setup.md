# Collibra DQ AKS セットアップ手順書

> **対象バージョン**: Collibra DQ 2026.02  
> **前提**: AKS クラスター基盤が構築済みであること（[aks-build.md](../kubernetes/aks-build.md) 参照）  
> **公式ドキュメント**: [EKS / GKE / AKS - Collibra Product Resource Center](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/EKS%20%20GKE%20%20AKS.htm)

---

## 目次

1. [はじめに](#1-はじめに)
2. [事前準備](#2-事前準備)
3. [コンテナイメージの準備と ACR 転送](#3-コンテナイメージの準備と-acr-転送)
4. [Helm チャートの準備](#4-helm-チャートの準備)
5. [ストレージの設定](#5-ストレージの設定)
6. [認証・シークレットの設定](#6-認証シークレットの設定)
7. [SSL/HTTPS 設定](#7-sslhttps-設定)
8. [外部メタストア（PostgreSQL）接続設定](#8-外部メタストアpostgresql接続設定)
9. [Collibra DQ のデプロイ（Helm）](#9-collibra-dq-のデプロイhelm)
10. [ネットワーク・外部アクセスの設定](#10-ネットワーク外部アクセスの設定)
11. [DQ Agent の設定](#11-dq-agent-の設定)
12. [動作確認](#12-動作確認)
13. [トラブルシューティング](#13-トラブルシューティング)
14. [アップグレード手順](#14-アップグレード手順)
15. [参考リンク](#15-参考リンク)

---

## 1. はじめに

### 1.1 ドキュメントの目的と範囲

本ドキュメントは、Azure Kubernetes Service (AKS) 上に Collibra DQ (Data Quality) をデプロイするための詳細なセットアップ手順を記載する。

**対象読者**: AKS の基本操作（kubectl / helm）を理解しているインフラエンジニア・システムエンジニア

**対象範囲**:

| スコープ | 本ドキュメントの扱い |
|---|---|
| AKS クラスター構築（VNET / ACR / ノードプール等） | 対象外（`aks-build.md` 参照） |
| Collibra DQ アプリケーションのデプロイ・設定 | **対象** |
| DQ Agent の接続・Spark 設定 | **対象** |
| Collibra DQ の日常運用・監視 | 一部対象（動作確認・アップグレードのみ） |

**デプロイ対象コンポーネント**:

| コンポーネント | 役割 |
|---|---|
| DQ Web | Web UI / REST API サーバー（ポート 9000） |
| DQ Agent | Spark ジョブ実行エンジン（ポート 9101） |
| Spark | データ品質チェック処理基盤（Executor Pod として動的生成） |

### 1.2 前提条件

本手順を実施する前に、以下がすべて完了していることを確認すること。

#### インフラ層（`aks-build.md` で構築済み）

| 項目 | 確認方法 |
|---|---|
| AKS クラスター（`aks-collibra-dq`）が Running 状態 | `az aks show -g rg-collibra-dq -n aks-collibra-dq --query provisioningState` |
| DQ 用ノードプール（`dqpool`）が Ready | `kubectl get nodes -l agentpool=dqpool` |
| ACR（`acrcollibradq`）が AKS にアタッチ済み | `az aks show -g rg-collibra-dq -n aks-collibra-dq --query addonProfiles` |
| 管理用 Linux VM（`vm-aks-mgmt`）に SSH 接続可能 | SSH 接続確認 |
| kubectl・helm が管理 VM にインストール済み | `kubectl version --client` / `helm version` |
| Azure Database for PostgreSQL（外部メタストア）が起動済み | Azure Portal または az コマンドで確認 |
| Private Endpoint 経由で metastore に疎通可能 | `nc -zv <host> 5432` |

#### ライセンス・認証情報（Collibra 社から取得済み）

| 項目 | 取得先 |
|---|---|
| ライセンスキー（`license_key`） | Collibra ライセンスメール |
| ライセンス名（`license_name`） | Collibra ライセンスメール |
| コンテナイメージ取得用認証情報（ユーザー名・パスワード） | Collibra ライセンスメール |
| Helm チャート ZIP ファイルのダウンロード URL | Collibra ライセンスメール |

#### バージョン要件

| ソフトウェア | 要件 | 本環境の値 |
|---|---|---|
| Collibra DQ | 2026.02 | 2026.02 |
| Spark | 4.1.0（DQ 2026.02 必須） | 4.1.0 |
| Java | 17（DQ 2026.02 必須） | 17（コンテナ内蔵） |
| Kubernetes | 1.29〜1.34 | 1.32 |
| Helm | v3 以上 | v3.x |
| PostgreSQL | 13 以上 | Azure DB for PostgreSQL Flexible Server |

### 1.3 関連ドキュメント一覧

| ドキュメント | 内容 | 参照タイミング |
|---|---|---|
| `docs/collibra/report.md` | Collibra DQ 製品概要・システム要件 | 製品仕様確認時 |
| `docs/collibra/deployment-comparison.md` | デプロイ構成比較（AKS 推奨の根拠） | 構成検討時 |
| `docs/collibra/setup.md` | スタンドアロン・Kubernetes インストール概要 | 構成概要の確認時 |
| `docs/kubernetes/aks-design.md` | AKS 設計書（Hub-Spoke 構成） | インフラ設計確認時 |
| `docs/kubernetes/aks-build.md` | AKS 基盤構築手順（インフラ層） | **本手順の前提作業** |
| `docs/kubernetes/helm.md` | Helm 基礎知識 | Helm 操作の参考 |

---

## 2. 事前準備

### 2.1 変数定義

本手順全体で使用する環境変数を定義する。`aks-build.md` と同一の値を使用する。

```bash
# ---- Azure 基本情報 ----
SUBSCRIPTION_ID="<サブスクリプションID>"
LOCATION="japaneast"
RG_NAME="rg-collibra-dq"

# ---- AKS ----
AKS_NAME="aks-collibra-dq"

# ---- ACR ----
ACR_NAME="acrcollibradq"
ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"

# ---- Collibra DQ アプリケーション ----
NAMESPACE="collibra-dq"
DQ_VERSION="2026.02"
SPARK_VERSION="4.1.0"
HELM_RELEASE_NAME="collibra-dq"

# ---- Collibra イメージレジストリ（Collibra 社提供） ----
COLLIBRA_REGISTRY="<Collibraから提供されたレジストリURL>"
COLLIBRA_REGISTRY_USER="<提供されたユーザー名>"
COLLIBRA_REGISTRY_PASS="<提供されたパスワード>"

# ---- ライセンス情報（Collibra 社提供） ----
DQ_LICENSE_KEY="<ライセンスキー>"
DQ_LICENSE_NAME="<ライセンス名>"

# ---- メタストア（Azure DB for PostgreSQL） ----
METASTORE_HOST="<PostgreSQL のホスト名>.postgres.database.azure.com"
METASTORE_PORT="5432"
METASTORE_DB="owlmetastore"
METASTORE_USER="<DBユーザー名>"
METASTORE_PASS="<DBパスワード>"

# ---- DQ 管理者アカウント ----
DQ_ADMIN_EMAIL="<管理者メールアドレス>"
DQ_ADMIN_PASS="<管理者パスワード>"   # 8〜72文字・大文字/数字/特殊文字を各1字以上含む

# ---- Helm チャートパス ----
CHART_PATH="/home/${USER}/collibra-dq-chart"   # Helm チャート展開先（3章で設定）
```

> **注意**: パスワード類はシェル変数に直接書かず、Azure Key Vault や `.env` ファイル（Git 管理外）から読み込むことを推奨する。

### 2.2 AKS クラスターへの接続確認

管理用 Linux VM から AKS クラスターへの認証情報を取得し、ノードの状態を確認する。

```bash
# Azure ログイン・サブスクリプション切り替え
az login
az account set --subscription "${SUBSCRIPTION_ID}"

# AKS の kubeconfig を取得
az aks get-credentials \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --overwrite-existing

# 接続確認
kubectl cluster-info
```

**期待される出力例:**
```
Kubernetes control plane is running at https://aks-collibra-dq-xxxxx.privatelink.japaneast.azmk8s.io:443
```

```bash
# ノード一覧と状態確認
kubectl get nodes -o wide
```

**期待される出力例（全ノードが Ready）:**
```
NAME                              STATUS   ROLES    AGE   VERSION
aks-system-xxxxx-vmss000000       Ready    <none>   1d    v1.32.x
aks-dqpool-xxxxx-vmss000000       Ready    <none>   1d    v1.32.x
aks-dqpool-xxxxx-vmss000001       Ready    <none>   1d    v1.32.x
aks-dqpool-xxxxx-vmss000002       Ready    <none>   1d    v1.32.x
```

```bash
# DQ 用ノードプールの確認
kubectl get nodes -l agentpool=dqpool
```

### 2.3 必要ツールの確認（kubectl / helm / az CLI）

各ツールのバージョンと動作を確認する。

```bash
# kubectl バージョン確認（クライアント・サーバーの差が1マイナーバージョン以内であること）
kubectl version

# Helm バージョン確認（v3 系であること）
helm version
# 期待値例: version.BuildInfo{Version:"v3.x.x", ...}

# az CLI バージョン確認
az version
```

**Helm が未インストールの場合:**
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

### 2.4 ネームスペース作成

Collibra DQ 専用のネームスペースを作成し、識別用ラベルを付与する。

```bash
# ネームスペース作成
kubectl create namespace "${NAMESPACE}"

# ラベル付与（リソース識別用）
kubectl label namespace "${NAMESPACE}" \
  app.kubernetes.io/name=collibra-dq \
  environment=production

# 確認
kubectl get namespace "${NAMESPACE}"
```

**期待される出力例:**
```
NAME          STATUS   AGE
collibra-dq   Active   5s
```

```bash
# 以降のコマンドでネームスペース指定を省略するためのデフォルト設定（任意）
kubectl config set-context --current --namespace="${NAMESPACE}"
```

---

## 3. コンテナイメージの準備と ACR 転送

> **背景**: Collibra DQ のコンテナイメージは Google Container Registry (GCR) のセキュアリポジトリに格納されており、初回取得にはインターネット経由のアクセスが必要。本環境はプライベート AKS のため、GCR から取得したイメージを社内 ACR に転送してから AKS へデプロイする。

### 3.1 Collibra ライセンス情報の確認

Collibra 社から受領するライセンスメールに以下の情報が記載されている。事前に手元に用意すること。

| 情報 | 説明 | 変数名（2章で定義） |
|---|---|---|
| イメージレジストリ URL | GCR のリポジトリパス | `COLLIBRA_REGISTRY` |
| レジストリ認証ユーザー名 | docker login 用ユーザー名 | `COLLIBRA_REGISTRY_USER` |
| レジストリ認証パスワード | docker login 用パスワード | `COLLIBRA_REGISTRY_PASS` |
| Helm チャート ZIP ダウンロード URL | チャートファイルの取得先 | （4章で使用） |

### 3.2 Collibra レジストリへのログインとイメージ取得

管理用 Linux VM（インターネット経由アクセスが可能な環境）で実行する。

```bash
# Collibra レジストリにログイン
docker login "${COLLIBRA_REGISTRY}" \
  --username "${COLLIBRA_REGISTRY_USER}" \
  --password "${COLLIBRA_REGISTRY_PASS}"
```

DQ 2026.02 で使用する主要イメージを取得する。

```bash
# DQ Web（UI / REST API サーバー）
docker pull "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}"

# DQ Agent（Spark ジョブオーケストレーター）
docker pull "${COLLIBRA_REGISTRY}/owl-agent:${DQ_VERSION}"

# Spark（データ品質チェック処理基盤）
docker pull "${COLLIBRA_REGISTRY}/owl-spark:${SPARK_VERSION}"
```

> **補足**: 提供されるイメージ名・タグは Collibra のバージョンによって異なる場合がある。ライセンスメールまたは Helm チャートの `values.yaml` に記載されたイメージ名を優先すること。

取得できたことを確認する。

```bash
docker images | grep -E "owl-web|owl-agent|owl-spark"
```

### 3.3 ACR へのイメージ転送

取得したイメージに ACR のタグを付け直し、社内 ACR へプッシュする。

```bash
# ACR にログイン
az acr login --name "${ACR_NAME}"

# --- DQ Web ---
docker tag "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-web:${DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-web:${DQ_VERSION}"

# --- DQ Agent ---
docker tag "${COLLIBRA_REGISTRY}/owl-agent:${DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-agent:${DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-agent:${DQ_VERSION}"

# --- Spark ---
docker tag "${COLLIBRA_REGISTRY}/owl-spark:${SPARK_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"
```

ACR にイメージが登録されたことを確認する。

```bash
az acr repository list --name "${ACR_NAME}" --output table
az acr repository show-tags \
  --name "${ACR_NAME}" \
  --repository collibra/owl-web \
  --output table
```

**期待される出力例:**
```
Result
------------------
collibra/owl-web
collibra/owl-agent
collibra/owl-spark
```

### 3.4 イメージプルシークレットの設定

AKS は ACR に直接アタッチ済みのため、通常はプルシークレットは不要。ただし、Helm チャートが明示的にプルシークレットを参照する場合は以下で作成する。

```bash
# ACR 認証用プルシークレットを作成
ACR_PASSWORD=$(az acr credential show \
  --name "${ACR_NAME}" \
  --query "passwords[0].value" \
  --output tsv)

kubectl create secret docker-registry dq-pull-secret \
  --docker-server="${ACR_LOGIN_SERVER}" \
  --docker-username="${ACR_NAME}" \
  --docker-password="${ACR_PASSWORD}" \
  --namespace "${NAMESPACE}"
```

作成を確認する。

```bash
kubectl get secret dq-pull-secret -n "${NAMESPACE}"
```

**期待される出力例:**
```
NAME              TYPE                             DATA   AGE
dq-pull-secret    kubernetes.io/dockerconfigjson   1      5s
```

> **補足**: AKS と ACR が `az aks create --attach-acr` で連携済みの場合、Managed Identity 経由でのプル認証が自動で機能する。プルシークレットを二重に作成する必要はなく、Helm values でのシークレット参照も省略できる。

---

## 4. Helm チャートの準備

> **背景**: Collibra DQ は Helm チャート形式で配布される。チャートは Collibra ライセンスメール経由で ZIP ファイルとして提供される。Helm を使うことで、テンプレート化された Kubernetes マニフェストをパラメータ指定だけでデプロイできる。

### 4.1 Helm チャートの入手方法

ライセンスメールに記載のダウンロードリンクから ZIP ファイルを管理用 VM に取得し、展開する。

```bash
# ダウンロード（URL はライセンスメールに記載）
wget -O collibra-dq-chart.zip "<ライセンスメール記載のダウンロードURL>"

# 展開先ディレクトリを作成して解凍
mkdir -p "${CHART_PATH}"
unzip collibra-dq-chart.zip -d "${CHART_PATH}"

# 展開されたディレクトリを確認
ls -l "${CHART_PATH}"
```

### 4.2 チャートディレクトリ構造の確認

展開後のディレクトリ構造を確認する。

```bash
find "${CHART_PATH}" -maxdepth 3 | sort
```

**典型的なチャート構造:**

```
collibra-dq-chart/
├── Chart.yaml          # チャートのメタ情報（名前・バージョン・依存関係）
├── values.yaml         # デフォルト設定値（カスタマイズの起点）
├── templates/          # Kubernetes マニフェストテンプレート群
│   ├── deployment-web.yaml
│   ├── deployment-agent.yaml
│   ├── service-web.yaml
│   ├── pvc-web.yaml
│   ├── rbac.yaml
│   └── ...
└── charts/             # 依存サブチャート（metastore 等）
```

```bash
# Chart.yaml でチャートバージョンと対応 DQ バージョンを確認
cat "${CHART_PATH}/Chart.yaml"

# values.yaml の全内容を確認（カスタマイズ前の参照用）
cat "${CHART_PATH}/values.yaml"
```

### 4.3 values.yaml 設定パラメータ一覧

カスタマイズが必要な主要パラメータを以下に示す。実際の値は 9 章のデプロイ時に `--set` または独自の `custom-values.yaml` で指定する。

#### グローバル設定

| パラメータ | 説明 | 設定例 |
|---|---|---|
| `global.version.dq` | Collibra DQ のバージョン | `"2026.02"` |
| `global.version.spark` | Spark のバージョン | `"4.1.0"` |
| `global.image.repo` | コンテナイメージのリポジトリパス | `"acrcollibradq.azurecr.io/collibra"` |
| `global.configMap.data.license_key` | ライセンスキー | `"<license_key>"` |
| `global.configMap.data.license_name` | ライセンス名 | `"<license_name>"` |

#### DQ Web 設定

| パラメータ | 説明 | 設定例 |
|---|---|---|
| `global.web.admin.email` | 管理者メールアドレス | `"admin@example.com"` |
| `global.web.admin.password` | 管理者パスワード | `"<password>"` |
| `global.web.service.type` | サービスタイプ | `"ClusterIP"`（Ingress 使用時）|
| `global.web.tls.enabled` | HTTPS 有効化 | `true` |

#### ストレージ設定

| パラメータ | 説明 | 設定例 |
|---|---|---|
| `global.persistence.web.storageClassName` | DQ Web 用ストレージクラス | `"azurefile-csi"` |
| `spark_scratch_type` | Spark 作業領域のタイプ | `"persistentVolumeClaim"` |
| `spark_scratch_storage_class` | Spark PVC 用ストレージクラス | `"azurefile-csi"` |
| `spark_scratch_storage_size` | Spark PVC サイズ | `"20Gi"` |

#### メタストア設定

| パラメータ | 説明 | 設定例 |
|---|---|---|
| `global.metastore.host` | PostgreSQL ホスト名 | `"<host>.postgres.database.azure.com"` |
| `global.metastore.port` | PostgreSQL ポート番号 | `"5432"` |
| `global.metastore.db` | データベース名 | `"owlmetastore"` |
| `global.metastore.user` | DB ユーザー名 | `"<user>"` |

> **注意**: パスワードや秘密情報は `--set` でコマンドラインに直接渡すとシェル履歴に残る。6章で説明する Kubernetes Secret または Azure Key Vault 経由での受け渡しを推奨する。

---

## 5. ストレージの設定

> **背景**: Collibra DQ の DQ Web および Spark は永続ストレージを必要とする。AKS では Azure Files を利用した ReadWriteMany (RWX) 構成が推奨される。Azure Disk（RWO）は単一 Pod からのアクセスのみで、複数 Pod が読み書きする Collibra DQ には適さない。

**本章で作成するストレージリソースの一覧:**

| リソース | 用途 | アクセスモード | サイズ |
|---|---|---|---|
| StorageClass `azurefile-csi-rwx` | DQ Web / Spark 共用 | ReadWriteMany | - |
| PVC `dq-web-pvc` | DQ Web の設定・ログ永続化 | ReadWriteMany | 10Gi |
| PVC `spark-scratch-pvc` | Spark の一時処理領域 | ReadWriteMany | 20Gi |
| PVC `dq-jdbc-drivers-pvc` | JDBC ドライバー格納 | ReadWriteMany | 5Gi |

### 5.1 Azure Files ストレージクラスの確認

AKS に組み込みのストレージクラスを確認する。

```bash
kubectl get storageclass
```

**AKS の標準ストレージクラス一覧（抜粋）:**

```
NAME                     PROVISIONER                    RECLAIMPOLICY
azurefile                kubernetes.io/azure-file       Delete
azurefile-csi            file.csi.azure.com             Delete
azurefile-csi-premium    file.csi.azure.com             Delete
azuredisk-csi            disk.csi.azure.com             Delete
```

`azurefile-csi` は ReadWriteMany に対応しているが、SMB プロトコルを使用するため Linux コンテナの権限設定に注意が必要。本手順では NFS プロトコルを使用するカスタムストレージクラスを作成して使用する。

**カスタムストレージクラス（NFS / ReadWriteMany）を作成する:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-rwx
provisioner: file.csi.azure.com
parameters:
  protocol: nfs          # NFS プロトコルを使用（Linux 権限の問題を回避）
  skuName: Premium_LRS   # NFS は Premium ストレージが必須
reclaimPolicy: Retain    # PVC 削除後もデータを保持
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
```

確認する。

```bash
kubectl get storageclass azurefile-csi-rwx
```

### 5.2 DQ Web 用 PVC 設定

DQ Web が設定ファイル・ログ等を永続化するための PVC を作成する。

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dq-web-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 10Gi
EOF
```

PVC がバインドされるまで待機して確認する。

```bash
kubectl get pvc dq-web-pvc -n "${NAMESPACE}" --watch
```

**期待される出力（STATUS が Bound になること）:**

```
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS        AGE
dq-web-pvc    Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            azurefile-csi-rwx   30s
```

### 5.3 Spark Scratch Disk 用 PVC 設定

Spark が大規模データ処理時にメモリとディスク間でデータをスピルする一時領域として使用する PVC を作成する。処理するデータ量に応じてサイズを調整すること（デフォルト 20Gi）。

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: spark-scratch-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 20Gi   # 大規模ジョブの場合は 50Gi 以上を推奨
EOF
```

```bash
kubectl get pvc spark-scratch-pvc -n "${NAMESPACE}"
```

### 5.4 JDBC ドライバー用 PVC 設定

各種データソース（SQL Server、Oracle、Snowflake 等）への接続に使用する JDBC ドライバーを格納するための PVC を作成する。

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dq-jdbc-drivers-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 5Gi
EOF
```

**JDBC ドライバーのアップロード（初回のみ）:**

DQ Web Pod 起動後、以下の手順でドライバー JAR ファイルを PVC にコピーする。

```bash
# Pod 名を取得
DQ_WEB_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=owl-web -o jsonpath='{.items[0].metadata.name}')

# ローカルの JAR ファイルを Pod 内の JDBC ドライバーディレクトリにコピー
kubectl cp ./drivers/mssql-jdbc.jar \
  "${NAMESPACE}/${DQ_WEB_POD}:/opt/owl/drivers/mssql-jdbc.jar"
```

> **補足**: DQ 標準で同梱されるドライバー（PostgreSQL / MySQL / Snowflake / Redshift 等）は追加コピー不要。オプションドライバー（Athena / BigQuery / Databricks 等）のみ追加が必要。

**全 PVC の状態まとめ確認:**

```bash
kubectl get pvc -n "${NAMESPACE}"
```

**期待される出力（全て Bound）:**

```
NAME                   STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS        AGE
dq-web-pvc             Bound    pvc-xxx    10Gi       RWX            azurefile-csi-rwx   2m
spark-scratch-pvc      Bound    pvc-yyy    20Gi       RWX            azurefile-csi-rwx   1m
dq-jdbc-drivers-pvc    Bound    pvc-zzz    5Gi        RWX            azurefile-csi-rwx   30s
```

---

## 6. 認証・シークレットの設定

> **背景**: ライセンスキー・DB パスワード・管理者パスワード等の機密情報をコマンドラインや values.yaml に平文で記載しないよう、Kubernetes Secret または Azure Key Vault で管理する。

**本章で作成するシークレット一覧:**

| シークレット名 | 種別 | 格納内容 |
|---|---|---|
| `dq-pull-secret` | kubernetes.io/dockerconfigjson | ACR 認証情報（3章で作成済み） |
| `dq-license-secret` | Opaque | ライセンスキー・ライセンス名 |
| `dq-metastore-secret` | Opaque | メタストア DB パスワード |
| `dq-admin-secret` | Opaque | DQ Web 管理者パスワード |

### 6.1 イメージプルシークレット登録確認

3章で作成した `dq-pull-secret` が対象ネームスペースに存在することを確認する。

```bash
kubectl get secret dq-pull-secret -n "${NAMESPACE}"
```

存在しない場合は 3章の 3.4 節を参照して再作成すること。

### 6.2 ライセンスキーのシークレット化

Collibra ライセンスキーと管理者パスワードを Kubernetes Secret として登録する。

```bash
# ライセンス情報の Secret
kubectl create secret generic dq-license-secret \
  --from-literal=license_key="${DQ_LICENSE_KEY}" \
  --from-literal=license_name="${DQ_LICENSE_NAME}" \
  --namespace "${NAMESPACE}"

# メタストア DB パスワードの Secret
kubectl create secret generic dq-metastore-secret \
  --from-literal=password="${METASTORE_PASS}" \
  --namespace "${NAMESPACE}"

# DQ Web 管理者パスワードの Secret
kubectl create secret generic dq-admin-secret \
  --from-literal=password="${DQ_ADMIN_PASS}" \
  --namespace "${NAMESPACE}"
```

作成した Secret を確認する（値は表示されない）。

```bash
kubectl get secret -n "${NAMESPACE}"
```

**期待される出力例:**

```
NAME                  TYPE                             DATA   AGE
dq-pull-secret        kubernetes.io/dockerconfigjson   1      10m
dq-license-secret     Opaque                           2      30s
dq-metastore-secret   Opaque                           1      20s
dq-admin-secret       Opaque                           1      10s
```

### 6.3 Azure Key Vault 統合（オプション）

機密情報を Azure Key Vault で一元管理し、Secret Store CSI ドライバー経由で Pod にマウントする構成。Kubernetes Secret を使用しない場合に選択する。

#### 前提: CSI ドライバーアドオンの有効化

```bash
# AKS に Secret Store CSI ドライバーアドオンを有効化
az aks enable-addons \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --addons azure-keyvault-secrets-provider

# Pod が起動していることを確認
kubectl get pods -n kube-system \
  -l app=secrets-store-csi-driver
```

#### Key Vault へのシークレット登録

```bash
KV_NAME="kv-collibra-dq"   # Key Vault 名（事前に作成済みであること）

az keyvault secret set --vault-name "${KV_NAME}" \
  --name "dq-license-key"   --value "${DQ_LICENSE_KEY}"
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "dq-license-name"  --value "${DQ_LICENSE_NAME}"
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "dq-metastore-pass" --value "${METASTORE_PASS}"
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "dq-admin-pass"    --value "${DQ_ADMIN_PASS}"
```

#### SecretProviderClass の作成

```bash
KV_TENANT_ID=$(az account show --query tenantId -o tsv)

cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: dq-akv-secrets
  namespace: ${NAMESPACE}
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: "<Workload Identity のクライアント ID>"  # 6.4 節で取得
    keyvaultName: "${KV_NAME}"
    tenantId: "${KV_TENANT_ID}"
    objects: |
      array:
        - |
          objectName: dq-license-key
          objectType: secret
        - |
          objectName: dq-license-name
          objectType: secret
        - |
          objectName: dq-metastore-pass
          objectType: secret
        - |
          objectName: dq-admin-pass
          objectType: secret
  secretObjects:
    - secretName: dq-license-secret
      type: Opaque
      data:
        - objectName: dq-license-key
          key: license_key
        - objectName: dq-license-name
          key: license_name
    - secretName: dq-metastore-secret
      type: Opaque
      data:
        - objectName: dq-metastore-pass
          key: password
    - secretName: dq-admin-secret
      type: Opaque
      data:
        - objectName: dq-admin-pass
          key: password
EOF
```

### 6.4 Workload Identity 設定

DQ Web Pod が Azure リソース（Key Vault 等）にパスワードレスでアクセスするための Workload Identity を設定する。

```bash
# OIDC 発行者 URL を取得
OIDC_ISSUER=$(az aks show \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Workload Identity 用マネージド ID を作成
MI_NAME="mi-collibra-dq"
az identity create \
  --resource-group "${RG_NAME}" \
  --name "${MI_NAME}" \
  --location "${LOCATION}"

MI_CLIENT_ID=$(az identity show \
  --resource-group "${RG_NAME}" \
  --name "${MI_NAME}" \
  --query clientId -o tsv)

MI_OBJECT_ID=$(az identity show \
  --resource-group "${RG_NAME}" \
  --name "${MI_NAME}" \
  --query principalId -o tsv)
```

```bash
# Key Vault へのアクセス権を付与
KV_ID=$(az keyvault show --name "${KV_NAME}" --query id -o tsv)
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee-object-id "${MI_OBJECT_ID}" \
  --scope "${KV_ID}"
```

```bash
# フェデレーション ID 資格情報を作成（Pod の ServiceAccount と紐付け）
az identity federated-credential create \
  --name "dq-web-federated" \
  --identity-name "${MI_NAME}" \
  --resource-group "${RG_NAME}" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:${NAMESPACE}:collibra-dq-sa" \
  --audience api://AzureADTokenExchange
```

```bash
# Workload Identity アノテーション付き ServiceAccount を作成
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: collibra-dq-sa
  namespace: ${NAMESPACE}
  annotations:
    azure.workload.identity/client-id: "${MI_CLIENT_ID}"
EOF
```

設定を確認する。

```bash
kubectl get serviceaccount collibra-dq-sa -n "${NAMESPACE}" -o yaml
```

---

## 7. SSL/HTTPS 設定

> **背景**: 本番環境では HTTPS 通信が必須。Collibra DQ は Java Keystore (JKS) 形式または PKCS12 形式の証明書をサポートする。

### 7.1 Java Keystore の作成

`keytool` コマンドを使用して、署名済み証明書・秘密鍵を含む Keystore ファイル（`keystore.jks`）を作成する。

### 7.2 CA 証明書のインポート

外部データソース接続で使用する CA 証明書を Java の `cacerts` にインポートする。

### 7.3 Kubernetes Secret への登録

作成した Keystore ファイルを Kubernetes Secret（`dq-ssl-secret`）として対象ネームスペースに登録する。

### 7.4 Helm パラメータ設定

Helm の `values.yaml` または `--set` オプションで TLS 関連パラメータ（`global.web.tls.enabled`、証明書エイリアス、パスワード等）を設定する。

---

## 8. 外部メタストア（PostgreSQL）接続設定

> **背景**: Collibra DQ のメタデータを永続化するためのメタストア DB として、外部 PostgreSQL を使用する。AKS 環境では Azure Database for PostgreSQL Flexible Server を推奨。

### 8.1 Azure Database for PostgreSQL Flexible Server への接続

Private Endpoint 経由での接続設定（ホスト名、ポート、DB 名、ユーザー）を確認する。

### 8.2 パスワードレス認証（Azure AD）設定

Azure Active Directory 認証を使用し、パスワードを直接扱わない接続方式を構成する（Workload Identity と連携）。

### 8.3 接続文字列の設定

Helm の values または Secret として JDBC 接続文字列を設定し、DQ Web からメタストアへの接続を確立する。

---

## 9. Collibra DQ のデプロイ（Helm）

### 9.1 helm upgrade --install コマンド

バージョン、ライセンス、ストレージクラス、サービスタイプ等を指定した `helm upgrade --install` コマンドを実行する。

### 9.2 デプロイ状態の確認

Pod の起動状況、PVC のバインド状態、Service の作成を確認する。

### 9.3 初期起動の確認

DQ Web Pod のログを確認し、アプリケーションが正常に起動していることを確認する。

---

## 10. ネットワーク・外部アクセスの設定

### 10.1 Ingress コントローラー（NGINX）設定

NGINX Ingress コントローラーを使用した Ingress リソースを作成し、DQ Web への HTTP/HTTPS アクセスを構成する。

### 10.2 サービスタイプの選択と設定

環境に応じたサービスタイプ（ClusterIP + Ingress / LoadBalancer / NodePort）を選択し、設定を適用する。

### 10.3 DQ Web への外部アクセス確認

設定した URL または IP アドレスで DQ Web UI へのアクセスが正常に行えることを確認する。

---

## 11. DQ Agent の設定

> **背景**: DQ Agent は Collibra DQ Web と連携し、Spark ジョブのオーケストレーションを担う。AKS 環境では Agent も Kubernetes 上で動作する。

### 11.1 Agent 接続先の設定

DQ Agent が接続する DQ Web のエンドポイント（ホスト名・ポート）を設定する。

### 11.2 Spark Executor 設定

Spark Driver・Executor の Pod スペック（CPU・メモリ）、イメージ、ネームスペース等を設定する。

### 11.3 RBAC / サービスアカウント設定

DQ Agent と Spark Driver が Pod の作成・削除権限を持つよう、ServiceAccount・Role・RoleBinding を設定する。

---

## 12. 動作確認

### 12.1 Pod / Service / PVC の状態確認

全コンポーネントの Pod が `Running` 状態であること、PVC が `Bound` 状態であることを確認する。

### 12.2 DQ Web UI へのアクセス確認

ブラウザから DQ Web UI にアクセスし、管理者アカウントでのログインを確認する。

### 12.3 サンプルジョブの実行テスト

DQ Web UI からサンプルデータソースを登録し、DQ ジョブを実行して正常に完了することを確認する。

### 12.4 ログ・メトリクスの確認

各 Pod のログ出力にエラーがないことを確認する。Container Insights での監視データ収集も確認する。

---

## 13. トラブルシューティング

### 13.1 よくあるエラーと対処法

インストール・起動時に発生しやすい代表的なエラー（イメージプル失敗、PVC バインド失敗、メタストア接続失敗等）と対処法をまとめる。

### 13.2 デバッグコマンド集

問題調査に使用する `kubectl` コマンド（`describe`、`logs`、`exec`、`get events` 等）を用途別にまとめる。

---

## 14. アップグレード手順

### 14.1 バージョンアップの手順

新バージョンのイメージを ACR に転送し、Helm の `--set global.version.dq` を更新して `helm upgrade` を実行する手順を記載する。

### 14.2 ロールバック手順

アップグレード失敗時に `helm rollback` を使用して前バージョンに戻す手順を記載する。

---

## 15. 参考リンク

| タイトル | URL |
|---|---|
| EKS / GKE / AKS - Product Resource Center | https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/EKS%20%20GKE%20%20AKS.htm |
| Cloud native requirements | https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/Cloud%20native%20requirements.htm |
| Deploy on Self-hosted Kubernetes | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_cloud-deploy.htm |
| Cloud native install | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/Cloud%20native%20install.htm |
| Securely pass sensitive values to Helm Chart | https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_passing-sensitive-values-to-helm-based-deployments.htm |
| Configure Spark scratch disk space | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_configure-spark-scratch-disk-space-for-large-jobs.htm |
| Setting up SSL (HTTPS) | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQSecurity/ta_ssl-setup.htm |
| Configure Azure passwordless authentication | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DBConnection/Authentication/ta_azure-passwordless-authentication.htm |
| System requirements | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm |
| AKS / EKS / GKE Kubernetes Deployment (dq-docs) | https://dq-docs.collibra.com/installation/cloud-native-owldq/aks-eks-gke-kubernetes-deployment |
