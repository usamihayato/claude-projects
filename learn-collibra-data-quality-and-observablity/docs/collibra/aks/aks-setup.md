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

> **背景**: 本番環境では HTTPS 通信が必須。Collibra DQ は Java Keystore (JKS) 形式または PKCS12 形式の証明書をサポートする。SAML 認証を利用する場合も SSL/TLS の設定が前提条件となる。

**証明書の準備方法は2パターン:**

| パターン | 内容 | 推奨場面 |
|---|---|---|
| A. 自己署名証明書 | keytool で新規作成 | 検証・開発環境 |
| B. CA 署名済み証明書 | 既存の PEM 証明書を JKS に変換 | 本番環境 |

### 7.1 Java Keystore の作成

#### パターン A: 自己署名証明書（検証用）

管理用 VM（Java 17 インストール済み）で実行する。

```bash
# 作業ディレクトリ作成
mkdir -p ~/ssl && cd ~/ssl

# Keystore の作成（有効期間 3650 日 = 約10年）
keytool -genkey \
  -alias dq-server \
  -keyalg RSA \
  -keysize 2048 \
  -keystore keystore.jks \
  -validity 3650 \
  -storepass "<keystoreパスワード>" \
  -keypass  "<keystoreパスワード>" \
  -dname "CN=<DQ Web のFQDNまたはIP>, OU=IT, O=<会社名>, L=Tokyo, ST=Tokyo, C=JP"
```

```bash
# 作成確認
keytool -list -keystore keystore.jks -storepass "<keystoreパスワード>"
```

**期待される出力例:**
```
Keystore type: PKCS12
Keystore provider: SUN
Your keystore contains 1 entry
dq-server, YYYY/MM/DD, PrivateKeyEntry,
Certificate fingerprint (SHA-256): xx:xx:xx:...
```

#### パターン B: CA 署名済み証明書（本番用）

既存の PEM 形式証明書（`.crt` / `.key`）を JKS に変換する。

```bash
# Step 1: PEM → PKCS12 に変換
openssl pkcs12 -export \
  -in   server.crt \
  -inkey server.key \
  -chain \
  -CAfile ca-chain.crt \
  -name  dq-server \
  -out   keystore.p12 \
  -passout pass:"<keystoreパスワード>"

# Step 2: PKCS12 → JKS に変換
keytool -importkeystore \
  -srckeystore   keystore.p12 \
  -srcstoretype  PKCS12 \
  -srcstorepass  "<keystoreパスワード>" \
  -destkeystore  keystore.jks \
  -deststoretype JKS \
  -deststorepass "<keystoreパスワード>"
```

### 7.2 CA 証明書のインポート

外部データソース（SQL Server / Oracle 等）が SSL を要求する場合、その CA 証明書を Java の `cacerts` に追加する。

```bash
# Java 17 の cacerts パスを確認
JAVA_CACERTS=$(find /usr/lib/jvm -name "cacerts" 2>/dev/null | head -1)
echo "cacerts: ${JAVA_CACERTS}"

# CA 証明書をインポート（複数ある場合は繰り返す）
keytool -import \
  -alias  "external-db-ca" \
  -file   ca-cert.pem \
  -keystore "${JAVA_CACERTS}" \
  -storepass "changeit" \
  -noprompt

# インポート確認
keytool -list -keystore "${JAVA_CACERTS}" \
  -storepass "changeit" | grep "external-db-ca"
```

> **補足**: `cacerts` への変更は Collibra DQ コンテナには直接反映されない。コンテナ内の `cacerts` に反映するには、Dockerfile で追加するか、7.3 節の Secret に `cacerts` も含めてマウントする。

### 7.3 Kubernetes Secret への登録

作成した Keystore ファイルを Kubernetes Secret として対象ネームスペースに登録する。

```bash
kubectl create secret generic dq-ssl-secret \
  --from-file=keystore.jks=~/ssl/keystore.jks \
  --namespace "${NAMESPACE}"
```

登録確認（ファイルが格納されていることを確認）。

```bash
kubectl get secret dq-ssl-secret -n "${NAMESPACE}"
kubectl describe secret dq-ssl-secret -n "${NAMESPACE}"
```

**期待される出力例:**
```
Name:         dq-ssl-secret
Namespace:    collibra-dq
Type:         Opaque
Data
====
keystore.jks:  3452 bytes
```

### 7.4 Helm パラメータ設定

Helm デプロイ時（9章）に以下のパラメータを追加して TLS を有効化する。

**`--set` で指定する場合:**

