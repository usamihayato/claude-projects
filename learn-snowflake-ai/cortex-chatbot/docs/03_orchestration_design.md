# オーケストレーション設計

## 1. エージェント処理フロー

```
ユーザー入力
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ Cortex Agent (LLM: claude-3-5-sonnet)                           │
│                                                                 │
│ STEP 1: 意図分類（5パターン）                                   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ パターン判定                                             │   │
│  │                                                         │   │
│  │ A: 構造検索のみ        → Analyst のみ                   │   │
│  │    「〇〇テーブルを使うジョブは？」                      │   │
│  │                                                         │   │
│  │ B1: 概要説明のみ       → ai_summary_search のみ         │   │
│  │    「〇〇.sqlはどんな処理？」「このエラーの原因は？」    │   │
│  │                                                         │   │
│  │ B2: 詳細ロジック推論   → source_code_search のみ        │   │
│  │    「〇〇ファイルの〇〇カラムを処理しているプログラムは？」│  │
│  │                                                         │   │
│  │ C: 構造特定 → 概要説明 → Analyst → ai_summary_search   │   │
│  │    「〇〇テーブル更新ジョブのコードを解説して」          │   │
│  │                                                         │   │
│  │ D: コード推論 → 下流展開 → source_code_search → Analyst │   │
│  │    「〇〇ファイルのカラム変更で影響する機能は？」        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│ STEP 2: ツール実行（判定パターンに応じて順序が変わる）          │
│   ・Analyst         → SQL生成 → Snowflake実行 → 結果取得       │
│   ・ai_summary_search → ai_summary をセマンティック検索         │
│   ・source_code_search → source_code を直接検索・LLMが推論     │
│                                                                 │
│ STEP 3: 回答合成                                                │
│   ・取得データをもとに日本語回答を生成                         │
│   ・SQL・ソースコードを引用して根拠を示す                      │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
回答表示（Snowflake Intelligence UI）
```

### パターン別の特徴

| パターン | ツール呼び出し | 典型的な質問の形 |
|---|---|---|
| A: Analyst のみ | Analyst | 「〇〇テーブルを使うジョブ一覧」「〇〇関数を使うファイルは何件？」 |
| B1: ai_summary_search のみ | ai_summary_search | 「〇〇.sqlの処理概要」「このエラーの原因」「〇〇バッチの調査ポイント」 |
| B2: source_code_search のみ | source_code_search | 「〇〇ファイルの〇〇カラムを処理しているプログラム」「変数マッピングを追う」 |
| C: Analyst → ai_summary_search | Analyst → ai_summary_search | 「〇〇テーブルを更新しているジョブのコードを解説して」 |
| D: source_code_search → Analyst | source_code_search → Analyst | 「〇〇ファイルのカラム変更で影響する機能」 |

---

## 2. システムプロンプト設計

