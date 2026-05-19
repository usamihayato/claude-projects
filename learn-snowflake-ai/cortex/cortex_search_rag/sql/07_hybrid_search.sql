-- ============================================================
-- Snowflake Cortex RAG デモ: 構造化データ + ドキュメント ハイブリッド検索
-- ============================================================
-- 概要:
--   テーブルレコード（構造化データ）と社内ドキュメント（非構造化）の
--   両方を検索してコンテキストを構築し、LLMで回答を生成するサンプル集。
--
--   [アーキテクチャ]
--   質問
--     ├─ SQL検索     → 社員・経費レコード（構造化）
--     └─ Cortex Search → 規定・ポリシー文書（非構造化）
--               ↓ 両方のコンテキストを合算
--           CORTEX.COMPLETE → 回答
-- ============================================================

USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 1: 構造化データ用テーブルの作成とサンプルデータ投入
-- ============================================================

-- 社員テーブル
CREATE TABLE IF NOT EXISTS employees (
    employee_id  VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    emp_code     VARCHAR UNIQUE NOT NULL,    -- 社員番号
    name         VARCHAR NOT NULL,
    department   VARCHAR NOT NULL,
    role         VARCHAR,
    hire_date    DATE,
    annual_leave NUMBER DEFAULT 10,         -- 年間付与日数
    used_leave   NUMBER DEFAULT 0,          -- 取得済日数
    updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 経費申請テーブル
CREATE TABLE IF NOT EXISTS expense_applications (
    app_id       VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    emp_code     VARCHAR REFERENCES employees(emp_code),
    category     VARCHAR NOT NULL,   -- 交通費 / 接待費 / 出張費 / 消耗品
    amount       NUMBER  NOT NULL,
    applied_date DATE    DEFAULT CURRENT_DATE(),
    status       VARCHAR DEFAULT '申請中',  -- 申請中 / 承認済 / 却下
    description  VARCHAR,
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- -------- サンプルデータ --------
TRUNCATE TABLE employees;
INSERT INTO employees (emp_code, name, department, role, hire_date, annual_leave, used_leave) VALUES
('E001', '山田 太郎', '人事部',       '課長',   '2018-04-01', 20, 5),
('E002', '鈴木 花子', '経理部',       '主任',   '2020-10-01', 15, 8),
('E003', '田中 一郎', '情報システム部', 'エンジニア', '2021-07-01', 12, 2),
('E004', '佐藤 美咲', '営業部',       '担当',   '2023-04-01', 10, 3),
('E005', '伊藤 健二', '人事部',       '担当',   '2022-01-15', 12, 7);

TRUNCATE TABLE expense_applications;
INSERT INTO expense_applications (emp_code, category, amount, applied_date, status, description) VALUES
('E001', '接待費',  45000, '2026-03-10', '承認済', '取引先4名との会食（新宿）'),
('E001', '交通費',   3200, '2026-03-12', '承認済', '出張交通費（東京↔横浜）'),
('E002', '接待費',  28000, '2026-03-15', '申請中', '仕入先3名との懇親会'),
('E002', '消耗品',   4500, '2026-03-18', '承認済', '事務用品購入'),
('E003', '出張費', 120000, '2026-03-05', '承認済', '大阪出張（2泊3日）'),
('E003', '交通費',   2400, '2026-03-20', '申請中', 'セミナー参加交通費'),
('E004', '接待費',  52000, '2026-03-08', '却下',   '接待費上限超過のため'),
('E005', '交通費',   1800, '2026-03-22', '申請中', '顧客訪問交通費');

-- 確認
SELECT '社員数' AS item, COUNT(*) AS cnt FROM employees
UNION ALL
SELECT '経費申請数', COUNT(*) FROM expense_applications;


-- ============================================================
-- Step 2: 構造化データのみの検索（ベースライン）
-- ============================================================

-- 部署ごとの有給残日数サマリ
SELECT
    department,
    COUNT(*)                              AS 社員数,
    SUM(annual_leave - used_leave)        AS 有給残合計,
    ROUND(AVG(annual_leave - used_leave), 1) AS 有給残平均
FROM employees
GROUP BY department
ORDER BY 有給残合計 DESC;

-- 却下された経費申請の一覧
SELECT
    e.name,
    e.department,
    ea.category,
    ea.amount,
    ea.applied_date,
    ea.description
FROM expense_applications ea
JOIN employees e ON ea.emp_code = e.emp_code
WHERE ea.status = '却下'
ORDER BY ea.applied_date DESC;


-- ============================================================
-- Step 3: ドキュメント検索のみ（Cortex Search ベースライン）
-- ============================================================

-- ※ 05_cortex_search_setup.sql で company_doc_search が作成済みであること

SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "接待費の上限と承認ルール",
            "columns": ["doc_name", "content", "category"],
            "limit": 2
        }'
    )
) AS doc_result;


-- ============================================================
-- Step 4: ハイブリッド検索 - 構造化 + ドキュメント を結合して RAG
-- ============================================================

