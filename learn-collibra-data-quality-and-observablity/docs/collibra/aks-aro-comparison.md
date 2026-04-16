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

*（後半：8〜16章は別途作成）*