```bash
--set global.web.tls.enabled=true \
--set global.web.tls.key.secretName=dq-ssl-secret \
--set global.web.tls.key.alias=dq-server \
--set global.web.tls.key.type=JKS \
--set global.web.tls.key.pass="<keystoreパスワード>" \
--set global.web.tls.key.store.name=keystore.jks
```

**`custom-values.yaml` に記載する場合（推奨）:**

```yaml
global:
  web:
    tls:
      enabled: true
      key:
        secretName: dq-ssl-secret
        alias: dq-server
        type: JKS          # JKS または PKCS12
        pass: "<keystoreパスワード>"
        store:
          name: keystore.jks
```

TLS 有効化時に DQ Web の ConfigMap に設定される主要な環境変数：

| 環境変数 | 値 | 説明 |
|---|---|---|
| `SERVER_HTTPS_ENABLED` | `true` | HTTPS 有効化 |
| `SERVER_HTTP_ENABLED` | `false` | HTTP 無効化（本番推奨） |
| `SERVER_REQUIRE_SSL` | `true` | SSL 必須化 |
| `SERVER_SSL_KEY_TYPE` | `JKS` | Keystore 形式 |
| `SERVER_SSL_KEY_STORE` | `keystore.jks` | Keystore ファイル名 |
| `SERVER_SSL_KEY_ALIAS` | `dq-server` | キーエイリアス |

> **注意**: TLS 有効化後、DQ Web へのアクセス URL は `https://<host>:9000` となる。Ingress を使用する場合は 10 章の設定も合わせて変更すること。

---

## 8. 外部メタストア（PostgreSQL）接続設定

> **背景**: Collibra DQ のメタデータを永続化するためのメタストア DB として、外部 PostgreSQL を使用する。AKS 環境では Azure Database for PostgreSQL Flexible Server を推奨。aks-build.md で構築した Private Endpoint 経由で接続する。

### 8.1 Azure Database for PostgreSQL Flexible Server への接続確認

Private Endpoint の疎通確認と、メタストア用 DB・ユーザーの存在を確認する。

```bash
# 管理用 VM から PostgreSQL への疎通確認
kubectl run pg-test --rm -it \
  --image=postgres:15 \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  -- psql "host=${METASTORE_HOST} port=${METASTORE_PORT} \
           dbname=${METASTORE_DB} user=${METASTORE_USER} \
           password=${METASTORE_PASS} sslmode=require" \
  -c "SELECT version();"
```

**期待される出力例:**
```
                                   version
----------------------------------------------------------------------
 PostgreSQL 16.x on x86_64-pc-linux-gnu, compiled by gcc ...
(1 row)
```

接続できない場合は以下を確認する。

```bash
# AKS ノードから PostgreSQL ポートへの疎通確認
kubectl run nc-test --rm -it \
  --image=alpine \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  -- nc -zv "${METASTORE_HOST}" 5432
```

#### メタストア DB の初期作成（未作成の場合）

```bash
# 管理者権限で接続し、メタストア用 DB とユーザーを作成
kubectl run pg-init --rm -it \
  --image=postgres:15 \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  -- psql "host=${METASTORE_HOST} port=${METASTORE_PORT} \
           dbname=postgres user=<管理者ユーザー> \
           password=<管理者パスワード> sslmode=require" \
  -c "
    CREATE DATABASE ${METASTORE_DB};
    CREATE USER ${METASTORE_USER} WITH PASSWORD '${METASTORE_PASS}';
    GRANT ALL PRIVILEGES ON DATABASE ${METASTORE_DB} TO ${METASTORE_USER};
    ALTER DATABASE ${METASTORE_DB} OWNER TO ${METASTORE_USER};
  "
```

### 8.2 パスワードレス認証（Azure AD）設定

パスワードを直接扱わず、Azure AD のマネージド ID 経由で PostgreSQL に接続する構成。6章で作成した Workload Identity を利用する。

```bash
# PostgreSQL サーバーで Azure AD 認証を有効化
PG_SERVER_NAME="<PostgreSQL サーバー名>"
az postgres flexible-server update \
  --resource-group "${RG_NAME}" \
  --name "${PG_SERVER_NAME}" \
  --active-directory-auth Enabled

# マネージド ID を PostgreSQL の Azure AD 管理者として設定
az postgres flexible-server ad-admin create \
  --resource-group "${RG_NAME}" \
  --server-name "${PG_SERVER_NAME}" \
  --display-name "${MI_NAME}" \
  --object-id "${MI_OBJECT_ID}" \
  --type ServicePrincipal
```

