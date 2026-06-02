-- ============================================================
-- Cortex Agent セットアップ
-- エージェントAPIを呼び出すストアドプロシージャ
-- ============================================================

-- ============================================================
-- 1. セマンティックモデルのステージアップロード確認
-- ============================================================

-- ステージ内のファイルを確認
LIST @CHATBOT_MODELS_STAGE;

-- ============================================================
-- 2. エージェント呼び出し用ストアドプロシージャ
-- ============================================================

CREATE OR REPLACE PROCEDURE SP_CHATBOT_AGENT(
    p_question     VARCHAR,
    p_conv_history VARIANT   -- 会話履歴（JSON配列）
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
AS
$$
import _snowflake
import json
import requests
import time

def run(session, p_question: str, p_conv_history):
    """
    Cortex AgentにリクエストしてSSEストリームをパースして回答を返す
    """
    # Snowflakeの内部認証トークンを取得
    token = _snowflake.get_snowflake_env_var('SNOWFLAKE_HOST')
    host = session.sql("SELECT CURRENT_ACCOUNT()").collect()[0][0].lower()
    account_url = f"https://{host}.snowflakecomputing.com"

    # 会話履歴を構築
    messages = []
    if p_conv_history:
        for msg in p_conv_history:
            messages.append(msg)

    # 新しいユーザーメッセージを追加
    messages.append({
        "role": "user",
        "content": [{"type": "text", "text": p_question}]
    })

    # リクエストペイロード
    payload = {
        "model": "claude-3-5-sonnet",
        "messages": messages,
        "tools": [
            {
                "tool_spec": {
                    "type": "cortex_analyst_text_to_sql",
                    "name": "impact_analysis_tool"
                },
                "tool_resources": {
                    "semantic_model": "@CHATBOT_MODELS_STAGE/semantic_model.yaml"
                }
            },
            {
                "tool_spec": {
                    "type": "cortex_search_service",
                    "name": "source_code_search_tool"
                },
                "tool_resources": {
                    "cortex_search_service": f"{session.get_current_database()}.{session.get_current_schema()}.SRC_SEARCH_SERVICE"
                }
            }
        ],
        "tool_choice": "auto",
        "stream": True
    }

    # エージェントAPIを呼び出し
    resp = requests.post(
        f"{account_url}/api/v2/cortex/agents/execute",
        json=payload,
        headers={
            "Authorization": f"Bearer {_snowflake.get_snowflake_env_var('SNOWFLAKE_JWT_TOKEN')}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        },
        stream=True,
        timeout=60
    )

    # SSEストリームをパース
    answer_text = ""
    used_tools = []

    for line in resp.iter_lines():
        if not line:
            continue
        line_str = line.decode("utf-8")
        if not line_str.startswith("data: "):
            continue

        data_str = line_str[6:]
        if data_str == "[DONE]":
            break

        try:
            event = json.loads(data_str)
        except json.JSONDecodeError:
            continue

        event_type = event.get("type", "")

        # テキスト回答の取得
        if event_type == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                answer_text += delta.get("text", "")

        # ツール使用履歴の取得
        elif event_type == "tool_use":
            used_tools.append(event.get("name", ""))

    return {
        "answer": answer_text,
        "used_tools": used_tools,
        "status": "success"
    }
$$;

-- ============================================================
-- 3. 評価用: バッチテスト実行プロシージャ
-- ============================================================

CREATE OR REPLACE PROCEDURE SP_RUN_EVAL_BATCH(
    p_tool_type VARCHAR  -- 'search_only' または 'hybrid'
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    result_msg VARCHAR DEFAULT '';
BEGIN
    -- テストケーステーブルからケースを読み込み、エージェントを呼び出す処理
    -- 実際の実装はPythonスクリプトで行うことを推奨（ループ処理のため）
    result_msg := 'バッチ評価はPythonスクリプト(evaluate_agent.py)で実行してください。';
    RETURN result_msg;
END;
$$;

-- ============================================================
-- 4. 動作テスト: プロシージャを直接呼び出し
-- ============================================================

-- 影響調査クエリのテスト
CALL SP_CHATBOT_AGENT(
    '受注テーブルを更新しているジョブを教えてください。',
    PARSE_JSON('[]')
);

-- ソースコード解説クエリのテスト
CALL SP_CHATBOT_AGENT(
    'JOB_ORDER_001.sqlはどんな処理をしているプログラムですか？',
    PARSE_JSON('[]')
);

-- ============================================================
-- 5. 評価結果集計クエリ
-- ============================================================

-- カテゴリ・ツール別のスコア集計
SELECT
    category,
    tool_type,
    COUNT(*) AS total_cases,
    ROUND(AVG(CASE WHEN is_correct THEN 1.0 ELSE 0.0 END) * 100, 1) AS accuracy_pct,
    ROUND(AVG(recall_score) * 100, 1) AS avg_recall_pct,
    ROUND(AVG(precision_score) * 100, 1) AS avg_precision_pct,
    ROUND(AVG(relevance_score), 2) AS avg_relevance_score,
    ROUND(AVG(response_sec), 2) AS avg_response_sec
FROM T_EVAL_RESULTS
GROUP BY category, tool_type
ORDER BY category, tool_type;

-- Search only vs Hybrid の比較サマリー
SELECT
    tool_type,
    ROUND(AVG(CASE WHEN category IN ('A','B') AND is_correct THEN 1.0 ELSE 0.0 END) * 100, 1) AS impact_accuracy_pct,
    ROUND(AVG(CASE WHEN category IN ('C','D') THEN relevance_score ELSE NULL END), 2) AS code_search_score,
    ROUND(AVG(CASE WHEN category = 'E' AND tool_match THEN 1.0 ELSE 0.0 END) * 100, 1) AS tool_routing_accuracy_pct,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY response_sec), 2) AS p95_response_sec
FROM T_EVAL_RESULTS
GROUP BY tool_type;
