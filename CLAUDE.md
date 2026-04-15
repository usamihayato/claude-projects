# CLAUDE.md

このファイルは Claude Code (claude.ai/code) がリポジトリで作業する際のガイダンスを提供します。

---

## 作業スタイル

- **応答は日本語で行う**
- **コードコメントも日本語で記述する**

---

## リポジトリ概要

このリポジトリは、テーマごとの独立した学習・調査プロジェクトを格納するモノレポ構成です。
ルート直下に各プロジェクトディレクトリを配置し、それぞれが独立した CLAUDE.md を持ちます。

```
claude-projects/
├── CLAUDE.md                                      ← 本ファイル（ルートガイダンス）
├── .claude/
│   └── settings.local.json                        ← Claude Code の権限設定
├── learn-oci/
│   └── oci-architect-associate/                   ← OCI 資格学習プロジェクト
│       ├── CLAUDE.md
│       └── docs/
│           ├── 01-global-infrastructure/
│           ├── 02-identity-and-access-management/
│           ├── 03-networking/
│           ├── 04-compute/
│           └── 05-storage/
└── learn-collibra-data-quality-and-observablity/  ← Collibra DQ 導入調査プロジェクト
    ├── CLAUDE.md
    └── docs/
        ├── collibra/
        │   ├── setup.md
        │   ├── deployment-comparison.md
        │   └── report.md
        └── kubernetes/
            ├── aks-build.md
            ├── aks-design.md
            └── helm.md
```

---

## プロジェクト構成

| ディレクトリ | 内容 | 主なトピック |
|---|---|---|
| `learn-oci/` | Oracle Cloud Infrastructure (OCI) 学習用プロジェクト | OCI 資格試験対策、インフラ設計 |
| `learn-collibra-data-quality-and-observablity/` | Collibra Data Quality & Observability 導入調査 | Azure/AKS 上での DQ Agent + Spark 構築 |

---

## 各プロジェクトの概要

### learn-oci/oci-architect-associate

**目的**: Azure 経験者が OCI 資格（Architect Associate / Professional）を取得するための学習ノート

**背景**:
- 担当者は Azure Administrator・Azure Infrastructure Solutions の資格を保有
- OCI プロジェクト参加に向けてスキルアップが必要

**ドキュメント構成** (`docs/` 配下):
| ディレクトリ | 内容 |
|---|---|
| `01-global-infrastructure/` | リージョン・AD・FD の概念、高可用性設計 |
| `02-identity-and-access-management/` | IAM、ポリシー、コンパートメント |
| `03-networking/` | VCN、サブネット、セキュリティリスト |
| `04-compute/` | インスタンス、シェイプ、ブートボリューム |
| `05-storage/` | オブジェクトストレージ、ブロックボリューム |

**参照先**: 2025年以降の最新 OCI 資格試験に対応した情報を使用すること

---

### learn-collibra-data-quality-and-observablity

**目的**: Collibra Data Quality & Observability Classic を社内導入するための事前調査・設計ドキュメント

**背景**:
- DQ Web・Metastore はグループ会社の既存環境を共用
- 自社が構築・運用するのは **DQ Agent** と **Spark** のみ
- 基盤は **Azure（AKS）** で検討中

**アーキテクチャの要点**:
```
グループ会社（既存）                自社（今回構築）
┌──────────────────┐    ジョブ割当    ┌────────────────────┐
│  DQ Web          │ ─────────────▶ │  DQ Agent          │
│  Metastore (PG)  │ ◀── 結果書込 ── │  Spark クラスタ     │
└──────────────────┘                └────────────────────┘
         ↕ Private Endpoint（クロステナント）
```

**ドキュメント構成** (`docs/` 配下):
| ファイル | 内容 |
|---|---|
| `collibra/setup.md` | スタンドアロン・AKS インストール手順、設定ファイルリファレンス |
| `collibra/deployment-comparison.md` | スタンドアロン vs Kubernetes ネイティブの比較表・推奨構成 |
| `collibra/report.md` | 調査レポート |
| `kubernetes/aks-design.md` | AKS クラスター設計 |
| `kubernetes/aks-build.md` | AKS 構築手順 |
| `kubernetes/helm.md` | Helm チャート概要 |

**推奨構成**: AKS による Kubernetes ネイティブ構成（スケール・可用性・IaC 管理の観点から）

---

## 開発ワークフロー

### ブランチ戦略

- **メインブランチ**: `main`
- **機能ブランチ**: `claude/<作業内容>-<ID>` 形式（例: `claude/add-claude-documentation-X93FM`）

### コミット規約

コミットメッセージは日本語で記述する。プレフィックスの例:

| プレフィックス | 用途 |
|---|---|
| `新規作成:` | 新規ドキュメント・ファイルの追加 |
| `add:` | 機能・コンテンツの追加 |
| `update:` | 既存コンテンツの更新 |
| `fix:` | 修正 |

---

## Claude Code 設定

### 許可されているドメイン（WebFetch）

`.claude/settings.local.json` で以下のドメインへのアクセスが許可されています:

| ドメイン | 用途 |
|---|---|
| `support.collibra.com` | Collibra サポートサイト |
| `developer.collibra.com` | Collibra 開発者ドキュメント |
| `productresources.collibra.com` | Collibra 製品リソース（公式ドキュメント） |
| `helm.sh` | Helm 公式ドキュメント |

---

## ドキュメント作成規約

1. **言語**: 日本語で記述する
2. **日付フォーマット**: `YYYY-MM-DD`（例: `2026-04-15`）
3. **情報源**: 公式ドキュメントをベースにすること
4. **比較表**: Markdown テーブル形式で整理する
5. **アーキテクチャ図**: ASCII アート（コードブロック内）を使用する
6. **各 `notes.md`**: 試験対策チェックリストと頻出問題パターンを末尾に含める

---

## 新しいプロジェクトを追加する場合

1. ルート直下に `learn-<テーマ>/` ディレクトリを作成する
2. プロジェクト固有の `CLAUDE.md`（役割・目標・制約）を配置する
3. ルートの本 `CLAUDE.md` のプロジェクト構成テーブルに追記する
4. 必要に応じて `.claude/settings.local.json` に WebFetch 許可ドメインを追加する
