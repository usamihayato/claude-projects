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

対象範囲はアプリケーション層のセットアップに限定し、Azure インフラ（AKS クラスター、VNET、ACR 等）の構築手順は含まない。

### 1.2 前提条件（AKS 基盤構築済み前提）

本手順を実施する前に、以下が完了していること：

- AKS クラスターの構築完了（`aks-build.md` 参照）
- Azure Container Registry (ACR) の構築と AKS への接続完了
- 管理用 Linux VM へのアクセス確認（kubectl / helm インストール済み）
- 外部メタストア用 Azure Database for PostgreSQL の準備
- Collibra 社からのライセンスキーおよびコンテナイメージアクセス情報の取得

### 1.3 関連ドキュメント一覧

| ドキュメント | 内容 |
|---|---|
| `docs/collibra/report.md` | Collibra DQ 製品概要・システム要件 |
| `docs/collibra/deployment-comparison.md` | デプロイ構成比較（AKS 推奨の根拠） |
| `docs/collibra/setup.md` | スタンドアロン・Kubernetes インストール概要 |
| `docs/kubernetes/aks-design.md` | AKS 設計書（Hub-Spoke 構成） |
| `docs/kubernetes/aks-build.md` | AKS 基盤構築手順（インフラ層） |
| `docs/kubernetes/helm.md` | Helm 基礎知識 |

---

## 2. 事前準備

### 2.1 変数定義

本手順全体で使用する環境変数を定義する。

### 2.2 AKS クラスターへの接続確認

管理用 Linux VM から AKS クラスターへの接続と、ノード・ネームスペースの状態を確認する。

### 2.3 必要ツールの確認（kubectl / helm / az CLI）

各ツールのバージョンと動作を確認する。Helm は v3 系が必須。

### 2.4 ネームスペース作成

Collibra DQ 専用のネームスペースを作成し、以降の操作対象とする。

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