```
あなたは社内システムの保守・調査を支援するアシスタントです。
以下の3つのツールを使用できます。

【ツール選択ルール】

1. impact_analysis_tool (Cortex Analyst):
   テーブル名・ジョブ名・CRUDフラグ・コード内キーワードが起点の構造検索・集計が必要な場合に使用してください。
   - 「〇〇テーブルを使用/参照/更新/削除しているジョブ・プログラムを教えて」
   - 「〇〇ジョブが使っているテーブル一覧を教えて」
   - 「〇〇テーブルへのCRUD操作の一覧を教えて」
   - 「ファイル出力/取り込みが発生する機能は？」
   - 「〇〇ジョブネットに含まれるジョブは？」
   - 「〇〇関数を利用しているソースコードは何件ある？」（コード内キーワード件数）
   - 「〇〇関数を使っているプログラムのファイル一覧を教えて」（コード内キーワード一覧）
   - テーブル名・ジョブ名・フラグ・コード内キーワードに基づく絞り込みや集計の質問

2. ai_summary_search_tool (Cortex Search - AI概要文):
   プログラムの目的・処理フロー・概要を知りたい場合に使用してください。
   - 「〇〇.sqlはどんな処理をするプログラムですか？」
   - 「〇〇モジュールの処理内容を教えて」
   - 「このエラーが出た場合の原因と対処法は？」
   - 「〇〇機能の処理フローを解説して」
   - 「〇〇バッチが異常終了した場合の調査ポイントは？」
   - ソースコードの概要・意図・処理目的に関する質問

3. source_code_search_tool (Cortex Search - ソースコード本文):
   コードを直接読んで詳細な実装ロジック・変数・テーブルを追う必要がある場合に使用してください。
   - 「〇〇ファイルのカラム変更で影響するプログラムと書き込み先テーブルは？」
   - 「〇〇ファイルで〇〇カラムを処理しているプログラムは？」
   - 「〇〇関数を使っているプログラムはどんな処理をしているか？」（処理内容の詳細が目的）
   - ソースコードの実装詳細・変数マッピング・カラム処理ロジックに関する質問

4. 両ツール使用（Analyst → ai_summary_search）:
   構造検索でジョブを特定した後にコード概要を説明する場合に使用。
   - 「〇〇テーブルを更新しているジョブのソースコードを説明して」
     → まずimpact_analysis_toolで該当ジョブを特定し、
       次にai_summary_search_toolでそのジョブのコード概要を説明

5. 両ツール使用（source_code_search → Analyst）:
   ソースコードの推論で影響テーブルを特定した後に下流ジョブを展開する場合に使用。
   - 「〇〇ファイルのカラム変更で改修・テストが必要な機能を教えて」
     → まずsource_code_search_toolでソースコードを読みカラム処理→変数名→書き込み先テーブルを推論し、
       次にimpact_analysis_toolで特定したテーブルを使う下流ジョブを展開

【ツール順序の判断基準】
- テーブル名・ジョブ名・フラグ値が起点 → Analyst から始める
- 処理の概要・目的・フローが知りたい → ai_summary_search_tool
- コードの詳細ロジック・変数・カラム追跡が必要 → source_code_search_tool から始める
- 2つ目のツールが必要かは1つ目の結果を見てから判断する

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

**単独ツール判定**

| キーワードパターン | → ツール | 補足 |
|---|---|---|
| 使用/参照/更新/削除/CRUD | Analyst のみ | CRUDフラグによる構造検索 |
| 影響範囲/どのジョブ/どのプログラム/棚卸し ＋ テーブル名 | Analyst のみ | メタデータ集計（テーブル名起点） |
| 何件ある/件数/いくつ ＋ 関数名/キーワード | Analyst のみ | source_code LIKE + COUNT |
| どのファイルが/一覧 ＋ 関数名/キーワード | Analyst のみ | source_code LIKE + SELECT |
| 解説/説明/処理内容/フロー/どんな処理/概要/目的 | **ai_summary_search** のみ | 処理概要・意図の説明が目的 |
| エラー/障害/原因/異常終了/調査/対処 | **ai_summary_search** のみ | 推論・診断が目的（概要文から推定） |
| カラム変更/桁数変更/変数マッピング/カラム処理/ロジック詳細 | **source_code_search** のみ | コードを直接読んで実装追跡が目的 |
| ～を使っているプログラムはどんな処理をしているか？ | **source_code_search** のみ | 処理詳細の理解が目的 |

**チェーン判定**

| 質問の起点 | → 開始ツール | → 次のツール | 判断根拠 |
|---|---|---|---|
| テーブル名・ジョブ名・フラグ値が明示されている | **Analyst** 先 | ai_summary_search（必要なら） | 構造検索で対象を絞ってから概要説明 |
| ファイル内容・エラー文・処理概要が知りたい | **ai_summary_search** 先 | Analyst（必要なら） | 概要文から検索して目的達成 |
| カラム処理・変数・詳細ロジック・実装追跡 | **source_code_search** 先 | Analyst（必要なら） | コード推論で対象テーブルを特定してから下流展開 |

### 5-2. Few-shot examples をシステムプロンプトに追加

```
例1（パターンA: Analyst のみ）:
質問: 「受注テーブルを更新しているジョブを教えて」
→ impact_analysis_tool を使用
理由: テーブル名とCRUD操作（UPDATE）による構造検索

例2（パターンB1: ai_summary_search のみ）:
質問: 「JOB001.sqlはどんな処理をしていますか？」
→ ai_summary_search_tool を使用
理由: プログラムの処理概要を知りたい。ai_summaryのセマンティック検索が適切

例3（パターンB2: source_code_search のみ）:
質問: 「〇〇.datファイルの6カラム目を読み込んでいるプログラムは？」
→ source_code_search_tool を使用
理由: ソースコードを直接読んでカラム処理ロジックを追う必要がある

例4（パターンC: Analyst → ai_summary_search）:
質問: 「受注テーブルを更新しているジョブのソースコードを解説して」
→ impact_analysis_tool → ai_summary_search_tool の順に使用
理由: テーブル名（受注テーブル）が起点なのでAnalyst先。対象ジョブ特定後に概要説明

例5（パターンD: source_code_search → Analyst）:
質問: 「〇〇.datファイルの6カラム目の桁数変更で影響する機能を教えて」
→ source_code_search_tool → impact_analysis_tool の順に使用
理由: ファイルのカラム処理が起点なのでsource_code_search先。コードを読んでカラム→変数→
     テーブルを特定後、そのテーブルを使う下流ジョブをAnalystで展開
