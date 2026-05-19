-- ============================================================
-- Cortex Analyst ストアドプロシージャ定義
-- 実行順: 01_setup.sql → 02_sample_data.sql → このファイル
-- ============================================================

USE ROLE     ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- ============================================================
-- 1. analyst_to_sql: 自然言語 → SQL 生成（生 JSON を返す）
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_to_sql(question VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

SEMANTIC_MODEL = '@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml'

def run(session, question: str) -> dict:
    """
    Cortex Analyst REST API を呼び出し、レスポンス全体を返す。
    レスポンスに生成 SQL とテキスト回答が含まれる。
    """
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {},
        {},
        {
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": question}]}
            ],
            "semantic_model_file": SEMANTIC_MODEL
        },
        None,
        30000
    )
    return json.loads(response["content"])
$$;

-- ============================================================
-- 2. analyst_get_sql: 生成 SQL のみを文字列で返す
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_get_sql(question VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

SEMANTIC_MODEL = '@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml'

def run(session, question: str) -> str:
    """
    Cortex Analyst を呼び出し、生成された SQL 文字列のみを返す。
    SQL が生成されなかった場合は空文字を返す。
    """
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {},
        {},
        {
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": question}]}
            ],
            "semantic_model_file": SEMANTIC_MODEL
        },
        None,
        30000
    )
    resp_json = json.loads(response["content"])

    for item in resp_json.get("message", {}).get("content", []):
        if item.get("type") == "sql":
            return item["statement"]
    return ""
$$;

-- ============================================================
-- 3. analyst_execute: 自然言語 → SQL 生成 → 即時実行
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_execute(question VARCHAR)
RETURNS TABLE()
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

SEMANTIC_MODEL = '@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml'

def run(session, question: str):
    """
    Cortex Analyst で SQL を生成し、その場で実行して結果を返す。
    生成 SQL の透明性を保つため、SQL もログとして出力する。
    """
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {},
        {},
        {
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": question}]}
            ],
            "semantic_model_file": SEMANTIC_MODEL
        },
        None,
        30000
    )
    resp_json = json.loads(response["content"])

    generated_sql = ""
    for item in resp_json.get("message", {}).get("content", []):
        if item.get("type") == "sql":
            generated_sql = item["statement"]
            break

    if not generated_sql:
        return session.create_dataframe(
            [{"message": "SQL が生成されませんでした。質問を具体的にしてみてください。"}]
        )

    return session.sql(generated_sql)
$$;

-- ============================================================
-- 4. analyst_with_context: 会話履歴付きの呼び出し（マルチターン）
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_with_context(
    question         VARCHAR,
    prev_question    VARCHAR DEFAULT '',
    prev_sql         VARCHAR DEFAULT ''
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

SEMANTIC_MODEL = '@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml'

def run(session, question: str, prev_question: str = '', prev_sql: str = '') -> dict:
    """
    前の会話（質問・SQL）をコンテキストとして引き継ぎ、
    「それをさらに地域別に分けて」のようなフォローアップ質問に対応する。
    """
    messages = []

    # 前の会話履歴を追加
    if prev_question:
        messages.append({
            "role": "user",
            "content": [{"type": "text", "text": prev_question}]
        })
    if prev_sql:
        messages.append({
            "role": "analyst",
            "content": [{"type": "sql", "statement": prev_sql}]
        })

    # 今回の質問を追加
    messages.append({
        "role": "user",
        "content": [{"type": "text", "text": question}]
    })

    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {},
        {},
        {
            "messages": messages,
            "semantic_model_file": SEMANTIC_MODEL
        },
        None,
        30000
    )
    return json.loads(response["content"])
$$;

-- ============================================================
-- 5. upload_semantic_model: セマンティックモデルを更新するヘルパー
--    ※ローカルファイルの PUT は外部から実行が必要
--      このプロシージャはステージ内容の確認・削除に使用
-- ============================================================

CREATE OR REPLACE PROCEDURE list_semantic_models()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
def run(session) -> list:
    """ステージ内のセマンティックモデルファイル一覧を返す。"""
    result = session.sql(
        "LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE"
    ).to_pandas()
    return result.to_dict('records')
$$;

-- ============================================================
-- 動作確認
-- ============================================================

-- プロシージャ一覧の確認
SHOW PROCEDURES IN SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA;

-- 基本動作テスト（セマンティックモデルがステージにある前提）
-- CALL analyst_to_sql('月別の売上合計を教えて');
-- CALL analyst_get_sql('先月の売上上位5商品は？');
-- CALL analyst_execute('カテゴリ別の売上構成比');

-- マルチターンのテスト
-- CALL analyst_with_context(
--     'それをさらに地域別に分けて',
--     '先月の売上上位5商品は？',
--     '<前の質問で生成された SQL>'
-- );