PostgreSQL 側でマネージド ID に権限を付与する。

```bash
kubectl run pg-role --rm -it \
  --image=postgres:15 \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  -- psql "host=${METASTORE_HOST} port=${METASTORE_PORT} \
           dbname=${METASTORE_DB} \
           user=<Azure AD 管理者ユーザー> \
           password=<Azure AD アクセストークン> sslmode=require" \
  -c "
    GRANT ALL PRIVILEGES ON DATABASE ${METASTORE_DB} TO \"${MI_NAME}\";
    GRANT ALL ON SCHEMA public TO \"${MI_NAME}\";
  "
```

> **補足**: パスワードレス認証を使用する場合、Helm values の metastore パスワード設定は空にするか省略し、Workload Identity トークンでの認証に切り替える。対応状況は利用する Collibra DQ のバージョンに依存するため、ライセンスメールまたはリリースノートで確認すること。

### 8.3 接続文字列の設定

JDBC 接続文字列を Kubernetes Secret として設定し、Helm values から参照する。

```bash
# JDBC 接続 URL を Secret に追加
JDBC_URL="jdbc:postgresql://${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}?currentSchema=public&sslmode=require"

kubectl create secret generic dq-metastore-jdbc \
  --from-literal=url="${JDBC_URL}" \
  --from-literal=username="${METASTORE_USER}" \
  --namespace "${NAMESPACE}"
```

Helm values での参照設定（`custom-values.yaml` に追記）:

```yaml
global:
  metastore:
    host: "<METASTORE_HOST>"
    port: "5432"
    db: "owlmetastore"
    user: "<METASTORE_USER>"
    # パスワードは Secret から参照
    existingSecret: dq-metastore-secret
    existingSecretKey: password
```

接続文字列パターンの参考:

| 接続先 | JDBC URL 例 |
|---|---|
| Azure DB for PostgreSQL（SSL必須） | `jdbc:postgresql://<host>.postgres.database.azure.com:5432/owlmetastore?currentSchema=public&sslmode=require` |
| ローカル PostgreSQL | `jdbc:postgresql://localhost:5432/owlmetastore?currentSchema=public` |
| Amazon RDS | `jdbc:postgresql://<host>.rds.amazonaws.com:5432/owlmetastore?currentSchema=public` |

---

## 9. Collibra DQ のデプロイ（Helm）

> **前提**: 2〜8章の設定が完了していること。特にネームスペース・PVC・Secret・Keystore がすべて作成済みであることを確認してからデプロイを実行する。

### 9.1 デプロイ前チェックリスト

```bash
# ネームスペース確認
kubectl get namespace "${NAMESPACE}"

# PVC が全て Bound であることを確認
kubectl get pvc -n "${NAMESPACE}"

# Secret が揃っていることを確認
kubectl get secret -n "${NAMESPACE}"

# チャートファイルの存在確認
ls "${CHART_PATH}/Chart.yaml"
```

**デプロイ前の期待状態:**

| リソース | 確認項目 |
|---|---|
| Namespace | `collibra-dq` が Active |
| PVC | `dq-web-pvc` / `spark-scratch-pvc` / `dq-jdbc-drivers-pvc` が Bound |
| Secret | `dq-pull-secret` / `dq-license-secret` / `dq-metastore-secret` / `dq-admin-secret` / `dq-ssl-secret` が存在 |
| Chart | `${CHART_PATH}/Chart.yaml` が存在 |

### 9.2 custom-values.yaml の作成

`--set` での指定が増えると管理しにくいため、カスタム値ファイルにまとめる。

```bash
cat <<EOF > ~/custom-values.yaml
global:
  version:
    dq: "${DQ_VERSION}"
    spark: "${SPARK_VERSION}"

  image:
    repo: "${ACR_LOGIN_SERVER}/collibra"

  configMap:
    data:
      license_key: ""    # Secret から参照するため空欄
      license_name: ""

  web:
    admin:
      email: "${DQ_ADMIN_EMAIL}"
      password: ""       # Secret から参照するため空欄
    service:
      type: ClusterIP    # Ingress 使用時は ClusterIP（10章で Ingress を設定）
    tls:
      enabled: true
      key:
        secretName: dq-ssl-secret
        alias: dq-server
        type: JKS
        pass: "<keystoreパスワード>"
        store:
          name: keystore.jks

  metastore:
    host: "${METASTORE_HOST}"
    port: "${METASTORE_PORT}"
    db: "${METASTORE_DB}"
    user: "${METASTORE_USER}"
    existingSecret: dq-metastore-secret
    existingSecretKey: password

  persistence:
    web:
      storageClassName: azurefile-csi-rwx
      existingClaim: dq-web-pvc

spark_scratch_type: persistentVolumeClaim
spark_scratch_storage_class: azurefile-csi-rwx
spark_scratch_storage_size: 20Gi

imagePullSecrets:
  - name: dq-pull-secret

serviceAccount:
  name: collibra-dq-sa   # 6章で作成した Workload Identity 用 SA
EOF
```

