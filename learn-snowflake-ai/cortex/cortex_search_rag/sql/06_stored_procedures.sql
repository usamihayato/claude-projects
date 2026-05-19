-- ============================================================
-- Snowflake Cortex RAG デモ: ストアドプロシージャ集
-- ============================================================
USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- 1. 汎用 RAG 検索プロシージャ（VECTOR型 使用）
-- ============================================================
CREATE OR REPLACE PROCEDURE rag_search(
    query_text  VARCHAR,
    top_k       NUMBER DEFAULT 3,
    threshold   FLOAT DEFAULT 0.5,
    model_name  VARCHAR DEFAULT 'snowflake-arctic'
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    result VARCHAR;
BEGIN
    WITH query_vec AS (
        SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
            'snowflake-arctic-embed-m',
            :query_text
        ) AS vec
    ),
    top_chunks AS (
        SELECT
            c.doc_name,
            c.chunk_text,
            VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS score
        FROM document_chunks_vec c, query_vec q
        WHERE VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) >= :threshold
        ORDER BY score DESC
        LIMIT :top_k
    ),
    context AS (
        SELECT
            CASE
                WHEN COUNT(*) = 0 THEN NULL
                ELSE LISTAGG('【' || doc_name || '】: ' || chunk_text, '\n\n')
            END AS context_text
        FROM top_chunks
    )
    SELECT
        CASE
            WHEN context_text IS NULL
            THEN '申し訳ありませんが、関連する情報が見つかりませんでした。'
            ELSE SNOWFLAKE.CORTEX.COMPLETE(
                :model_name,
                CONCAT(
                    'あなたは社内規定の専門家です。以下の文書を参考に質問に日本語で回答してください。\n\n',
                    '=== 参考文書 ===\n', context_text,
                    '\n\n=== 質問 ===\n', :query_text
                )
            )
        END INTO result
    FROM context;

    RETURN result;
END;
$$;

-- テスト
CALL rag_search('有給休暇は何日もらえますか？');
CALL rag_search('パスワードの要件', 3, 0.4, 'llama3.1-70b');
CALL rag_search('存在しない情報', 3, 0.8);

-- ============================================================
-- 2. Cortex Search Service を使用した RAG プロシージャ
-- ============================================================
CREATE OR REPLACE PROCEDURE cortex_search_rag(
    query_text        VARCHAR,
    department_filter VARCHAR DEFAULT NULL,
    llm_model         VARCHAR DEFAULT 'snowflake-arctic',
    result_count      NUMBER DEFAULT 3
)
RETURNS OBJECT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json
from snowflake.snowpark import Session

def run(session: Session, query_text: str, department_filter: str,
        llm_model: str, result_count: int) -> dict:

    # 1. 検索クエリ構築
    search_query = {
        "query": query_text,
        "columns": ["doc_name", "content", "category", "department"],
        "limit": result_count
    }
    if department_filter:
        search_query["filter"] = {"@eq": {"department": department_filter}}

    # 2. Cortex Search で検索
    search_result = session.sql(f"""
        SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'company_doc_search',
            '{json.dumps(search_query, ensure_ascii=False)}'
        ) AS result
    """).collect()[0]["RESULT"]

    data = json.loads(search_result)
    results = data.get("results", [])

    if not results:
        return {"answer": "関連するドキュメントが見つかりませんでした。", "sources": [], "count": 0}

    # 3. コンテキスト構築
    context_parts = []
    sources = []
    for i, r in enumerate(results, 1):
        context_parts.append(f"[{i}] 【{r.get('doc_name')}】\n{r.get('content')}")
        sources.append({
            "rank": i,
            "doc_name": r.get("doc_name"),
            "department": r.get("department"),
            "score": round(r.get("@search_score", 0), 4)
        })

    context_text = "\n\n".join(context_parts)
    prompt = (
        f"以下の社内文書[1][2][3]を参考に質問に日本語で回答してください。"
        f"参照番号[N]を明記してください。\n\n"
        f"=== 参考文書 ===\n{context_text}\n\n"
        f"=== 質問 ===\n{query_text}"
    )

    # 4. LLM で回答生成
    answer = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?) AS answer",
        [llm_model, prompt]
    ).collect()[0]["ANSWER"]

    return {"answer": answer, "sources": sources, "count": len(results)}
