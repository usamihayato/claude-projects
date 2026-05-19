# 構造化データ × ドキュメント ハイブリッド検索

## 概要

Cortex Search はドキュメント（非構造化テキスト）の検索が得意ですが、
社員テーブルや経費申請テーブルのような**構造化データ（レコード）との組み合わせ**で
さらに実用的な回答が得られます。

```
質問
  ├─ SQL検索     → テーブルレコード（社員・経費など）
  └─ Cortex Search → 規定・マニュアル・ポリシー文書
          ↓ 両方のコンテキストを合算
      CORTEX.COMPLETE → 回答
```

---

## なぜハイブリッド検索が必要か

| 検索種別 | 得意なこと | 苦手なこと |
|---|---|---|
| 構造化のみ（SQL） | 数値集計・特定レコード抽出 | 「なぜそうなのか」「どうすべきか」の文脈 |
| ドキュメントのみ（Cortex Search） | ルール・手順の説明 | 「今の状況がどうなっているか」の実データ |
| **ハイブリッド** | **実データ + ルールを組み合わせた具体的な回答** | — |

### 回答品質の差（Step 7 の比較）

質問:「接待費の却下申請はどう対処すべきか？」

| | 回答内容 |
|---|---|
| 構造化のみ | 「山田さんの45,000円が却下されています」→ **原因が不明** |
| ドキュメントのみ | 「接待費の上限は1人あたり10,000円です」→ **誰の話かわからない** |
| **ハイブリッド** | **「山田さんの申請は4名×10,000円の上限を超えた45,000円のため却下。上限内の40,000円に修正して再申請が必要」** |

---

## テーブル構成

```sql
-- 構造化テーブル（sql/07_hybrid_search.sql Step 1 で作成）

employees (
    emp_code     -- 社員番号
    name         -- 氏名
    department   -- 部署
    role         -- 役職
    annual_leave -- 年間付与日数
    used_leave   -- 取得済日数
)

expense_applications (
    emp_code     -- 社員番号（FK）
    category     -- 交通費 / 接待費 / 出張費 / 消耗品
    amount       -- 金額
    status       -- 申請中 / 承認済 / 却下
    description  -- 内容
)
```

---

## サンプルクエリ

### パターン1: 経費申請状況 × 規定

```sql
SET hybrid_query = '接待費の申請ルールと、現在の申請状況を教えてください';
SET target_dept  = '経理部';

WITH
-- [A] 構造化データ: 対象部署の経費申請を集計
structured_context AS (
    SELECT
        LISTAGG(
            e.name || ': ' || ea.category
            || ' ¥' || TO_CHAR(ea.amount, '999,999')
            || ' [' || ea.status || '] ' || ea.description,
            '\n'
        ) AS records_text
    FROM expense_applications ea
    JOIN employees e ON ea.emp_code = e.emp_code
    WHERE e.department = $target_dept
),
-- [B] ドキュメント検索: 経費規定を Cortex Search で取得
doc_context AS (
    SELECT LISTAGG(
        '【' || r.value:doc_name::VARCHAR || '】\n' || r.value:content::VARCHAR,
        '\n\n'
    ) AS policy_text
    FROM (
        SELECT PARSE_JSON(
            SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'company_doc_search',
                CONCAT(
                    '{"query": "', $hybrid_query, '",',
                    '"columns": ["doc_name", "content"],',
                    '"filter": {"@eq": {"category": "財務規定"}},',
                    '"limit": 2}'
                )
            )
        ) AS result
    ),
    LATERAL FLATTEN(input => result:results) r
),
-- [C] コンテキスト結合
combined AS (
    SELECT CONCAT(
        '=== 経費精算規定 ===\n', dc.policy_text, '\n\n',
        '=== ', $target_dept, ' の申請データ ===\n', sc.records_text
    ) AS full_context
    FROM structured_context sc, doc_context dc
)
-- [D] LLM で回答
SELECT
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '規定とデータを元に質問に具体的に答えてください。\n\n',
            full_context,
            '\n\n質問: ', $hybrid_query
        )
    ) AS 回答
FROM combined;
```