### 9.3 helm upgrade --install コマンド

```bash
helm upgrade --install "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --values ~/custom-values.yaml \
  --set global.configMap.data.license_key="$(
      kubectl get secret dq-license-secret -n ${NAMESPACE} \
        -o jsonpath='{.data.license_key}' | base64 -d)" \
  --set global.configMap.data.license_name="$(
      kubectl get secret dq-license-secret -n ${NAMESPACE} \
        -o jsonpath='{.data.license_name}' | base64 -d)" \
  --set global.web.admin.password="$(
      kubectl get secret dq-admin-secret -n ${NAMESPACE} \
        -o jsonpath='{.data.password}' | base64 -d)" \
  --timeout 10m \
  --wait
```

デプロイの進行状況を別ターミナルで確認する。

```bash
kubectl get pods -n "${NAMESPACE}" --watch
```

### 9.4 デプロイ状態の確認

```bash
# Pod の状態確認（全て Running になること）
kubectl get pods -n "${NAMESPACE}" -o wide

# Service の確認
kubectl get svc -n "${NAMESPACE}"

# PVC のバインド確認
kubectl get pvc -n "${NAMESPACE}"

# Helm リリース確認
helm list -n "${NAMESPACE}"
```

**正常時の Pod 一覧例:**

```
NAME                              READY   STATUS    RESTARTS   AGE
collibra-dq-web-xxxxxxxxx-xxxxx   1/1     Running   0          3m
collibra-dq-agent-xxxxxxx-xxxxx   1/1     Running   0          3m
```

### 9.5 初期起動の確認

DQ Web Pod のログで正常起動メッセージを確認する。

```bash
# DQ Web のログを確認
kubectl logs -n "${NAMESPACE}" \
  -l app=owl-web \
  --tail=100 \
  --follow
```

**正常起動時のログキーワード:**

```
Started OwlApplication in xx.xxx seconds
Tomcat started on port(s): 9000
```

エラーが出力されている場合は 13章（トラブルシューティング）を参照すること。

```bash
# エラーのみ抽出して確認
kubectl logs -n "${NAMESPACE}" \
  -l app=owl-web \
  --tail=200 | grep -iE "error|exception|failed"
```

---

## 10. ネットワーク・外部アクセスの設定

> **背景**: 9章のデプロイでは DQ Web の Service タイプを `ClusterIP` にしたため、クラスター外からはアクセスできない。本章では NGINX Ingress コントローラーを使用して外部アクセスを構成する。

**サービスタイプの選択指針:**

| タイプ | 用途 | 本環境での採用 |
|---|---|---|
| ClusterIP + Ingress | プライベートクラスター・エンタープライズ標準 | **推奨（本手順）** |
| LoadBalancer | パブリッククラスターで簡易に公開 | 非推奨（プライベートクラスターのため） |
| NodePort | 開発・検証のみ | 非推奨 |

### 10.1 NGINX Ingress コントローラーのインストール

```bash
# ingress-nginx の Helm リポジトリを追加
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Internal LoadBalancer（プライベート IP）として NGINX をデプロイ
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
  --set controller.service.loadBalancerIP="" \
  --set controller.replicaCount=2 \
  --wait
```

Internal LoadBalancer の IP が払い出されるまで待機して確認する。

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
```

**期待される出力例（EXTERNAL-IP にプライベート IP が表示）:**

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
ingress-nginx-controller   LoadBalancer   172.16.x.x     10.1.x.x      80:xxxxx/TCP,443:xxxxx/TCP
```

```bash
# Ingress コントローラーの IP を変数に保存
INGRESS_IP=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: ${INGRESS_IP}"
```

### 10.2 Ingress リソースの作成

DQ Web へのアクセスルールを定義する Ingress リソースを作成する。

#### HTTPS（TLS termination あり）の場合

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dq-web-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"   # DQ Web 側も HTTPS の場合
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - dq.example.internal          # 社内 DNS に登録するホスト名
      secretName: dq-ssl-secret        # 7章で作成した TLS Secret
  rules:
    - host: dq.example.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: collibra-dq-web  # Helm が作成した Service 名
                port:
                  number: 9000
