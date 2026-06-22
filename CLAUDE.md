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
├── learn-collibra-data-quality-and-observablity/  ← Collibra DQ 導入調査プロジェクト
│   ├── CLAUDE.md
│   └── docs/
│       └── collibra/
│           ├── investigation-summary.md           ← 事前調査まとめ
│           ├── todo-qa.md                         ← Todo QA 一覧
│           ├── report.md
│           ├── setup.md
│           ├── azure-vm-setup.md
│           ├── deployment-comparison.md
│           ├── constraints-comparison.md
│           ├── cost-comparison.md
│           ├── open-issues.md
│           └── aks/                               ← AKS 参考資料（Standalone 採用のため参照用）
│               ├── aks-setup.md
│               ├── aks-build.md
│               ├── aks-design.md
│               ├── aks-aro-comparison.md
│               └── helm.md
└── learn-sqlserver-migration/                     ← SQL Server クラウド移行調査プロジェクト
    ├── CLAUDE.md
    └── docs/
        ├── 01-migration-targets/
        ├── 02-knockout-requirements/
        ├── 03-adms/
        ├── 04-cost-analysis/
        ├── 05-network-design/
        └── 06-migration-procedures/              ← 移行手順書（検証・本番）
            ├── 01-verification-procedure.md      ← 自宅検証手順（BACPAC）
            ├── 02-production-dms-procedure.md    ← 本番移行手順（Azure DMS・2TB）
            └── fact-check.md                     ← 公式ドキュメントによるファクトチェック結果
```

---

## プロジェクト構成

| ディレクトリ | 内容 | 主なトピック |
|---|---|---|
| `learn-oci/` | Oracle Cloud Infrastructure (OCI) 学習用プロジェクト | OCI 資格試験対策、インフラ設計 |
| `learn-collibra-data-quality-and-observablity/` | Collibra Data Quality & Observability 導入調査 | Azure VM（Standalone）上での DQ Agent + Spark 構築 |
| `learn-sqlserver-migration/` | SQL Server クラウド移行調査 | SQL MI / DMS / ノックアウト要件 / コスト最適化 |

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
