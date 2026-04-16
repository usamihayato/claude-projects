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

> **背景**: Collibra DQ のコンテナイメージは Google Container Registry のセキュアリポジトリに格納されており、インターネット経由でのアクセスが必要。プライベート AKS 環境では ACR 経由でのアクセスが推奨される。

### 3.1 Collibra ライセンス情報の確認

Collibra 社から提供されるライセンスメールに記載されたイメージリポジトリ URL・認証情報を確認する。

### 3.2 Google Container Registry からのイメージ取得

提供された認証情報を使用し、DQ Web・Spark・Agent 等の各コンテナイメージを取得する。

### 3.3 ACR へのイメージ転送

取得したイメージを社内 ACR にプッシュし、AKS からの参照先を ACR に統一する。

### 3.4 イメージプルシークレットの設定

AKS の対象ネームスペース内に、ACR 認証用のプルシークレット（`dq-pull-secret`）を作成する。

---

## 4. Helm チャートの準備

> **背景**: Collibra DQ は Helm チャート形式で配布される。チャートは Collibra ライセンスメール経由で ZIP ファイルとして提供される。

### 4.1 Helm チャートの入手方法

ライセンスメールに記載のダウンロードリンクから ZIP ファイルを取得し、管理用 VM に展開する。

### 4.2 チャートディレクトリ構造の確認

展開したチャートのディレクトリ構造・主要ファイル（`Chart.yaml`、`values.yaml`、`templates/`）を確認する。

### 4.3 values.yaml 設定パラメータ一覧

カスタマイズが必要な主要パラメータ（バージョン、ライセンス、ストレージクラス、サービスタイプ等）を一覧化する。

---

## 5. ストレージの設定

> **背景**: Collibra DQ の DQ Web および Spark は永続ストレージを必要とする。AKS では Azure Files を利用した ReadWriteMany (RWX) 構成が推奨される。

### 5.1 Azure Files ストレージクラスの確認

AKS に組み込みの Azure Files ストレージクラスを確認し、必要に応じてカスタムストレージクラスを定義する。

### 5.2 DQ Web 用 PVC 設定

DQ Web コンポーネントが使用する PersistentVolumeClaim (PVC) を作成する。アクセスモードは ReadWriteMany を使用。

### 5.3 Spark Scratch Disk 用 PVC 設定

大規模データ処理時に Spark が使用するスクラッチディスク用の PVC を設定する（デフォルト 20Gi、用途に応じて拡大）。

### 5.4 JDBC ドライバー用 PV/PVC 設定

各種データソースへの接続に使用する JDBC ドライバーを格納するための PV/PVC を設定する。

---

## 6. 認証・シークレットの設定

### 6.1 イメージプルシークレット登録

Helm デプロイ時に使用するイメージプルシークレットをネームスペースに登録する（第 3 章で作成したものを確認）。

### 6.2 ライセンスキーのシークレット化

Collibra ライセンスキーを Kubernetes Secret として登録し、Helm values から参照する。

### 6.3 Azure Key Vault 統合（オプション）

Secret Store CSI ドライバーを使用して Azure Key Vault のシークレットを Pod に直接マウントする設定を行う。Helm チャートの `vaultProvider: "akv"` オプションを活用。

### 6.4 Workload Identity 設定

Azure Workload Identity を使用し、Pod が Azure リソース（Key Vault、PostgreSQL 等）にパスワードレスでアクセスできるよう構成する。

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
