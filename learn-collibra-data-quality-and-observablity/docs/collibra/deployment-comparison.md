# Collibra DQ デプロイメント構成比較

> **作成日**: 2026-04-14  
> **対象バージョン**: 2026.02

---

## 目次

1. [前提・スコープ整理](#1-前提スコープ整理)
2. [オンプレ k3s の位置づけ](#2-オンプレ-k3s-の位置づけ)
3. [スタンドアロン vs Kubernetes ネイティブ 比較表](#3-スタンドアロン-vs-kubernetes-ネイティブ-比較表)
4. [各構成のデプロイ概念図](#4-各構成のデプロイ概念図)
5. [構成選定フロー・推奨まとめ](#5-構成選定フロー推奨まとめ)

---

## 1. 前提・スコープ整理

### 担当コンポーネントの分担

DQ Web と Metastore はグループ会社の既存環境を共用するため、**自社が構築・運用するのは Agent と Spark のみ**。

| コンポーネント | 担当 | 備考 |
|-------------|------|------|
| DQ Web | グループ会社（既存） | UI・API エンドポイント。自社では構築しない |
| Metastore（PostgreSQL） | グループ会社（既存） | 別テナント・Azure US リージョン。Private Endpoint 経由で接続 |
| **DQ Agent** | **自社（今回の対象）** | ジョブのオーケストレーション（5秒ポーリング） |
| **Spark** | **自社（今回の対象）** | データ品質チェックの分散処理実行基盤 |

### Agent と Spark の関係

```
グループ会社（既存）                自社（今回構築）
┌──────────────────┐    ジョブ割当    ┌──────────────────────────────┐
│  DQ Web          │ ─────────────▶ │  DQ Agent                    │
│  (UI / REST API) │                │  (Metastore を5秒ポーリング)   │
│                  │                │         │ Spark ジョブ投入      │
│  Metastore       │ ◀── 結果書込 ── │         ▼                    │
│  (PostgreSQL)    │                │  Spark クラスタ                │
│  ※Private EP     │                │  (データ品質チェック実行)        │
└──────────────────┘                └──────────────────────────────┘
         ↕ Private Endpoint（クロステナント）
```

> **本比較資料は Agent + Spark のデプロイ方式に絞って比較する。**

---

## 2. オンプレ k3s の位置づけ

### 公式サポート状況

| Kubernetes プロバイダー | 公式サポート |
|----------------------|:----------:|
| AKS / EKS / GKE | ✓ 明示的にサポート対象 |
| OpenShift / Rancher | ✓ サポート対象として記載あり |
| **k3s（オンプレ）** | **✗ 公式ドキュメントに記載なし** |

> **公式ドキュメントの注記（2つ）**:
> - *"Support for Collibra DQ cloud native deployment is limited to deployments using the containers provided from the Collibra container registry."*
> - *"The Helm deployment is unique for each customer and Collibra Support may be limited."*

### オンプレで k3s を使うことが非推奨の理由

| 観点 | 内容 |
|------|------|
| **サポート対象外** | k3s は公式サポートプロバイダーに含まれない。Collibra サポートに問い合わせできないリスクがある |
| **運用コスト増** | k3s クラスター自体の構築・バージョン管理・障害対応をすべて自社で担う。コントロールプレーンの自己管理が必要 |
| **メリット薄い** | スタンドアロンに比べた複雑さに見合うメリット（スケール・可用性）が、クラウドマネージドと比べると大幅に低い |
| **互換性管理** | k3s のバージョンと Collibra DQ 対応 Kubernetes バージョン（1.29〜1.34）の整合性を継続的に自社で確認・管理が必要 |

### 結論

> オンプレにデプロイするなら **スタンドアロンが最も現実的**。  
> Kubernetes ネイティブを採用するなら、公式サポート対象の **クラウドマネージド（AKS/EKS/GKE）** を選ぶこと。

---

## 3. スタンドアロン vs Kubernetes ネイティブ 比較表

※ Agent + Spark のデプロイスコープで比較

| 比較項目 | スタンドアロン（RHEL VM） | Kubernetes ネイティブ（AKS 等） |
|---------|:--------------------:|:---------------------------:|
| **対象環境** | オンプレ / クラウド VM | クラウドマネージド Kubernetes |
| **インフラ複雑度** | ★☆☆ 低い | ★★★ 高い |
| **必要スキル** | Linux / Java / Spark | Linux + Kubernetes + Helm + Azure |
| **初期構築コスト** | 低い | 高い |
| **運用管理コスト** | 中（OS・JVM プロセス管理） | 低（クラウドに委譲できる部分が多い） |
| **Spark スケール** | 垂直スケール（VM サイズアップ）のみ | 水平スケール（Pod 自動追加）対応 |
| **Agent 冗長化** | 追加 VM が必要 | `replicaCount` を増やすだけ |
| **Spark 冗長化** | 追加 VM + Standalone クラスタ設定 | Kubernetes が自動で再スケジュール |
| **メタストア接続** | `owl.properties` に JDBC 直書き | Helm values / Kubernetes Secret で管理 |
| **アップグレード** | JAR 差し替え → 手動再起動 | `helm upgrade` → ローリング更新 |
| **ロールバック** | 旧 JAR に戻して手動再起動 | `helm rollback` 1 コマンド |
| **デプロイ設定管理** | ファイル（`owl.properties` / `agent.properties`） | YAML（`values.yaml`）で IaC 管理可 |
| **セキュリティパッチ** | OS・JVM を個別に手動管理 | AKS ノード OS は自動管理（設定次第） |
| **Defender 統合** | Defender for Servers | Defender for Containers（より高機能） |
| **コスト構造** | VM 費用のみ | AKS + ノード VM + ACR 等の費用 |
| **Collibra サポート** | 完全サポート | 完全サポート（Helm カスタムは限定的） |

---

## 4. 各構成のデプロイ概念図

### スタンドアロン構成（Agent + Spark のみ）

```
┌─────────────────────────────────────────────────────┐
│               RHEL VM（Agent + Spark 専用）           │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  DQ Agent（owlmanage.sh で起動）               │   │
│  │  ・5秒ごとに Metastore をポーリング             │   │
│  │  ・ジョブを Spark に投入                       │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Spark Standalone（Master + Worker）           │   │
│  │  ・Agent から受けたジョブを実行                  │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
        │ JDBC（Private Endpoint 経由）
        ▼
  グループ会社 Metastore（別テナント・Azure US）
```

**デプロイコマンド**:

```bash
# Agent のみインストール（DQ Web・PostgreSQL はスキップ）
./setup.sh \
  -owlbase=$OWL_BASE \
  -options=spark,owlagent \
  -pgserver="<metastore-host>:5432/<db>"
```

**接続設定（owl.properties）**:

```properties
# グループ会社の Metastore への接続
spring.agent.datasource.url=jdbc:postgresql://<metastore-host>:5432/owlmetastore\
  ?currentSchema=public&sslmode=require
spring.agent.datasource.username=<USER>
spring.agent.datasource.password=<ENCRYPTED_PASSWORD>
```

---

### Kubernetes ネイティブ構成（Agent + Spark のみ、AKS）

```
┌──────────────────────────────────────────────────────────┐
│                    AKS クラスター                          │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐  │
│  │  DQ Agent (Pod × 2)  │  │  Spark Worker (Pod × n)  │  │
│  │  ・Metastore ポーリング │  │  ・動的スケール            │  │
│  │  ・Spark ジョブ投入    │  │  ・ジョブ完了後に縮退      │  │
│  └──────────────────────┘  └──────────────────────────┘  │
│                                                          │
│  ← owl-web.enabled: false / metastore.enabled: false →  │
└──────────────────────────────────────────────────────────┘
        │ Private Endpoint（クロステナント）
        ▼
  グループ会社 Metastore（別テナント・Azure US）
```

**Helm デプロイコマンド**:

```bash
helm upgrade --install collibra-dq ./dq \
  --namespace collibra-dq \
  --values ./values.yaml
```

**values.yaml（Agent + Spark のみ有効化）**:

```yaml
# ---- 自社担当外のコンポーネントは無効化 ----
metastore:
  enabled: false     # グループ会社の既存 Metastore を使用

owl-web:
  enabled: false     # グループ会社の既存 DQ Web を使用

# ---- 自社担当コンポーネント ----
owl-agent:
  enabled: true
  replicaCount: 2
  env:
    - name: METASTORE_URL
      value: "jdbc:postgresql://<metastore-host>:5432/owlmetastore\
              ?currentSchema=public&sslmode=require"
    - name: METASTORE_USER
      valueFrom:
        secretKeyRef:
          name: dq-secrets
          key: metastore_user
    - name: METASTORE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: dq-secrets
          key: metastore_password

spark:
  enabled: true
  replicas: 3
  resources:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "4"
      memory: "8Gi"
```

---

## 5. 構成選定フロー・推奨まとめ

### 判断フロー

```
Q1: 導入環境はオンプレ？ クラウド（Azure）？
│
├─ オンプレミス
│     │
│     └─ → ★ スタンドアロン推奨
│           （k3s は非推奨。OpenShift/Rancher があれば検討可）
│
└─ クラウド（Azure）
      │
      Q2: 将来的に Spark のスケールアウト・高可用性が必要か？
      │
      ├─ Yes → ★ Kubernetes ネイティブ（AKS）推奨
      │
      └─ No（PoC・小規模）
            │
            ├─ 早期検証優先 → スタンドアロン（クラウド VM）
            └─ 本番想定・将来拡張 → Kubernetes ネイティブ（AKS）
```

### 推奨まとめ

| シナリオ | 推奨構成 | 理由 |
|---------|---------|------|
| オンプレ 中小規模 | **スタンドアロン** | 最も低コスト・完全サポート・構築が早い |
| オンプレ 大規模 | スタンドアロン（複数 VM）または OpenShift | k3s は非推奨 |
| **オンプレ k3s** | **非推奨** | 公式サポート対象外。障害時の切り分けリスク大 |
| クラウド（Azure）PoC | スタンドアロン（VM） | 構築が早く検証しやすい |
| **クラウド（Azure）本番** | **Kubernetes ネイティブ（AKS）** | スケール・可用性・運用自動化のメリット大 |

### 本プロジェクトの結論

> **AKS による Kubernetes ネイティブ構成を推奨する。**

本プロジェクトは以下の条件をすべて満たすため、AKS が最適：

- ✓ Azure 基盤（Hub-Spoke / ExpressRoute 構成）にすでに合わせた設計
- ✓ Agent + Spark のみのシンプルなスコープ（DQ Web・Metastore は不要）
- ✓ Defender for Containers・自動アップグレード等の運用設計が AKS と親和性が高い
- ✓ Spark のスケールアウト（将来的なデータ増加に対応）
- ✓ Helm による IaC 管理・ロールバックが容易