EOF
```

#### HTTP のみ（検証環境）の場合

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dq-web-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
spec:
  ingressClassName: nginx
  rules:
    - host: dq.example.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: collibra-dq-web
                port:
                  number: 9000
EOF
```

Ingress リソースの確認。

```bash
kubectl get ingress -n "${NAMESPACE}"
kubectl describe ingress dq-web-ingress -n "${NAMESPACE}"
```

### 10.3 DNS 設定と外部アクセス確認

社内 DNS に Ingress IP のAレコードを登録する（DNS 管理者に依頼）。

```
dq.example.internal  A  10.1.x.x（Ingress IP）
```

DNS 登録後、管理用 VM または社内端末からアクセスを確認する。

```bash
# 名前解決の確認
nslookup dq.example.internal

# HTTP アクセス確認（curl）
curl -sk https://dq.example.internal/ | head -20

# ブラウザアクセス
# https://dq.example.internal/
```

**期待される応答:**

```html
<!DOCTYPE html>
<html>
  <head><title>Collibra Data Quality</title>
  ...
```

> **補足**: DNS 登録が完了するまでの間は `/etc/hosts`（Linux）または `C:\Windows\System32\drivers\etc\hosts`（Windows）に一時的にエントリを追加して確認できる。

---

## 11. DQ Agent の設定

> **背景**: DQ Agent は Collibra DQ Web と連携し、Spark ジョブのオーケストレーションを担う。AKS 環境では Agent も Kubernetes 上で動作し、データ品質チェック時に Spark Driver / Executor Pod を動的に生成・破棄する。

**DQ Agent の役割:**

```
DQ Web UI
   │ REST API (ポート 9000)
   ▼
DQ Agent (ポート 9101)
   │ Kubernetes API
   ▼
Spark Driver Pod（動的生成）
   │
   ├── Spark Executor Pod 1
   ├── Spark Executor Pod 2
   └── Spark Executor Pod N
```

### 11.1 RBAC / ServiceAccount 設定

DQ Agent と Spark Driver が Pod の作成・削除を行うために必要な権限を付与する。Helm チャートが自動作成する場合は本節をスキップしてよいが、Edit ロールが利用できない制限環境では手動設定が必要。

```bash
cat <<EOF | kubectl apply -f - -n "${NAMESPACE}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dq-agent-sa
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dq-agent-role
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "create", "delete", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dq-agent-rolebinding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: dq-agent-sa
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: dq-agent-role
EOF
```

確認する。

```bash
kubectl get role,rolebinding,serviceaccount -n "${NAMESPACE}"
```

### 11.2 Agent 接続先の設定

DQ Agent が DQ Web に接続するためのエンドポイントを Helm values に設定する。`custom-values.yaml` に以下を追記する。

```yaml
# DQ Agent の設定（custom-values.yaml に追記）
agent:
  serviceAccount:
    name: dq-agent-sa       # 11.1 で作成した ServiceAccount
  config:
    owlweb:
      host: "collibra-dq-web.${NAMESPACE}.svc.cluster.local"
      port: "9000"
      protocol: "https"     # TLS 有効時は https
    # Agent の待ち受けポート
    port: "9101"
```

設定変更を Helm で反映する。

```bash
helm upgrade "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --values ~/custom-values.yaml \
  --reuse-values \
  --wait
```

Agent Pod の起動確認。

```bash
kubectl get pods -n "${NAMESPACE}" -l app=owl-agent
kubectl logs -n "${NAMESPACE}" -l app=owl-agent --tail=50
```

**Agent 正常接続時のログキーワード:**

```
Connected to DQ Web at https://collibra-dq-web:9000
Agent is running on port 9101
```

### 11.3 Spark Executor 設定

Spark Driver・Executor の Pod リソースとイメージを設定する。`custom-values.yaml` に以下を追記する。

```yaml
# Spark の設定（custom-values.yaml に追記）
spark:
  image: "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"

  # Spark Driver の設定
  driver:
    cores: 1
    memory: "2g"
    serviceAccount: dq-agent-sa

  # Spark Executor の設定
  executor:
    cores: 2
    memory: "4g"
    instances: 2            # デフォルト Executor 数
    # 大規模ジョブでは instances を増やす（dqpool の最大ノード数に依存）

  # Spark Scratch Disk（5章で作成した PVC を参照）
  scratchDisk:
    type: persistentVolumeClaim
    claimName: spark-scratch-pvc

  # Spark が動作するネームスペース（Agent と同一）
  namespace: "${NAMESPACE}"

  # ノードプール指定（DQ 用ノードプール dqpool に配置）
  nodeSelector:
    agentpool: dqpool
```

