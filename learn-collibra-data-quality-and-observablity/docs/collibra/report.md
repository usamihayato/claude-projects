# Collibra Data Quality & Observability Classic 調査レポート

> **対象バージョン**: 2026.02（最新）  
> **作成日**: 2026-04-13  
> **目的**: Azure基盤での社内導入・Agent構築のための事前調査

---

## 目次

1. [製品概要](#1-製品概要)
2. [システム要件](#2-システム要件)
3. [ネットワーク要件](#3-ネットワーク要件)
4. [アーキテクチャ](#4-アーキテクチャ)
5. [Agent構築情報](#5-agent構築情報)
6. [バージョン情報・参考リンク](#6-バージョン情報参考リンク)

---

## 1. 製品概要

### Collibra DQ とは

Collibra Data Quality & Observability Classic（以下 Collibra DQ）は、**MLおよびデータサイエンス技術を活用した自動データ品質管理ソリューション**。

- **ルール不要の自動品質評価**: データセットを観察・学習することでデータ品質を自動評価。従来は数ヶ月かかるデータ品質問題の検出を数分で完了
- **機械学習による異常検知**: データの統計的特性を自動学習し、品質劣化を自動検出
- **分散コンピュート対応**: Apache Spark を基盤とした高速・大規模データ処理

### 主な機能

| 機能カテゴリ | 概要 |
|-------------|------|
| **データ品質チェック** | ルールベース・ML両方のデータ品質ルール評価 |
| **オブザーバビリティ** | データパイプライン全体の品質状態を継続的に可視化 |
| **品質スコアリング** | データセットごとのDQスコアを算出、Collibra Platform に同期可能 |
| **異常検知** | ML層による統計的異常の自動検出 |
| **レポーティング** | ジョブ実行結果・検出結果のダッシュボード表示 |

### エディション

| エディション | 特徴 |
|-------------|------|
| **Classic (self-hosted)** | オンプレミスまたはプライベートクラウドに自社管理でインストール。本レポートの対象 |
| **SaaS** | Collibra 管理のクラウドサービス。インフラ管理不要 |

> **参照**: [Data Quality & Observability Classic (self-hosted)](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/to_data-quality-and-observability-classic.htm)

---

## 2. システム要件

### 対応オペレーティングシステム

- Red Hat Enterprise Linux (RHEL) **8.x**
- Red Hat Enterprise Linux (RHEL) **9.x**

> Azure 上での構築時は RHEL イメージの VM または AKS（Azure Kubernetes Service）を使用する。

### ハードウェア要件

| 規模 | 総CPU | 総RAM | DQ Web | PostgreSQL | Spark Worker |
|------|-------|-------|--------|------------|--------------|
| **小規模** | 16コア | 128 GB | 2 GB / 2コア | 2 GB / 2コア | 100 GB / 10コア |
| **中規模** | 32コア | 256 GB | 2 GB / 2コア | 2 GB / 2コア | 250 GB / 26コア |
| **大規模** | 64コア | 512 GB | 2 GB / 2コア | 2 GB / 2コア | 486 GB / 54コア |

### ソフトウェア要件

| ソフトウェア | バージョン | 備考 |
|-------------|-----------|------|
| **Java** | 17 | 2026.02以降は必須（旧バージョン非対応） |
| **PostgreSQL** | 11.9以上（テスト済み）<br>**13以上（推奨）**<br>17まで検証済み | 外部メタストアとして使用推奨。Kubernetes環境では 100GB PVC 以上を確保 |
| **Apache Spark** | 4.1.0（2026.02以降）<br>3.5.6（2025.08〜2026.01） | Kubernetes 構成では Helm チャートで管理 |
| **Kubernetes** | 1.29 〜 1.34 | AKS, EKS, GKE, OpenShift, Rancher 対応 |

### 追加設定

- **ULIMIT**: 4096以上を推奨  
  - DQ サービスは約 428スレッドを消費
  - DQ ジョブ1件につき追加で約 400スレッド消費
  - ULIMIT 4096 では同時約9ジョブが上限
- **データ制限**: 1ジョブで 2TB を超えるデータは削減処理が必要

> **参照**: [System requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm)

---

## 3. ネットワーク要件

### ポート一覧

| ポート番号 | プロトコル | コンポーネント | 用途 |
|-----------|----------|--------------|------|
| **9000** | TCP | DQ Web | Web UI / REST API（外部からのアクセスが必要） |
| **9101** | TCP | DQ Agent | ヘルスチェック API（内部監視用） |
| **5432** | TCP | PostgreSQL MetaStore | DQ Web・DQ Agent・Spark からのメタストア接続 |
| **443** | TCP | 外部データソース | JDBC/HTTPS 経由でのデータソース接続 |

> **補足**: Kubernetes 環境では **DQ Web（ポート 9000）のみ**外部からのアクセスが必要。DQ Agent・MetaStore はクラスタ内部通信のみ。

### コンポーネント間の通信フロー

```
外部クライアント（ブラウザ / API）
        │ HTTPS :9000
        ▼
    DQ Web
        │ PostgreSQL :5432
        ▼
  PostgreSQL MetaStore ◀──── DQ Agent（5秒ポーリング :5432）
                                    │
                             Spark ジョブ投入
                                    │
                              Apache Livy
                                    │
                           Spark クラスタ（Pod）
                                    │ JDBC :443
                           データソース（DB等）
```

### Kubernetes 環境（AKS）でのネットワーク設計

| 通信経路 | 方式 | 備考 |
|---------|------|------|
| 外部 → DQ Web | LoadBalancer Service または Ingress | AKS では Azure Load Balancer / Application Gateway を使用 |
| DQ Agent → MetaStore | ClusterIP Service（内部通信） | 外部公開不要 |
| DQ Web → MetaStore | ClusterIP Service（内部通信） | 外部公開不要 |
| DQ → Azure DB for PostgreSQL | VNet 統合 / Private Endpoint | パブリック接続は非推奨 |
| Edge → データソース | VNet ピアリング / Private Link | データソースが別 VNet にある場合 |

### ファイアウォール・NSG 設定の指針

| ルール | 方向 | ポート | 用途 |
|--------|------|--------|------|
| 許可（受信） | Inbound | 9000/TCP | Web UI・API へのアクセス |
| 許可（送信） | Outbound | 5432/TCP | PostgreSQL への接続 |
| 許可（送信） | Outbound | 443/TCP | データソース・Collibra Platform への接続 |
| 拒否（受信） | Inbound | 9101/TCP | Agent ヘルスチェックは内部のみ（外部公開不要） |

> **参照**: [System requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm)

---

## 4. アーキテクチャ


### コンポーネント構成

| コンポーネント | 役割 |
|--------------|------|
| **DQ Web** | ユーザーインターフェース（UI）および REST API エンドポイントを提供 |
| **DQ Agent** | DQ ジョブのオーケストレーション。5秒ごとにメタストアをポーリングして割り当てジョブを実行 |
| **PostgreSQL Metastore** | メタデータ・ジョブ情報・検出結果を永続化するメタデータストア |
| **Apache Spark** | 分散コンピュート基盤。スタンドアロンまたはKubernetesクラスタ上で動作 |
| **Apache Livy** | Spark セッションマネージャー。REST経由でSparkジョブを投入 |
| **Edge** | データソース接続・認証管理。k3s バンドルまたはマネージド Kubernetes 上に展開 |

### デプロイメント構成

#### パターン1: スタンドアロン構成

```
┌─────────────────────────────────────┐
│           Single VM / Node          │
│                                     │
│  ┌─────────┐  ┌──────────────────┐  │
│  │ DQ Web  │  │   DQ Agent       │  │
│  └─────────┘  └──────────────────┘  │
│  ┌──────────┐  ┌────────────────┐   │
│  │PostgreSQL│  │ Spark Standalone│  │
│  │Metastore │  │ (Master+Worker) │  │
│  └──────────┘  └────────────────┘   │
└─────────────────────────────────────┘
```

- Spark のマスターとワーカーが同一サーバーで動作する疑似クラスタ構成
- 小〜中規模の環境、高並行チェックが不要な場合に適している

#### パターン2: Kubernetes ネイティブ構成（推奨）

```
┌───────────────────────────────────────────────┐
│              AKS Cluster (Azure)               │
│                                                │
│  ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
│  │  DQ Web  │ │ DQ Agent │ │  Spark Pods   │  │
│  │  (Pod)   │ │  (Pod)   │ │  (動的スケール) │  │
│  └──────────┘ └──────────┘ └───────────────┘  │
│  ┌────────────────────────────────────────┐    │
│  │  PostgreSQL (外部 or Azure Database)   │    │
│  └────────────────────────────────────────┘    │
└───────────────────────────────────────────────┘
```

- Helm チャートを使用して一括デプロイ
- マイクロサービスアーキテクチャによる水平スケーラビリティ
- Azure では **AKS（Azure Kubernetes Service）** を使用

**Kubernetes コンポーネント最小リソース要件**:

| コンポーネント | CPU | メモリ | PVC（永続ストレージ） |
|--------------|-----|--------|-------------------|
| DQ Web | 1コア | 2 GB | 10 MB |
| DQ Agent | 1コア | 1 GB | 100 MB |
| PostgreSQL MetaStore | 1コア | 2 GB | **100 GB以上** |
| Spark（ワーカー Pod） | 2コア | 2 GB | — |

**Helm デプロイコマンド例**:

```bash
helm upgrade --install --namespace <namespace> \
  --set global.version.dq=<version> \
  --set global.image.repo=<repo> \
  <deployment-name> <helm-chart-path>
```

### Integration アーキテクチャ（Collibra Platform との連携）

```
Collibra DQ Classic  ──Integration API──▶  Collibra Platform
       │
    Edge (k3s / AKS)
       │
  データソース（DB / ファイルストレージ等）
```

| 連携要素 | 概要 |
|---------|------|
| **Integration Control Panel** | Collibra Platform との初期セットアップを管理 |
| **Integration API** | DQ ルール・ML検出結果・DQ スコアを Collibra Platform にリアルタイム送信 |
| **前提条件** | Collibra Platform に Sysadmin・DataSteward ロールが必要。両製品が 2023.05以上であること |

> **参照**: [Integration architecture](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Integrations/ref_integration-architecture.htm)  
> **参照**: [Installing on self-hosted Kubernetes](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/to_dq-cloud-native.htm)

---

## 5. Agent構築情報

### DQ Agent の役割

- DQ ジョブのオーケストレーションコンポーネント
- **5秒ごと**に PostgreSQL メタストアをポーリングし、割り当てジョブを検出して実行
- ジョブを Spark ジョブ（ローカルまたはクラスタ上）として投入

| 管理項目 | 説明 |
|---------|------|
| Agent ID | 自動生成される一意の数値識別子（編集不可） |
| Agent Name | 自動生成される一意の名称（編集不可） |
| Agent Display Name | カスタマイズ可能な表示名。英数字・ハイフン・アンダースコア推奨 |
| Agent Status | **Online**（利用可）/ **Offline**（利用不可） |
| 実行中ジョブ数（Open Jobs） | 実行中のジョブ数。クリックで詳細確認可能 |

> **参照**: [Agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Agent.htm)  
> **参照**: [Agent Configuration](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQAdmin/co_agent-configuration.htm)

---

### REST API

Collibra DQ は 2種類の REST API を提供する。

| API タイプ | 用途 | 安定性 |
|-----------|------|--------|
| **Product API（公式）** | 本番環境向けの標準インターフェース | 安定（変更通知あり） |
| **Internal API** | すべての機能を公開 | 非推奨（仕様変更の可能性あり） |

#### 認証

JWT トークンによる認証。

```http
POST /auth/signin
Content-Type: application/json

{
  "username": "<ユーザー名>",
  "password": "<パスワード>",
  "issuerCredentials": "<発行者情報>"
}
```

レスポンスで取得した JWT トークンを以降のリクエストの Authorization ヘッダーに付与する。

#### 主要エンドポイント

| 操作 | メソッド | エンドポイント | 説明 |
|------|---------|--------------|------|
| **認証** | POST | `/auth/signin` | JWT トークン取得 |
| **データセット作成** | POST | `/v3/datasetDefs/` | データセット定義の新規作成 |
| **データセット更新** | PUT | `/v3/datasetDefs/` | データセット定義の更新 |
| **ジョブ実行** | POST | `/v3/jobs/run/{dataset},{runDate}` | DQ チェックジョブを実行 |
| **ステータス確認** | GET | `/v3/jobs/{jobId}/status` | ジョブの進捗・状態を確認 |
| **結果取得** | GET | `/v3/jobs/{jobId}/findings` | データ品質検出結果を取得 |

#### SDK の自動生成

Swagger 仕様から Python・Java・Scala・C# 等のクライアントライブラリを自動生成できる。

1. 以下の URL から Swagger 仕様（JSON）を取得する:
   ```
   https://<host>/v2/api-docs?group=Product%20API
   ```
2. [Swagger Editor](https://editor.swagger.io) を開き、取得した JSON をインポート
3. **Generate Client** から対象言語を選択してライブラリを生成

> **参照**: [Rest APIs](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQApis/to_rest-apis.htm)

---

### Integration API（Collibra Platform 統合）

DQ ルール・ML検出結果・DQ スコアを Collibra Platform にリアルタイム送信するための API。

**前提条件**:
- Collibra Platform アカウントに **Sysadmin** および **DataSteward** のグローバルロールが必要
- Collibra Platform・Collibra DQ ともに **2023.05以上**

**利点**:
- Collibra Platform 内でリアルタイムに品質メトリクスとスコアが更新される
- Edge コンポーネントへの依存なしで統合可能

> **参照**: [Integration API](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQApis/to_dgc-integrations-api.htm)

---

### Edge コンポーネント（データソース接続）

データソース接続・認証管理を担当するコンポーネント。

| 項目 | 内容 |
|------|------|
| **展開方式** | k3s バンドル または マネージド Kubernetes（AKS 等） |
| **DQ Connector** | Edge 上で動作し、JDBC 経由でデータソースにアクセス |
| **データソース接続** | 各データソース接続に Catalog JDBC 取り込み Edge capability テンプレートが必要 |

---

### Azure / AKS 上での構築における注意点

| 項目 | 推奨対応 |
|------|---------|
| **Kubernetes** | AKS（Kubernetes 1.29〜1.34 に対応）を使用 |
| **PostgreSQL** | Azure Database for PostgreSQL を外部メタストアとして利用 |
| **ストレージ** | Spark の作業領域として Azure Disk / Azure Files を使用 |
| **ネットワーク** | Edge コンポーネントからデータソースへの通信経路を設計（VNet ピアリング等） |
| **Java バージョン** | コンテナイメージに Java 17 が含まれていることを確認 |

---

## 6. バージョン情報・参考リンク

### 最新バージョン

- **2026.02-ABDGCSHILM-4223**

### ビルド命名規則

```
2024.01 - ABDGCSHILM - 1234
  │              │        └─ ビルド識別番号
  │              └───────── 含まれるオプションドライバーの頭文字
  └──────────────────────── リリース番号（年.月）
```

### デフォルト同梱ドライバー（常に含まれる）

SQL Server, Oracle, Snowflake, Redshift, S3, ADLS, PostgreSQL, MySQL, Teradata, Sybase, Db2, Dremio

### オプションドライバー（コンテナ版のみ）

Athena, BigQuery, Databricks, Google Cloud Storage, Hive, Impala, Livy, MongoDB, Hudi

### 参考ドキュメントリンク

| ドキュメント | URL |
|------------|-----|
| 製品概要 | [Data Quality & Observability Classic](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/to_data-quality-and-observability-classic.htm) |
| システム要件 | [System requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm) |
| Integration アーキテクチャ | [Integration architecture](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Integrations/ref_integration-architecture.htm) |
| Agent インストール | [Agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Agent.htm) |
| Agent 設定 | [Agent Configuration](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQAdmin/co_agent-configuration.htm) |
| REST API | [Rest APIs](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQApis/to_rest-apis.htm) |
| Integration API | [Integration API](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQApis/to_dgc-integrations-api.htm) |
| Kubernetes インストール | [Installing on self-hosted Kubernetes](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/to_dq-cloud-native.htm) |
| ビルド情報 | [Builds](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Builds.htm) |
| アップグレード手順 | [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) |
