-- ============================================================
-- Snowflake Cortex RAG デモ: RAG クエリサンプル集
-- ============================================================
USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- サンプル 1: 基本的な RAG クエリ
-- ============================================================
SET query_1 = '有給休暇は何日もらえますか？';

WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_1
    ) AS vec
),
top_chunks AS (
    SELECT
        c.doc_name,
        c.chunk_text,
        VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS score
    FROM document_chunks_vec c, query_vec q
    ORDER BY score DESC
    LIMIT 3
),
context AS (
    SELECT LISTAGG(
        '【' || doc_name || '】: ' || chunk_text,
        '\n\n'
    ) AS context_text
    FROM top_chunks
)
SELECT
    $query_1 AS question,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic',
        CONCAT(
            'あなたは社内規定の専門家です。以下の文書を参考に質問に日本語で答えてください。\n\n',
            '=== 参考文書 ===\n', context_text,
            '\n\n=== 質問 ===\n', $query_1
        )
    ) AS answer
FROM context;

-- ============================================================
-- サンプル 2: 複数の質問をバッチ処理
-- ============================================================
CREATE OR REPLACE TEMPORARY TABLE batch_questions (
    question_id NUMBER,
    question    VARCHAR
);

INSERT INTO batch_questions VALUES
(1, '在宅勤務の申請期限はいつですか？'),
(2, '接待費の上限はいくらですか？'),
(3, 'パスワードの要件を教えてください'),
(4, 'Snowflakeのウェアハウスの自動停止設定は何分ですか？');

-- 全質問に対して一括でRAGを実行
-- ※ Snowflake はスカラーサブクエリ内の CTE 不可のため、段階的 CTE で処理
WITH question_embeddings AS (
    -- Step1: 全質問のベクトルをまとめて生成
    SELECT
        question_id,
        question,
        SNOWFLAKE.CORTEX.EMBED_TEXT_768(
            'snowflake-arctic-embed-m',
            question
        ) AS vec
    FROM batch_questions
),
all_scores AS (
    -- Step2: 全チャンクとの類似度を計算
    SELECT
        qe.question_id,
        qe.question,
        dc.chunk_text,
        VECTOR_COSINE_SIMILARITY(dc.chunk_vec, qe.vec) AS score
    FROM question_embeddings qe
    CROSS JOIN document_chunks_vec dc
),
ranked AS (
    -- Step3: 類似度でランク付け (閾値 0.5 以上)
    SELECT
        question_id,
        question,
        chunk_text,
        score,
        ROW_NUMBER() OVER (PARTITION BY question_id ORDER BY score DESC) AS rn
    FROM all_scores
    WHERE score >= 0.5
),
context AS (
    -- Step4: 上位2件のチャンクを質問ごとに結合
    SELECT
        question_id,
        question,
        LISTAGG(chunk_text, '\n') AS context_text
    FROM ranked
    WHERE rn <= 2
    GROUP BY question_id, question
)
SELECT
    question_id,
    question,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic',
        CONCAT(
            '以下の文書を参考に質問に答えてください。\n\n文書: ',
            context_text,
            '\n\n質問: ', question
        )
    ) AS answer
FROM context
ORDER BY question_id;

-- ============================================================
-- サンプル 3: 出典付き回答（引用番号付き）
-- ============================================================
SET query_3 = 'セキュリティに関するルールを3点挙げてください';

WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_3
    ) AS vec
),
top_chunks AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) DESC) AS ref_no,
        c.doc_name,
        c.chunk_text,
        ROUND(VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec), 4) AS score
    FROM document_chunks_vec c, query_vec q
    ORDER BY score DESC
    LIMIT 4
),
context AS (
    SELECT
        LISTAGG(
            '[' || ref_no || '] 【' || doc_name || '】: ' || chunk_text,
            '\n\n'
        ) AS context_text,
        LISTAGG(
            '[' || ref_no || '] ' || doc_name || ' (類似度: ' || score || ')',
            ' | '
        ) AS sources_summary
    FROM top_chunks
)
SELECT
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '以下の参考文書[1][2][3][4]を使って質問に答えてください。',
            '各ポイントに参照番号[N]を付けてください。\n\n',
            context_text,
            '\n\n質問: ', $query_3
        )
    ) AS answer,
    sources_summary AS "参照文書"
FROM context;

-- ============================================================
-- サンプル 4: 異なる LLM モデルの比較
-- ============================================================
SET query_4 = '経費精算で必要な書類は何ですか？';

WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_4
    ) AS vec
),
top_chunks AS (
    SELECT
        chunk_text,
        VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS score
    FROM document_chunks_vec c, query_vec q
    ORDER BY score DESC
    LIMIT 2
),
context AS (
    SELECT LISTAGG(chunk_text, '\n') AS context_text
    FROM top_chunks
)
SELECT
    'snowflake-arctic' AS model,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic',
        CONCAT('文書: ', context_text, '\n\n質問: ', $query_4)
    ) AS answer
FROM context
UNION ALL
SELECT
    'llama3.1-70b' AS model,
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT('文書: ', context_text, '\n\n質問: ', $query_4)
    ) AS answer
FROM context
UNION ALL
SELECT
    'mistral-large2' AS model,
    SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        CONCAT('文書: ', context_text, '\n\n質問: ', $query_4)
    ) AS answer
FROM context;

-- ============================================================
-- サンプル 5: 閾値を使った「わからない」応答
-- ============================================================
SET query_5 = '社員食堂のメニューを教えてください';  -- 存在しない情報

WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_5
    ) AS vec
),
top_chunks AS (
    SELECT
        chunk_text,
        VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS score
    FROM document_chunks_vec c, query_vec q
    ORDER BY score DESC
    LIMIT 3
),
context AS (
    SELECT
        CASE
            WHEN MAX(score) >= 0.6
            THEN LISTAGG(chunk_text, '\n')
            ELSE NULL
        END AS context_text,
        MAX(score) AS max_score
    FROM top_chunks
)
SELECT
    $query_5 AS question,
    ROUND(max_score, 4) AS "最高類似度スコア",
    CASE
        WHEN context_text IS NULL
        THEN '申し訳ありませんが、その質問に関連する社内文書が見つかりませんでした。'
        ELSE SNOWFLAKE.CORTEX.COMPLETE(
            'snowflake-arctic',
            CONCAT('文書: ', context_text, '\n\n質問: ', $query_5)
        )
    END AS answer
FROM context;

-- ============================================================
-- サンプル 6: RAG ストアドプロシージャの呼び出し
-- ============================================================

-- ストアドプロシージャが作成済みの場合
-- CALL rag_search('有給休暇の繰り越しルールは？');
-- CALL rag_search('パスワードの変更頻度を教えてください', 3, 0.4, 'llama3.1-70b');

-- ============================================================
-- パフォーマンス確認: クエリ履歴の確認
-- ============================================================
SELECT
    QUERY_TEXT,
    EXECUTION_TIME / 1000 AS exec_sec,
    CREDITS_USED_CLOUD_SERVICES
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE QUERY_TEXT LIKE '%EMBED_TEXT%'
   OR QUERY_TEXT LIKE '%COMPLETE%'
ORDER BY START_TIME DESC
LIMIT 20;