Spark ジョブ実行時に Executor Pod が dqpool ノード上に生成されることを確認する（12章の動作確認で検証）。

```bash
# ジョブ実行中に Executor Pod を確認するコマンド
kubectl get pods -n "${NAMESPACE}" | grep spark
```

---

## 12. 動作確認

### 12.1 Pod / Service / PVC の状態確認

全コンポーネントのリソースが正常状態であることを一括確認する。

```bash
# Pod・Service・PVC・Ingress を一括確認
kubectl get pod,svc,pvc,ingress -n "${NAMESPACE}"
```

**正常時の期待状態:**

| リソース | 種別 | 期待状態 |
|---|---|---|
| `collibra-dq-web-xxx` | Pod | Running 1/1 |
| `collibra-dq-agent-xxx` | Pod | Running 1/1 |
| `collibra-dq-web` | Service | ClusterIP |
| `dq-web-pvc` | PVC | Bound |
| `spark-scratch-pvc` | PVC | Bound |
| `dq-jdbc-drivers-pvc` | PVC | Bound |
| `dq-web-ingress` | Ingress | ADDRESS に IP が表示 |

Pod が正常に起動しない場合はイベントを確認する。

```bash
kubectl get events -n "${NAMESPACE}" \
  --sort-by='.lastTimestamp' | tail -20
```

### 12.2 DQ Web UI へのアクセス確認

ブラウザまたは curl で DQ Web UI にアクセスし、ログイン画面が表示されることを確認する。

```bash
# Ingress 経由でのアクセス確認
curl -sk https://dq.example.internal/ -o /dev/null -w "%{http_code}\n"
# 期待値: 200
```

ブラウザで `https://dq.example.internal/` を開き、以下を確認する。

1. Collibra DQ のログイン画面が表示される
2. 管理者アカウント（`DQ_ADMIN_EMAIL` / `DQ_ADMIN_PASS`）でログインできる
3. ダッシュボードが表示される

### 12.3 サンプルジョブの実行テスト

DQ Web UI から接続テストとジョブ実行を行い、Spark が正常に動作することを確認する。

**手順:**

1. **データソース登録**
   - 左メニューの **Explorer** を開く
   - **Add Connection** でメタストア（PostgreSQL）の接続情報を入力
   - **Test Connection** をクリックして接続成功を確認

2. **DQ ジョブ実行**
   - 登録したデータソースからテーブルを選択
   - **Run** でプロファイリングジョブを実行
   - ジョブステータスが **Success** になることを確認

3. **Spark Executor Pod の確認**（ジョブ実行中に別ターミナルで）

```bash
# Executor Pod が生成されることを確認
kubectl get pods -n "${NAMESPACE}" --watch | grep spark
```

**期待される出力（ジョブ実行中）:**

```
collibra-dq-spark-driver-xxx   1/1     Running   0   10s
collibra-dq-spark-exec-1-xxx   1/1     Running   0   15s
collibra-dq-spark-exec-2-xxx   1/1     Running   0   15s
```

ジョブ完了後、Executor Pod は自動的に削除される。

### 12.4 ログ・メトリクスの確認

各コンポーネントのログにエラーがないことを確認する。

```bash
# DQ Web のログ確認（エラー抽出）
kubectl logs -n "${NAMESPACE}" \
  -l app=owl-web --tail=200 \
  | grep -iE "error|exception|warn" | grep -v "WARN.*hikari"

# DQ Agent のログ確認
kubectl logs -n "${NAMESPACE}" \
  -l app=owl-agent --tail=100 \
  | grep -iE "error|exception"
```

Container Insights でのメトリクス確認（Azure Portal）:

```bash
# Log Analytics でノード・Pod のメトリクスを確認
az monitor log-analytics query \
  --workspace "${LAW_NAME}" \
  --analytics-query "
    KubePodInventory
    | where Namespace == '${NAMESPACE}'
    | summarize count() by PodStatus
  " \
  --timespan PT1H
```

---

## 13. トラブルシューティング

### 13.1 よくあるエラーと対処法

