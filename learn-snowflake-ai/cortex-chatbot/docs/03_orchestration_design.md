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
   - 「〇〇関数を利用しているソースコードは何件ある？」（コード内キーワード件数）
   - 「〇〇関数を使っているプログラムのファイル一覧を教えて」（コード内キーワード一覧）
   - テーブル名・ジョブ名・フラグ・コード内キーワードに基づく絞り込みや集計の質問

2. source_code_search_tool (Cortex Search):
   以下の質問には必ずこのツールを使用してください。
   - 「〇〇.sqlはどんな処理をするプログラムですか？」
   - 「〇〇モジュールの処理内容を教えて」
   - 「このエラーが出た場合の原因と対処法は？」
   - 「〇〇機能の処理フローを解説して」
   - 「〇〇関数を使っているプログラムはどんな処理をしているか？」（件数でなく内容が目的）
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

| キーワード | → ツール | 補足 |
|---|---|---|
| 使用/参照/更新/削除/CREATE/READ/UPDATE/DELETE/CRUD | impact_analysis_tool | CRUDフラグによる構造検索 |
| 影響/影響範囲/どのジョブ/どのプログラム/棚卸し | impact_analysis_tool | メタデータ集計 |
| 何件ある/何件/件数/いくつ + 関数名/キーワード | impact_analysis_tool | source_code LIKE + COUNT |
| どのファイルが/一覧 + 関数名/キーワード | impact_analysis_tool | source_code LIKE + SELECT |
| 解説/説明/処理内容/フロー/どんな処理/概要 | source_code_search_tool | 意味的な内容説明が目的 |
| エラー/障害/原因/異常終了/調査/対処 | source_code_search_tool | 推論・診断が目的 |
| ～を使っているプログラムはどんな処理？ | source_code_search_tool | 件数でなく処理内容が目的 |

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

## 7. 影響連鎖調査クエリへの対応（設計上の限界と対策）

### 7-1. 問題のあるクエリタイプ

以下のような**「ファイル仕様変更 → 改修・テスト影響範囲」**を問うクエリは、
2ツール単純チェーンでは完全対応できない。

```
例: 「〇〇.datファイルの6カラム目の桁数が変更になった場合に
     改修・テストが必要な機能を教えて」
```

**必要なステップと各ステップの課題**:

```
STEP1: 〇〇.datを取り込んでいるプログラムを特定
  → Analyst: file_table_name LIKE '〇〇.dat%' AND file_i_flg = 1
  → ✅ 対応可能

STEP2: その中で「6カラム目」を処理しているプログラムを絞り込む
  → ❌ 対応困難（根本原因）
     ・メタデータテーブルにカラム定義情報がない
     ・source_code LIKE '%6%' はノイズが多すぎる
     ・ai_summary がカラム位置の詳細を要約していない可能性がある

STEP3: 絞り込んだジョブが属する機能・モジュールを取得
  → Analyst: CRUD JOINで機能・モジュールを特定
  → ✅ STEP2が解決すれば対応可能

STEP4: テスト観点の解説
  → Search: テスト影響範囲を概要から取得
  → ✅ 部分的に対応可能（詳細なテスト観点はai_summaryに含まれない場合あり）
```

---

### 7-2. 現状でエージェントが返せる回答の限界

現状の2ツール構成で上記クエリを投げると、以下のような**不完全な回答**になる：

```
エージェントの動作（現状）:
  Analyst → 〇〇.datを取り込むジョブ一覧（5件）を返す
  Search  → ai_summaryから「6カラム目」を処理しているプログラムを探す
              → ai_summaryに記載がなければヒットしない、またはノイズが多い
  結果: STEP1の5ジョブをそのまま「影響範囲」として回答してしまう
        → 実際には6カラム目を参照していないプログラムも含まれる
```

---

### 7-3. 推奨対応案（優先度順）

#### 短期対応: マルチターン会話で段階的に絞り込む

ユーザーが自分でステップを分けて質問することで現行ツールで対応できる：

```
Turn 1: 「〇〇.datを取り込んでいるプログラム一覧を教えて」
  → Analyst が取り込みジョブ5件をリスト

Turn 2: 「そのうち、ファイルの固定長カラムを位置で解析しているプログラムを教えて」
  → Search が source_code / ai_summary から該当プログラムを絞り込み

Turn 3: 「絞り込んだ〇〇プログラムが属する機能・モジュールを教えて」
  → Analyst が機能・モジュールを返す

Turn 4: 「その機能のテスト観点を教えて」
  → Search がai_summaryからテスト観点を説明
```

→ **ユーザーが4ターン質問する必要があり、一発解決にはならない**

---

#### 中期対応①: ai_summaryの生成プロンプトを改善

現状の ai_summary はプログラム全体の概要文。
ファイルのカラム定義・位置指定の情報を含むよう**プロンプトを改善**する：

```sql
-- ai_summary 再生成プロンプト例（固定長ファイル解析情報を含める）
UPDATE T_<システム名>_SRC
SET ai_summary = SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    '以下のSQLまたはバッチプログラムを分析し、以下の項目を含む概要を200〜400文字で作成してください。\n'
    || '1. 処理の目的と概要\n'
    || '2. 入力ファイル名とそのカラム位置・桁数の利用箇所（固定長・CSV等）\n'
    || '3. 処理対象のテーブル名\n'
    || '4. 処理の主要ロジック\n\n'
    || source_code
)
WHERE file_name LIKE '%.dat%'  -- .datファイルを扱うプログラムを優先
   OR source_code LIKE '%固定%'
   OR source_code LIKE '%桁%';
```

→ **改善後のai_summaryには「6カラム目（10桁）を〇〇に格納」のような情報が入り、Searchで絞れるようになる**

---

#### 中期対応②: ファイルレイアウトの専用メタデータテーブルを追加

ファイルのカラム定義を管理するテーブルを作成し、Analystの対象に追加する：

```sql
-- ファイルレイアウト定義テーブル（新規作成）
CREATE TABLE T_<システム名>_FILE_LAYOUT (
    file_name       VARCHAR,   -- 〇〇.dat
    col_no          INTEGER,   -- カラム番号（1始まり）
    col_name        VARCHAR,   -- カラム名称（日本語）
    start_pos       INTEGER,   -- 開始桁位置（固定長の場合）
    length          INTEGER,   -- 桁数
    data_type       VARCHAR,   -- 文字/数値/日付
    used_by_src     VARCHAR,   -- このカラムを参照しているソースファイル名
    remarks         VARCHAR    -- 備考
);
```

このテーブルをセマンティックモデルに追加すれば：

```sql
-- Analyst が生成できるようになるSQL
SELECT DISTINCT s.function_name, s.module_name, s.ajs_name
FROM T_<システム名>_FILE_LAYOUT fl
JOIN T_<システム名>_SRC s ON fl.used_by_src = s.file_name
WHERE fl.file_name = '〇〇.dat'
  AND fl.col_no = 6;
```

→ **一発で改修対象の機能・モジュールを返せるようになる（最も根本的な解決）**

---

### 7-4. 対応案のまとめ

| 対応案 | 対応時期 | 効果 | コスト |
|---|---|---|---|
| マルチターン会話で段階的に質問 | **今すぐ** | 部分対応（4ターン必要） | ゼロ（運用対応） |
| ai_summaryの生成プロンプト改善 | 近日 | Searchの絞り込み精度向上 | 低（SQL1本） |
| ファイルレイアウト定義テーブル追加 | 中期 | 完全対応（1発回答可能） | 高（メタデータ整備工数が必要） |

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
