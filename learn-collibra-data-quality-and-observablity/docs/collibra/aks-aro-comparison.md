# Collibra DQ: AKS vs ARO 比較ガイド

> **対象バージョン**: Collibra DQ 2026.02  
> **作成日**: 2026-04-16  
> **関連ドキュメント**: [`aks-setup.md`](./aks-setup.md) / [`aro-setup.md`](./aro-setup.md)

---

## 目次

1. [はじめに](#1-はじめに)
2. [プラットフォーム概要](#2-プラットフォーム概要)
3. [クラスター接続・CLI](#3-クラスター接続cli)
4. [名前空間 / Project 管理](#4-名前空間--project-管理)
5. [コンテナイメージ・レジストリ](#5-コンテナイメージレジストリ)
6. [ストレージ設定](#6-ストレージ設定)
7. [Pod セキュリティ（PSA vs SCC）](#7-pod-セキュリティpsa-vs-scc)
8. [認証・シークレット管理](#8-認証シークレット管理)
9. [SSL/TLS 設定](#9-ssltls-設定)
10. [外部アクセス（Ingress vs Route）](#10-外部アクセスingress-vs-route)
11. [Helm デプロイの差異](#11-helm-デプロイの差異)
12. [RBAC・Agent / Spark 設定](#12-rbacagent--spark-設定)
13. [監視・ログ](#13-監視ログ)
14. [トラブルシューティングの差異](#14-トラブルシューティングの差異)
15. [アップグレード手順の差異](#15-アップグレード手順の差異)
16. [採用判断フロー](#16-採用判断フロー)

---

## 1. はじめに

### 1.1 目的

本ドキュメントは、Collibra DQ を Azure 上の Kubernetes プラットフォームに展開する際の **AKS（Azure Kubernetes Service）** と **ARO（Azure Red Hat OpenShift）** の差異を横断的に整理する。  
セットアップ手順書（aks-setup.md / aro-setup.md）の「なぜここだけ手順が違うのか」をテーマ別に対比することで、設計・移行・レビュー時の参照資料として活用する。

### 1.2 スコープ

本ドキュメントが対象とする比較項目を以下に示す。

| 対象 | 説明 |
|---|---|
| Collibra DQ コンポーネント | DQ Web / DQ Agent / Spark（フルデプロイ想定） |
| Azure サービス | AKS クラスター / ARO クラスター・ACR・Azure DB for PostgreSQL・Azure Key Vault |
| デプロイツール | Helm v3 |

### 1.3 比較サマリー（早見表）

| 項目 | AKS | ARO |
|---|---|---|
| 管理主体 | Microsoft | Microsoft + Red Hat |
| ベース | Kubernetes（CNCF 準拠） | OpenShift Container Platform |
| CLI | `kubectl` / `az` | `oc`（`kubectl` 互換） / `az` / `oc` |
| 名前空間 | Namespace | Project（Namespace 互換） |
| Pod セキュリティ | PodSecurity Admission（PSA） | Security Context Constraints（SCC） |
| 外部アクセス | NGINX Ingress（別途インストール） | OpenShift Route（組み込み） |
| イメージレジストリ | ACR | ACR または OpenShift 内部レジストリ |
| 監視 | Container Insights（Azure Monitor） | OpenShift 組み込み監視（Prometheus / Grafana） |
| Web コンソール | Azure Portal / Lens | OpenShift Web コンソール（組み込み） |
| コスト構造 | AKS 管理料 + ノード VM | ARO 管理料（RHEL + OCP ライセンス込み）+ ノード VM |
| サポート | Microsoft サポート | Microsoft + Red Hat 共同サポート |

---

## 2. プラットフォーム概要

### 2.1 アーキテクチャ上の位置づけ

```
【AKS】
Azure
└── AKS クラスター（Microsoft マネージド コントロールプレーン）
    ├── System Node Pool（コントロール系 Pod）
    └── User Node Pool（アプリ / Spark）

【ARO】
Azure
└── ARO クラスター（Microsoft + Red Hat マネージド）
    ├── Master Node（OpenShift コントロールプレーン × 3）
    ├── Infra Node（Router / Registry / Monitoring）
    └── Worker Node（アプリ / Spark）
```

ARO は Master ノードと Infra ノードが専用に確保されるため、ワーカーノードのみがアプリ用として利用可能になる。AKS は System Pool と User Pool の分離が推奨だが、構成の柔軟度が高い。

### 2.2 コスト構造

| 費用項目 | AKS | ARO |
|---|---|---|
| コントロールプレーン | 無料（Standard tier は有料） | ARO サービス料金に含む |
| ノード VM | ノード数 × VM SKU 料金 | 同左（ただし RHEL ライセンス込み） |
| OS ライセンス | Ubuntu（無料）または Windows | Red Hat Enterprise Linux（ARO 料金に含む） |
| OpenShift ライセンス | 不要 | ARO 料金に含む（別途 OCP ライセンス不要） |
| 概算目安（8コア×3ワーカー） | 低め | AKS 比 1.5〜2 倍程度 |

### 2.3 サポート体制

| 観点 | AKS | ARO |
|---|---|---|
| プラットフォームサポート | Microsoft のみ | Microsoft + Red Hat 共同 |
| Kubernetes / OpenShift 問題 | Microsoft サポート | Red Hat サポートも利用可 |
| Collibra DQ サポート | Collibra（Helm 設定は限定的） | 同左（OpenShift の場合も Helm デプロイは限定的） |
| SLA | Standard tier: 99.95%（Availability Zones 使用時） | 99.95%（3 AZ 構成時） |

---

## 3. クラスター接続・CLI

### 3.1 コマンド体系の対応表

ARO の `oc` コマンドは `kubectl` の完全上位互換。ほぼすべての `kubectl` コマンドは `oc` に置き換えるだけで動作する。

| 操作 | AKS（kubectl / az） | ARO（oc / az） |
|---|---|---|
| クラスター認証情報取得 | `az aks get-credentials` | `oc login` |
| 接続中クラスター確認 | `kubectl config current-context` | `oc whoami --show-server` |
| Pod 一覧 | `kubectl get pods -n <ns>` | `oc get pods -n <proj>` |
| Pod ログ | `kubectl logs <pod>` | `oc logs <pod>` |
| Pod 内シェル | `kubectl exec -it <pod> -- bash` | `oc exec -it <pod> -- bash` |
| イベント確認 | `kubectl get events -n <ns>` | `oc get events -n <proj>` |
| リソース詳細 | `kubectl describe <resource>` | `oc describe <resource>` |
| Web コンソール URL | `az aks browse` / Azure Portal | `oc whoami --show-console` |
| クラスター管理者権限付与 | `az role assignment create` | `oc adm policy add-cluster-role-to-user cluster-admin` |

### 3.2 クラスター接続コマンド比較

**AKS:**

```bash
# kubeconfig にクラスター情報をマージ
az aks get-credentials \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --overwrite-existing

# 接続確認
kubectl get nodes
kubectl version --client
```

**ARO:**

```bash
# API サーバー URL と初期管理者パスワードを取得
ARO_API_URL=$(az aro show \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query apiserverProfile.url -o tsv)

ARO_ADMIN_PASS=$(az aro list-credentials \
  --resource-group "${RG_NAME}" \
  --name "${ARO_NAME}" \
  --query kubeadminPassword -o tsv)

# oc login で認証
oc login "${ARO_API_URL}" \
  --username kubeadmin \
  --password "${ARO_ADMIN_PASS}"

# 接続確認
oc get nodes
oc version
```

> **ポイント**: AKS は `az aks get-credentials` で kubeconfig を更新するだけだが、ARO は `oc login` でトークンを取得する認証フローになる。CI/CD パイプラインでは ARO はサービスアカウントトークンを利用するケースが多い。

---

## 4. 名前空間 / Project 管理

### 4.1 Namespace と Project の違い

| 観点 | AKS（Namespace） | ARO（Project） |
|---|---|---|
| 実体 | Kubernetes Namespace | Namespace + OpenShift メタデータ |
| 作成コマンド | `kubectl create namespace` | `oc new-project`（推奨）または `kubectl create namespace` |
| 削除コマンド | `kubectl delete namespace` | `oc delete project` |
| ラベル付与 | `kubectl label namespace` | `oc label namespace` または `oc new-project --description` |
| ネットワーク分離 | NetworkPolicy（別途設定） | NetworkPolicy（デフォルトで Project 間分離あり） |
| 作業 Project の切り替え | `kubectl config set-context --current --namespace` | `oc project <project>` |

### 4.2 作成コマンド比較

**AKS:**

```bash
# Namespace 作成
kubectl create namespace "${NAMESPACE}"

# PSA（Pod Security Admission）ラベルを付与
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted

# 確認
kubectl get namespace "${NAMESPACE}"
```

**ARO:**

```bash
# Project 作成（説明・表示名も設定可能）
oc new-project "${OC_PROJECT}" \
  --display-name="Collibra DQ" \
  --description="Collibra Data Quality deployment"

# 作業 Project を切り替え
oc project "${OC_PROJECT}"

# 確認
oc get project "${OC_PROJECT}"
```

> **ポイント**: ARO では `oc new-project` が Project（Namespace）の作成と同時にデフォルト NetworkPolicy・RoleBinding の設定も行う。AKS では Namespace 作成後に PSA ラベルを手動付与するが、ARO では SCC が Namespace レベルではなく ServiceAccount レベルで制御される。

---

## 5. コンテナイメージ・レジストリ

### 5.1 レジストリ選択肢

| 観点 | AKS | ARO |
|---|---|---|
| 推奨レジストリ | Azure Container Registry（ACR） | ACR または OpenShift 内部レジストリ |
| ACR 統合 | Managed Identity で自動認証（attach） | プルシークレット必須（内部レジストリ不使用時） |
| 内部レジストリ | なし | OpenShift Image Registry（クラスター内蔵） |
| プルシークレット | Managed Identity 使用時は不要 | `dq-pull-secret` の作成 + `oc secrets link` が必要 |

### 5.2 イメージ転送フロー

**AKS（ACR のみ）:**

```
Collibra Registry
  └─ docker pull ──▶ ローカル
       └─ docker tag / push ──▶ ACR（acrcollibradq.azurecr.io）
                                    └─ Managed Identity ──▶ AKS が自動プル
```

**ARO（ACR 経由）:**

```
Collibra Registry
  └─ docker pull ──▶ ローカル
       └─ docker tag / push ──▶ ACR（acrcollibradq.azurecr.io）
                                    └─ プルシークレット（dq-pull-secret）──▶ ARO がプル
```

**ARO（内部レジストリ経由）:**

```
Collibra Registry
  └─ docker pull ──▶ ローカル
       └─ docker tag / push ──▶ OpenShift 内部レジストリ
                                    └─ 認証不要（Project 内から直接プル）
```

### 5.3 イメージプルの設定差異

**AKS（Managed Identity 使用時はプルシークレット不要）:**

```bash
# ACR と AKS を紐付け（Managed Identity 経由）
az aks update \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --attach-acr "${ACR_NAME}"

# Helm の values で直接イメージ URL を指定するだけでプル可能
```

**ARO（プルシークレット必須）:**

```bash
# プルシークレット作成
kubectl create secret docker-registry dq-pull-secret \
  --docker-server="${ACR_LOGIN_SERVER}" \
  --docker-username="${ACR_SP_ID}" \
  --docker-password="${ACR_SP_SECRET}" \
  -n "${OC_PROJECT}"

# ServiceAccount にシークレットを紐付け（ARO 固有の操作）
oc secrets link default dq-pull-secret --for=pull -n "${OC_PROJECT}"

# 確認
oc get secret dq-pull-secret -n "${OC_PROJECT}"
```

### 5.4 内部レジストリへのプッシュ（ARO 固有）

AKS には存在しない ARO 固有の手順。Collibra イメージを外部に出したくない場合に使用する。

```bash
# 内部レジストリの外部公開ルートを有効化
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  --patch '{"spec":{"defaultRoute":true}}'

# 内部レジストリの URL を取得
INTERNAL_REGISTRY=$(oc get route default-route \
  -n openshift-image-registry \
  -o jsonpath='{.spec.host}')

# oc login トークンで docker login
docker login "${INTERNAL_REGISTRY}" \
  -u "$(oc whoami)" \
  -p "$(oc whoami -t)"

# 内部レジストリへプッシュ
docker tag "${COLLIBRA_REGISTRY}/owl-web:${DQ_VERSION}" \
  "${INTERNAL_REGISTRY}/${OC_PROJECT}/owl-web:${DQ_VERSION}"
docker push "${INTERNAL_REGISTRY}/${OC_PROJECT}/owl-web:${DQ_VERSION}"
```

---

## 6. ストレージ設定

### 6.1 StorageClass の差異

ReadWriteMany（RWX）対応の StorageClass はどちらも Azure Files を使用するが、プロトコルと互換性に差異がある。

| 観点 | AKS | ARO |
|---|---|---|
| 組み込み StorageClass | `azurefile-csi`（SMB / NFS） | `azurefile-csi`（組み込みあり） |
| SMB での RWX | 利用可能 | SCC 権限競合が発生しやすく非推奨 |
| NFS での RWX | カスタム StorageClass で利用可能 | **NFS カスタム StorageClass が必須** |
| 理由 | AKS は PSA で制御するため SMB でも動作 | ARO の SCC が SMB マウントの UID/GID と競合する |

### 6.2 StorageClass 定義の比較

**AKS（NFS プロトコル指定のカスタム StorageClass）:**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
mountOptions:
  - nconnect=8
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
```

**ARO（SMB 非推奨・NFS 必須のカスタム StorageClass）:**

```yaml
# AKS 版と定義内容は同一
# ARO では SMB（デフォルト azurefile-csi）を使うと SCC 違反が起きるため
# NFS プロトコル指定を必ず行う
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs        # ARO では NFS を必ず指定
  skuName: Premium_LRS
mountOptions:
  - nconnect=8
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
```

### 6.3 PVC 設定

PVC の YAML 自体は AKS / ARO で同一。適用コマンドのみ異なる。

| PVC | サイズ | AccessMode |
|---|---|---|
| `dq-web-pvc` | 10Gi | ReadWriteMany |
| `spark-scratch-pvc` | 20Gi | ReadWriteMany |
| `dq-jdbc-drivers-pvc` | 5Gi | ReadWriteMany |

```yaml
# AKS / ARO 共通（oc apply / kubectl apply どちらでも適用可能）
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dq-web-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-nfs   # NFS StorageClass を明示
  resources:
    requests:
      storage: 10Gi
```

---

## 7. Pod セキュリティ（PSA vs SCC）

### 7.1 セキュリティモデルの違い

AKS と ARO では Pod のセキュリティ制御の仕組みが根本的に異なる。これが ARO 固有の設定が多くなる主な原因。

| 観点 | AKS: PodSecurity Admission（PSA） | ARO: Security Context Constraints（SCC） |
|---|---|---|
| 制御単位 | Namespace 単位でポリシーを適用 | ServiceAccount 単位で SCC を付与 |
| 設定方法 | Namespace へのラベル付与 | `oc adm policy add-scc-to-user` コマンド |
| ポリシー種別 | `privileged` / `baseline` / `restricted` の 3 段階 | `anyuid` / `restricted-v2` / `privileged` / カスタム SCC 等 |
| UID 制御 | `restricted` は任意 UID を許可しない | `anyuid` は任意 UID を許可、`restricted-v2` は拒否 |
| Collibra DQ の要件 | `baseline` レベルで動作可能 | `anyuid` SCC の付与が必要（または カスタム SCC） |
| Spark Executor への影響 | Executor Pod も同一 Namespace ポリシーが適用 | Executor Pod にも ServiceAccount の SCC が継承される |

### 7.2 設定コマンドの比較

**AKS（Namespace ラベルで制御）:**

```bash
# Namespace に PSA ポリシーラベルを付与
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted

# 確認
kubectl get namespace "${NAMESPACE}" --show-labels
```

**ARO（ServiceAccount に SCC を付与）:**

```bash
# ServiceAccount を作成
oc create serviceaccount collibra-dq-sa -n "${OC_PROJECT}"

# anyuid SCC を付与（cluster-admin 権限が必要）
oc adm policy add-scc-to-user anyuid \
  -z collibra-dq-sa \
  -n "${OC_PROJECT}"

# DQ Agent 用 SA にも付与（Spark Executor 生成のため必須）
oc adm policy add-scc-to-user anyuid \
  -z dq-agent-sa \
  -n "${OC_PROJECT}"

# 確認
oc adm policy who-can use scc/anyuid | grep "${OC_PROJECT}"
```

### 7.3 カスタム SCC（ARO 固有）

`anyuid` よりも権限を絞りたい場合はカスタム SCC を作成する。AKS には対応する仕組みがない（PSA は 3 段階のみ）。

```yaml
# ARO 固有: カスタム SCC（最小権限）
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: collibra-dq-scc
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
runAsUser:
  type: MustRunAsRange
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
  - persistentVolumeClaim
  - configMap
  - secret
  - emptyDir
```

```bash
# カスタム SCC の作成・付与
oc apply -f collibra-dq-scc.yaml

oc adm policy add-scc-to-user collibra-dq-scc \
  -z collibra-dq-sa \
  -n "${OC_PROJECT}"
```

### 7.4 Helm values での securityContext 設定差異

SCC の違いは Helm values の `securityContext` 設定にも影響する。

**AKS（`custom-values.yaml`）:**

```yaml
# AKS: 特定の UID を明示指定可能
global:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
```

**ARO（`custom-values-aro.yaml`）:**

```yaml
# ARO: UID を明示指定すると SCC 検証で競合する場合があるため省略
# anyuid SCC 使用時は OpenShift がプロジェクトの UID レンジから自動割り当て
global:
  securityContext:
    runAsNonRoot: true
    # runAsUser / runAsGroup / fsGroup は省略（ARO が自動割り当て）
```

---

## 8. 認証・シークレット管理

### 8.1 シークレット一覧と管理コマンドの差異

作成するシークレットの種類は AKS / ARO で同一。コマンドが `kubectl` → `oc` に変わるだけ。

| シークレット名 | 内容 | AKS | ARO |
|---|---|---|---|
| `dq-pull-secret` | ACR 認証情報 | `kubectl create secret docker-registry` | `oc create secret docker-registry` + `oc secrets link` |
| `dq-license-secret` | ライセンスキー | `kubectl create secret generic` | `oc create secret generic` |
| `dq-metastore-secret` | メタストア DB パスワード | 同上 | 同上 |
| `dq-admin-secret` | DQ Web 管理者パスワード | 同上 | 同上 |

**AKS との最大の差異**: ARO では `oc secrets link` で ServiceAccount にプルシークレットを明示的に紐付けないとイメージプルが失敗する。

```bash
# AKS: プルシークレット作成のみで済む
kubectl create secret docker-registry dq-pull-secret \
  --docker-server="${ACR_LOGIN_SERVER}" \
  --docker-username="${ACR_SP_ID}" \
  --docker-password="${ACR_SP_SECRET}" \
  -n "${NAMESPACE}"

# ARO: 作成後に ServiceAccount へ明示的に紐付けが必要
oc create secret docker-registry dq-pull-secret \
  --docker-server="${ACR_LOGIN_SERVER}" \
  --docker-username="${ACR_SP_ID}" \
  --docker-password="${ACR_SP_SECRET}" \
  -n "${OC_PROJECT}"

oc secrets link default dq-pull-secret --for=pull -n "${OC_PROJECT}"  # ARO 固有
```

### 8.2 Azure Key Vault CSI ドライバーの有効化方法

Kubernetes Secret を使用せず Azure Key Vault で機密情報を集中管理する場合、有効化の方法が異なる。

| 観点 | AKS | ARO |
|---|---|---|
| 有効化方法 | `az aks enable-addons`（1コマンド） | Helm で手動インストール |
| マネージドの度合い | AKS アドオンとして自動更新 | Helm リリースとして自分で更新管理 |
| SecretProviderClass YAML | 共通（内容は同一） | 共通（内容は同一） |

**AKS（アドオン有効化）:**

```bash
az aks enable-addons \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --addons azure-keyvault-secrets-provider
```

**ARO（Helm インストール）:**

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm upgrade --install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true

helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm upgrade --install azure-csi-provider \
  csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system
```

### 8.3 Workload Identity の設定差異

Azure AD Workload Identity を使用してパスワードレス認証を行う場合、OIDC 発行者 URL の取得方法が異なる。

| 観点 | AKS | ARO |
|---|---|---|
| OIDC 有効化 | `az aks update --enable-oidc-issuer` | ARO は標準で OIDC を提供（有効化不要） |
| OIDC URL 取得 | `az aks show --query oidcIssuerProfile.issuerUrl` | `oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}'` |
| フェデレーション subject | `system:serviceaccount:${NAMESPACE}:collibra-dq-sa` | `system:serviceaccount:${OC_PROJECT}:collibra-dq-sa` |
| SA へのアノテーション | `kubectl annotate serviceaccount` | `oc annotate serviceaccount` |

```bash
# AKS: OIDC 発行者 URL 取得
OIDC_ISSUER=$(az aks show \
  --resource-group "${RG_NAME}" --name "${AKS_NAME}" \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# ARO: OIDC 発行者 URL 取得（組み込みのため az コマンド不要）
OIDC_ISSUER=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}')
```

フェデレーション ID 資格情報の作成コマンドは両者ほぼ同一。`--subject` の namespace 部分のみ異なる（`${NAMESPACE}` vs `${OC_PROJECT}`）。

---

## 9. SSL/TLS 設定

### 9.1 TLS 終端アーキテクチャの違い

AKS と ARO では TLS を終端する場所と設定箇所が根本的に異なる。

```
【AKS】
クライアント
  │ HTTPS
  ▼
NGINX Ingress Controller（TLS 終端）
  │ HTTP または HTTPS（backend-protocol に依存）
  ▼
DQ Web Pod（Service: ClusterIP）

【ARO: Edge termination（推奨）】
クライアント
  │ HTTPS
  ▼
OpenShift Router（TLS 終端）
  │ HTTP（平文）
  ▼
DQ Web Pod（Service: ClusterIP）

【ARO: Re-encrypt termination】
クライアント
  │ HTTPS
  ▼
OpenShift Router（Route 証明書で終端）
  │ HTTPS（再暗号化）
  ▼
DQ Web Pod（JKS 証明書で終端）
```

### 9.2 Java Keystore（JKS）が必要なケース

| シナリオ | AKS | ARO |
|---|---|---|
| Ingress / Route で TLS を終端 | JKS 不要（Ingress が証明書を処理） | Edge termination なら JKS 不要 |
| アプリまで E2E 暗号化 | NGINX の `backend-protocol: HTTPS` + JKS 必要 | Re-encrypt / Passthrough + JKS 必要 |
| 検証環境 | HTTP Ingress でも可 | `oc expose svc` の自動 Route URL で代替可 |

> **ARO の優位点**: Edge termination を採用すれば、DQ Web Pod 側の TLS 設定（JKS 作成・Secret 登録）が不要になる。AKS でも NGINX TLS termination で同様にできるが、設定が Route より煩雑になる。

### 9.3 TLS 設定の構成要素比較

**AKS（NGINX Ingress での TLS termination）:**

```yaml
# 7章で作成した TLS Secret を Ingress で参照
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dq-web-ingress
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"   # Edge 相当
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - dq.example.internal
      secretName: dq-ssl-secret       # type: kubernetes.io/tls の Secret
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
```

**ARO（Route Edge termination）:**

```yaml
# CA 署名済み証明書を Route に直接埋め込む（Secret 参照は不要）
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: dq-web-route
spec:
  host: dq.example.internal
  to:
    kind: Service
    name: collibra-dq-web
  port:
    targetPort: 9000
  tls:
    termination: edge               # Route が TLS を終端
    certificate: |
      -----BEGIN CERTIFICATE-----
      <PEM 証明書>
      -----END CERTIFICATE-----
    key: |
      -----BEGIN PRIVATE KEY-----
      <PEM 秘密鍵>
      -----END PRIVATE KEY-----
    insecureEdgeTerminationPolicy: Redirect   # HTTP → HTTPS リダイレクト
```

### 9.4 証明書の Secret 形式の差異

| 観点 | AKS（Ingress 用） | ARO（Route 用） |
|---|---|---|
| Secret タイプ | `kubernetes.io/tls` | Route に PEM を直接記載（Secret 参照不可） |
| 証明書フォーマット | PEM（tls.crt / tls.key） | PEM（Route YAML に inline で記載） |
| 中間 CA の扱い | `tls.crt` に連結して記載 | `caCertificate` フィールドに別記 |
| 証明書のローテーション | Secret を更新 → Ingress が自動反映 | Route を更新（`oc edit route` または `oc apply`） |

---

## 10. 外部アクセス（Ingress vs Route）

### 10.1 仕組みの根本的な差異

| 観点 | AKS: NGINX Ingress | ARO: OpenShift Route |
|---|---|---|
| 導入方法 | Helm で別途インストール必要 | ARO に組み込み済み（インストール不要） |
| 実装 | NGINX（OSS / Ingress-NGINX） | HAProxy（OpenShift Router） |
| API リソース | `networking.k8s.io/v1 Ingress` | `route.openshift.io/v1 Route` |
| TLS 設定場所 | Ingress `spec.tls` + Secret | Route `spec.tls`（inline PEM） |
| ホスト名自動割り当て | なし（手動で hosts 指定） | あり（`<route>.<project>.<cluster-domain>` 形式） |
| HTTP→HTTPS リダイレクト | `nginx.ingress.kubernetes.io/ssl-redirect: "true"` アノテーション | `insecureEdgeTerminationPolicy: Redirect` |
| タイムアウト設定 | `nginx.ingress.kubernetes.io/proxy-read-timeout` アノテーション | `haproxy.router.openshift.io/timeout` アノテーション |
| WebSocket サポート | アノテーションで有効化 | デフォルトで有効 |

### 10.2 セットアップ手順の比較

**AKS: NGINX Ingress コントローラーのインストール（別途必要）:**

```bash
# Step 1: Helm リポジトリ追加・インストール
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
  --set controller.replicaCount=2 \
  --wait

# Step 2: Internal LoadBalancer の IP 取得
INGRESS_IP=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Step 3: Ingress リソース作成
kubectl apply -f dq-web-ingress.yaml -n "${NAMESPACE}"
```

**ARO: Route のみ作成（インストール不要）:**

```bash
# Step 1: デフォルトドメイン確認（インストール作業なし）
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'

# Step 2: Route リソース作成のみ
oc apply -f dq-web-route.yaml -n "${OC_PROJECT}"

# Step 3: 自動割り当てされた URL を確認
oc get route dq-web-route -n "${OC_PROJECT}" -o jsonpath='{.spec.host}'
```

### 10.3 設定 YAML の対応関係

| 設定項目 | AKS（Ingress） | ARO（Route） |
|---|---|---|
| ホスト名 | `spec.rules[].host` | `spec.host` |
| バックエンド Service | `spec.rules[].http.paths[].backend.service.name` | `spec.to.name` |
| バックエンドポート | `spec.rules[].http.paths[].backend.service.port.number` | `spec.port.targetPort` |
| TLS 有効化 | `spec.tls[].secretName` | `spec.tls.termination: edge` |
| TLS 証明書 | Secret（`kubectl create secret tls`） | Route YAML に inline 記載 |
| HTTP リダイレクト | `nginx.ingress.kubernetes.io/ssl-redirect: "true"` | `spec.tls.insecureEdgeTerminationPolicy: Redirect` |
| タイムアウト（例: 1時間） | `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` | `haproxy.router.openshift.io/timeout: "1h"` |

### 10.4 DNS 設定の差異

**AKS:**
```
# Ingress Controller の Internal LoadBalancer IP に A レコードを登録
dq.example.internal  A  10.1.x.x（INGRESS_IP）
```

**ARO:**
```
# Router の IP に A レコード、またはデフォルトドメインに CNAME を設定
dq.example.internal  CNAME  router-default.apps.aro-xxx.japaneast.aroapp.io

# または Router の外部 IP を直接指定
ROUTER_IP=$(oc get svc router-default -n openshift-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# dq.example.internal  A  ${ROUTER_IP}
```

> **ARO の優位点**: デフォルトドメインを使用する場合、DNS 登録不要で即座に `https://<route名>-<project名>.apps.<cluster-domain>/` の URL が利用可能になる。社内 DNS への依頼待ち時間なしで動作確認できる。

---

## 11. Helm デプロイの差異

### 11.1 デプロイ前チェックリストの差異

ARO には AKS にない SCC の確認ステップが加わる。

| チェック項目 | AKS | ARO |
|---|---|---|
| Namespace / Project の確認 | `kubectl get namespace` | `oc get project` |
| PVC の確認 | `kubectl get pvc -n` | `oc get pvc -n` |
| Secret の確認 | `kubectl get secret -n` | `oc get secret -n` |
| **SCC の確認（ARO 固有）** | 不要 | `oc adm policy who-can use scc anyuid \| grep collibra-dq-sa` |
| チャートの確認 | `ls ${CHART_PATH}/Chart.yaml` | 同左 |

### 11.2 custom-values.yaml の主要差異

ファイル名と TLS・securityContext の設定が異なる。その他の設定（メタストア接続・PVC 参照・イメージリポジトリ）は共通。

| 設定キー | AKS（custom-values.yaml） | ARO（custom-values-aro.yaml） |
|---|---|---|
| `global.web.tls.enabled` | `true`（JKS を使用） | `false`（Edge Route が TLS を処理） |
| `global.web.tls.key.secretName` | `dq-ssl-secret` | 設定不要 |
| `podSecurityContext.runAsUser` | `1000`（UID を明示指定可） | 省略（ARO が自動割り当て） |
| `podSecurityContext.runAsNonRoot` | `true` | `true` |
| `securityContext.capabilities.drop` | 省略可 | `["ALL"]`（restricted-v2 準拠） |
| `serviceAccount.name` | `collibra-dq-sa` | `collibra-dq-sa`（SCC 付与済みであること） |

**AKS（TLS 有効・UID 指定あり）:**

```yaml
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
  # securityContext で UID を明示指定
podSecurityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  runAsNonRoot: true
```

**ARO（TLS 無効・UID 省略）:**

```yaml
global:
  web:
    tls:
      enabled: false          # Route の Edge termination が TLS を処理
# securityContext は runAsNonRoot のみ（UID は省略）
podSecurityContext:
  runAsNonRoot: true
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

### 11.3 helm upgrade --install コマンドの差異

コマンド本体は同一。`--namespace` の参照変数と、シークレット参照コマンドが `kubectl` → `oc` に変わる。

```bash
# AKS
helm upgrade --install "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --values ~/custom-values.yaml \
  --set global.configMap.data.license_key="$(
      kubectl get secret dq-license-secret -n ${NAMESPACE} \
        -o jsonpath='{.data.license_key}' | base64 -d)" \
  --timeout 10m --wait

# ARO（--namespace と secret 参照コマンドのみ変更）
helm upgrade --install "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${OC_PROJECT}" \
  --values ~/custom-values-aro.yaml \
  --set global.configMap.data.license_key="$(
      oc get secret dq-license-secret -n ${OC_PROJECT} \
        -o jsonpath='{.data.license_key}' | base64 -d)" \
  --timeout 10m --wait
```

### 11.4 デプロイ後の SCC 確認（ARO 固有）

ARO では Pod 起動後に使用された SCC を確認できる。

```bash
# ARO 固有: 起動中 Pod の SCC を確認
oc get pod -n "${OC_PROJECT}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'

# 期待値: anyuid または collibra-dq-scc が表示されること
```

---

## 12. RBAC・Agent / Spark 設定

### 12.1 RBAC の差異

Role / RoleBinding の YAML 定義は AKS / ARO で同一。ARO では RBAC に加えて SCC 付与が必須。

| 設定内容 | AKS | ARO |
|---|---|---|
| ServiceAccount 作成 | `kubectl apply` | `oc apply` |
| Role / RoleBinding 作成 | `kubectl apply` | `oc apply` |
| **SCC 付与（ARO 固有）** | 不要 | `oc adm policy add-scc-to-user anyuid -z dq-agent-sa` |
| SCC の確認 | 不要 | `oc adm policy who-can use scc/anyuid` |

> **重要**: ARO で SCC 付与を忘れると Spark Executor Pod の動的生成時に以下のエラーが発生する。
> ```
> Error creating: pods "spark-exec-xxx" is forbidden:
>   unable to validate against any security context constraint
> ```

### 12.2 Spark nodeSelector の差異

AKS と ARO ではノードラベルの付け方が異なるため、`nodeSelector` の指定が変わる。

| 観点 | AKS | ARO |
|---|---|---|
| ノード種別ラベル | `agentpool: <pool名>`（AKS が自動付与） | `node-role.kubernetes.io/worker: ""`（OpenShift 標準） |
| 専用プール指定 | `agentpool: dqpool` | `node-role.kubernetes.io/worker: ""`（worker 全体） |
| 特定ノードプール指定 | `agentpool: dqpool` | カスタムラベルを別途付与して指定 |

```yaml
# AKS（Spark Executor の nodeSelector）
spark:
  nodeSelector:
    agentpool: dqpool          # AKS ノードプール名

# ARO（Spark Executor の nodeSelector）
spark:
  nodeSelector:
    node-role.kubernetes.io/worker: ""    # OpenShift ワーカーノード全体
```

ARO で特定のノードグループに限定したい場合は、ノードにカスタムラベルを追加して指定する。

```bash
# ARO のワーカーノードにカスタムラベルを付与
oc label node <worker-node-name> workload=dq

# custom-values-aro.yaml での指定
# spark:
#   nodeSelector:
#     workload: dq
```

### 12.3 Spark securityContext の差異

Executor Pod の securityContext も AKS / ARO で異なる。

```yaml
# AKS: UID を明示指定可能
spark:
  driver:
    serviceAccount: dq-agent-sa
  executor:
    securityContext:
      runAsUser: 1000

# ARO: UID は省略（SCC が継承・自動割り当て）
spark:
  driver:
    serviceAccount: dq-agent-sa
    securityContext:
      runAsNonRoot: true        # UID は anyuid SCC が処理
  executor:
    securityContext:
      runAsNonRoot: true
```

---

## 13. 監視・ログ

### 13.1 監視スタックの違い

| 観点 | AKS | ARO |
|---|---|---|
| 監視基盤 | Azure Monitor / Container Insights | OpenShift 組み込み監視（Prometheus / Alertmanager） |
| 有効化 | AKS 作成時または `az aks enable-addons` | ARO に標準搭載（有効化不要） |
| ダッシュボード | Azure Portal の監視ブレード / Grafana（別途） | OpenShift Web コンソール（Observe） / 組み込み Grafana |
| ログ集約 | Log Analytics ワークスペース | OpenShift Logging（EFK: Elasticsearch / Fluentd / Kibana）または Azure Monitor |
| アラート | Azure Monitor アラートルール | Alertmanager + PrometheusRule |
| コスト | Log Analytics インジェスト料金（GB 単位） | OpenShift 監視は追加コストなし |

### 13.2 ログ確認コマンドの差異

Pod ログの確認コマンドは `kubectl` → `oc` に置き換えるだけで同等。

```bash
# AKS
kubectl logs -n "${NAMESPACE}" -l app=owl-web --tail=200 \
  | grep -iE "error|exception|warn"

kubectl logs -n "${NAMESPACE}" -l app=owl-agent --tail=100

# ARO（コマンド以外は同一）
oc logs -n "${OC_PROJECT}" -l app=owl-web --tail=200 \
  | grep -iE "error|exception|warn"

oc logs -n "${OC_PROJECT}" -l app=owl-agent --tail=100
```

### 13.3 メトリクス確認方法の差異

**AKS（Container Insights / Log Analytics）:**

```bash
# Log Analytics クエリで Pod ステータスを確認
az monitor log-analytics query \
  --workspace "${LAW_NAME}" \
  --analytics-query "
    KubePodInventory
    | where Namespace == '${NAMESPACE}'
    | summarize count() by PodStatus
  " \
  --timespan PT1H

# Azure Portal > AKS > 監視 > インサイト からも GUI で確認可
```

**ARO（OpenShift 組み込み Prometheus）:**

```bash
# Prometheus / Grafana の Route URL を取得
oc get route -n openshift-monitoring

# PromQL でメトリクスを確認（Web コンソール > Observe > Metrics）
```

PromQL クエリ例:

```promql
# DQ Web の CPU 使用率
rate(container_cpu_usage_seconds_total{
  namespace="collibra-dq", container="owl-web"}[5m])

# DQ Agent のメモリ使用量
container_memory_working_set_bytes{
  namespace="collibra-dq", container="owl-agent"}

# Spark Executor Pod が存在する間の Pod 数
count(kube_pod_info{namespace="collibra-dq"}) by (pod)
```

### 13.4 アラート設定の差異

**AKS（Azure Monitor アラートルール）:**

```bash
# Pod の再起動回数が閾値を超えたらアラート
az monitor metrics alert create \
  --name "dq-pod-restart-alert" \
  --resource-group "${RG_NAME}" \
  --scopes "/subscriptions/.../resourceGroups/.../providers/Microsoft.ContainerService/managedClusters/${AKS_NAME}" \
  --condition "avg kube_pod_container_status_restarts_total > 5" \
  --window-size 5m \
  --evaluation-frequency 1m
```

**ARO（PrometheusRule）:**

```yaml
# oc apply でアラートルールを作成
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: collibra-dq-alerts
  namespace: collibra-dq
spec:
  groups:
    - name: collibra-dq
      rules:
        - alert: DQPodCrashLooping
          expr: |
            rate(kube_pod_container_status_restarts_total{
              namespace="collibra-dq"}[5m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Collibra DQ Pod がクラッシュしています"
```

---

## 14. トラブルシューティングの差異

### 14.1 エラー一覧比較

| 症状 | AKS | ARO | 対処法の差異 |
|---|---|---|---|
| `ImagePullBackOff` | ACR 未転送 / プルシークレット未設定 | 同左 + `oc secrets link` 未実施 | ARO は `oc secrets link default dq-pull-secret --for=pull` を追加で確認 |
| Pod が `Pending` | ノードリソース不足 / PVC Pending | 同左 | コマンドが `kubectl describe` → `oc describe` |
| PVC が `Pending` | StorageClass 未作成 / SMB の NFS 未対応 | **SMB StorageClass を使用している可能性（ARO）** | ARO は `protocol: nfs` を明示した StorageClass を使用しているか確認 |
| `CrashLoopBackOff` | DB 接続失敗 / ライセンス不正 | 同左 | コマンドが `--previous` 付きログ確認（`kubectl` → `oc`） |
| `OOMKilled` | Spark Executor のメモリ不足 | 同左 | `executor.memory` 増加（コマンドは共通） |
| Ingress/Route の外部アクセス不可 | NGINX Controller Pod の起動失敗 | Route 設定ミス / Router Pod の問題 | AKS: `kubectl get pods -n ingress-nginx` / ARO: `oc get pods -n openshift-ingress` |
| 502 Bad Gateway | DQ Web Pod 未起動 / Service ポート不一致 | 同左 | AKS は Ingress の backend 設定を確認 / ARO は Route の `spec.to.name` を確認 |
| Spark ジョブ `FAILED` | RBAC 不足（Forbidden） | 同左 + **SCC 違反（ARO 固有）** | ARO は RBAC に加えて `oc adm policy who-can use scc/anyuid` で SCC も確認 |
| **SCC 違反**（ARO 固有） | `dq-agent-sa` への SCC 付与漏れ | ARO のみ発生 | `oc adm policy add-scc-to-user anyuid -z dq-agent-sa -n ${OC_PROJECT}` |
| **内部レジストリ認証失敗**（ARO 固有） | プッシュ権限不足 | ARO のみ発生 | `oc policy add-role-to-user registry-editor -z default` |

### 14.2 デバッグコマンド対応表

基本コマンドは `kubectl` → `oc` に読み替えるだけで動作する。ARO 固有コマンドを追加で覚える。

| 操作 | AKS | ARO |
|---|---|---|
| Pod 一覧 | `kubectl get pods -n ${NAMESPACE} -o wide` | `oc get pods -n ${OC_PROJECT} -o wide` |
| Pod 詳細 | `kubectl describe pod <POD> -n ${NAMESPACE}` | `oc describe pod <POD> -n ${OC_PROJECT}` |
| ログ確認 | `kubectl logs <POD> -n ${NAMESPACE}` | `oc logs <POD> -n ${OC_PROJECT}` |
| 直前のログ | `kubectl logs <POD> --previous` | `oc logs <POD> --previous` |
| Pod 内シェル | `kubectl exec -it <POD> -- bash` | `oc exec -it <POD> -- bash` |
| イベント確認 | `kubectl get events --sort-by='.lastTimestamp'` | `oc get events --sort-by='.lastTimestamp'` |
| 全リソース確認 | `kubectl get all -n ${NAMESPACE}` | `oc get all -n ${OC_PROJECT}` |
| **SCC 確認（ARO 固有）** | — | `oc adm policy who-can use scc/anyuid` |
| **SCC 付与（ARO 固有）** | — | `oc adm policy add-scc-to-user anyuid -z <SA>` |
| **SCC レビュー（ARO 固有）** | — | `oc adm policy scc-review -z <SA> --resource=pods` |
| **Pod の SCC 確認（ARO 固有）** | — | `oc get pod -o jsonpath='{.metadata.annotations.openshift\.io/scc}'` |
| Ingress/Route 確認 | `kubectl get ingress -n ${NAMESPACE}` | `oc get route -n ${OC_PROJECT}` |
| Helm 状態確認 | `helm status ${HELM_RELEASE_NAME} -n ${NAMESPACE}` | `helm status ${HELM_RELEASE_NAME} -n ${OC_PROJECT}` |
| Helm values 確認 | `helm get values ${HELM_RELEASE_NAME} -n ${NAMESPACE}` | `helm get values ${HELM_RELEASE_NAME} -n ${OC_PROJECT}` |

### 14.3 SCC 違反のデバッグフロー（ARO 固有）

```
Pod が Pending / Error
  │
  ├─ oc describe pod <POD> -n ${OC_PROJECT}
  │    └─ Events に "unable to validate against any security context constraint" ?
  │         │
  │         Yes
  │         │
  │         ├─ oc adm policy who-can use scc/anyuid | grep <SA>
  │         │    └─ SA が含まれていない？
  │         │         └─ oc adm policy add-scc-to-user anyuid -z <SA> -n ${OC_PROJECT}
  │         │
  │         └─ SCC は付与済みだが securityContext と競合している？
  │              └─ custom-values.yaml の runAsUser を削除（ARO 自動割り当てに委譲）
  │
  └─ 別の原因（ImagePullBackOff / OOMKilled 等）→ 14.1 の対処法を参照
```

---

## 15. アップグレード手順の差異

### 15.1 手順の全体フロー比較

`helm upgrade` コマンド本体と Helm チャートの取得手順は完全に共通。差異はイメージ転送先とローリングアップデート確認コマンドのみ。

| ステップ | AKS | ARO |
|---|---|---|
| 1. バックアップ | `helm get values ... -n ${NAMESPACE}` / `pg_dump` | `helm get values ... -n ${OC_PROJECT}` / `pg_dump` |
| 2. イメージ転送 | ACR のみ | **ACR または OpenShift 内部レジストリ**（2択） |
| 3. Helm チャート取得 | `wget` + `unzip`（共通） | 同左 |
| 4. values バージョン更新 | `sed -i` で `custom-values.yaml` を更新 | `sed -i` で `custom-values-aro.yaml` を更新 |
| 5. `helm upgrade` | `--namespace "${NAMESPACE}"` | `--namespace "${OC_PROJECT}"` |
| 6. ローリング確認 | `kubectl rollout status` | `oc rollout status` |
| 7. ロールバック | `helm rollback` + `kubectl rollout status` | `helm rollback` + `oc rollout status` |

### 15.2 イメージ転送の差異

ARO のみ内部レジストリへの転送パターンが追加される。

**AKS（ACR のみ）:**

```bash
az acr login --name "${ACR_NAME}"
for IMG in owl-web owl-agent; do
  docker tag  "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}" \
              "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
  docker push "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
done
```

**ARO（ACR または内部レジストリ）:**

```bash
# パターン A: ACR へ転送（AKS と同一）
az acr login --name "${ACR_NAME}"
for IMG in owl-web owl-agent; do
  docker tag  "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}" \
              "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
  docker push "${ACR_LOGIN_SERVER}/collibra/${IMG}:${NEW_DQ_VERSION}"
done

# パターン B: OpenShift 内部レジストリへ転送（ARO 固有）
INTERNAL_REGISTRY=$(oc get route default-route \
  -n openshift-image-registry -o jsonpath='{.spec.host}')
docker login "${INTERNAL_REGISTRY}" -u "$(oc whoami)" -p "$(oc whoami -t)"
for IMG in owl-web owl-agent; do
  docker tag  "${COLLIBRA_REGISTRY}/${IMG}:${NEW_DQ_VERSION}" \
              "${INTERNAL_REGISTRY}/${OC_PROJECT}/${IMG}:${NEW_DQ_VERSION}"
  docker push "${INTERNAL_REGISTRY}/${OC_PROJECT}/${IMG}:${NEW_DQ_VERSION}"
done
```

### 15.3 ローリングアップデート確認コマンドの差異

```bash
# AKS
kubectl rollout status deployment/collibra-dq-web  -n "${NAMESPACE}"
kubectl rollout status deployment/collibra-dq-agent -n "${NAMESPACE}"

# ARO（oc に置き換えるだけ）
oc rollout status deployment/collibra-dq-web  -n "${OC_PROJECT}"
oc rollout status deployment/collibra-dq-agent -n "${OC_PROJECT}"
```

### 15.4 ロールバックコマンドの差異

```bash
# AKS
helm rollback "${HELM_RELEASE_NAME}" 1 --namespace "${NAMESPACE}" --wait
kubectl rollout status deployment/collibra-dq-web -n "${NAMESPACE}"

# ARO
helm rollback "${HELM_RELEASE_NAME}" 1 --namespace "${OC_PROJECT}" --wait
oc rollout status deployment/collibra-dq-web -n "${OC_PROJECT}"
```

> **共通の注意点**: ロールバック後にメタストアのスキーマが新バージョンで変更されていると旧バージョンと互換性がない場合がある。Collibra のリリースノートでスキーママイグレーションの有無を事前に確認すること。

---

## 16. 採用判断フロー

### 16.1 総合比較サマリー

本ドキュメント全体の差異を「導入コスト」「運用コスト」「セキュリティ」「既存環境との親和性」の4観点で評価する。

| 評価観点 | AKS | ARO | 備考 |
|---|---|---|---|
| **初期構築の難易度** | ★★☆ 中 | ★★★ 高 | ARO は SCC・Route・内部レジストリ等の追加設定が必要 |
| **必要な追加知識** | Kubernetes + Azure | Kubernetes + Azure + OpenShift / RHEL | ARO は OpenShift 固有の概念（SCC・Route・Project）の習得が必要 |
| **月額コスト** | 低〜中 | 中〜高（RHEL + OCP ライセンス込み） | ARO は AKS の 1.5〜2 倍程度が目安 |
| **サポート体制** | Microsoft のみ | Microsoft + Red Hat 共同 | ARO は OpenShift 問題を Red Hat に問い合わせ可能 |
| **セキュリティ機能** | PSA（3段階）+ Azure Policy | SCC（細粒度）+ OpenShift Security | ARO の SCC は細粒度設定が可能だが設定コストも高い |
| **外部アクセス設定** | NGINX インストール必要 | Route が標準搭載（インストール不要） | ARO は Ingress Controller 管理が不要 |
| **監視基盤** | Container Insights（別途設定） | Prometheus/Grafana（標準搭載） | ARO は追加コストなしで監視スタックを利用可能 |
| **Web コンソール** | Azure Portal（クラウド管理UI） | OpenShift Web コンソール（Kubernetes 操作 UI） | ARO は Pod・ログ・メトリクスをブラウザで直接操作可能 |
| **Collibra DQ の互換性** | 完全サポート | 完全サポート | 両者とも公式サポート対象 |
| **IaC / GitOps 親和性** | Helm + Azure Bicep / Terraform | Helm + ArgoCD / OpenShift GitOps | ARO は GitOps ワークフローが標準機能として充実 |

### 16.2 採用判断フロー

```
START: Collibra DQ を Azure Kubernetes 基盤にデプロイする
  │
  Q1: 組織内に既存の OpenShift / ARO 環境があるか？
  │
  ├─ YES ──▶ 既存 ARO 環境に相乗りできるか確認
  │               │
  │               ├─ YES ──▶ ★ ARO を選択（既存インフラ活用）
  │               └─ NO  ──▶ Q2 へ
  │
  └─ NO ──▶ Q2 へ
        │
        Q2: Red Hat / OpenShift の運用経験がチームにあるか？
        │
        ├─ YES ──▶ Q3 へ
        └─ NO  ──▶ ★ AKS を選択（学習コスト最小）
              │
              Q3: 以下の要件が1つ以上あるか？
              │   ・Red Hat サポートを利用したい
              │   ・OpenShift の Web コンソール・GitOps を活用したい
              │   ・SCC による細粒度のセキュリティ制御が必要
              │   ・RHEL ベースの OS が組織要件（セキュリティ基準等）
              │
              ├─ YES ──▶ ★ ARO を選択
              └─ NO  ──▶ Q4 へ
                    │
                    Q4: コスト最優先か？
                    │
                    ├─ YES ──▶ ★ AKS を選択（ARO 比 1.5〜2 倍安価）
                    └─ NO  ──▶ ★ AKS を選択（デフォルト推奨）
```

### 16.3 シナリオ別推奨まとめ

| シナリオ | 推奨 | 主な理由 |
|---|---|---|
| Azure ネイティブで新規構築。OpenShift 経験なし | **AKS** | 学習コスト・運用コスト・金額コストすべて低い |
| 社内に既存 ARO クラスターがある | **ARO（既存活用）** | 新規クラスター不要。インフラ費用を抑制できる |
| Red Hat サポートを利用したい | **ARO** | OpenShift 問題を Red Hat に問い合わせ可能 |
| OpenShift の SCC で細粒度セキュリティ制御が必要 | **ARO** | PSA より柔軟な SCC を活用可能 |
| 監視・GitOps を標準搭載で使いたい | **ARO** | Prometheus・Grafana・ArgoCD が組み込み済み |
| コスト最優先（PoC / 小規模本番） | **AKS** | ARO より 1.5〜2 倍安価。必要十分な機能を提供 |
| 将来 AWS/GCP への移植可能性を残したい | **AKS** | CNCF 準拠の標準 Kubernetes。EKS/GKE との差異最小 |
| RHEL ベース OS が組織のセキュリティ要件 | **ARO** | ノード OS が RHEL（ARO は RHCOS）で統一可能 |

### 16.4 本プロジェクトへの適用

本プロジェクト（Azure Hub-Spoke 構成・DQ Agent + Spark のみ・OpenShift 経験なし）に対する推奨:

> **AKS による構築を推奨する。**

| 判断根拠 | 内容 |
|---|---|
| Azure 基盤との親和性 | Hub-Spoke / Private Endpoint / Managed Identity がそのまま利用可能 |
| OpenShift 経験不要 | SCC・Route・Project 等の追加概念の習得が不要 |
| コスト効率 | ARO 比で約 1.5〜2 倍安価 |
| 将来の移植性 | 標準 Kubernetes のため EKS/GKE への移植が容易 |
| 運用の自動化 | AKS ノードの自動アップグレード・Container Insights との統合が容易 |

ただし、以下に該当する場合は ARO への移行または ARO での新規構築を再検討すること:

- 組織内で ARO / OpenShift の標準化が決定された場合
- Red Hat サポートが契約要件になった場合
- OpenShift の細粒度 SCC によるセキュリティポリシー適用が必須になった場合

---

## 付録: 変数名・設定値の対応表

各ドキュメントで使用している変数名と値の対応を整理する。

| 変数 | AKS（aks-setup.md） | ARO（aro-setup.md） | 備考 |
|---|---|---|---|
| クラスター名変数 | `AKS_NAME=aks-collibra-dq` | `ARO_NAME=aro-collibra-dq` | |
| 名前空間変数 | `NAMESPACE=collibra-dq` | `OC_PROJECT=collibra-dq` | 値は同一 |
| Helm 名前空間指定 | `--namespace "${NAMESPACE}"` | `--namespace "${OC_PROJECT}"` | |
| values ファイル名 | `custom-values.yaml` | `custom-values-aro.yaml` | |
| ロールアウト確認 | `kubectl rollout status` | `oc rollout status` | |
| リソース確認コマンド | `kubectl get pod,svc,pvc,ingress` | `oc get pod,svc,pvc,route` | `ingress` → `route` |
| イメージレジストリ | ACR（`${ACR_LOGIN_SERVER}`） | ACR または内部レジストリ | |
| ノード選択キー | `agentpool: dqpool` | `node-role.kubernetes.io/worker: ""` | |
