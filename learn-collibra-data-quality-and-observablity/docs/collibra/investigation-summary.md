# Collibra DQ 事前調査まとめ

> **作成日**: 2026-04-17
> **対象バージョン**: Collibra DQ 2026.02
> **ステータス**: 事前調査フェーズ完了

---

## 目次

1. [プロジェクト概要・スコープ](#1-プロジェクト概要スコープ)
2. [採用構成の決定](#2-採用構成の決定)
3. [システム要件（確定値）](#3-システム要件確定値)
4. [ネットワーク設計（確定値）](#4-ネットワーク設計確定値)
5. [コスト試算](#5-コスト試算)
6. [制約事項サマリー](#6-制約事項サマリー)
7. [今後の作業](#7-今後の作業)

---

## 1. プロジェクト概要・スコープ

### 担当コンポーネントの分担

DQ Web と Metastore はグループ会社の既存環境を共用するため、**自社が構築・運用するのは Agent と Spark のみ**。

| コンポーネント | 担当 | 備考 |
|---|---|---|
| DQ Web | グループ会社（既存） | UI・API エンドポイント。自社では構築しない |
| Metastore（PostgreSQL） | グループ会社（既存） | 別テナント・Azure US リージョン。Private Endpoint 経由で接続 |
| **DQ Agent** | **自社（今回の対象）** | ジョブのオーケストレーション（5秒ポーリング） |
| **Spark** | **自社（今回の対象）** | データ品質チェックの分散処理実行基盤 |

### システム全体像

```
グループ会社（既存）                         自社（今回構築）
┌─────────────────────┐                  ┌──────────────────────────────┐
│  DQ Web             │ ─── ジョブ割当 ──▶ │  Azure VM（E16s_v5）           │
│  (UI / REST API)    │                  │                              │
│                     │                  │  DQ Agent                    │
│  Metastore          │ ◀── 結果書込 ───── │  （Metastore を5秒ポーリング）  │
│  (PostgreSQL)       │                  │         │ Spark ジョブ投入      │
│  ※Private EP        │                  │         ▼                    │
└─────────────────────┘                  │  Spark Standalone            │
         ↕ Private Endpoint              │  （Master + Worker）           │
         （クロステナント、Azure US）        └──────────────────────────────┘
                                                  │ JDBC
                                                  ▼
                                         オンプレ DB（ExpressRoute 経由）
```

---

## 2. 採用構成の決定

### 採用: Standalone（Azure VM）

| 理由 | 詳細 |
|---|---|
| **構築コスト最小** | Kubernetes 不要。Linux / Java / Spark の標準スキルで構築可能 |
| **コスト最安** | 月額 ¥141,611（三構成中最安。AKS 比 −¥11,819/月） |
| **Collibra 完全サポート対象** | スタンドアロン構成は公式に完全サポート |
| **スコープに適合** | Agent + Spark のみの小規模スコープで Kubernetes の複雑さは不要 |
| **運用シンプル** | systemd + テキストファイル（`owl.properties`）操作のみ |

### 比較検討の結果

| 構成 | 月額コスト | 採用可否 | 不採用理由 |
|---|---|:---:|---|
| **Standalone（Azure VM）** | **¥141,611** | **✓ 採用** | — |
| AKS（Kubernetes ネイティブ） | ¥153,430 | ✗ | 構築・運用コスト増。スコープに対して過剰 |
| ARO（OpenShift） | ¥461,416 | ✗ | コスト約3.3倍。OpenShift の必要性なし |
| オンプレ k3s | — | ✗ | Collibra 公式サポート対象外 |

---

## 3. システム要件（確定値）

### ソフトウェア要件

| 項目 | 確定値 | 備考 |
|---|---|---|
| **製品バージョン** | 2026.02-ABDGCSHILM-4223 | 最新リリース |
| **対応 OS** | RHEL 8.x / 9.x | Ubuntu・CentOS は非サポート |
| **Java** | Java 17 | 2026.02 以降は必須。Java 8/11 は非対応 |
| **Spark** | 4.1.0 | 2026.02 同梱バージョン |
| **PostgreSQL（Metastore）** | 13 以上（17 まで検証済み） | グループ会社管理のため要確認 |

> **出典**:
> - [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) — OS / Java / Spark バージョン対応表
> - [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm) — インストール前提条件

### ハードウェア要件（VM スペック）

| 項目 | 確定値 | 備考 |
|---|---|---|
| **VM SKU** | Standard_E16s_v5 | 16 vCPU / 128 GB RAM |
| **OS Disk** | Premium SSD P10（128 GB） | OS 領域 |
| **Data Disk** | Premium SSD P20（512 GB） | ログ・Spark 一時領域 |
| **ULIMIT** | 4096 以上（必須） | デフォルト 1024 では動作不可 |

> **出典**: [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) — ティア別スペック表（Small Tier: 16コア / 128 GB RAM、ULIMIT 4096 以上）

### 同時ジョブ上限（E16s_v5 + ULIMIT 4096）

```
ULIMIT ベース: (4096 - 428) / 400 ≒ 9 ジョブ
RAM ベース:    (128 / 28) - 1 ≒ 4 ジョブ
→ 小さい方が制約: 実質 約 4 ジョブ が上限
```

### 同梱 JDBC ドライバー（デフォルト）

SQL Server, Oracle, Snowflake, Redshift, S3, ADLS, PostgreSQL, MySQL, Teradata, Sybase, Db2, Dremio

---

## 4. ネットワーク設計（確定値）

### ポート要件

| コンポーネント | ポート | 方向 | 備考 |
|---|---|---|---|
| DQ Agent | 9101 (TCP) | 内部のみ | 外部公開不要 |
| DQ Web（グループ会社） | 9000 (TCP) | 外部 | 自社構築外 |
| Metastore | 5432 (TCP) | 内部 | Private Endpoint 経由 |
| データソース（JDBC） | 443 (HTTPS) | アウトバウンド | ExpressRoute 経由でオンプレ接続 |

> **出典**: [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) — ネットワークポート一覧（9101: Health Check API、9000: DQ Web、5432: Metastore、443: データソース接続）

### 接続経路

```
[自社 Azure VM]
    │
    ├─ Metastore への接続
    │     → Private Endpoint（クロステナント）→ グループ会社 Metastore（Azure US）
    │
    └─ オンプレ DB への接続
          → ExpressRoute（全社共有）→ オンプレ DB
             ⚠️ 帯域逼迫リスクあり（詳細: todo-qa.md A-1〜A-3）
```

### 設定ファイル構成

Standalone 環境では **2種類の設定ファイル** を使い分ける。

| ファイル | パス | 役割 |
|---|---|---|
| `owl-env.sh` | `$OWL_BASE/owl/config/` | 環境変数定義。JVM オプション・DB 接続 URL・SSL 設定など起動時パラメータ |
| `owl.properties` | `$OWL_BASE/owl/config/` | アプリケーション設定。ライセンスキー・Agent DB 接続・詳細チューニング |

#### `owl-env.sh` の主要設定例

```bash
# DQ Web → Metastore 接続（グループ会社 Metastore を参照）
export SPRING_DATASOURCE_URL="jdbc:postgresql://<metastore-host>:5432/postgres?sslmode=require"

# HTTPS 有効化
export SERVER_HTTPS_ENABLED=true

# JVM ヒープ調整（メモリ不足時）
export EXTRA_JVM_OPTIONS="-Xms2g -Xmx2g"

# ローカルパスのアクセス許可
export ALLOWED_LOCAL_PATHS='*'
```

#### `owl.properties` の主要設定例

```properties
# ライセンスキー
key=<LICENSE_KEY>

# DQ Agent → グループ会社 Metastore への接続
spring.agent.datasource.url=jdbc:postgresql://<metastore-host>:5432/owlmetastore\
  ?currentSchema=public&sslmode=require
spring.agent.datasource.username=<USER>
spring.agent.datasource.password=<ENCRYPTED_PASSWORD>
```

> **出典**:
> - [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) — `owl-env.sh` / `owl.properties` の全パラメータ一覧
> - [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) — Agent 設定手順（パスワード暗号化 `owlmanage.sh encrypt`、Admin Console 設定）
> - [Complete initial setup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) — ライセンスキー設定・Spark Master URL 取得手順

---

## 5. コスト試算

### 月額内訳（Pay-as-you-go）

| # | コンポーネント | リソース | 月額（JPY） |
|---|---|---|---|
| 1 | DQ VM | Standard_E16s_v5 × 1 | ¥131,371 |
| 2 | OS Disk | Premium SSD P10（128 GB） | ¥2,529 |
| 3 | Data Disk | Premium SSD P20（512 GB） | ¥7,546 |
| 4 | ネットワーク（アウトバウンド 10 GB/月） | — | ¥165 |
| **合計** | | | **¥141,611/月** |

> Metastore（PostgreSQL）はグループ会社環境を利用するため、本試算に含まない。

### コスト削減オプション

| オプション | 月額（JPY） | 5年総額（JPY） | 削減率 |
|---|---|---|---|
| **従量課金（現状）** | **¥141,611** | **¥8,496,660** | 基準 |
| **Reserved Instance 1年** | **¥94,317** | **¥5,659,020** | −33% |
| Reserved Instance 3年 | ¥63,484（目安） | ¥3,809,040（目安） | −55% |

> 価格は 2025年8月時点の Azure 公式価格（Japan East・JPY）。最新価格は Azure 料金計算ツールで確認すること。

---

## 6. 制約事項サマリー

### リソース・スケール

| 制約 | 内容 |
|---|---|
| **同時ジョブ上限** | E16s_v5 + ULIMIT 4096 の場合: 約 4 ジョブ（RAM 制約が支配的） |
| **1ジョブあたりデータサイズ** | 最大 2 TB（Collibra 公式制約） |
| **スケール方式** | 垂直スケール（VM サイズアップ）のみ。水平スケールアウト不可 |
| **スケール時ダウンタイム** | VM Deallocate → Resize → 起動 の間、DQ Agent・Spark が停止 |

### 運用・メンテナンス

| 制約 | 内容 |
|---|---|
| **アップグレード方式** | `owlmanage.sh stop=owlweb` / `stop=owlagent` → 旧 JAR を `/tmp` へ退避 → 新 JAR を配置 → サービス再起動。ローリング更新不可 |
| **アップグレード時のダウンタイム** | 必ず発生。DQ Metastore バックアップが**公式必須**（外部 Metastore のためグループ会社への依頼が必要）。VM Disk Snapshot も追加で推奨 |
| **ロールバック** | ⚠️ **公式非サポート**。バックアップからの復元のみ対応可 |

> **引用** (出典: [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm)):
> "Rolling back Collibra DQ to an older version is not supported."
>
> **出典**:
> - [Create a backup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_create-backup.htm) — アップグレード前バックアップ手順（外部 Metastore は PostgreSQL 公式手順に従う）
> - [Prepare environment for upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_prepare-environment-for-upgrade.htm) — アップグレード前チェックリスト
> - [Troubleshooting upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/co_troubleshooting-upgrade.htm#tab-Standalone) — アップグレード後の既知問題と対処法（Standalone タブ）

### ネットワーク

| 制約 | 内容 |
|---|---|
| **ExpressRoute 帯域逼迫リスク** | スキャン時に最大 2 TB のデータが ExpressRoute（全社共有）を流れる |
| **対策（フェーズ1）** | サンプリング設定 + 深夜スケジュール実行 |
| **対策（フェーズ2）** | Azure Monitor で帯域監視 + 閾値超過時の自動停止 |

---

## 7. 今後の作業

確認・検討が必要な事項は [todo-qa.md](./todo-qa.md) を参照。

| カテゴリ | 確認先 | 優先度 |
|---|---|---|
| ExpressRoute 帯域・スキャン対象 DB の確定 | 社内（ネットワーク部門 / 業務部門） | 高 |
| Metastore 接続情報・接続遅延の確認 | グループ会社 | 高 |
| ライセンスキー・インストーラーの受領フロー | Collibra（ベンダー） | 高 |
| アップグレード時の Metastore バックアップ取得フロー確認 | グループ会社（Metastore 管理者） | 中（アップグレード前に要合意） |

---

## 8. 参考ドキュメント

### 社内ドキュメント

| ドキュメント | パス |
|---|---|
| 詳細セットアップ手順 | [azure-vm-setup.md](./azure-vm-setup.md) |
| デプロイメント構成比較 | [deployment-comparison.md](./deployment-comparison.md) |
| 制約事項詳細 | [constraints-comparison.md](./constraints-comparison.md) |
| コスト試算詳細 | [cost-comparison.md](./cost-comparison.md) |
| 課題事項一覧 | [open-issues.md](./open-issues.md) |
| Todo QA 一覧 | [todo-qa.md](./todo-qa.md) |

### Collibra 公式ドキュメント（Standalone）

| ページ | URL | 参照セクション |
|---|---|---|
| トップ | [Data Quality & Observability Classic](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/to_data-quality-and-observability-classic.htm) | — |
| インストール前提条件 | [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm) | §3 ソフトウェア要件 |
| インストール手順 | [Install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm) | §4 設定ファイル |
| 初期セットアップ完了 | [Complete initial setup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) | §4 設定ファイル |
| 設定オプション一覧 | [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) | §4 設定ファイル |
| Spark スクリプト一覧 | [Spark scripts](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-spark-scripts.htm) | §4 設定ファイル |
| Agent 設定 | [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) | §4 設定ファイル |
| FIPS 設定 | [Configure FIPS](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-fips.htm) | （セキュリティ要件がある場合） |
| トラブルシューティング | [Troubleshooting](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-troubleshooting.htm) | — |
| アップグレード要件 | [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) | §3 システム要件、§6 制約事項 |
| アップグレード前準備 | [Prepare environment for upgrade](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_prepare-environment-for-upgrade.htm) | §6 運用・メンテナンス |
| バックアップ作成 | [Create a backup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_create-backup.htm) | §6 運用・メンテナンス |
| Spark アップグレード | [Upgrade Spark](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-spark.htm) | §6 運用・メンテナンス |
| DQ アップグレード手順 | [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) | §6 運用・メンテナンス |
| アップグレード後トラブルシューティング | [Troubleshooting upgrade (Standalone)](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/co_troubleshooting-upgrade.htm#tab-Standalone) | §6 運用・メンテナンス |
