# Cortex Search + RAG 概要

## このセクションについて

このセクションでは、**Snowflake Cortex Search を使った RAG（Retrieval-Augmented Generation）** の基礎から実装までを学びます。

---

## RAG とは

RAG（Retrieval-Augmented Generation）は、**LLM の回答精度を高めるためのアーキテクチャパターン**です。

```
通常の LLM:
  質問 → LLM → 回答（学習データのみ）

RAG:
  質問 → 検索 → 関連ドキュメント取得 → LLM（コンテキスト付き）→ 精度の高い回答
```

社内規定・製品マニュアル・最新情報など、LLM の学習データに含まれない情報を回答に使えるようになります。

---

## Cortex Search とは

Snowflake が提供する **フルマネージドの検索サービス**。ベクトル検索と全文検索を組み合わせたハイブリッド検索を、SQL の延長で利用できます。

| 比較軸 | 従来のベクトル検索 | Cortex Search |
|---|---|---|
| 構築の手間 | Embedding → ベクトル DB → 検索 API を自前実装 | `CREATE CORTEX SEARCH SERVICE` の 1 文 |
| インフラ管理 | 必要 | Snowflake がすべて管理 |
| データ連携 | Snowflake → 外部システムへ転送 | Snowflake 内のテーブルを直接参照 |
| ガバナンス | 別途設計が必要 | Snowflake の RBAC がそのまま適用 |

---

## このセクションの構成

```
cortex_search_rag/
├── docs/
│   ├── 01_overview.md                 ← 本ファイル（導入）
│   ├── 02_rag_components.md           ← RAG の構成要素（チャンキング・Embedding・検索）
│   ├── 03_cortex_search.md            ← Cortex Search の詳細仕様・設計パターン
│   ├── 04_cortex_rag_sample.md        ← ハンズオン（環境構築 → データ投入 → 検索）
│   ├── 05_demo_app.md                 ← Streamlit in Snowflake でのデモアプリ実装
│   ├── 06_differentiation.md          ← 他サービス（Elasticsearch 等）との比較
│   ├── 07_hybrid_search.md            ← ハイブリッド検索の設計・SQL パターン
│   └── 08_structured_data_patterns.md ← 構造化データ × RAG の統合パターン
└── sql/
    ├── 01_setup.sql                   ← 環境セットアップ
    ├── 02_sample_data.sql             ← サンプルドキュメントデータ投入
    ├── 03_chunking_and_embedding.sql  ← テキストチャンキング・Embedding 生成
    ├── 04_rag_queries.sql             ← RAG クエリパターン集
    ├── 05_cortex_search_setup.sql     ← Cortex Search Service 作成
    ├── 06_stored_procedures.sql       ← RAG 用ストアドプロシージャ
    ├── 07_hybrid_search.sql           ← ハイブリッド検索 SQL
    ├── 08_code_master_rag.sql         ← コードマスター RAG 実装
    └── 09_cortex_analyst_rag.sql      ← Cortex Analyst との統合
```

---

## 学習フロー

```
1. RAG の基礎を理解する
   → 02_rag_components.md

2. Cortex Search の詳細を把握する
   → 03_cortex_search.md

3. ハンズオンで動かす
   → 04_cortex_rag_sample.md（SQL: 01〜05）

4. デモアプリを作る
   → 05_demo_app.md（SQL: 06）

5. 応用パターンを学ぶ
   → 07_hybrid_search.md, 08_structured_data_patterns.md
```

---

## 関連セクション

- [../00_cortex_overview/](../00_cortex_overview/) — Snowflake Cortex 全体の概要
- [../cortex_analyst/](../cortex_analyst/) — 構造化データへの自然言語クエリ（Cortex Analyst）
- [../cortex_agent/](../cortex_agent/) — Cortex Search + Analyst を統合するエージェント
