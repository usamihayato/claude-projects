-- ============================================================
-- Snowflake Cortex Search Service: セットアップ & サンプル
-- ============================================================
USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 1: Cortex Search Service の作成
-- ============================================================

-- company_documents テーブルが存在することを確認
SELECT COUNT(*) AS doc_count FROM company_documents;

-- Cortex Search Service の作成
-- ※ 作成には数分かかる場合があります
CREATE OR REPLACE CORTEX SEARCH SERVICE company_doc_search
    ON content                                      -- 主検索対象カラム
    ATTRIBUTES doc_name, category, department       -- フィルタ用属性カラム
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 minute'                        -- インデックス更新間隔
    COMMENT = '社内ドキュメント検索サービス'
AS (
    -- ソースクエリ（ビューや複数テーブルのJOINも可能）
    SELECT
        doc_id,
        doc_name,
        category,
        department,
        content,
        updated_at
    FROM company_documents
);

-- 作成確認
SHOW CORTEX SEARCH SERVICES;
DESCRIBE CORTEX SEARCH SERVICE company_doc_search;

-- ============================================================
-- Step 2: 基本的な検索クエリ
-- ============================================================

-- シンプルな全文検索
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "有給休暇の申請方法",
            "columns": ["doc_name", "content", "category"],
            "limit": 3
        }'
    )
) AS result;

-- ============================================================
-- Step 3: 結果をテーブル形式に展開するビュー
-- ============================================================

-- 検索結果展開のユーティリティクエリ
WITH search_raw AS (
    SELECT PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'company_doc_search',
            '{
                "query": "在宅勤務のルールを教えてください",
                "columns": ["doc_name", "content", "category", "department"],
                "limit": 5
            }'
        )
    ) AS result
)
SELECT
    r.value:doc_name::VARCHAR                           AS doc_name,
    r.value:category::VARCHAR                           AS category,
    r.value:department::VARCHAR                         AS department,
    r.value:"@search_score":reranker_score::FLOAT       AS reranker_score,
    r.value:"@search_score":cosine_similarity::FLOAT    AS cosine_similarity,
    r.value:"@search_score":text_match::FLOAT           AS text_match,
    LEFT(r.value:content::VARCHAR, 200)                 AS content_preview
FROM search_raw,
    LATERAL FLATTEN(input => result:results) r
ORDER BY reranker_score DESC;

-- ============================================================
-- Step 4: フィルタリング検索
-- ============================================================

-- 単一フィルタ: 特定部署のみ
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "申請手続きについて",
            "columns": ["doc_name", "content"],
            "filter": {
                "@eq": {"department": "人事部"}
            },
            "limit": 3
        }'
    )
) AS result;

-- 複合フィルタ: OR 条件
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "セキュリティポリシー",
            "columns": ["doc_name", "content", "department"],
            "filter": {
                "@or": [
                    {"@eq": {"category": "IT規定"}},
                    {"@eq": {"department": "情報システム部"}}
                ]
            },
            "limit": 5
        }'
    )
) AS result;

-- 複合フィルタ: AND 条件
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "申請期限",
            "columns": ["doc_name", "content"],
            "filter": {
                "@and": [
                    {"@eq": {"department": "経理部"}},
                    {"@eq": {"category": "財務規定"}}
                ]
            },
            "limit": 3
        }'
    )
) AS result;

-- ============================================================
-- Step 5: Cortex Search + LLM による完全な RAG
-- ============================================================

SET cs_query = '経費精算の締め切りと必要書類について教えてください';
SET cs_department = '経理部';

WITH search_raw AS (
    SELECT PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'company_doc_search',
            CONCAT(
                '{"query": "', $cs_query, '",',
                '"columns": ["doc_name", "content", "department"],',
                '"filter": {"@eq": {"department": "', $cs_department, '"}},',
                '"limit": 3}'
            )
        )
    ) AS result
),
chunks AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY r.value:"@search_score":reranker_score::FLOAT DESC) AS ref_no,
        r.value:doc_name::VARCHAR                        AS doc_name,
        r.value:content::VARCHAR                         AS content,
        r.value:"@search_score":reranker_score::FLOAT    AS score
    FROM search_raw,
        LATERAL FLATTEN(input => result:results) r
),
context AS (
    SELECT
        LISTAGG(
            '[' || ref_no || '] 【' || doc_name || '】: ' || content,
            '\n\n'
        ) AS context_text,
        LISTAGG(
            '[' || ref_no || '] ' || doc_name,
            ', '
        ) AS sources
    FROM chunks
)
SELECT
    $cs_query AS "質問",
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '以下の社内文書を参考に質問に日本語で回答してください。',
            '参照した文書番号[N]を明記してください。\n\n',
            context_text,
            '\n\n質問: ', $cs_query
        )
    ) AS "回答",
    sources AS "参照文書"
FROM context;

-- ============================================================
-- Step 6: サービスの監視・管理
-- ============================================================

-- サービスの状態確認
SHOW CORTEX SEARCH SERVICES;

-- SHOW結果をテーブル形式で参照する場合
SELECT
    "name",
    "state",
    "target_lag",
    "data_timestamp"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- インデックス更新間隔の変更
ALTER CORTEX SEARCH SERVICE company_doc_search
    SET TARGET_LAG = '5 minutes';

-- サービスの一時停止（コスト削減）
-- ALTER CORTEX SEARCH SERVICE company_doc_search SUSPEND;

-- サービスの再開
-- ALTER CORTEX SEARCH SERVICE company_doc_search RESUME;

-- サービスの削除（不要になった場合）
-- DROP CORTEX SEARCH SERVICE company_doc_search;

-- ============================================================
-- Step 7: ドキュメントの追加と自動インデックス更新の確認
-- ============================================================

-- 新しいドキュメントを追加
INSERT INTO company_documents (doc_name, category, department, content)
VALUES (
    '育児休業規定',
    '人事規定',
    '人事部',
    '育児休業は子が1歳になるまで取得可能です。両親ともに取得した場合は最大1歳2ヶ月まで延長できます。出生後8週間以内に4週間取得できる産後パパ育休制度があります。育児休業中は社会保険料が免除されます。復職支援として短時間勤務制度（子が3歳まで）を利用できます。'
);

-- TARGET_LAG の時間が経過すると自動的にインデックスが更新される
-- 確認: 新しいドキュメントが検索に反映されるか
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'company_doc_search',
        '{
            "query": "育児休業について",
            "columns": ["doc_name", "content"],
            "limit": 3
        }'
    )
) AS result;

-- ============================================================
-- ユーティリティ: 検索パフォーマンス確認
-- ============================================================
SELECT
    QUERY_TEXT,
    ROUND(EXECUTION_TIME / 1000.0, 2) AS exec_sec,
    ROWS_PRODUCED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE QUERY_TEXT LIKE '%SEARCH_PREVIEW%'
ORDER BY START_TIME DESC
LIMIT 10;
