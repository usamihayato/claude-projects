# Helm 概要

> **参照**: [Helm 公式ドキュメント](https://helm.sh/docs/)

---

## 目次

1. [Helm とは](#1-helm-とは)
2. [基本概念](#2-基本概念)
3. [Chart の構成](#3-chart-の構成)
4. [インストール](#4-インストール)
5. [主要コマンド](#5-主要コマンド)
6. [values.yaml の使い方](#6-valuesyaml-の使い方)
7. [Collibra DQ での利用例](#7-collibra-dq-での利用例)

---

## 1. Helm とは

**Kubernetes 用のパッケージマネージャー**。複数の Kubernetes リソース（Deployment、Service、ConfigMap 等）をひとまとめにして管理・配布・デプロイするためのツール。

Linux における `apt` / `yum` に相当するものと考えるとわかりやすい。

| ツール | 役割 |
|--------|------|
| `apt` / `yum` | Linux パッケージ管理 |
| `Helm` | Kubernetes アプリケーション管理 |

---

## 2. 基本概念

Helm には3つの核となる概念がある。

### Chart（チャート）

Kubernetes クラスタ上でアプリケーションを動かすために必要な**全リソース定義のパッケージ**。  
Deployment / Service / ConfigMap / Secret 等のマニフェストをテンプレートとしてまとめたもの。

### Repository（リポジトリ）

Chart を集約・共有する場所。`helm repo add` でローカルに登録して使う。  
Collibra DQ の場合は公開リポジトリではなく、**ライセンス契約後にメールで配布される ZIP ファイル**として提供される。

### Release（リリース）

クラスタ上に**インストールされた Chart の実行インスタンス**。同一の Chart を複数回インストールすると、それぞれが独立した Release になる。

```
Chart（設計図）  ×  インストール  =  Release（実体）
```

---

## 3. Chart の構成

```
mychart/
├── Chart.yaml          # Chart のメタデータ（名前・バージョン・説明）
├── values.yaml         # デフォルト設定値
├── charts/             # 依存する子 Chart（サブチャート）を格納
└── templates/          # Kubernetes マニフェストのテンプレート群
    ├── deployment.yaml
    ├── service.yaml
    └── _helpers.tpl    # テンプレート共通関数
```

### Chart.yaml の例

```yaml
apiVersion: v2
name: collibra-dq
description: Collibra Data Quality & Observability
type: application
version: 1.0.0          # Chart 自体のバージョン
appVersion: "2026.02"   # アプリケーションのバージョン
```

### templates/ のしくみ

テンプレートファイルは `{{ }}` 構文で値を埋め込む。`values.yaml` の値や Release 名・名前空間等を参照できる。

```yaml
# templates/deployment.yaml の例
metadata:
  name: {{ .Release.Name }}-web
  namespace: {{ .Release.Namespace }}
spec:
  replicas: {{ .Values.owl-web.replicaCount }}
  image: {{ .Values.global.image.repo }}:{{ .Values.global.version.dq }}
```

### サブチャート（charts/ ディレクトリ）

Collibra DQ の Helm チャートは複数のサブチャートで構成されている。

```
dq/
└── charts/
    ├── metastore/          # PostgreSQL メタストア
    ├── owl-web/            # DQ Web
    ├── owl-agent/          # DQ Agent
    ├── owl-livy/           # Apache Livy
    └── spark-history-server/
```

各サブチャートは `values.yaml` で `enabled: true/false` により個別に有効化・無効化できる。

---

## 4. インストール

### バイナリから（RHEL / Linux）

```bash
# バイナリをダウンロードして配置
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
```

### パッケージマネージャーから

```bash
# Debian / Ubuntu
sudo apt-get install helm

# Fedora
sudo dnf install helm
```

### バージョン確認

```bash
helm version
```

---

## 5. 主要コマンド

### ライフサイクル管理

| コマンド | 用途 | 例 |
|---------|------|-----|
| `helm install` | Chart を新規インストール（Release を作成） | `helm install my-release ./chart` |
| `helm upgrade` | 既存 Release を更新 | `helm upgrade my-release ./chart` |
| `helm upgrade --install` | なければインストール、あれば更新（冪等） | よく使われるパターン |
| `helm rollback` | 前のリビジョンに戻す | `helm rollback my-release 1` |
| `helm uninstall` | Release を削除 | `helm uninstall my-release` |

### 情報確認

| コマンド | 用途 |
|---------|------|
| `helm list -n <namespace>` | Release 一覧を表示 |
| `helm status <release>` | Release の状態を確認 |
| `helm history <release>` | Release のリビジョン履歴を表示 |
| `helm get values <release>` | 適用済みの values を確認 |

### Chart 操作

| コマンド | 用途 |
|---------|------|
| `helm show values ./chart` | Chart のデフォルト values を確認 |
| `helm template ./chart` | テンプレートをレンダリングして確認（dry-run） |
| `helm lint ./chart` | Chart の構文チェック |
| `helm package ./chart` | Chart を `.tgz` にパッケージ化 |

### リポジトリ管理

```bash
helm repo add <name> <url>     # リポジトリを追加
helm repo update               # リポジトリ情報を更新
helm repo list                 # 登録済みリポジトリを一覧表示
helm search repo <keyword>     # リポジトリから Chart を検索
```

---

## 6. values.yaml の使い方

### 優先順位

values の上書きは以下の優先順位で適用される（下に行くほど優先度が高い）。

```
Chart デフォルト (values.yaml)
  ↓ 上書き
親 Chart の values.yaml
  ↓ 上書き
-f / --values で指定したファイル
  ↓ 上書き
--set で指定した個別の値  ← 最優先
```

### ファイル指定での上書き

```bash
helm upgrade --install my-release ./chart \
  --values ./my-values.yaml
```

### --set による個別上書き

```bash
# 単一の値
--set global.version.dq=2026.02

# ネストされた値
--set owl-web.replicaCount=3

# 配列の値
--set image.pullSecrets[0].name=collibra-registry
```

### values.yaml での Secret 参照（推奨パターン）

平文パスワードを values.yaml に直書きせず、Kubernetes Secret または Azure Key Vault を参照する。

```yaml
# Kubernetes Secret を参照
env:
  - name: METASTORE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: dq-secrets
        key: metastore_password
```

---

## 7. Collibra DQ での利用例

### 基本的なデプロイフロー

```bash
# 1. ZIP を解凍して Chart ディレクトリを準備
unzip collibra-dq-helm-chart.zip

# 2. デフォルト values を確認
helm show values ./dq

# 3. dry-run でマニフェストを確認
helm template collibra-dq ./dq --values ./my-values.yaml

# 4. インストール
helm upgrade --install collibra-dq \
  --namespace collibra-dq \
  --values ./my-values.yaml \
  ./dq

# 5. Release の状態確認
helm status collibra-dq -n collibra-dq

# 6. 適用済み values の確認
helm get values collibra-dq -n collibra-dq
```

### アップグレード

```bash
# 新バージョンの Chart ZIP を解凍後
helm upgrade collibra-dq \
  --namespace collibra-dq \
  --set global.version.dq=<NEW_VERSION> \
  ./dq-new

# ロールバック（問題が発生した場合）
helm history collibra-dq -n collibra-dq   # リビジョン番号を確認
helm rollback collibra-dq 1 -n collibra-dq
```

### 特定コンポーネントのみ無効化

```bash
# metastore と web を無効にして agent のみデプロイ
helm upgrade --install collibra-dq ./dq \
  --namespace collibra-dq \
  --set metastore.enabled=false \
  --set owl-web.enabled=false \
  --values ./my-values.yaml
```