-- ---- 例1: 「経費申請のルールと現在の申請状況を教えて」----

SET hybrid_query = '接待費の申請ルールと、現在の申請状況を教えてください';
SET target_dept  = '経理部';

WITH
-- [A] 構造化データ: 対象部署の経費申請レコードを集計
structured_context AS (
    SELECT
        LISTAGG(
            ea.emp_code || ' ' || e.name
            || '（' || e.department || '）: '
            || ea.category || ' ¥' || TO_CHAR(ea.amount, '999,999')
            || ' [' || ea.status || '] ' || ea.description,
            '\n'
        ) AS records_text,
        COUNT(*)                      AS total_count,
        SUM(CASE WHEN ea.status = '申請中' THEN 1 ELSE 0 END)  AS pending_count,
        SUM(CASE WHEN ea.status = '却下'   THEN 1 ELSE 0 END)  AS rejected_count,
        SUM(CASE WHEN ea.status = '承認済' THEN ea.amount ELSE 0 END) AS approved_total
    FROM expense_applications ea
    JOIN employees e ON ea.emp_code = e.emp_code
    WHERE e.department = $target_dept
),
-- [B] ドキュメント検索: 規定・ポリシーを Cortex Search で取得
doc_search AS (
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
doc_context AS (
    SELECT LISTAGG(
        '【' || r.value:doc_name::VARCHAR || '】\n'
        || r.value:content::VARCHAR,
        '\n\n'
    ) AS policy_text
    FROM doc_search,
        LATERAL FLATTEN(input => result:results) r
),
-- [C] 両方のコンテキストを結合してプロンプト構築
combined AS (
    SELECT
        CONCAT(
            '=== 経費申請規定（社内ポリシー） ===\n',
            dc.policy_text,
            '\n\n',
            '=== ', $target_dept, ' の経費申請データ（直近） ===\n',
            '申請件数: ', sc.total_count, '件',
            '（承認済: ', (sc.total_count - sc.pending_count - sc.rejected_count),
            '件 / 申請中: ', sc.pending_count,
            '件 / 却下: ', sc.rejected_count, '件）\n',
            '承認済合計金額: ¥', TO_CHAR(sc.approved_total, '999,999,999'), '\n\n',
            '申請明細:\n', sc.records_text
        ) AS full_context
    FROM structured_context sc, doc_context dc
)
-- [D] LLM で回答生成
SELECT
    $hybrid_query AS "質問",
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '社内の経費担当アシスタントです。以下の規定と申請データを元に質問に日本語で回答してください。\n',
            '規定と実際のデータ両方を参照して、具体的に回答してください。\n\n',
            full_context,
            '\n\n質問: ', $hybrid_query
        )
    ) AS "回答"
FROM combined;


-- ============================================================
-- Step 5: ハイブリッド検索 - 有給残日数 × 休暇規定
-- ============================================================

SET leave_query = '有給休暇が少ない社員と、取得ルールを教えてください';

WITH
-- [A] 有給残日数が少ない社員（残5日以下）
structured_context AS (
    SELECT LISTAGG(
        emp_code || ' ' || name
        || '（' || department || '）: '
        || '残' || (annual_leave - used_leave) || '日'
        || '（付与' || annual_leave || '日 / 取得済' || used_leave || '日）',
        '\n'
    ) AS records_text,
    COUNT(*) AS alert_count
    FROM employees
    WHERE (annual_leave - used_leave) <= 5
),
-- [B] 有給規定ドキュメント検索
doc_search AS (
    SELECT PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'company_doc_search',
            '{"query": "有給休暇 付与 申請 繰り越し",
              "columns": ["doc_name", "content"],
              "filter": {"@eq": {"department": "人事部"}},
              "limit": 2}'
        )
    ) AS result
),
doc_context AS (
    SELECT LISTAGG(
        '【' || r.value:doc_name::VARCHAR || '】\n' || r.value:content::VARCHAR,
        '\n\n'
    ) AS policy_text
    FROM doc_search, LATERAL FLATTEN(input => result:results) r
),
combined AS (
    SELECT CONCAT(
        '=== 有給休暇規定 ===\n', dc.policy_text, '\n\n',
        '=== 有給残少ない社員（残5日以下） ===\n',
        '対象者数: ', sc.alert_count, '名\n',
        sc.records_text
    ) AS full_context
    FROM structured_context sc, doc_context dc
)
SELECT
    $leave_query AS "質問",
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '人事担当アシスタントです。以下の規定と社員データを元に、',
            '有給消化が必要な社員への案内を日本語で作成してください。\n\n',
            full_context,
            '\n\n質問: ', $leave_query
        )
    ) AS "回答"
FROM combined;


-- ============================================================
-- Step 6: ハイブリッド検索ストアドプロシージャ
-- ============================================================