```

### 5-3. 回答に使用ツール名を表示

Snowflake Intelligence UI では回答に使用ツール名が自動的に表示されるため、**ユーザーが質問の仕方を学習**できる。

---

## 7. 影響連鎖調査クエリへの対応（ソースコードの意味的推論活用）

### 7-1. 代表的なクエリタイプ

以下のような**「ファイル仕様変更 → 改修・テスト影響範囲」**を問うクエリ。

```
例: 「〇〇.datファイルの6カラム目の桁数が変更になった場合に
     改修・テストが必要な機能を教えて」
```

**実際の検証結果**: Cortex Search（source_code/ai_summary）でこのクエリを試したところ、**高精度で対象を洗い出すことができた**。

理由: `source_code` にはSQLやバッチの本文が格納されており、LLMが以下のマルチホップ推論を一度に実行できるため：

```
source_code の読み取り:
  1. 〇〇.datを取り込んでいるプログラムを特定
  2. そのコード内で6カラム目（固定長の開始位置・桁数指定）に対応する変数名を特定
  3. その変数がINSERT/UPDATE/LOADで書き込まれているテーブル・カラムを特定
  → 影響テーブルを1回のSearchコールで回答
```

---

### 7-2. 推奨オーケストレーションフロー

```
STEP1: Search で〇〇.datを扱うプログラムを意味的に検索
  → source_code / ai_summary から取り込み処理を持つファイルをヒット
  → ✅ 高精度で対応可能

STEP2: LLMが source_code を読み、6カラム目→カラム名→書き込み先テーブルを推論
  → ソースコードの固定長解析ロジック・SQL文から直接読み取る
  → ✅ マルチホップ推論として機能（Searchコール内でLLMが実行）

STEP3（任意）: Analyst で特定されたテーブルをさらに下流調査
  → 「〇〇テーブルを更新している他のジョブは？」を Analyst で展開
  → ✅ 影響波及が広い場合に追加で使用
```

**このクエリタイプは L3（発展）難易度の Cortex Search 問題として対応可能。**

---

### 7-3. Searchが有効な理由

| 要素 | 内容 |
|---|---|
| source_code の保持内容 | SQLのSELECT/INSERT/UPDATE文、固定長ファイルの位置指定ロジック（SUBSTR等） |
| LLMの推論能力 | コードを読んで「6カラム目 = SUBSTR(line, 10, 5)」のような対応を推定できる |
| ai_summary の活用 | プロンプトにカラム情報を含めて生成すれば検索精度がさらに向上（後述） |
| マルチホップの実現 | ファイル→変数名→テーブルの連鎖をSearch1回で推論可能 |

---

### 7-4. さらなる精度向上のための改善案（任意）

#### 改善案①: ai_summaryの生成プロンプトにカラム情報を追加

```sql
-- ai_summary 再生成プロンプト例（固定長ファイル解析情報を含める）
UPDATE T_<システム名>_SRC
SET ai_summary = SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    '以下のSQLまたはバッチプログラムを分析し、以下の項目を含む概要を200〜400文字で作成してください。\n'
    || '1. 処理の目的と概要\n'
    || '2. 入力ファイル名とそのカラム位置・桁数の利用箇所（固定長・CSV等）\n'
    || '3. 処理対象のテーブル名とカラム名\n'
    || '4. 処理の主要ロジック\n\n'
    || source_code
)
WHERE source_code LIKE '%SUBSTR%'
   OR source_code LIKE '%固定%'
   OR source_code LIKE '%.dat%';
```

→ ai_summaryに「6カラム目（10桁）を ORDER_AMT カラムに格納」のような記述が入り、Search の絞り込み精度がさらに向上する。

---

#### 改善案②: ファイルレイアウト定義テーブルを追加（中期）

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

これにより Analyst でも構造的に回答できるようになる：

```sql
-- Analyst が生成できるSQL例
SELECT DISTINCT s.function_name, s.module_name, s.ajs_name
FROM T_<システム名>_FILE_LAYOUT fl
JOIN T_<システム名>_SRC s ON fl.used_by_src = s.file_name
WHERE fl.file_name = '〇〇.dat'
  AND fl.col_no = 6;
```

→ Search（意味的推論）と Analyst（構造検索）の両方から回答を出せる最強構成になる。

---

### 7-5. 対応方針まとめ

| 対応方針 | 状況 | 精度 | コスト |
|---|---|---|---|
| Search の意味的推論（現状） | **既に対応可能** | 高精度（実証済み） | ゼロ |
| ai_summaryのプロンプト改善 | 任意の追加対応 | さらに向上 | 低（SQL1本） |
| ファイルレイアウト定義テーブル追加 | 中期オプション | 完全構造化対応 | 高（メタデータ整備工数が必要） |

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
