# cortex-chatbot プロジェクト

## 概要

Snowflake Cortex Analyst + Cortex Search を組み合わせたハイブリッドエージェントによる
社内システム保守支援チャットボットの設計・検証プロジェクト。

## 目的

1. プログラム・バッチ・ジョブ変更時の**影響調査**の自動化（Cortex Analyst）
2. 新人・兼任担当者向けの**ソースコード解説・障害調査補助**（Cortex Search）

## 仮説

- 影響調査（「〇〇テーブルを使用しているジョブは？」）は構造化メタデータへのSQL問い合わせが適しており、Cortex Analystが有効
- ソースコード解説・障害分析（「このプログラムが落ちた原因は？」）は非構造化テキストへのセマンティック検索が適しており、Cortex Searchが有効
- Cortex Agentで両ツールを統合することで、単独Search比較で精度向上が期待できる

## ディレクトリ構成

```
cortex-chatbot/
├── CLAUDE.md              ← 本ファイル
├── docs/
│   ├── 01_goal_and_verification_plan.md   ← ゴール設定・検証ステップ
│   ├── 02_architecture_design.md          ← アーキテクチャ設計
│   ├── 03_orchestration_design.md         ← オーケストレーション設計
│   ├── 04_evaluation_cases.md             ← モデルケースと評価方法
│   └── 05_evaluation_report_template.md  ← 評価まとめ資料ドラフト
└── sql/
    ├── 01_setup.sql                       ← 環境セットアップ
    ├── 02_semantic_model.yaml             ← Cortex Analyst セマンティックモデル
    ├── 03_cortex_search_setup.sql         ← Cortex Search サービス設定
    ├── 04_agent_setup.sql                 ← エージェント設定・ストアドプロシージャ
    └── 05_streamlit_app.py                ← Streamlit チャットUIアプリ
```

## 関連ドキュメント

- [Cortex Analyst概要](../cortex/cortex_analyst/docs/01_cortex_analyst_overview.md)
- [Cortex Agent概要](../cortex/cortex_agent/docs/01_agent_overview.md)
- [Cortex Search RAG概要](../cortex/cortex_search_rag/docs/01_overview.md)
