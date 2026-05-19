-- ============================================================
-- パターン2: Cortex Analyst + RAG
-- ============================================================
-- 目的:
--   自然言語 → Cortex Analyst がSQLを生成 → 実行結果をLLMに渡す。
--   物理カラム名・コード値の知識はセマンティックモデル(YAML)が持つため、
--   RAGの呼び出し側はSQLを意識せずに構造化データを活用できる。
--
--   [フロー]
--   質問 (自然言語)
--       ↓ Cortex Analyst REST API (セマンティックモデルを参照)
--   生成SQL (コードマスタJOIN・デコード済み)
--       ↓ Snowflake で実行
--   クエリ結果 (人が読めるラベル)
--       ↓ Cortex Search のドキュメントと合算
--   CORTEX.COMPLETE → 回答
-- ============================================================

USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 1: セマンティックモデルをステージにアップロード
-- ============================================================

-- ステージが存在しない場合は作成
CREATE STAGE IF NOT EXISTS analyst_stage
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- ローカルからアップロード（Snowsight UI または SnowSQL で実行）
-- PUT file://cortex_analyst/expense_semantic_model.yaml @analyst_stage AUTO_COMPRESS=FALSE;

-- アップロード確認
LIST @analyst_stage;

-- ============================================================
-- Step 2: Cortex Analyst を呼び出すストアドプロシージャ
-- ============================================================
-- Cortex Analyst は REST API で提供される。
-- Python ストアドプロシージャ内から requests で呼び出す。

CREATE OR REPLACE PROCEDURE analyst_to_sql(
    question    VARCHAR,
    stage_path  VARCHAR DEFAULT '@analyst_stage/expense_semantic_model.yaml'
)
RETURNS OBJECT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
AS
$$
import json
import requests
from snowflake.snowpark import Session

def run(session: Session, question: str, stage_path: str) -> dict:

    # Snowflake 接続情報を取得
    account = session.get_current_account().strip('"')
    token   = session._conn._rest._token   # セッショントークン（内部API）

    # セマンティックモデルの参照パス（ステージURI形式）
    # @db.schema.stage/file.yaml → semantic_model_file に変換
    semantic_model_ref = stage_path  # 例: @RAG_DEMO_DB.RAG_SCHEMA.analyst_stage/expense_semantic_model.yaml

    # Cortex Analyst REST API エンドポイント
    url = f"https://{account}.snowflakecomputing.com/api/v2/cortex/analyst/message"

    payload = {
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": question}]}
        ],
        "semantic_model_file": semantic_model_ref
    }

    headers = {
        "Authorization": f"Snowflake Token=\"{token}\"",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=60)
    resp.raise_for_status()
    data = resp.json()

    # レスポンスからSQLと解説を抽出
    result = {"question": question, "sql": None, "explanation": None, "error": None}

    message_content = data.get("message", {}).get("content", [])
    for item in message_content:
        if item.get("type") == "sql":
            result["sql"] = item.get("statement")
        elif item.get("type") == "text":
            result["explanation"] = item.get("text")

    if not result["sql"]:
        result["error"] = "SQLを生成できませんでした"

    return result
$$;

-- ============================================================
-- Step 3: Cortex Analyst + Cortex Search のハイブリッドRAG
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_hybrid_rag(
    question        VARCHAR,
    doc_search_query VARCHAR DEFAULT NULL,   -- ドキュメント検索クエリ（NULLなら question を流用）
    doc_category    VARCHAR DEFAULT NULL,
    llm_model       VARCHAR DEFAULT 'llama3.1-70b'
)
RETURNS OBJECT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
AS
$$
import json
import requests
from snowflake.snowpark import Session

def _call_analyst(session: Session, question: str) -> dict:
    """Cortex Analyst を呼び出してSQLと解説を返す"""
    account = session.get_current_account().strip('"')
    token   = session._conn._rest._token
    url = f"https://{account}.snowflakecomputing.com/api/v2/cortex/analyst/message"

    payload = {
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": question}]}
        ],
        "semantic_model_file": "@RAG_DEMO_DB.RAG_SCHEMA.analyst_stage/expense_semantic_model.yaml"
    }
    headers = {
        "Authorization": f"Snowflake Token=\"{token}\"",
        "Content-Type": "application/json"
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=60)
    resp.raise_for_status()
    data = resp.json()

    sql, explanation = None, None
    for item in data.get("message", {}).get("content", []):
        if item.get("type") == "sql":
            sql = item.get("statement")
        elif item.get("type") == "text":
            explanation = item.get("text")
    return {"sql": sql, "explanation": explanation}

