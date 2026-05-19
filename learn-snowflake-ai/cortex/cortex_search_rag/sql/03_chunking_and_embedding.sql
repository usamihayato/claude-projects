-- ============================================================
-- Snowflake Cortex RAG デモ: チャンキング & 埋め込み生成
-- ============================================================
USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 1: チャンキング処理
-- ============================================================

-- 改行区切りのシンプルなチャンキング
TRUNCATE TABLE document_chunks;

INSERT INTO document_chunks (doc_id, doc_name, chunk_text, chunk_index)
SELECT
    d.doc_id,
    d.doc_name,
    TRIM(f.value::VARCHAR) AS chunk_text,
    f.index AS chunk_index
FROM documents d,
    LATERAL FLATTEN(input => SPLIT(d.doc_content, '\n')) f
WHERE TRIM(f.value::VARCHAR) != ''
  AND LENGTH(TRIM(f.value::VARCHAR)) > 10;  -- 短すぎる行を除外

-- チャンク確認
SELECT
    doc_name,
    chunk_index,
    LENGTH(chunk_text) AS char_count,
    LEFT(chunk_text, 100) AS preview
FROM document_chunks
ORDER BY doc_id, chunk_index;

SELECT COUNT(*) AS total_chunks FROM document_chunks;

-- ============================================================
-- Step 2: 埋め込み生成（EMBED_TEXT_768）
-- ============================================================

-- 処理には数秒〜数分かかります
TRUNCATE TABLE document_chunks_vec;

INSERT INTO document_chunks_vec (
    chunk_id, doc_id, doc_name, chunk_text, chunk_index, chunk_vec, embed_model
)
SELECT
    chunk_id,
    doc_id,
    doc_name,
    chunk_text,
    chunk_index,
    SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        chunk_text
    ) AS chunk_vec,
    'snowflake-arctic-embed-m' AS embed_model
FROM document_chunks;

-- 埋め込み確認（vec_status が ✅ OK = 生成成功、❌ NULL = 生成失敗）
SELECT
    chunk_id,
    doc_name,
    LEFT(chunk_text, 60) AS preview,
    768                   AS dimensions,       -- snowflake-arctic-embed-m の固定次元数
    IFF(chunk_vec IS NOT NULL, '✅ OK', '❌ NULL') AS vec_status
FROM document_chunks_vec
LIMIT 10;

SELECT COUNT(*) AS embedded_chunks FROM document_chunks_vec;

-- ============================================================
-- Step 3: ベクトルの品質確認（サンプル類似度チェック）
-- ============================================================

-- 同じドキュメントのチャンク同士は類似度が高いはず
WITH sample_pairs AS (
    SELECT
        a.chunk_id AS chunk_a,
        b.chunk_id AS chunk_b,
        a.doc_name,
        LEFT(a.chunk_text, 40) AS text_a,
        LEFT(b.chunk_text, 40) AS text_b,
        VECTOR_COSINE_SIMILARITY(a.chunk_vec, b.chunk_vec) AS similarity,
        CASE
            WHEN a.doc_id = b.doc_id THEN '同一ドキュメント'
            ELSE '異なるドキュメント'
        END AS relation
    FROM document_chunks_vec a
    JOIN document_chunks_vec b ON a.chunk_id < b.chunk_id
    LIMIT 20
)
SELECT
    relation,
    ROUND(AVG(similarity), 4) AS avg_similarity,
    ROUND(MIN(similarity), 4) AS min_similarity,
    ROUND(MAX(similarity), 4) AS max_similarity,
    COUNT(*) AS pair_count
FROM sample_pairs
GROUP BY relation;

-- ============================================================
-- Step 4: 類似検索のテスト
-- ============================================================

SET test_query = '有給休暇を申請するにはどうすればいいですか？';

-- クエリのベクトル化と類似検索
WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $test_query
    ) AS vec
)
SELECT
    c.doc_name,
    c.chunk_text,
    ROUND(VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec), 4) AS similarity_score
FROM document_chunks_vec c, query_vec q
ORDER BY similarity_score DESC
LIMIT 5;

-- ============================================================
-- Step 5: 異なる埋め込みモデルの比較（オプション）
-- ============================================================

-- voyage-multilingual-2 は多言語対応で精度が高い
-- （クレジット消費が多いため注意）

/*
-- 1024次元での埋め込み生成
CREATE TABLE IF NOT EXISTS document_chunks_vec_1024 (
    chunk_id    NUMBER PRIMARY KEY,
    doc_id      VARCHAR,
    doc_name    VARCHAR,
    chunk_text  VARCHAR NOT NULL,
    chunk_index NUMBER,
    chunk_vec   VECTOR(FLOAT, 1024),
    embed_model VARCHAR DEFAULT 'voyage-multilingual-2',
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO document_chunks_vec_1024 (
    chunk_id, doc_id, doc_name, chunk_text, chunk_index, chunk_vec, embed_model
)
SELECT
    chunk_id, doc_id, doc_name, chunk_text, chunk_index,
    SNOWFLAKE.CORTEX.EMBED_TEXT_1024(
        'voyage-multilingual-2',
        chunk_text
    ),
    'voyage-multilingual-2'
FROM document_chunks;
*/

-- ============================================================
-- 完了確認
-- ============================================================
SELECT
    'documents' AS table_name, COUNT(*) AS row_count FROM documents
UNION ALL
SELECT 'document_chunks', COUNT(*) FROM document_chunks
UNION ALL
SELECT 'document_chunks_vec', COUNT(*) FROM document_chunks_vec;
