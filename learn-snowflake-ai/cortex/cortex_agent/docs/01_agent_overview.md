# AI エージェントとは

## AI エージェントの定義

AI エージェントとは、**目標に向かって自律的にツールを選択・実行し、結果を評価しながら複数ステップのタスクを完遂する AI システム**です。

```
通常の LLM（質問応答）:
  ユーザー入力 → LLM → 1回の回答

AI エージェント:
  ユーザーの目標
    ↓
  計画（何をすべきか）
    ↓
  ツール選択 → ツール実行 → 結果確認
    ↓ ※必要なら繰り返す
  統合して回答
```

---

## RAG・SQL 生成との違い

| 比較軸 | RAG | Cortex Analyst | AI エージェント |
|---|---|---|---|
| 入力 | 自然言語の質問 | 自然言語の質問 | 自然言語の目標 |
| 処理 | 検索 → LLM | NL → SQL → 実行 | 計画 → ツール選択 → 実行 × N |
| ツール | 検索のみ | SQL 実行のみ | 複数ツールを自律的に組み合わせ |
| ステップ数 | 1 | 1 | 複数（動的） |
| 向いているタスク | ドキュメント検索・QA | データ集計・分析 | **複合的な調査・意思決定支援** |

---

## なぜエージェントが必要か

### 例: 「先月の売上が落ちた原因を調べて」

**RAG 単体では:**
- ドキュメントを検索して「売上低下の一般的な原因」は返せる
- 実際の自社データを分析することはできない

**Cortex Analyst 単体では:**
- 売上テーブルから数値は出せる
- 「なぜ落ちたか」を社内規定や競合情報と突き合わせることはできない

**AI エージェントなら:**

```
Step 1: Cortex Analyst で先月の売上をカテゴリ・地域別に集計
Step 2: 前月比で大きく落ちているカテゴリを特定
Step 3: Cortex Search で「売上低下」「キャンペーン中止」等の社内ドキュメントを検索
Step 4: 両方の結果を照合して原因仮説を生成
Step 5: 仮説を裏付けるデータをさらに Cortex Analyst で取得
Step 6: 統合レポートを生成
```

---

## Snowflake Cortex Agent の位置づけ

```
┌─────────────────────────────────────────────────────────────┐
│  Snowflake Cortex Agent                                     │
│                                                             │
│  LLM（オーケストレーター）                                   │
│    ├── ツール選択・実行の計画を立てる                        │
│    └── 結果を評価して次のステップを決める                    │
│                                                             │
│  利用可能なツール:                                           │
│    ├── Cortex Analyst  （自然言語 → SQL → 構造化データ取得） │
│    ├── Cortex Search   （ドキュメント検索・RAG）             │
│    ├── SQL 実行        （カスタム SQL の直接実行）           │
│    └── External Functions（外部 API・Slack・CRM など）       │
└─────────────────────────────────────────────────────────────┘
         ↑
Snowflake Intelligence（マネージド UI）がこの上に乗る
```

---

## アーキテクチャ図

```
ユーザー
  │ 自然言語でゴールを指定
  ▼
Cortex Agent（LLM: Llama / Claude / Arctic）
  │
  │  ① ゴールを分解してツールを選択
  ▼
┌────────────────────────────────────────────┐
│  ツール実行層                              │
│                                            │
│  Cortex Analyst  → SQL 生成 → DB 実行     │
│  Cortex Search   → ベクトル/全文検索      │
│  COMPLETE() 関数 → LLM 推論              │
│  External API    → Slack/CRM/REST         │
└────────────────────────────────────────────┘
  │
  │  ② 結果を受け取り、次のステップを判断
  ▼
Cortex Agent
  │  ③ 全ステップ完了 → 回答を統合
  ▼
ユーザーへの自然言語レスポンス
```

---

## Snowflake Cortex Agent の特徴

### データが外に出ない
- すべての処理が Snowflake 内で完結
- Snowflake の RBAC・列レベルセキュリティがそのまま適用

### 既存リソースをそのまま使える
- 作成済みの Cortex Search Service をツールとして登録するだけ
- 作成済みのセマンティックモデル YAML を Cortex Analyst のツールとして使える

### REST API で呼び出せる
- `POST /api/v2/cortex/agents/execute`
- アプリケーションからシンプルに呼べる

---

## このセクションの構成

```
cortex_agent/
└── docs/
    ├── 01_agent_overview.md          ← 本ファイル（AI エージェントとは）
    ├── 02_cortex_agent.md            ← Cortex Agent の詳細仕様・REST API
    ├── 03_cortex_agent_demo.md       ← Analyst + Search 統合デモ
    └── 04_snowflake_intelligence.md  ← Cortex Agent 上のマネージド UI
```

---

## 次のステップ

- [02_cortex_agent.md](02_cortex_agent.md) — Cortex Agent の REST API とツール定義
