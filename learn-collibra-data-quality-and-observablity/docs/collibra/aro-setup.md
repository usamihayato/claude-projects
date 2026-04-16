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

> **AKS 版との違い**: 接続確認・JDBC URL・パスワードレス認証の設定手順は AKS 版と同一。`kubectl run` の代わりに `oc run` を使用する。

### 8.1 Azure Database for PostgreSQL への接続確認

`oc run` による疎通確認と、メタストア用 DB・ユーザーの存在確認を行う。

### 8.2 パスワードレス認証（Azure AD）設定

Azure AD 認証を有効化し、Workload Identity 経由でのパスワードレス接続を構成する。

### 8.3 接続文字列の設定

JDBC 接続 URL を OpenShift Secret として登録し、Helm values から参照する。

---

## 9. Collibra DQ のデプロイ（Helm）

> **AKS 版との違い**: `helm upgrade --install` の基本コマンドは同一。ARO 向けには SCC・`securityContext`・Route 有効化の設定を `custom-values.yaml` に追加する。

### 9.1 デプロイ前チェックリスト

プロジェクト・PVC・Secret・SCC 設定がすべて完了していることを確認する。

### 9.2 custom-values.yaml の作成（ARO 向け追加設定）

AKS 版の values に加え、ARO 固有のパラメータ（`securityContext.runAsNonRoot`・`podSecurityContext.fsGroup` 等）を追加する。

### 9.3 helm upgrade --install コマンド

ARO 向けのパラメータを指定した `helm upgrade --install` を実行する。

### 9.4 デプロイ状態の確認

Pod・Service・PVC の状態を `oc get` コマンドで確認する。

### 9.5 初期起動の確認

DQ Web Pod のログを `oc logs` で確認し、正常起動を確認する。

---

## 10. ネットワーク・外部アクセスの設定

> **AKS 版との最大の違い**: AKS では NGINX Ingress を使用するが、ARO では **OpenShift Route** を使用して外部アクセスを構成する。Route は ARO 組み込みの Router（HAProxy ベース）が処理するため、Ingress コントローラーの別途インストールは不要。

### 10.1 OpenShift Route の概要

Route の TLS 終端方式（Edge / Passthrough / Re-encrypt）の違いと、ARO でのデフォルトドメイン（`*.apps.<cluster>.<domain>`）について説明する。

### 10.2 Route リソースの作成

DQ Web への外部アクセス用 Route を作成する（`oc expose` または YAML 直接適用）。

### 10.3 カスタムドメインの設定（オプション）

ARO デフォルトドメイン以外のカスタムドメインを使用する場合の設定を行う。

### 10.4 DQ Web への外部アクセス確認

Route の URL で DQ Web UI にアクセスできることを確認する。

---

## 11. DQ Agent の設定

> **AKS 版との違い**: Agent の設定内容は同一。ARO では Spark Executor Pod 生成時にも SCC が適用されるため、ServiceAccount に適切な SCC を付与する必要がある。

### 11.1 RBAC / ServiceAccount 設定（SCC 付与含む）

DQ Agent・Spark Driver 用 ServiceAccount を作成し、Pod 操作権限（Role / RoleBinding）と SCC（`anyuid` または カスタム）を付与する。

### 11.2 Agent 接続先の設定

DQ Agent が接続する DQ Web のエンドポイントを Helm values に設定する。

### 11.3 Spark Executor 設定

Spark Driver・Executor の Pod リソースと ARO ノードへの配置設定を行う。

---

## 12. 動作確認

> **AKS 版との違い**: 確認コマンドは `kubectl` の代わりに `oc` を使用する。OpenShift 組み込みの Web コンソール（管理 UI）からも Pod・ログ・メトリクスを確認できる。

### 12.1 Pod / Service / PVC の状態確認

`oc get pod,svc,pvc,route` で全コンポーネントのリソース状態を一括確認する。

### 12.2 DQ Web UI へのアクセス確認

Route の URL でブラウザからアクセスし、管理者アカウントでのログインを確認する。

### 12.3 サンプルジョブの実行テスト

DQ Web UI からデータソースを登録し、DQ ジョブを実行して Spark Executor Pod が正常に生成・完了することを確認する。

### 12.4 ログ・メトリクスの確認

`oc logs` によるログ確認と、OpenShift 組み込み監視（Prometheus / Grafana）でのメトリクス確認を行う。

---

## 13. トラブルシューティング

> **AKS 版との違い**: エラー種別と調査コマンドは基本的に同一（`kubectl` → `oc`）。ARO 固有のエラーとして **SCC 違反**（`Error creating: pods ... is forbidden: unable to validate against any security context constraint`）を追加する。

### 13.1 よくあるエラーと対処法

AKS 版の項目に加え、ARO 固有エラー（SCC 違反・内部レジストリ認証失敗・Route 設定ミス等）と対処法を記載する。

### 13.2 デバッグコマンド集

`oc describe`・`oc logs`・`oc exec`・`oc get events`・`oc adm policy` 等を用途別にまとめる。

---

## 14. アップグレード手順

> **AKS 版との違い**: イメージ転送先が ACR または OpenShift 内部レジストリになる点以外、手順は AKS 版と同一。

### 14.1 アップグレード前の準備

メタストアバックアップ・Helm values バックアップを取得する。

### 14.2 新バージョンのイメージをレジストリに転送

新バージョンのイメージを ACR または OpenShift 内部レジストリに転送する。

### 14.3 新バージョンの Helm チャートを取得

新バージョンの Helm チャートをダウンロード・展開する。

### 14.4 helm upgrade の実行

`custom-values.yaml` のバージョンを更新し、`helm upgrade` を実行してローリングアップデートを行う。

### 14.5 ロールバック手順

アップグレード後に問題が発生した場合、`helm rollback` で前バージョンに戻す。

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