| 症状 | 主な原因 | 確認コマンド / 対処法 |
|---|---|---|
| Pod が `ImagePullBackOff` | ACR へのイメージ未転送、またはプルシークレット未設定 | `kubectl describe pod <pod> -n ${NAMESPACE}` でイメージ名を確認。3章の ACR 転送・3.4 節のシークレット作成を再実施 |
| Pod が `Pending` | ノードリソース不足、または PVC がバインドされていない | `kubectl describe pod <pod>` の Events 欄を確認。ノードプールのスケールアウトまたは PVC の状態を確認 |
| PVC が `Pending` のまま | StorageClass が存在しない、または NFS に対応していない | `kubectl describe pvc <pvc> -n ${NAMESPACE}` を確認。5章の StorageClass 作成を再実施 |
| Pod が `CrashLoopBackOff` | アプリ起動エラー（DB 接続失敗・ライセンスキー不正等） | `kubectl logs <pod> -n ${NAMESPACE} --previous` でクラッシュ直前のログを確認 |
| メタストア接続エラー | Private Endpoint の疎通不可、または DB 資格情報の誤り | 8.1 節の疎通確認を再実施。Secret の値が正しいかを確認 |
| `OOMKilled` | Spark Executor のメモリ不足 | 11.3 節の `executor.memory` を増加。dqpool ノードの VM サイズ（Standard_D16s_v5）を確認 |
| Ingress が `ADDRESS` 未表示 | NGINX Ingress コントローラーの起動失敗 | `kubectl get pods -n ingress-nginx` で Controller Pod の状態を確認 |
| DQ Web に接続できない（502） | DQ Web Pod が未起動、または Service 名・ポートの不一致 | `kubectl get svc -n ${NAMESPACE}` で Service 名とポートを確認。Ingress の backend 設定と一致させる |
| Spark ジョブが `FAILED` | RBAC 不足で Executor Pod を作成できない | `kubectl get events -n ${NAMESPACE}` で `Forbidden` エラーを確認。11.1 節の Role に `create pods` 権限を付与 |
| Agent が DQ Web に接続できない | ホスト名解決失敗、または TLS 証明書エラー | Agent ログで接続エラーを確認。11.2 節の `owlweb.host` に ClusterIP DNS 名（`<svc>.<ns>.svc.cluster.local`）を指定 |

### 13.2 デバッグコマンド集

#### Pod の状態調査

```bash
# Pod 一覧と状態確認
kubectl get pods -n "${NAMESPACE}" -o wide

# Pod の詳細（イベント・マウント・コンテナ情報）
kubectl describe pod <POD_NAME> -n "${NAMESPACE}"

# クラッシュ直前のログ（CrashLoopBackOff 時）
kubectl logs <POD_NAME> -n "${NAMESPACE}" --previous

# リアルタイムログ追跡
kubectl logs <POD_NAME> -n "${NAMESPACE}" -f

# ラベルで複数 Pod のログを集約
kubectl logs -n "${NAMESPACE}" -l app=owl-web --tail=100
```

#### Pod 内での調査

```bash
# Pod 内シェルに接続
kubectl exec -it <POD_NAME> -n "${NAMESPACE}" -- /bin/bash

# Pod 内から PostgreSQL への疎通確認
kubectl exec -it <POD_NAME> -n "${NAMESPACE}" -- \
  nc -zv "${METASTORE_HOST}" 5432

# Pod 内の環境変数確認（ライセンスキー等）
kubectl exec -it <POD_NAME> -n "${NAMESPACE}" -- env | grep -iE "license|owl|db"
```

#### ネームスペース全体の調査

```bash
# 直近のイベントを確認（エラー原因の特定に有効）
kubectl get events -n "${NAMESPACE}" \
  --sort-by='.lastTimestamp' | tail -30

# 全リソースの一覧確認
kubectl get all -n "${NAMESPACE}"

# Secret の存在確認（値は表示しない）
kubectl get secret -n "${NAMESPACE}"
kubectl describe secret <SECRET_NAME> -n "${NAMESPACE}"
```

#### Helm の状態調査

```bash
# Helm リリースの状態確認
helm status "${HELM_RELEASE_NAME}" -n "${NAMESPACE}"

# デプロイ済みの values を確認
helm get values "${HELM_RELEASE_NAME}" -n "${NAMESPACE}"

# Helm が生成したマニフェストを確認
helm get manifest "${HELM_RELEASE_NAME}" -n "${NAMESPACE}"

# Helm リリース履歴
helm history "${HELM_RELEASE_NAME}" -n "${NAMESPACE}"
```

---

## 14. アップグレード手順

> **注意**: アップグレード前に必ず動作確認済みの環境でテストを行うこと。本番環境への適用前にメタストアのバックアップを取得すること。

### 14.1 アップグレード前の準備