### パターン2: 有給残日数 × 休暇規定

```sql
WITH
-- 有給残が少ない社員を抽出（残5日以下）
structured_context AS (
    SELECT LISTAGG(
        name || '（' || department || '）: 残' || (annual_leave - used_leave) || '日',
        '\n'
    ) AS records_text
    FROM employees
    WHERE (annual_leave - used_leave) <= 5
),
-- 有給規定ドキュメント検索
doc_context AS (
    SELECT LISTAGG(
        r.value:content::VARCHAR, '\n\n'
    ) AS policy_text
    FROM (
        SELECT PARSE_JSON(
            SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'company_doc_search',
                '{"query": "有給休暇 付与 繰り越し 申請",
                  "columns": ["doc_name", "content"],
                  "filter": {"@eq": {"department": "人事部"}},
                  "limit": 2}'
            )
        ) AS result
    ),
    LATERAL FLATTEN(input => result:results) r
),
combined AS (
    SELECT CONCAT(
        '=== 有給休暇規定 ===\n', dc.policy_text, '\n\n',
        '=== 有給残少ない社員 ===\n', sc.records_text
    ) AS full_context
    FROM structured_context sc, doc_context dc
)
SELECT
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '人事担当として、以下のデータと規定を元に',
            '有給消化が必要な社員への案内文を作成してください。\n\n',
            full_context
        )
    ) AS 案内文
FROM combined;
```

### パターン3: ストアドプロシージャによる汎用ハイブリッド検索

```sql
-- Step1: 構造化データをSQL集計してテキスト変数に格納
SET struct_ctx = (
    SELECT LISTAGG(
        ea.emp_code || ' ' || e.name
        || '（' || e.department || '）'
        || ea.category || ' ¥' || ea.amount
        || ' [' || ea.status || ']',
        '\n'
    )
    FROM expense_applications ea
    JOIN employees e ON ea.emp_code = e.emp_code
    WHERE ea.status IN ('申請中', '却下')
);

-- Step2: ハイブリッドRAG実行（sql/07 の hybrid_rag_search プロシージャ）
CALL hybrid_rag_search(
    '申請中・却下の経費について、規定に照らした対応方法を教えてください',
    $struct_ctx,    -- 構造化コンテキスト（事前集計）
    '財務規定',      -- ドキュメントフィルタ（カテゴリ）
    2,              -- 取得ドキュメント数
    'llama3.1-70b'  -- LLMモデル
);
```

---

## 設計のポイント

### 構造化コンテキストの作り方

ポイントは「LLMが読みやすいテキスト形式」に変換すること。
`LISTAGG` で各レコードを1行テキストに変換するのが基本パターン。

```sql
-- NG: 数値をそのまま渡す
SELECT amount FROM expense_applications;

-- OK: 文脈が伝わるテキストに変換
SELECT LISTAGG(
    name || ': ' || category || ' ¥' || amount || ' [' || status || ']',
    '\n'
) FROM ...;
```

### ドキュメントフィルタの使い方

質問の性質に合わせてフィルタを変える：

| 質問の種類 | 推奨フィルタ |
|---|---|
| 経費・精算関連 | `"filter": {"@eq": {"category": "財務規定"}}` |
| 休暇・勤怠関連 | `"filter": {"@eq": {"department": "人事部"}}` |
| セキュリティ関連 | `"filter": {"@eq": {"category": "IT規定"}}` |
| フィルタ不要 | フィルタ省略（全ドキュメントから検索） |

### ストアドプロシージャの使い分け

| プロシージャ | 用途 |
|---|---|
| `cortex_search_rag` (06) | ドキュメントのみ。質問と関連文書だけで回答 |
| `hybrid_rag_search` (07) | 構造化データ + ドキュメント。実データが必要な質問に使う |

---

## 参考リンク

- [Cortex Search 公式ドキュメント](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search/cortex-search-overview)
- [Cortex Analyst（構造化データへの自然言語クエリ）](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [CORTEX.COMPLETE](https://docs.snowflake.com/en/sql-reference/functions/complete-snowflake-cortex)