CREATE OR REPLACE PROCEDURE hybrid_rag_search(
    query_text          VARCHAR,
    structured_context  VARCHAR,  -- 呼び出し側で事前にSQL集計したテキストを渡す
    doc_filter_category VARCHAR DEFAULT NULL,
    doc_limit           NUMBER   DEFAULT 2,
    llm_model           VARCHAR  DEFAULT 'llama3.1-70b'
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, query_text: str, structured_context: str,
        doc_filter_category: str, doc_limit: int, llm_model: str) -> str:

    # 1. Cortex Search でドキュメント取得
    search_query = {
        "query": query_text,
        "columns": ["doc_name", "content", "category", "department"],
        "limit": doc_limit
    }
    if doc_filter_category:
        search_query["filter"] = {"@eq": {"category": doc_filter_category}}

    search_result = session.sql(
        "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('company_doc_search', ?) AS result",
        [json.dumps(search_query, ensure_ascii=False)]
    ).collect()[0]["RESULT"]

    data = json.loads(search_result)
    doc_parts = []
    for i, r in enumerate(data.get("results", []), 1):
        doc_parts.append(
            f"[文書{i}] 【{r.get('doc_name')}】\n{r.get('content')}"
        )

    doc_context = "\n\n".join(doc_parts) if doc_parts else "関連ドキュメントなし"

    # 2. 構造化コンテキスト + ドキュメントコンテキストを結合
    full_context = (
        f"=== 構造化データ（DB レコード） ===\n{structured_context}\n\n"
        f"=== 関連ドキュメント（規定・ポリシー） ===\n{doc_context}"
    )

    # 3. LLM で回答生成
    prompt = (
        f"以下のデータと規定を参考に、質問に日本語で具体的に回答してください。\n"
        f"データと規定の両方を活用して回答し、参照した文書は[文書N]で明示してください。\n\n"
        f"{full_context}\n\n"
        f"質問: {query_text}"
    )

    answer = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?) AS answer",
        [llm_model, prompt]
    ).collect()[0]["ANSWER"]

    return answer
$$;

-- ---- ストアドプロシージャ呼び出しサンプル ----

-- Step1: 構造化データをSQL集計してテキストに変換
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

-- Step2: ハイブリッドRAG実行
CALL hybrid_rag_search(
    '申請中・却下の経費について、規定に照らしてどのような対応が必要か教えてください',
    $struct_ctx,
    '財務規定',
    2,
    'llama3.1-70b'
);


-- ============================================================
-- Step 7: 検索結果の比較（構造化のみ vs ドキュメントのみ vs ハイブリッド）
-- ============================================================

-- この出力を並べて見ると「ハイブリッドの価値」がわかる

SET compare_query = '接待費の却下申請はどう対処すべきか？';

-- [A] 構造化データのみの回答
WITH struct_only AS (
    SELECT LISTAGG(
        e.name || ': ' || ea.category || ' ¥' || ea.amount || ' → ' || ea.description,
        '\n'
    ) AS ctx
    FROM expense_applications ea
    JOIN employees e ON ea.emp_code = e.emp_code
    WHERE ea.status = '却下'
)
SELECT
    '構造化のみ' AS 検索種別,
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT('以下のデータを元に質問に答えてください。\n\n', ctx, '\n\n質問: ', $compare_query)
    ) AS 回答
FROM struct_only

UNION ALL

-- [B] ドキュメントのみの回答
SELECT
    'ドキュメントのみ',
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '以下の規定を元に質問に答えてください。\n\n',
            (
                SELECT LISTAGG(r.value:content::VARCHAR, '\n\n')
                FROM (
                    SELECT PARSE_JSON(
                        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                            'company_doc_search',
                            '{"query": "接待費 上限 却下 承認",
                              "columns": ["doc_name","content"],
                              "limit": 2}'
                        )
                    ) AS result
                ),
                LATERAL FLATTEN(input => result:results) r
            ),
            '\n\n質問: ', $compare_query
        )
    )
FROM (SELECT 1)

UNION ALL

-- [C] ハイブリッド（両方合算）
SELECT
    'ハイブリッド',
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '以下のデータと規定を両方参考にして、質問に具体的に答えてください。\n\n',
            -- 構造化
            '=== 却下申請データ ===\n',
            (
                SELECT LISTAGG(
                    e.name || ': ¥' || ea.amount || ' ' || ea.description, '\n'
                )
                FROM expense_applications ea
                JOIN employees e ON ea.emp_code = e.emp_code
                WHERE ea.status = '却下'
            ),
            '\n\n',
            -- ドキュメント
            '=== 経費規定 ===\n',
            (
                SELECT LISTAGG(r.value:content::VARCHAR, '\n\n')
                FROM (
                    SELECT PARSE_JSON(
                        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                            'company_doc_search',
                            '{"query": "接待費 上限 承認 規定",
                              "columns": ["doc_name","content"],
                              "limit": 2}'
                        )
                    ) AS result
                ),
                LATERAL FLATTEN(input => result:results) r
            ),
            '\n\n質問: ', $compare_query
        )
    )
FROM (SELECT 1);