$$;

-- テスト
CALL cortex_search_rag('在宅勤務の申請方法を教えてください');
CALL cortex_search_rag('セキュリティポリシー', '情報システム部', 'llama3.1-70b', 3);

-- ============================================================
-- 3. ドキュメント処理パイプライン
-- ============================================================
CREATE OR REPLACE PROCEDURE process_new_documents()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    processed_count NUMBER DEFAULT 0;
BEGIN
    -- 未処理のチャンクに埋め込みを生成
    INSERT INTO document_chunks_vec (
        chunk_id, doc_id, doc_name, chunk_text, chunk_index, chunk_vec, embed_model
    )
    SELECT
        c.chunk_id,
        c.doc_id,
        c.doc_name,
        c.chunk_text,
        c.chunk_index,
        SNOWFLAKE.CORTEX.EMBED_TEXT_768(
            'snowflake-arctic-embed-m',
            c.chunk_text
        ) AS chunk_vec,
        'snowflake-arctic-embed-m'
    FROM document_chunks c
    WHERE NOT EXISTS (
        SELECT 1 FROM document_chunks_vec v
        WHERE v.chunk_id = c.chunk_id
    );

    SELECT COUNT(*) INTO processed_count
    FROM document_chunks_vec
    WHERE created_at >= DATEADD(minute, -5, CURRENT_TIMESTAMP());

    RETURN '処理完了: ' || processed_count || ' チャンクを埋め込み生成しました';
END;
$$;

-- ============================================================
-- 4. ドキュメント削除プロシージャ
-- ============================================================
CREATE OR REPLACE PROCEDURE delete_document(p_doc_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    deleted_chunks NUMBER;
BEGIN
    -- ベクトルチャンクの削除
    DELETE FROM document_chunks_vec
    WHERE doc_id IN (
        SELECT doc_id FROM documents WHERE doc_name = :p_doc_name
    );
    SET deleted_chunks = SQLROWCOUNT;

    -- チャンクの削除
    DELETE FROM document_chunks
    WHERE doc_id IN (
        SELECT doc_id FROM documents WHERE doc_name = :p_doc_name
    );

    -- ドキュメント本体の削除
    DELETE FROM documents WHERE doc_name = :p_doc_name;

    RETURN p_doc_name || ' を削除しました（' || deleted_chunks || ' チャンク削除）';
END;
$$;

-- ============================================================
-- 5. RAG 品質ログ記録プロシージャ
-- ============================================================
CREATE OR REPLACE PROCEDURE log_rag_query(
    p_query       VARCHAR,
    p_answer      VARCHAR,
    p_max_sim     FLOAT,
    p_avg_sim     FLOAT,
    p_model       VARCHAR,
    p_latency_ms  NUMBER,
    p_feedback    VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO rag_quality_log (
        query, answer, max_similarity, avg_similarity,
        model_used, latency_ms, user_feedback
    ) VALUES (
        :p_query, :p_answer, :p_max_sim, :p_avg_sim,
        :p_model, :p_latency_ms, :p_feedback
    );
    RETURN '記録完了';
END;
$$;

-- ============================================================
-- 品質ダッシュボードクエリ
-- ============================================================
-- 日別統計
SELECT
    DATE_TRUNC('day', logged_at)::DATE AS date,
    COUNT(*) AS query_count,
    ROUND(AVG(max_similarity), 4) AS avg_max_similarity,
    ROUND(AVG(latency_ms), 0) AS avg_latency_ms,
    SUM(CASE WHEN user_feedback = 'good' THEN 1 ELSE 0 END) AS good_count,
    SUM(CASE WHEN user_feedback = 'bad' THEN 1 ELSE 0 END) AS bad_count
FROM rag_quality_log
GROUP BY date
ORDER BY date DESC;