def _exec_sql(session: Session, sql: str) -> str:
    """SQLを実行してテキスト形式に変換する"""
    rows = session.sql(sql).collect()
    if not rows:
        return "該当データなし"

    # ヘッダー行
    headers = list(rows[0].as_dict().keys())
    lines = [" | ".join(headers)]
    lines.append("-" * len(lines[0]))

    # データ行（最大20件）
    for row in rows[:20]:
        d = row.as_dict()
        lines.append(" | ".join(str(d.get(h, "")) for h in headers))

    if len(rows) > 20:
        lines.append(f"... 他 {len(rows) - 20} 件")

    return "\n".join(lines)

def _search_docs(session: Session, query: str, category: str, limit: int = 2) -> str:
    """Cortex Search でドキュメントを検索してテキストに変換する"""
    search_query = {
        "query": query,
        "columns": ["doc_name", "content"],
        "limit": limit
    }
    if category:
        search_query["filter"] = {"@eq": {"category": category}}

    raw = session.sql(
        "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('company_doc_search', ?) AS r",
        [json.dumps(search_query, ensure_ascii=False)]
    ).collect()[0]["R"]

    data = json.loads(raw)
    parts = []
    for r in data.get("results", []):
        parts.append(f"【{r.get('doc_name')}】\n{r.get('content')}")
    return "\n\n".join(parts) if parts else "関連ドキュメントなし"

def run(session: Session, question: str, doc_search_query: str,
        doc_category: str, llm_model: str) -> dict:

    # 1. Cortex Analyst で SQL 生成
    analyst_result = _call_analyst(session, question)
    generated_sql  = analyst_result.get("sql")
    sql_explanation = analyst_result.get("explanation", "")

    if not generated_sql:
        return {
            "answer": "構造化データのクエリを生成できませんでした",
            "generated_sql": None,
            "error": "Cortex Analyst から SQL が返りませんでした"
        }

    # 2. 生成SQLを実行
    structured_text = _exec_sql(session, generated_sql)

    # 3. Cortex Search でドキュメント検索
    doc_query = doc_search_query if doc_search_query else question
    doc_text  = _search_docs(session, doc_query, doc_category)

    # 4. コンテキスト結合
    full_context = (
        f"=== 構造化データ（Cortex Analyst が生成したSQL結果）===\n"
        f"{structured_text}\n\n"
        f"=== 関連ドキュメント（規定・ポリシー） ===\n"
        f"{doc_text}"
    )

    # 5. LLM で回答生成
    prompt = (
        f"以下のデータと規定を参考に、質問に日本語で具体的に回答してください。\n\n"
        f"{full_context}\n\n"
        f"質問: {question}"
    )
    answer = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?) AS a",
        [llm_model, prompt]
    ).collect()[0]["A"]

    return {
        "answer": answer,
        "generated_sql": generated_sql,
        "sql_explanation": sql_explanation
    }
$$;

-- ============================================================
-- Step 4: 実行サンプル
-- ============================================================

-- [1] Cortex Analyst 単体: 自然言語 → SQL の生成だけ確認
CALL analyst_to_sql('却下された接待費の申請一覧を教えてください');
CALL analyst_to_sql('部署ごとの承認済み経費の合計金額を教えてください');
CALL analyst_to_sql('有給残日数が5日以下の社員は誰ですか');

-- [2] ハイブリッドRAG: 構造化 + ドキュメント → 回答
CALL analyst_hybrid_rag(
    '却下された経費申請について、規定上の上限と照らして再申請のアドバイスをください',
    '接待費 上限 承認 規定',   -- ドキュメント検索クエリ
    '財務規定',                -- ドキュメントフィルタ
    'llama3.1-70b'
);

CALL analyst_hybrid_rag(
    '有給残日数が少ない社員への対応方針を教えてください',
    '有給休暇 付与 申請 繰り越し',
    '人事規定',
    'llama3.1-70b'
);

-- ============================================================
-- Step 5: Cortex Analyst の動作確認（REST API 直接呼び出し例）
-- ============================================================
-- SnowSQL / Python SDK からの直接呼び出し（参考）

-- Python SDK (Snowpark Container Services / ローカル) からの例:
-- ----------------------------------------------------------------
-- import requests, json
-- from snowflake.snowpark import Session
--
-- session = Session.builder.configs({...}).create()
-- account = session.get_current_account().strip('"')
-- token   = session._conn._rest._token
--
-- resp = requests.post(
--     f"https://{account}.snowflakecomputing.com/api/v2/cortex/analyst/message",
--     headers={
--         "Authorization": f'Snowflake Token="{token}"',
--         "Content-Type": "application/json"
--     },
--     json={
--         "messages": [
--             {"role": "user", "content": [{"type": "text",
--              "text": "接待費の却下申請一覧"}]}
--         ],
--         "semantic_model_file":
--             "@RAG_DEMO_DB.RAG_SCHEMA.analyst_stage/expense_semantic_model.yaml"
--     }
-- )
-- print(json.dumps(resp.json(), ensure_ascii=False, indent=2))
