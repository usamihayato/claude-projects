# オーケストレーション設計

## 1. エージェント処理フロー

```
ユーザー入力
    │
    ▼
┌─────────────────────────────────────────────────────┐
│ Cortex Agent (LLM: claude-3-5-sonnet)               │
│                                                     │
│ STEP 1: 意図分類                                    │
│   ・影響調査か？ → impact_analysis_tool を選択      │
│   ・解説・障害調査か？ → source_code_search_tool    │
│   ・両方必要か？ → 両ツールを順次呼び出し          │
│                                                     │
│ STEP 2: ツール実行                                  │
│   ・Analyst → SQL生成 → Snowflake実行 → 結果取得   │
│   ・Search → セマンティック検索 → 関連文書取得     │
│                                                     │
│ STEP 3: 回答合成                                    │
│   ・取得データをもとに日本語回答を生成             │
│   ・SQL・ソースコードを引用して根拠を示す          │
└─────────────────────────────────────────────────────┘
    │
    ▼
回答表示（Snowflake Intelligence UI）
```

---

## 2. システムプロンプト設計

```
あなたは社内システムの保守・調査を支援するアシスタントです。
以下の2つのツールを使用できます。

【ツール選択ルール】

1. impact_analysis_tool (Cortex Analyst):
   以下の質問には必ずこのツールを使用してください。
   - 「〇〇テーブルを使用/参照/更新/削除しているジョブ・プログラムを教えて」
   - 「〇〇ジョブが使っているテーブル一覧を教えて」
   - 「〇〇テーブルへのCRUD操作の一覧を教えて」
   - 「ファイル出力/取り込みが発生する機能は？」
   - 「〇〇ジョブネットに含まれるジョブは？」
   - テーブル名・ジョブ名・フラグに基づく絞り込みを含む質問

2. source_code_search_tool (Cortex Search):
   以下の質問には必ずこのツールを使用してください。
   - 「〇〇.sqlはどんな処理をするプログラムですか？」
   - 「〇〇モジュールの処理内容を教えて」
   - 「このエラーが出た場合の原因と対処法は？」
   - 「〇〇機能の処理フローを解説して」
   - ソースコードの内容・意図・処理ロジックに関する質問

3. 両ツール使用:
   - 「〇〇テーブルを更新しているジョブのソースコードを説明して」
     → まずimpact_analysis_toolで該当ジョブを特定し、
       次にsource_code_search_toolでそのジョブのコードを検索

【回答ルール】
- 必ず日本語で回答してください
- impact_analysis_toolが生成したSQLを回答に含めてください
- ソースコードを引用する場合は、ファイル名・モジュール名を明記してください
- 確認できなかった情報は「データに存在しません」と明確に伝えてください
```

---

## 3. ツール定義（API JSON）

### Cortex Analyst ツール

```json
{
  "tool_spec": {
    "type": "cortex_analyst_text_to_sql",
    "name": "impact_analysis_tool"
  },
  "tool_resources": {
    "semantic_model": "@<DB>.<SCHEMA>.<STAGE>/semantic_model.yaml"
  }
}
```

### Cortex Search ツール

```json
{
  "tool_spec": {
    "type": "cortex_search_service",
    "name": "source_code_search_tool"
  },
  "tool_resources": {
    "cortex_search_service": "<DB>.<SCHEMA>.SRC_SEARCH_SERVICE"
  }
}
```

---

## 4. エージェント設定（Snowflake Intelligence）

> **本プロジェクトでは Snowflake Intelligence を使うため、カスタムAPIコードは不要です。**
> 以下は参考として、エージェントの設定パラメータをAPIの観点で整理したものです。

```json
{
  "agent_name": "社内システム保守支援Bot",
  "model": "claude-3-5-sonnet",
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "impact_analysis_tool"
      },
      "tool_resources": {
        "semantic_model": "@CHATBOT_MODELS_STAGE/02_semantic_model.yaml"
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search_service",
        "name": "source_code_search_tool"
      },
      "tool_resources": {
        "cortex_search_service": "<DB>.<SCHEMA>.SRC_SEARCH_SERVICE"
      }
    }
  ],
  "system_prompt": "（03_orchestration_design.md Section 2 参照）"
}
```

Intelligence上でのエージェント作成・公開手順は `sql/05_intelligence_agent_config.sql` を参照。

---

## 5. ルーティング精度向上のための工夫

### 5-1. 明示的な質問分類指示

システムプロンプトにルールを列挙するだけでなく、**質問のキーワードパターン**を定義:

| キーワード | → ツール |
|---|---|
| 使用/参照/更新/削除/CREATE/READ/UPDATE/DELETE/CRUD | impact_analysis_tool |
| 影響/影響範囲/どのジョブ/どのプログラム/棚卸し | impact_analysis_tool |
| 解説/説明/処理内容/フロー/どんな処理/概要 | source_code_search_tool |
| エラー/障害/原因/異常終了/調査/対処 | source_code_search_tool |
| ソースコード/ロジック/アルゴリズム/実装 | source_code_search_tool |

### 5-2. Few-shot examples をシステムプロンプトに追加

```
例1:
質問: 「受注テーブルを更新しているジョブを教えて」
→ impact_analysis_tool を使用
理由: テーブル名とCRUD操作（UPDATE）による構造的な検索

例2:
質問: 「JOB001.sqlはどんな処理をしていますか？」
→ source_code_search_tool を使用
理由: ソースコードの内容説明が目的

例3:
質問: 「受注テーブルを更新しているジョブのソースコードを解説して」
→ impact_analysis_tool → source_code_search_tool の順に使用
理由: まずジョブ特定（Analyst）、次にコード解説（Search）
```

### 5-3. 回答に使用ツール名を表示

Snowflake Intelligence UI では回答に使用ツール名が自動的に表示されるため、**ユーザーが質問の仕方を学習**できる。

---

## 6. マルチターン会話の設計

Snowflake Intelligence は会話履歴の保持を自動で行うため、マルチターンは設定不要で動作する。

**マルチターンの活用例**:
```
Turn 1: 「受注テーブルを使用しているジョブを教えて」
  → Analyst が5ジョブをリスト

Turn 2: 「そのうちJOB_ORDER_001.sqlの処理内容を教えて」
  → Search で前の文脈（受注テーブル）を踏まえてコード解説
  → Intelligence が前のやり取りを記憶しているため自然に繋がる
```