```bash
# 現在のバージョンを確認
helm list -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" \
  -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'

# メタストアのバックアップ（Azure DB for PostgreSQL）
pg_dump \
  "host=${METASTORE_HOST} port=${METASTORE_PORT} \
   dbname=${METASTORE_DB} user=${METASTORE_USER} sslmode=require" \
  -F c -f "owlmetastore_backup_$(date +%Y%m%d).dump"

# Helm の現在の values をバックアップ
helm get values "${HELM_RELEASE_NAME}" -n "${NAMESPACE}" \
  > ~/helm-values-backup-$(date +%Y%m%d).yaml
```

### 14.2 新バージョンのイメージを ACR に転送

```bash
# 新バージョンの変数を設定
NEW_DQ_VERSION="<新バージョン例: 2026.05>"
NEW_SPARK_VERSION="<対応 Spark バージョン>"

# Collibra レジストリからイメージを取得
docker login "${COLLIBRA_REGISTRY}" \
  --username "${COLLIBRA_REGISTRY_USER}" \
  --password "${COLLIBRA_REGISTRY_PASS}"

docker pull "${COLLIBRA_REGISTRY}/owl-web:${NEW_DQ_VERSION}"
docker pull "${COLLIBRA_REGISTRY}/owl-agent:${NEW_DQ_VERSION}"
docker pull "${COLLIBRA_REGISTRY}/owl-spark:${NEW_SPARK_VERSION}"

# ACR へ転送
az acr login --name "${ACR_NAME}"

docker tag "${COLLIBRA_REGISTRY}/owl-web:${NEW_DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-web:${NEW_DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-web:${NEW_DQ_VERSION}"

docker tag "${COLLIBRA_REGISTRY}/owl-agent:${NEW_DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-agent:${NEW_DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-agent:${NEW_DQ_VERSION}"

docker tag "${COLLIBRA_REGISTRY}/owl-spark:${NEW_SPARK_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-spark:${NEW_SPARK_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-spark:${NEW_SPARK_VERSION}"
```

### 14.3 新バージョンの Helm チャートを取得

```bash
# 新バージョンの Helm チャートを取得・展開
NEW_CHART_PATH="/home/${USER}/collibra-dq-chart-${NEW_DQ_VERSION}"
mkdir -p "${NEW_CHART_PATH}"
wget -O collibra-dq-chart-new.zip "<新バージョンのダウンロードURL>"
unzip collibra-dq-chart-new.zip -d "${NEW_CHART_PATH}"
```

### 14.4 helm upgrade の実行

```bash
# custom-values.yaml のバージョンを更新
sed -i \
  "s/dq: \"${DQ_VERSION}\"/dq: \"${NEW_DQ_VERSION}\"/" \
  ~/custom-values.yaml
sed -i \
  "s/spark: \"${SPARK_VERSION}\"/spark: \"${NEW_SPARK_VERSION}\"/" \
  ~/custom-values.yaml

# アップグレード実行
helm upgrade "${HELM_RELEASE_NAME}" "${NEW_CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --values ~/custom-values.yaml \
  --timeout 15m \
  --wait
```

ローリングアップデートの進行を確認する。

```bash
kubectl rollout status deployment/collibra-dq-web -n "${NAMESPACE}"
kubectl rollout status deployment/collibra-dq-agent -n "${NAMESPACE}"
```

**アップグレード完了後の確認:**

```bash
# バージョンが更新されていることを確認
helm list -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" \
  -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'

# DQ Web にログインしてバージョン表示を確認
# 画面右上メニュー > About > バージョン番号
```

### 14.5 ロールバック手順

アップグレード後に問題が発生した場合、Helm を使用して前バージョンに戻す。

```bash
# Helm リリース履歴を確認（REVISION 番号を控える）
helm history "${HELM_RELEASE_NAME}" -n "${NAMESPACE}"
```

**出力例:**

```
REVISION  UPDATED       STATUS      CHART               DESCRIPTION
1         2026-03-01    superseded  collibra-dq-2026.02  Install complete
2         2026-06-01    deployed    collibra-dq-2026.05  Upgrade complete
```

```bash
# 前のリビジョン（例: 1）にロールバック
helm rollback "${HELM_RELEASE_NAME}" 1 \
  --namespace "${NAMESPACE}" \
  --wait

# ロールバック完了を確認
kubectl rollout status deployment/collibra-dq-web -n "${NAMESPACE}"
helm list -n "${NAMESPACE}"
```

> **補足**: ロールバック後もデータベーススキーマが新バージョンで変更されている場合、旧バージョンのアプリケーションと互換性がない可能性がある。Collibra のリリースノートでスキーママイグレーションの有無を事前に確認すること。

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
