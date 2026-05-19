# Collibra DQ ARO セットアップ手順書

> **対象バージョン**: Collibra DQ 2026.02  
> **前提**: Azure Red Hat OpenShift (ARO) クラスター基盤が構築済みであること  
> **公式ドキュメント**: [EKS / GKE / AKS - Collibra Product Resource Center](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/EKS%20%20GKE%20%20AKS.htm)

> **AKS 版との主な違い:**
>
> | 項目 | AKS | ARO（本ドキュメント） |
> |---|---|---|
> | CLI | `kubectl` | `oc`（kubectl も使用可） |
> | 名前空間 | Namespace | Project（Namespace と互換） |
> | 外部アクセス | Ingress（NGINX） | Route（OpenShift Router） |
> | Pod セキュリティ | PodSecurity Admission | Security Context Constraints (SCC) |
> | イメージレジストリ | ACR | ACR または OpenShift 内部レジストリ |
> | 監視 | Container Insights | OpenShift 組み込み監視（Prometheus/Grafana） |

---

## 目次

1. [はじめに](#1-はじめに)
2. [事前準備](#2-事前準備)
3. [コンテナイメージの準備とレジストリ転送](#3-コンテナイメージの準備とレジストリ転送)
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

本ドキュメントは、Azure Red Hat OpenShift (ARO) 上に Collibra DQ (Data Quality) をデプロイするための詳細なセットアップ手順を記載する。

**対象読者**: ARO / OpenShift の基本操作（`oc` コマンド・Helm）を理解しているインフラエンジニア・システムエンジニア

**対象範囲**:

| スコープ | 本ドキュメントの扱い |
|---|---|
| ARO クラスター構築（VNET / ノードプール等） | 対象外 |
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

#### インフラ層（ARO クラスター構築済み）

| 項目 | 確認方法 |
|---|---|
| ARO クラスターが Running 状態 | `az aro show -g <RG> -n <ARO_NAME> --query provisioningState` |
| Worker ノードが Ready 状態（3台以上） | `oc get nodes` |
| `oc` CLI がインストール済み・ログイン可能 | `oc whoami` |
| ACR または OpenShift 内部レジストリが利用可能 | `oc get route default-route -n openshift-image-registry` |
| Azure Database for PostgreSQL（外部メタストア）が起動済み | Azure Portal または az コマンドで確認 |
| Private Endpoint 経由で metastore に疎通可能 | `nc -zv <host> 5432` |

#### ライセンス・認証情報（Collibra 社から取得済み）

| 項目 | 取得先 |
|---|---|
| ライセンスキー（`license_key`） | Collibra ライセンスメール |
| ライセンス名（`license_name`） | Collibra ライセンスメール |
| コンテナイメージ取得用認証情報 | Collibra ライセンスメール |
| Helm チャート ZIP のダウンロード URL | Collibra ライセンスメール |

#### バージョン要件

| ソフトウェア | 要件 | 本環境の値 |
|---|---|---|
| Collibra DQ | 2026.02 | 2026.02 |
| Spark | 4.1.0（DQ 2026.02 必須） | 4.1.0 |
| Java | 17（コンテナ内蔵） | 17 |
| OpenShift | 4.12 以上推奨 | 4.x |
| Helm | v3 以上 | v3.x |
| PostgreSQL | 13 以上 | Azure DB for PostgreSQL Flexible Server |

### 1.3 関連ドキュメント一覧

| ドキュメント | 内容 | AKS 版との対応 |
|---|---|---|
| `docs/collibra/report.md` | Collibra DQ 製品概要・システム要件 | 共通 |
| `docs/collibra/deployment-comparison.md` | デプロイ構成比較 | 共通 |
| `docs/collibra/aks-setup.md` | AKS 版セットアップ手順 | **本ドキュメントの対応版** |
| `docs/kubernetes/aks-design.md` | AKS 設計書（参考） | AKS のみ |
| `docs/kubernetes/aks-build.md` | AKS 基盤構築手順（参考） | AKS のみ |
| `docs/kubernetes/helm.md` | Helm 基礎知識 | 共通 |

---

## 2. 事前準備

### 2.1 変数定義

本手順全体で使用する環境変数を定義する。AKS 版と共通の変数に加え、ARO 固有の変数を追加する。

```bash
# ---- Azure 基本情報 ----
SUBSCRIPTION_ID="<サブスクリプションID>"
LOCATION="japaneast"
RG_NAME="rg-collibra-aro"

# ---- ARO クラスター ----
ARO_NAME="aro-collibra-dq"
ARO_CONSOLE_URL=$(az aro show \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query consoleProfile.url -o tsv)
ARO_API_URL=$(az aro show \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query apiserverProfile.url -o tsv)

# ---- ACR（イメージレジストリ） ----
ACR_NAME="acrcollibradq"
ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"

# ---- Collibra DQ アプリケーション ----
OC_PROJECT="collibra-dq"           # OpenShift Project 名
NAMESPACE="${OC_PROJECT}"           # Helm / oc コマンドで共用
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
DQ_ADMIN_PASS="<管理者パスワード>"

# ---- Helm チャートパス ----
CHART_PATH="/home/${USER}/collibra-dq-chart"
```

### 2.2 ARO クラスターへの接続確認

ARO の管理者認証情報を取得して `oc login` でクラスターに接続する。

```bash
# ARO の kubeadmin パスワードを取得
ARO_PASSWORD=$(az aro list-credentials \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query kubeadminPassword -o tsv)

# oc login で接続
oc login "${ARO_API_URL}" \
  --username kubeadmin \
  --password "${ARO_PASSWORD}" \
  --insecure-skip-tls-verify=false

# 接続確認
oc whoami
oc cluster-info
```

**期待される出力例:**
```
kubeadmin
Kubernetes control plane is running at https://api.aro-collibra-dq.xxxx.japaneast.aroapp.io:6443
```

```bash
# ノード一覧と状態確認（全ノードが Ready であること）
oc get nodes -o wide
```

**期待される出力例:**
```
NAME                  STATUS   ROLES                  AGE   VERSION
master-0              Ready    control-plane,master   1d    v1.29.x
master-1              Ready    control-plane,master   1d    v1.29.x
master-2              Ready    control-plane,master   1d    v1.29.x
worker-japaneast-0    Ready    worker                 1d    v1.29.x
worker-japaneast-1    Ready    worker                 1d    v1.29.x
worker-japaneast-2    Ready    worker                 1d    v1.29.x
```

### 2.3 必要ツールの確認（oc / kubectl / helm / az CLI）

```bash
# oc CLI バージョン確認
oc version
# 期待値: Client Version: 4.x.x / Server Version: 4.x.x

# Helm バージョン確認（v3 系であること）
helm version

# az CLI バージョン確認
az version
```

**oc CLI が未インストールの場合:**

```bash
# OpenShift コンソールのダウンロードページから取得
# https://<ARO_CONSOLE_URL>/command-line-tools

# または ARO の API サーバーからダウンロード
curl -sL "${ARO_API_URL}/api/v1/namespaces/openshift/configmaps/console-public" \
  | grep consoleURL

# Linux 向け（例）
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar -xvf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/
oc version
```

### 2.4 OpenShift プロジェクト作成

AKS の Namespace に相当する OpenShift **Project** を作成する。Project は Namespace の上位概念で、RBAC・ネットワークポリシー・リソースクォータを一括管理できる。

```bash
# Project 作成
oc new-project "${OC_PROJECT}" \
  --description="Collibra DQ deployment project" \
  --display-name="Collibra DQ"

# 作成確認
oc get project "${OC_PROJECT}"
oc project "${OC_PROJECT}"   # 作業 Project を切り替え
```

**期待される出力例:**
```
NAME          DISPLAY NAME   STATUS
collibra-dq   Collibra DQ    Active
Now using project "collibra-dq" on server "https://api.aro-...".
```

```bash
# Project にラベルを付与（リソース識別用）
oc label namespace "${OC_PROJECT}" \
  app.kubernetes.io/name=collibra-dq \
  environment=production
```

---

## 3. コンテナイメージの準備とレジストリ転送

> **AKS 版との違い**: Collibra GCR からのイメージ取得手順は同一。転送先として **ACR**（AKS 版と同様）と **OpenShift 内部レジストリ**の2択がある。プライベートクラスター環境では ACR を推奨する。

**レジストリ選択指針:**

| レジストリ | メリット | デメリット | 推奨場面 |
|---|---|---|---|
| ACR | AKS/ARO 共通で管理可・Private Endpoint 対応 | 別途コスト発生 | **本手順で採用（推奨）** |
| OpenShift 内部レジストリ | ARO 標準・追加コストなし | ARO 専用・外部共有不可 | ARO 単独運用時 |

### 3.1 Collibra ライセンス情報の確認

Collibra 社から受領するライセンスメールに記載されたイメージレジストリ URL・認証情報を確認する（AKS 版 3.1 節と同一）。

### 3.2 Collibra レジストリからのイメージ取得

```bash
# Collibra レジストリにログイン
docker login "${COLLIBRA_REGISTRY}" \
  --username "${COLLIBRA_REGISTRY_USER}" \
  --password "${COLLIBRA_REGISTRY_PASS}"

# DQ Web / Agent / Spark イメージを取得
docker pull "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}"
docker pull "${COLLIBRA_REGISTRY}/owl-agent:${DQ_VERSION}"
docker pull "${COLLIBRA_REGISTRY}/owl-spark:${SPARK_VERSION}"

# 取得確認
docker images | grep -E "owl-web|owl-agent|owl-spark"
```

### 3.3 ACR へのイメージ転送

```bash
# ACR にログイン
az acr login --name "${ACR_NAME}"

# DQ Web
docker tag "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-web:${DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-web:${DQ_VERSION}"

# DQ Agent
docker tag "${COLLIBRA_REGISTRY}/owl-agent:${DQ_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-agent:${DQ_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-agent:${DQ_VERSION}"

# Spark
docker tag "${COLLIBRA_REGISTRY}/owl-spark:${SPARK_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"

# 登録確認
az acr repository list --name "${ACR_NAME}" --output table
```

#### 補足: OpenShift 内部レジストリへの転送（ACR 非使用時）

```bash
# 内部レジストリの Route を有効化（管理者権限が必要）
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  --patch '{"spec":{"defaultRoute":true}}'

# 内部レジストリの外部 URL を取得
INTERNAL_REGISTRY=$(oc get route default-route \
  -n openshift-image-registry \
  -o jsonpath='{.spec.host}')

# OpenShift トークンで docker login
docker login "${INTERNAL_REGISTRY}" \
  --username kubeadmin \
  --password "$(oc whoami -t)"

# イメージをタグ付けしてプッシュ
docker tag "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}" \
  "${INTERNAL_REGISTRY}/${OC_PROJECT}/owl-web:${DQ_VERSION}"
docker push "${INTERNAL_REGISTRY}/${OC_PROJECT}/owl-web:${DQ_VERSION}"
# Agent / Spark も同様に実施
```

### 3.4 イメージプルシークレットの設定

#### ACR 使用時

```bash
ACR_PASSWORD=$(az acr credential show \
  --name "${ACR_NAME}" \
  --query "passwords[0].value" -o tsv)

oc create secret docker-registry dq-pull-secret \
  --docker-server="${ACR_LOGIN_SERVER}" \
  --docker-username="${ACR_NAME}" \
  --docker-password="${ACR_PASSWORD}" \
  -n "${OC_PROJECT}"

# デフォルト ServiceAccount に紐付け（Pod が自動使用）
oc secrets link default dq-pull-secret --for=pull -n "${OC_PROJECT}"

# 確認
oc get secret dq-pull-secret -n "${OC_PROJECT}"
```

#### OpenShift 内部レジストリ使用時

```bash
# 内部レジストリは ServiceAccount のトークンで自動認証されるため
# 追加のプルシークレット設定は不要
# ImageStream を使用してイメージを管理する
oc import-image collibra/owl-web:${DQ_VERSION} \
  --from="${INTERNAL_REGISTRY}/${OC_PROJECT}/owl-web:${DQ_VERSION}" \
  --confirm -n "${OC_PROJECT}"
```

---

## 4. Helm チャートの準備

> **AKS 版との違い**: チャートの入手・展開手順は同一。ARO では OpenShift の SCC 制約により、コンテナの `runAsUser` を固定できないケースがある。ARO が自動割り当てする UID 範囲を許容するよう `securityContext` を調整する必要がある。

### 4.1 Helm チャートの入手方法

```bash
# ライセンスメール記載の URL からダウンロード
wget -O collibra-dq-chart.zip "<ライセンスメール記載のダウンロードURL>"

mkdir -p "${CHART_PATH}"
unzip collibra-dq-chart.zip -d "${CHART_PATH}"

ls -l "${CHART_PATH}"
```

### 4.2 チャートディレクトリ構造の確認

```bash
find "${CHART_PATH}" -maxdepth 3 | sort
```

**典型的なチャート構造:**

```
collibra-dq-chart/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── deployment-web.yaml
│   ├── deployment-agent.yaml
│   ├── service-web.yaml
│   ├── pvc-web.yaml
│   ├── rbac.yaml
│   └── ...
└── charts/
```

```bash
# チャートバージョン確認
cat "${CHART_PATH}/Chart.yaml"
```

### 4.3 values.yaml 設定パラメータ一覧

AKS 版と共通のパラメータに加え、ARO 固有の設定を示す。

#### 共通パラメータ（AKS 版と同一）

| パラメータ | 説明 | 設定例 |
|---|---|---|
| `global.version.dq` | Collibra DQ バージョン | `"2026.02"` |
| `global.version.spark` | Spark バージョン | `"4.1.0"` |
| `global.image.repo` | コンテナイメージリポジトリ | `"acrcollibradq.azurecr.io/collibra"` |
| `global.configMap.data.license_key` | ライセンスキー | `"<license_key>"` |
| `global.web.service.type` | サービスタイプ | `"ClusterIP"`（Route で公開） |
| `global.persistence.web.storageClassName` | DQ Web 用 StorageClass | `"azurefile-csi"` |

#### ARO 固有パラメータ

| パラメータ | 説明 | ARO での推奨値 |
|---|---|---|
| `global.web.securityContext.runAsNonRoot` | root 以外で実行 | `true` |
| `global.web.securityContext.runAsUser` | 実行 UID（SCC anyuid 使用時のみ指定） | 省略（ARO が自動割り当て）|
| `global.web.podSecurityContext.fsGroup` | ボリュームマウント用 GID | 省略（ARO が自動割り当て） |
| `global.web.securityContext.allowPrivilegeEscalation` | 権限昇格の禁止 | `false` |
| `global.web.securityContext.capabilities.drop` | Linux Capabilities の削除 | `["ALL"]` |

> **補足**: ARO の `restricted-v2` SCC（デフォルト）では UID が自動割り当てされるため、`runAsUser` を固定指定するとデプロイが拒否される。Collibra DQ が特定 UID を必要とする場合は 6章で `anyuid` SCC を付与する。

---

## 5. ストレージの設定

> **AKS 版との違い**: Azure Files を使用する点は同一。ARO では StorageClass のプロビジョナー名が異なる場合があるため、クラスター既存の StorageClass を優先して確認する。

**本章で作成するストレージリソースの一覧:**

| リソース | 用途 | アクセスモード | サイズ |
|---|---|---|---|
| StorageClass `azurefile-csi-rwx` | DQ Web / Spark 共用 | ReadWriteMany | - |
| PVC `dq-web-pvc` | DQ Web の設定・ログ永続化 | ReadWriteMany | 10Gi |
| PVC `spark-scratch-pvc` | Spark の一時処理領域 | ReadWriteMany | 20Gi |
| PVC `dq-jdbc-drivers-pvc` | JDBC ドライバー格納 | ReadWriteMany | 5Gi |

### 5.1 OpenShift の StorageClass 確認

ARO に組み込みの StorageClass を確認する。

```bash
oc get storageclass
```

**ARO の標準 StorageClass 一覧（抜粋）:**

```
NAME                    PROVISIONER                    RECLAIMPOLICY
managed-csi (default)   disk.csi.azure.com             Delete
managed-csi-premium     disk.csi.azure.com             Delete
azurefile-csi           file.csi.azure.com             Delete
azurefile-csi-premium   file.csi.azure.com             Delete
```

`azurefile-csi` は ReadWriteMany に対応しているが、SMB プロトコルでは ARO の SCC と権限の競合が発生しやすい。NFS プロトコルを使用するカスタムストレージクラスを作成して使用する。

```bash
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-rwx
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

oc get storageclass azurefile-csi-rwx
```

### 5.2 DQ Web 用 PVC 設定

```bash
oc apply -f - -n "${OC_PROJECT}" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dq-web-pvc
  namespace: ${OC_PROJECT}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 10Gi
EOF

# バインド確認
oc get pvc dq-web-pvc -n "${OC_PROJECT}" --watch
```

**期待される出力（STATUS が Bound）:**

```
NAME         STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS        AGE
dq-web-pvc   Bound    pvc-xxxxx   10Gi       RWX            azurefile-csi-rwx   30s
```

### 5.3 Spark Scratch Disk 用 PVC 設定

```bash
oc apply -f - -n "${OC_PROJECT}" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: spark-scratch-pvc
  namespace: ${OC_PROJECT}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 20Gi
EOF

oc get pvc spark-scratch-pvc -n "${OC_PROJECT}"
```

### 5.4 JDBC ドライバー用 PVC 設定

```bash
oc apply -f - -n "${OC_PROJECT}" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dq-jdbc-drivers-pvc
  namespace: ${OC_PROJECT}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-rwx
  resources:
    requests:
      storage: 5Gi
EOF

# 全 PVC の状態まとめ確認
oc get pvc -n "${OC_PROJECT}"
```

**期待される出力（全て Bound）:**

```
NAME                   STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS        AGE
dq-web-pvc             Bound    pvc-xxx    10Gi       RWX            azurefile-csi-rwx   3m
spark-scratch-pvc      Bound    pvc-yyy    20Gi       RWX            azurefile-csi-rwx   2m
dq-jdbc-drivers-pvc    Bound    pvc-zzz    5Gi        RWX            azurefile-csi-rwx   1m
```

---

## 6. 認証・シークレットの設定

> **AKS 版との最大の違い**: ARO 固有の手順として **Security Context Constraints (SCC)** の付与が必要。Collibra DQ コンテナが必要とする UID での起動を許可するため、ServiceAccount に `anyuid` または カスタム SCC を付与する。

**本章で作成するリソース一覧:**

| リソース | 種別 | 内容 |
|---|---|---|
| `dq-pull-secret` | Secret | ACR 認証情報（3章で作成済み） |
| `dq-license-secret` | Secret | ライセンスキー・ライセンス名 |
| `dq-metastore-secret` | Secret | メタストア DB パスワード |
| `dq-admin-secret` | Secret | DQ Web 管理者パスワード |
| `collibra-dq-sa` | ServiceAccount | DQ / Spark 用 SA（SCC・Workload Identity 紐付け） |

### 6.1 Security Context Constraints (SCC) の設定

SCC は OpenShift 固有のセキュリティ制御機構。デフォルトの `restricted-v2` では固定 UID での起動が拒否されるため、Collibra DQ の要件に応じて設定する。

#### 現在の SCC を確認

```bash
# プロジェクトの Pod が使用している SCC を確認
oc get pod -n "${OC_PROJECT}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'

# 利用可能な SCC 一覧
oc get scc
```

#### ServiceAccount の作成

```bash
oc create serviceaccount collibra-dq-sa -n "${OC_PROJECT}"
```

#### anyuid SCC の付与（推奨）

Collibra DQ が特定の UID（例: 1000）での起動を必要とする場合、`anyuid` SCC を付与する。

```bash
# anyuid SCC を ServiceAccount に付与（クラスター管理者権限が必要）
oc adm policy add-scc-to-user anyuid \
  -z collibra-dq-sa \
  -n "${OC_PROJECT}"

# 付与の確認
oc adm policy who-can use scc anyuid | grep collibra-dq-sa
```

#### カスタム SCC の作成（最小権限構成）

`anyuid` よりも制限を絞りたい場合は、必要な権限のみを持つカスタム SCC を作成する。

```bash
oc apply -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: collibra-dq-scc
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
runAsUser:
  type: MustRunAsRange          # 指定範囲内の UID を許可
  uidRangeMin: 1000
  uidRangeMax: 65535
seLinuxContext:
  type: MustRunAs
fsGroup:
  type: MustRunAs
  ranges:
    - min: 1000
      max: 65535
volumes:
  - configMap
  - emptyDir
  - persistentVolumeClaim
  - secret
users: []
groups: []
EOF

# カスタム SCC を ServiceAccount に付与
oc adm policy add-scc-to-user collibra-dq-scc \
  -z collibra-dq-sa \
  -n "${OC_PROJECT}"
```

### 6.2 イメージプルシークレット登録確認

```bash
oc get secret dq-pull-secret -n "${OC_PROJECT}"
# 存在しない場合は 3.4 節を参照して再作成
```

### 6.3 ライセンスキーのシークレット化

```bash
# ライセンス情報
oc create secret generic dq-license-secret \
  --from-literal=license_key="${DQ_LICENSE_KEY}" \
  --from-literal=license_name="${DQ_LICENSE_NAME}" \
  -n "${OC_PROJECT}"

# メタストア DB パスワード
oc create secret generic dq-metastore-secret \
  --from-literal=password="${METASTORE_PASS}" \
  -n "${OC_PROJECT}"

# DQ Web 管理者パスワード
oc create secret generic dq-admin-secret \
  --from-literal=password="${DQ_ADMIN_PASS}" \
  -n "${OC_PROJECT}"

# 確認
oc get secret -n "${OC_PROJECT}"
```

### 6.4 Azure Key Vault 統合（オプション）

ARO では OperatorHub 経由または Helm で Secret Store CSI ドライバーをインストールする。

```bash
# Helm で secrets-store-csi-driver をインストール
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm upgrade --install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true

# Azure Key Vault プロバイダーをインストール
helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm upgrade --install azure-csi-provider \
  csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system
```

> **補足**: AKS では `az aks enable-addons` で有効化できるが、ARO では Helm または OperatorHub 経由で手動インストールが必要。SecretProviderClass の YAML 設定は AKS 版（6.3 節）と同一。

### 6.5 Workload Identity / ServiceAccount 設定

Azure AD Workload Identity と OpenShift の ServiceAccount を紐付ける。

```bash
# OIDC 発行者 URL を取得（ARO は組み込み OIDC を提供）
OIDC_ISSUER=$(az aro show \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query "clusterProfile.pullSecret" -o tsv 2>/dev/null || \
  oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}')

# Workload Identity 用マネージド ID を作成
MI_NAME="mi-collibra-aro"
az identity create \
  --resource-group "${RG_NAME}" \
  --name "${MI_NAME}" \
  --location "${LOCATION}"

MI_CLIENT_ID=$(az identity show -g "${RG_NAME}" -n "${MI_NAME}" \
  --query clientId -o tsv)
MI_OBJECT_ID=$(az identity show -g "${RG_NAME}" -n "${MI_NAME}" \
  --query principalId -o tsv)

# フェデレーション ID 資格情報を作成
az identity federated-credential create \
  --name "collibra-aro-federated" \
  --identity-name "${MI_NAME}" \
  --resource-group "${RG_NAME}" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:${OC_PROJECT}:collibra-dq-sa" \
  --audience api://AzureADTokenExchange

# ServiceAccount にアノテーションを付与
oc annotate serviceaccount collibra-dq-sa \
  azure.workload.identity/client-id="${MI_CLIENT_ID}" \
  -n "${OC_PROJECT}"
```

---

## 7. SSL/HTTPS 設定

> **AKS 版との違い**: Java Keystore の作成・Secret 登録手順は同一。ARO では TLS 終端を **OpenShift Route** で行う **Edge termination** が推奨。この方式ではアプリ（DQ Web）側での TLS 設定が不要になり、Route が証明書を処理する。

**ARO での TLS 終端方式比較:**

| 方式 | Route → Pod 通信 | アプリ側 TLS 設定 | 推奨場面 |
|---|---|---|---|
| Edge termination | HTTP（平文） | 不要 | **本手順で採用（推奨）** |
| Re-encrypt termination | HTTPS | 必要（JKS 設定） | アプリまで E2E 暗号化が必要な場合 |
| Passthrough termination | HTTPS（そのまま転送） | 必要（JKS 設定） | Route で証明書を管理しない場合 |

### 7.1 Java Keystore の作成

Edge termination では Route が TLS を処理するため Keystore は不要。**Re-encrypt / Passthrough 方式を使用する場合のみ**本節を実施する。

#### パターン A: 自己署名証明書（検証用）

```bash
mkdir -p ~/ssl && cd ~/ssl

keytool -genkey \
  -alias dq-server \
  -keyalg RSA \
  -keysize 2048 \
  -keystore keystore.jks \
  -validity 3650 \
  -storepass "<keystoreパスワード>" \
  -keypass  "<keystoreパスワード>" \
  -dname "CN=<DQ Web のFQDNまたはIP>, OU=IT, O=<会社名>, L=Tokyo, ST=Tokyo, C=JP"

keytool -list -keystore keystore.jks -storepass "<keystoreパスワード>"
```

#### パターン B: CA 署名済み証明書（本番用）

```bash
# PEM → PKCS12 → JKS に変換
openssl pkcs12 -export \
  -in server.crt -inkey server.key \
  -chain -CAfile ca-chain.crt \
  -name dq-server \
  -out keystore.p12 \
  -passout pass:"<keystoreパスワード>"

keytool -importkeystore \
  -srckeystore keystore.p12 -srcstoretype PKCS12 \
  -srcstorepass "<keystoreパスワード>" \
  -destkeystore keystore.jks -deststoretype JKS \
  -deststorepass "<keystoreパスワード>"
```

### 7.2 CA 証明書のインポート

外部データソース（SSL 接続が必要な場合）の CA 証明書を Java の `cacerts` にインポートする。

```bash
JAVA_CACERTS=$(find /usr/lib/jvm -name "cacerts" 2>/dev/null | head -1)

keytool -import \
  -alias "external-db-ca" \
  -file ca-cert.pem \
  -keystore "${JAVA_CACERTS}" \
  -storepass "changeit" \
  -noprompt
```

### 7.3 OpenShift Secret への登録

Re-encrypt / Passthrough 方式の場合のみ Keystore を Secret として登録する。

```bash
oc create secret generic dq-ssl-secret \
  --from-file=keystore.jks=~/ssl/keystore.jks \
  -n "${OC_PROJECT}"

oc describe secret dq-ssl-secret -n "${OC_PROJECT}"
```

### 7.4 TLS 終端方式の選択と Helm パラメータ設定

#### Edge termination（推奨）の場合

アプリ側での TLS 設定は不要。Helm values の TLS 設定は無効化する。

```yaml
# custom-values.yaml（Edge termination 時）
global:
  web:
    tls:
      enabled: false     # Route が TLS を処理するため無効
    service:
      type: ClusterIP
```

Route での証明書指定は 10章で行う。

#### Re-encrypt termination の場合

アプリ側でも TLS を有効化する。

```yaml
# custom-values.yaml（Re-encrypt termination 時）
global:
  web:
    tls:
      enabled: true
      key:
        secretName: dq-ssl-secret
        alias: dq-server
        type: JKS
        pass: "<keystoreパスワード>"
        store:
          name: keystore.jks
```

---

## 8. 外部メタストア（PostgreSQL）接続設定

> **AKS 版との違い**: 接続確認・JDBC URL・パスワードレス認証の設定手順は AKS 版と同一。`kubectl run` の代わりに `oc run` を使用する点のみ異なる。

### 8.1 Azure Database for PostgreSQL への接続確認

Private Endpoint の疎通確認と、メタストア用 DB・ユーザーの存在を確認する。

```bash
# PostgreSQL への疎通確認
oc run pg-test --rm -it \
  --image=postgres:15 \
  --restart=Never \
  -n "${OC_PROJECT}" \
  -- psql "host=${METASTORE_HOST} port=${METASTORE_PORT} \
           dbname=${METASTORE_DB} user=${METASTORE_USER} \
           password=${METASTORE_PASS} sslmode=require" \
  -c "SELECT version();"
```

> **注意**: ARO の SCC により `postgres:15` イメージが `restricted-v2` で拒否される場合がある。その場合は `--overrides` で `runAsNonRoot: false` を一時的に指定するか、疎通確認用に `alpine` + `nc` を使用する。

```bash
# ポート疎通のみ確認する場合（SCC 制限が厳しい環境向け）
oc run nc-test --rm -it \
  --image=alpine \
  --restart=Never \
  -n "${OC_PROJECT}" \
  -- nc -zv "${METASTORE_HOST}" 5432
```

#### メタストア DB の初期作成（未作成の場合）

```bash
oc run pg-init --rm -it \
  --image=postgres:15 \
  --restart=Never \
  -n "${OC_PROJECT}" \
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

6章で作成したマネージド ID（`mi-collibra-aro`）を使用して PostgreSQL にパスワードレスで接続する構成。手順は AKS 版と同一。

```bash
PG_SERVER_NAME="<PostgreSQL サーバー名>"

# PostgreSQL サーバーで Azure AD 認証を有効化
az postgres flexible-server update \
  --resource-group "${RG_NAME}" \
  --name "${PG_SERVER_NAME}" \
  --active-directory-auth Enabled

# マネージド ID を Azure AD 管理者として設定
az postgres flexible-server ad-admin create \
  --resource-group "${RG_NAME}" \
  --server-name "${PG_SERVER_NAME}" \
  --display-name "${MI_NAME}" \
  --object-id "${MI_OBJECT_ID}" \
  --type ServicePrincipal
```

### 8.3 接続文字列の設定

```bash
JDBC_URL="jdbc:postgresql://${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}?currentSchema=public&sslmode=require"

oc create secret generic dq-metastore-jdbc \
  --from-literal=url="${JDBC_URL}" \
  --from-literal=username="${METASTORE_USER}" \
  -n "${OC_PROJECT}"
```

`custom-values.yaml` に metastore 接続設定を追加する。

```yaml
global:
  metastore:
    host: "<METASTORE_HOST>"
    port: "5432"
    db: "owlmetastore"
    user: "<METASTORE_USER>"
    existingSecret: dq-metastore-secret
    existingSecretKey: password
```

---

## 9. Collibra DQ のデプロイ（Helm）

> **AKS 版との違い**: `helm upgrade --install` の基本コマンドは同一。ARO 向けには **SCC・securityContext** の設定を `custom-values.yaml` に追加する。確認コマンドは `kubectl` → `oc` に置き換える。

### 9.1 デプロイ前チェックリスト

```bash
# Project 確認
oc get project "${OC_PROJECT}"

# PVC が全て Bound であることを確認
oc get pvc -n "${OC_PROJECT}"

# Secret が揃っていることを確認
oc get secret -n "${OC_PROJECT}"

# SCC が ServiceAccount に付与されていることを確認
oc adm policy who-can use scc anyuid | grep collibra-dq-sa

# チャートファイルの存在確認
ls "${CHART_PATH}/Chart.yaml"
```

**デプロイ前の期待状態:**

| リソース | 確認項目 |
|---|---|
| Project | `collibra-dq` が Active |
| PVC | `dq-web-pvc` / `spark-scratch-pvc` / `dq-jdbc-drivers-pvc` が Bound |
| Secret | `dq-pull-secret` / `dq-license-secret` / `dq-metastore-secret` / `dq-admin-secret` が存在 |
| SCC | `collibra-dq-sa` に `anyuid` または カスタム SCC が付与済み |
| Chart | `${CHART_PATH}/Chart.yaml` が存在 |

### 9.2 custom-values.yaml の作成（ARO 向け追加設定）

```bash
cat <<EOF > ~/custom-values-aro.yaml
global:
  version:
    dq: "${DQ_VERSION}"
    spark: "${SPARK_VERSION}"

  image:
    repo: "${ACR_LOGIN_SERVER}/collibra"

  web:
    admin:
      email: "${DQ_ADMIN_EMAIL}"
      password: ""
    service:
      type: ClusterIP         # Route で公開するため ClusterIP
    tls:
      enabled: false          # Edge termination 時は無効（10章の Route で TLS 処理）

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

# ARO 固有: SCC anyuid が付与された SA を使用
serviceAccount:
  name: collibra-dq-sa

# ARO 固有: securityContext（restricted-v2 準拠）
podSecurityContext:
  runAsNonRoot: true
  # fsGroup は省略（ARO が Project の UID 範囲から自動割り当て）

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

spark_scratch_type: persistentVolumeClaim
spark_scratch_storage_class: azurefile-csi-rwx
spark_scratch_storage_size: 20Gi

imagePullSecrets:
  - name: dq-pull-secret
EOF
```

### 9.3 helm upgrade --install コマンド

```bash
helm upgrade --install "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${OC_PROJECT}" \
  --values ~/custom-values-aro.yaml \
  --set global.configMap.data.license_key="$(
      oc get secret dq-license-secret -n ${OC_PROJECT} \
        -o jsonpath='{.data.license_key}' | base64 -d)" \
  --set global.configMap.data.license_name="$(
      oc get secret dq-license-secret -n ${OC_PROJECT} \
        -o jsonpath='{.data.license_name}' | base64 -d)" \
  --set global.web.admin.password="$(
      oc get secret dq-admin-secret -n ${OC_PROJECT} \
        -o jsonpath='{.data.password}' | base64 -d)" \
  --timeout 10m \
  --wait
```

デプロイの進行を別ターミナルで確認する。

```bash
oc get pods -n "${OC_PROJECT}" --watch
```

### 9.4 デプロイ状態の確認

```bash
# Pod・Service・PVC を一括確認
oc get pod,svc,pvc -n "${OC_PROJECT}"

# Helm リリース確認
helm list -n "${OC_PROJECT}"
```

**正常時の Pod 一覧例:**

```
NAME                              READY   STATUS    RESTARTS   AGE
collibra-dq-web-xxxxxxxxx-xxxxx   1/1     Running   0          3m
collibra-dq-agent-xxxxxxx-xxxxx   1/1     Running   0          3m
```

SCC 違反で Pod が起動しない場合は以下を確認する。

```bash
oc describe pod <POD_NAME> -n "${OC_PROJECT}" | grep -A5 "Events:"
# "unable to validate against any security context constraint" が出る場合は 6.1 節を再確認
```

### 9.5 初期起動の確認

```bash
# DQ Web のログ確認
oc logs -n "${OC_PROJECT}" \
  -l app=owl-web \
  --tail=100 \
  --follow

# 正常起動時のキーワード
# Started OwlApplication in xx.xxx seconds
# Tomcat started on port(s): 9000

# エラー抽出
oc logs -n "${OC_PROJECT}" \
  -l app=owl-web --tail=200 \
  | grep -iE "error|exception|failed"
```

---

## 10. ネットワーク・外部アクセスの設定

> **AKS 版との最大の違い**: AKS では NGINX Ingress を別途インストールして使用するが、ARO では **OpenShift Route** を使用する。Route は ARO 組み込みの Router（HAProxy ベース）が自動処理するため、Ingress コントローラーのインストールは不要。

### 10.1 OpenShift Route の概要

ARO のデフォルトドメインを確認する。

```bash
# ARO のデフォルト Ingress ドメインを確認
oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}'
# 例: apps.aro-collibra-dq.xxxx.japaneast.aroapp.io
```

Route を作成すると `<route名>.<project名>.<デフォルトドメイン>` の URL が自動で割り当てられる。

**TLS 終端方式の選択:**

| 方式 | 説明 | 証明書の場所 | 推奨場面 |
|---|---|---|---|
| Edge | Route で TLS を終端。Pod まで HTTP | Route に証明書を設定 | **本手順で採用（推奨）** |
| Re-encrypt | Route と Pod の両方で TLS | Route + Pod（JKS） | E2E 暗号化が必要な場合 |
| Passthrough | Route は TLS を透過。Pod で終端 | Pod（JKS） | Route で証明書を管理しない場合 |

### 10.2 Route リソースの作成

#### Edge termination（推奨）

ARO デフォルトの自己署名証明書を使用する場合（簡易設定）:

```bash
# oc expose で Service から Route を作成
oc expose svc/collibra-dq-web \
  --name=dq-web-route \
  --port=9000 \
  -n "${OC_PROJECT}"

# 作成された Route の URL を確認
oc get route dq-web-route -n "${OC_PROJECT}" \
  -o jsonpath='{.spec.host}'
```

CA 署名済み証明書を使用する場合（本番推奨）:

```bash
oc apply -f - -n "${OC_PROJECT}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: dq-web-route
  namespace: ${OC_PROJECT}
spec:
  host: dq.example.internal          # カスタムホスト名（省略時は自動割り当て）
  to:
    kind: Service
    name: collibra-dq-web
  port:
    targetPort: 9000
  tls:
    termination: edge
    certificate: |                   # サーバー証明書（PEM 形式）
      -----BEGIN CERTIFICATE-----
      <証明書の内容>
      -----END CERTIFICATE-----
    key: |                           # 秘密鍵（PEM 形式）
      -----BEGIN PRIVATE KEY-----
      <秘密鍵の内容>
      -----END PRIVATE KEY-----
    caCertificate: |                 # CA 証明書（中間 CA がある場合）
      -----BEGIN CERTIFICATE-----
      <CA証明書の内容>
      -----END CERTIFICATE-----
    insecureEdgeTerminationPolicy: Redirect   # HTTP → HTTPS リダイレクト
EOF
```

#### Re-encrypt termination（E2E 暗号化）

```bash
oc apply -f - -n "${OC_PROJECT}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: dq-web-route
  namespace: ${OC_PROJECT}
spec:
  host: dq.example.internal
  to:
    kind: Service
    name: collibra-dq-web
  port:
    targetPort: 9000
  tls:
    termination: reencrypt
    certificate: |
      <Route の証明書（PEM）>
    key: |
      <Route の秘密鍵（PEM）>
    destinationCACertificate: |      # Pod の証明書に署名した CA（検証用）
      <Pod 側 CA 証明書（PEM）>
    insecureEdgeTerminationPolicy: Redirect
EOF
```

Route 作成を確認する。

```bash
oc get route -n "${OC_PROJECT}"
```

**期待される出力例:**

```
NAME            HOST/PORT                                              PATH   SERVICES          PORT   TERMINATION     WILDCARD
dq-web-route    dq-web-route-collibra-dq.apps.aro-xxx.japaneast...           collibra-dq-web   9000   edge/Redirect   None
```

### 10.3 カスタムドメインの設定（オプション）

ARO デフォルトドメイン（`*.apps.aro-xxx...`）以外のカスタムドメインを使用する場合、Route の `spec.host` にカスタムドメインを指定し、DNS に CNAME レコードを追加する。

```bash
# ARO Router の外部 IP / ホスト名を確認
oc get svc router-default -n openshift-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# DNS 設定例（社内 DNS 担当者に依頼）
# dq.example.internal  CNAME  <Router の外部 IP または FQDN>
```

### 10.4 DQ Web への外部アクセス確認

```bash
# Route の URL を取得
DQ_URL=$(oc get route dq-web-route -n "${OC_PROJECT}" \
  -o jsonpath='{.spec.tls.termination == "edge" && "https" || "http"}://{.spec.host}/')
DQ_URL="https://$(oc get route dq-web-route -n ${OC_PROJECT} -o jsonpath='{.spec.host}')"

# HTTP ステータス確認
curl -sk "${DQ_URL}" -o /dev/null -w "%{http_code}\n"
# 期待値: 200

echo "DQ Web URL: ${DQ_URL}"
```

ブラウザで `${DQ_URL}` を開き、Collibra DQ のログイン画面が表示されることを確認する。

---

## 11. DQ Agent の設定

> **AKS 版との違い**: Agent の設定内容は基本的に同一。ARO では Spark Executor Pod の動的生成時にも SCC が適用されるため、`dq-agent-sa` に `anyuid` SCC を付与することが必須となる。

**DQ Agent の役割（ARO）:**

```
DQ Web UI
   │ REST API (ポート 9000)
   ▼
DQ Agent (ポート 9101)
   │ Kubernetes API（OpenShift API Server 経由）
   ▼
Spark Driver Pod（動的生成）
   │
   ├── Spark Executor Pod 1
   ├── Spark Executor Pod 2
   └── Spark Executor Pod N
```

### 11.1 RBAC / ServiceAccount 設定（SCC 付与含む）

DQ Agent と Spark Driver が Pod の作成・削除を行うための権限と、ARO の SCC を付与する。

```bash
cat <<EOF | oc apply -f - -n "${OC_PROJECT}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dq-agent-sa
  namespace: ${OC_PROJECT}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dq-agent-role
  namespace: ${OC_PROJECT}
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
  namespace: ${OC_PROJECT}
subjects:
  - kind: ServiceAccount
    name: dq-agent-sa
    namespace: ${OC_PROJECT}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: dq-agent-role
EOF
```

ARO では ServiceAccount に SCC を付与しないと Spark Executor Pod の起動時に SCC 違反エラーが発生する。`cluster-admin` 権限で以下を実行する。

```bash
# dq-agent-sa に anyuid SCC を付与
oc adm policy add-scc-to-user anyuid \
  -z dq-agent-sa \
  -n "${OC_PROJECT}"

# 付与された SCC を確認
oc adm policy who-can use scc/anyuid | grep dq-agent-sa
```

> **補足**: Spark Executor Pod は `dq-agent-sa` を継承して動作するため、この ServiceAccount に anyuid を付与するだけで Executor Pod にも SCC が適用される。

RBAC の確認:

```bash
oc get role,rolebinding,serviceaccount -n "${OC_PROJECT}"
```

### 11.2 Agent 接続先の設定

DQ Agent が DQ Web に接続するためのエンドポイントを `custom-values-aro.yaml` に設定する。

```yaml
# DQ Agent の設定（custom-values-aro.yaml に追記）
agent:
  serviceAccount:
    name: dq-agent-sa       # 11.1 で作成した ServiceAccount
  config:
    owlweb:
      host: "collibra-dq-web.${OC_PROJECT}.svc.cluster.local"
      port: "9000"
      protocol: "https"     # TLS 有効時は https
    # Agent の待ち受けポート
    port: "9101"
```

設定変更を Helm で反映する。

```bash
helm upgrade "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${OC_PROJECT}" \
  --values ~/custom-values-aro.yaml \
  --reuse-values \
  --wait
```

Agent Pod の起動確認:

```bash
oc get pods -n "${OC_PROJECT}" -l app=owl-agent
oc logs -n "${OC_PROJECT}" -l app=owl-agent --tail=50
```

**Agent 正常接続時のログキーワード:**

```
Connected to DQ Web at https://collibra-dq-web:9000
Agent is running on port 9101
```

### 11.3 Spark Executor 設定

Spark Driver・Executor の Pod リソースとイメージを設定する。ARO では `nodeSelector` に OpenShift のワーカーノードラベルを指定する。

```yaml
# Spark の設定（custom-values-aro.yaml に追記）
spark:
  image: "${ACR_LOGIN_SERVER}/collibra/owl-spark:${SPARK_VERSION}"

  # Spark Driver の設定
  driver:
    cores: 1
    memory: "2g"
    serviceAccount: dq-agent-sa
    # ARO の SCC を継承するため ServiceAccount の指定が重要
    securityContext:
      runAsNonRoot: true

  # Spark Executor の設定
  executor:
    cores: 2
    memory: "4g"
    instances: 2
    securityContext:
      runAsNonRoot: true

  # Spark Scratch Disk（5章で作成した PVC を参照）
  scratchDisk:
    type: persistentVolumeClaim
    claimName: spark-scratch-pvc

  # Spark が動作する Project（Namespace）
  namespace: "${OC_PROJECT}"

  # ARO ワーカーノードへの配置
  nodeSelector:
    node-role.kubernetes.io/worker: ""
```

ジョブ実行中に Executor Pod が正常に起動することを確認する（12章の動作確認で検証）。

```bash
# ジョブ実行中に Executor Pod を確認するコマンド
oc get pods -n "${OC_PROJECT}" | grep spark
```

---

## 12. 動作確認

> **AKS 版との違い**: 確認コマンドは `kubectl` の代わりに `oc` を使用する。`Ingress` の代わりに `Route` を確認する。メトリクスは Container Insights の代わりに OpenShift 組み込み監視（Prometheus / Grafana）を使用する。

### 12.1 Pod / Service / PVC の状態確認

全コンポーネントのリソースが正常状態であることを一括確認する。

```bash
# Pod・Service・PVC・Route を一括確認
oc get pod,svc,pvc,route -n "${OC_PROJECT}"
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
| `dq-web-route` | Route | Accepted（HOST/PORT に FQDN が表示） |

Pod が正常に起動しない場合はイベントを確認する。

```bash
oc get events -n "${OC_PROJECT}" \
  --sort-by='.lastTimestamp' | tail -20
```

OpenShift Web コンソールでの確認（ブラウザ）:

```bash
# コンソール URL を取得
oc whoami --show-console
# 例: https://console-openshift-console.apps.<cluster-domain>
```

Web コンソールにログイン後、**Workloads > Pods** から Project `collibra-dq` を選択して Pod 一覧と状態を確認できる。

### 12.2 DQ Web UI へのアクセス確認

Route の URL でブラウザからアクセスし、ログイン画面が表示されることを確認する。

```bash
# Route の URL を取得
DQ_URL="https://$(oc get route dq-web-route -n ${OC_PROJECT} -o jsonpath='{.spec.host}')"
echo "DQ Web URL: ${DQ_URL}"

# HTTP ステータス確認
curl -sk "${DQ_URL}" -o /dev/null -w "%{http_code}\n"
# 期待値: 200
```

ブラウザで `${DQ_URL}` を開き、以下を確認する。

1. Collibra DQ のログイン画面が表示される
2. 管理者アカウント（`DQ_ADMIN_EMAIL` / `DQ_ADMIN_PASS`）でログインできる
3. ダッシュボードが表示される

> **補足**: Edge Termination を使用している場合、OpenShift Router が TLS を終端するため、ブラウザには Router の証明書（Let's Encrypt または自己署名）が提示される。自己署名証明書の場合はブラウザの警告をバイパスするか、信頼済み CA として登録する。

### 12.3 サンプルジョブの実行テスト

DQ Web UI からデータソースを登録し、DQ ジョブを実行して Spark Executor Pod が正常に生成・完了することを確認する。

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
# Executor Pod が生成されることを確認（ARO は oc コマンドを使用）
oc get pods -n "${OC_PROJECT}" --watch | grep spark
```

**期待される出力（ジョブ実行中）:**

```
collibra-dq-spark-driver-xxx   1/1     Running   0   10s
collibra-dq-spark-exec-1-xxx   1/1     Running   0   15s
collibra-dq-spark-exec-2-xxx   1/1     Running   0   15s
```

ジョブ完了後、Executor Pod は自動的に削除される。

> **ARO 固有チェック**: Executor Pod が `Pending` や `Error` になる場合は SCC 違反の可能性がある。13章のトラブルシューティングを参照。

### 12.4 ログ・メトリクスの確認

各コンポーネントのログにエラーがないことを確認する。

```bash
# DQ Web のログ確認（エラー抽出）
oc logs -n "${OC_PROJECT}" \
  -l app=owl-web --tail=200 \
  | grep -iE "error|exception|warn" | grep -v "WARN.*hikari"

# DQ Agent のログ確認
oc logs -n "${OC_PROJECT}" \
  -l app=owl-agent --tail=100 \
  | grep -iE "error|exception"
```

**OpenShift 組み込み監視（Prometheus / Grafana）でのメトリクス確認:**

ARO には OpenShift の標準監視スタック（Prometheus / Alertmanager / Grafana）が組み込まれている。Pod のリソース使用状況を確認するには Web コンソールを使用する。

```bash
# Prometheus / Grafana の URL を確認
oc get route -n openshift-monitoring
# prometheus-k8s, grafana, alertmanager-main の Route が表示される
```

Web コンソールでのメトリクス確認:

1. **Observe > Metrics** を開く
2. Project を `collibra-dq` に切り替える
3. PromQL クエリ例:

```promql
# CPU 使用率（DQ Web Pod）
rate(container_cpu_usage_seconds_total{namespace="collibra-dq", container="owl-web"}[5m])

# メモリ使用量（DQ Agent Pod）
container_memory_working_set_bytes{namespace="collibra-dq", container="owl-agent"}

# Spark Executor Pod 数
count(kube_pod_info{namespace="collibra-dq"}) by (pod)
```

Grafana でのダッシュボード確認（ARO クラスター管理者権限が必要）:

```bash
# Grafana の Route URL を取得
oc get route grafana -n openshift-monitoring \
  -o jsonpath='{.spec.host}'
```

---

## 13. トラブルシューティング

> **AKS 版との違い**: エラー種別と調査コマンドは基本的に同一（`kubectl` → `oc`）。ARO 固有エラーとして **SCC 違反**・**内部レジストリ認証失敗**・**Route 証明書エラー** を追加している。

### 13.1 よくあるエラーと対処法

| 症状 | 主な原因 | 確認コマンド / 対処法 |
|---|---|---|
| Pod が `ImagePullBackOff` | ACR へのイメージ未転送、またはプルシークレット未設定 | `oc describe pod <pod> -n ${OC_PROJECT}` でイメージ名を確認。3章の ACR 転送・3.4 節のシークレット作成を再実施 |
| Pod が `Pending` | ノードリソース不足、または PVC がバインドされていない | `oc describe pod <pod>` の Events 欄を確認。ワーカーノードのリソースまたは PVC の状態を確認 |
| PVC が `Pending` のまま | StorageClass が存在しない、または NFS に対応していない | `oc describe pvc <pvc> -n ${OC_PROJECT}` を確認。5章の StorageClass 作成を再実施 |
| Pod が `CrashLoopBackOff` | アプリ起動エラー（DB 接続失敗・ライセンスキー不正等） | `oc logs <pod> -n ${OC_PROJECT} --previous` でクラッシュ直前のログを確認 |
| メタストア接続エラー | Private Endpoint の疎通不可、または DB 資格情報の誤り | 8.1 節の疎通確認を再実施。Secret の値が正しいかを確認 |
| `OOMKilled` | Spark Executor のメモリ不足 | 11.3 節の `executor.memory` を増加。ワーカーノードの VM サイズを確認 |
| **SCC 違反** `is forbidden: unable to validate against any security context constraint` | `dq-agent-sa` への SCC 付与漏れ | `oc adm policy add-scc-to-user anyuid -z dq-agent-sa -n ${OC_PROJECT}` を実行（11.1 節を参照） |
| **SCC 違反（Spark Executor）** `pods "spark-exec-xxx" is forbidden` | Executor Pod 生成時の SCC 検証失敗 | `oc get events -n ${OC_PROJECT}` で `Forbidden` を確認。`dq-agent-sa` に anyuid が付与されているか `oc adm policy who-can use scc/anyuid` で確認 |
| Route が `503 Service Unavailable` | DQ Web Pod が未起動、または Service 名・ポートの不一致 | `oc get svc -n ${OC_PROJECT}` で Service 名とポートを確認。Route の `spec.to.name` が Service 名と一致するか検証 |
| Route の証明書エラー（ブラウザ） | 自己署名証明書または信頼されていない CA | Edge Termination の場合は OpenShift Router のワイルドカード証明書が使用される。`oc get route dq-web-route -n ${OC_PROJECT} -o yaml` で `tls.termination` を確認 |
| **内部レジストリ認証失敗** `unauthorized: authentication required` | OpenShift 内部レジストリへのプッシュ権限不足 | `oc policy add-role-to-user registry-editor -z default -n ${OC_PROJECT}` を実行 |
| Agent が DQ Web に接続できない | ホスト名解決失敗、または TLS 証明書エラー | Agent ログで接続エラーを確認。11.2 節の `owlweb.host` に ClusterDNS 名（`<svc>.<project>.svc.cluster.local`）を指定 |
| Spark ジョブが `FAILED` | RBAC 不足で Executor Pod を作成できない | `oc get events -n ${OC_PROJECT}` で `Forbidden` エラーを確認。11.1 節の Role に `create pods` 権限を付与 |

### 13.2 デバッグコマンド集

#### Pod の状態調査

```bash
# Pod 一覧と状態確認（ノード情報含む）
oc get pods -n "${OC_PROJECT}" -o wide

# Pod の詳細（イベント・マウント・コンテナ情報）
oc describe pod <POD_NAME> -n "${OC_PROJECT}"

# クラッシュ直前のログ（CrashLoopBackOff 時）
oc logs <POD_NAME> -n "${OC_PROJECT}" --previous

# リアルタイムログ追跡
oc logs <POD_NAME> -n "${OC_PROJECT}" -f

# ラベルで複数 Pod のログを集約
oc logs -n "${OC_PROJECT}" -l app=owl-web --tail=100
```

#### Pod 内での調査

```bash
# Pod 内シェルに接続
oc exec -it <POD_NAME> -n "${OC_PROJECT}" -- /bin/bash

# Pod 内から PostgreSQL への疎通確認
oc exec -it <POD_NAME> -n "${OC_PROJECT}" -- \
  nc -zv "${METASTORE_HOST}" 5432

# Pod 内の環境変数確認（ライセンスキー等）
oc exec -it <POD_NAME> -n "${OC_PROJECT}" -- env | grep -iE "license|owl|db"
```

#### Project 全体の調査

```bash
# 直近のイベントを確認（エラー原因の特定に有効）
oc get events -n "${OC_PROJECT}" \
  --sort-by='.lastTimestamp' | tail -30

# 全リソースの一覧確認
oc get all -n "${OC_PROJECT}"

# Secret の存在確認（値は表示しない）
oc get secret -n "${OC_PROJECT}"
oc describe secret <SECRET_NAME> -n "${OC_PROJECT}"

# Route の詳細確認
oc describe route dq-web-route -n "${OC_PROJECT}"
```

#### SCC 関連の調査（ARO 固有）

```bash
# dq-agent-sa に付与されている SCC を確認
oc get scc -o json | jq '.items[].users[]' 2>/dev/null | grep "dq-agent-sa"

# anyuid SCC の使用権限を確認
oc adm policy who-can use scc/anyuid

# SCC 違反の詳細確認（Kubernetes API 監査ログ）
oc get events -n "${OC_PROJECT}" \
  --field-selector reason=FailedCreate | grep -i "scc\|forbidden"

# ServiceAccount に付与されている SCC を一覧表示
oc adm policy scc-review \
  -z dq-agent-sa \
  -n "${OC_PROJECT}" \
  --resource=pods \
  --serviceaccount=dq-agent-sa
```

#### Helm の状態調査

```bash
# Helm リリースの状態確認
helm status "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}"

# デプロイ済みの values を確認
helm get values "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}"

# Helm が生成したマニフェストを確認
helm get manifest "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}"

# Helm リリース履歴
helm history "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}"
```

---

## 14. アップグレード手順

> **AKS 版との違い**: イメージ転送先が ACR または OpenShift 内部レジストリになる点と、ローリングアップデートの確認コマンドが `oc rollout status` になる点以外、手順は AKS 版と同一。

### 14.1 アップグレード前の準備

```bash
# 現在のバージョンを確認
helm list -n "${OC_PROJECT}"
oc get pods -n "${OC_PROJECT}" \
  -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'

# メタストアのバックアップ（Azure DB for PostgreSQL）
pg_dump \
  "host=${METASTORE_HOST} port=${METASTORE_PORT} \
   dbname=${METASTORE_DB} user=${METASTORE_USER} sslmode=require" \
  -F c -f "owlmetastore_backup_$(date +%Y%m%d).dump"

# Helm の現在の values をバックアップ
helm get values "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}" \
  > ~/helm-values-backup-$(date +%Y%m%d).yaml
```

### 14.2 新バージョンのイメージをレジストリに転送

**パターン A: ACR に転送する場合（推奨）**

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

for IMG in owl-web owl-agent; do
  docker tag "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}" \
             "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
  docker push "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
done

docker tag "${COLLIBRA_REGISTRY}/owl-spark:${NEW_SPARK_VERSION}" \
           "${ACR_LOGIN_SERVER}/collibra/owl-spark:${NEW_SPARK_VERSION}"
docker push "${ACR_LOGIN_SERVER}/collibra/owl-spark:${NEW_SPARK_VERSION}"
```

**パターン B: OpenShift 内部レジストリに転送する場合**

```bash
# 内部レジストリへのログイン
INTERNAL_REGISTRY=$(oc get route default-route \
  -n openshift-image-registry \
  -o jsonpath='{.spec.host}')
docker login "${INTERNAL_REGISTRY}" \
  -u "$(oc whoami)" \
  -p "$(oc whoami -t)"

# Collibra レジストリから pull して内部レジストリへ push
for IMG in owl-web owl-agent; do
  docker pull "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}"
  docker tag  "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}" \
              "${INTERNAL_REGISTRY}/${OC_PROJECT}/${IMG}:${NEW_DQ_VERSION}"
  docker push "${INTERNAL_REGISTRY}/${OC_PROJECT}/${IMG}:${NEW_DQ_VERSION}"
done
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
# custom-values-aro.yaml のバージョンを更新
sed -i \
  "s/dq: \"${DQ_VERSION}\"/dq: \"${NEW_DQ_VERSION}\"/" \
  ~/custom-values-aro.yaml
sed -i \
  "s/spark: \"${SPARK_VERSION}\"/spark: \"${NEW_SPARK_VERSION}\"/" \
  ~/custom-values-aro.yaml

# アップグレード実行
helm upgrade "${HELM_RELEASE_NAME}" "${NEW_CHART_PATH}" \
  --namespace "${OC_PROJECT}" \
  --values ~/custom-values-aro.yaml \
  --timeout 15m \
  --wait
```

ローリングアップデートの進行を確認する（ARO では `oc rollout` を使用）。

```bash
oc rollout status deployment/collibra-dq-web -n "${OC_PROJECT}"
oc rollout status deployment/collibra-dq-agent -n "${OC_PROJECT}"
```

**アップグレード完了後の確認:**

```bash
# バージョンが更新されていることを確認
helm list -n "${OC_PROJECT}"
oc get pods -n "${OC_PROJECT}" \
  -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'

# DQ Web にログインしてバージョン表示を確認
# 画面右上メニュー > About > バージョン番号
```

### 14.5 ロールバック手順

アップグレード後に問題が発生した場合、Helm を使用して前バージョンに戻す。

```bash
# Helm リリース履歴を確認（REVISION 番号を控える）
helm history "${HELM_RELEASE_NAME}" -n "${OC_PROJECT}"
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
  --namespace "${OC_PROJECT}" \
  --wait

# ロールバック完了を確認
oc rollout status deployment/collibra-dq-web -n "${OC_PROJECT}"
helm list -n "${OC_PROJECT}"
```

> **補足**: ロールバック後もデータベーススキーマが新バージョンで変更されている場合、旧バージョンのアプリケーションと互換性がない可能性がある。Collibra のリリースノートでスキーママイグレーションの有無を事前に確認すること。

---

## 15. 参考リンク

| タイトル | URL |
|---|---|
| EKS / GKE / AKS - Product Resource Center | https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/EKS%20%20GKE%20%20AKS.htm |
| Cloud native requirements | https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/Cloud%20native%20requirements.htm |
| Deploy on Self-hosted Kubernetes | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_cloud-deploy.htm |
| Setting up SSL (HTTPS) | https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQSecurity/ta_ssl-setup.htm |
| Azure Red Hat OpenShift ドキュメント | https://learn.microsoft.com/ja-jp/azure/openshift/ |
| OpenShift Security Context Constraints | https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html |
| OpenShift Route の設定 | https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html |
| OpenShift Helm サポート | https://docs.openshift.com/container-platform/latest/applications/working_with_helm_charts/understanding-helm.html |
