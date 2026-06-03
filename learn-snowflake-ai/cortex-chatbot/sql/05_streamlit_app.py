"""
社内システム保守支援チャットボット
Snowflake Cortex Analyst + Cortex Search ハイブリッドエージェント

Snowflake Streamlit in Snowflake (SiS) で動作させる想定。
"""

import streamlit as st
import _snowflake
import json
import requests
import time
from snowflake.snowpark.context import get_active_session

# ============================================================
# 定数設定
# ============================================================
AGENT_MODEL = "claude-3-5-sonnet"

SEMANTIC_MODEL_STAGE = "@CHATBOT_MODELS_STAGE/semantic_model.yaml"

# Cortex Search Service名（DBとスキーマは実行時のセッションから取得）
SEARCH_SERVICE_NAME = "SRC_SEARCH_SERVICE"

SYSTEM_PROMPT = """あなたは社内システムの保守・調査を支援するアシスタントです。
以下の2つのツールを使用できます。

【ツール選択ルール】

1. impact_analysis_tool (影響調査・CRUD棚卸し):
   以下の質問には必ずこのツールを使用してください。
   - 「〇〇テーブルを使用/参照/更新/削除しているジョブ・プログラムを教えて」
   - 「〇〇ジョブが使っているテーブル一覧を教えて」
   - 「〇〇テーブルへのCRUD操作の一覧を教えて」
   - 「ファイル出力/取り込みが発生する機能は？」
   - 「〇〇ジョブネットに含まれるジョブは？」
   - テーブル名・ジョブ名・CRUDフラグに基づく構造的な検索

2. source_code_search_tool (ソースコード解説・障害調査):
   以下の質問には必ずこのツールを使用してください。
   - 「〇〇.sqlはどんな処理をするプログラムですか？」
   - 「〇〇モジュールの処理内容を教えて」
   - 「このエラーが出た場合の原因と対処法は？」
   - 「〇〇機能の処理フローを解説して」
   - ソースコードの内容・意図・処理ロジックに関する質問

3. 複合質問（両ツールを使用）:
   「〇〇テーブルを更新しているジョブのソースコードを説明して」
   → まずimpact_analysis_toolでジョブを特定し、
     次にsource_code_search_toolでソースコードを検索

【回答ルール】
- 必ず日本語で回答してください
- impact_analysis_toolが生成したSQLを回答に含めてください
- ソースコードを引用する場合は、ファイル名・モジュール名を明記してください
- 確認できなかった情報は「データに存在しません」と伝えてください"""

TOOL_LABELS = {
    "impact_analysis_tool": "影響調査 (Cortex Analyst)",
    "source_code_search_tool": "ソースコード検索 (Cortex Search)",
}

EXAMPLE_QUESTIONS = [
    "受注テーブルを更新しているジョブを教えてください",
    "ファイル出力が発生する機能はどれですか？",
    "JOB_ORDER_001.sqlはどんな処理をしていますか？",
    "受注処理モジュールに含まれるジョブ一覧を教えてください",
    "受注テーブルを削除しているプログラムのソースコードを解説してください",
]

# ============================================================
# Snowflake セッション取得
# ============================================================

@st.cache_resource
def get_session():
    return get_active_session()

# ============================================================
# Cortex Agent API 呼び出し
# ============================================================

def call_cortex_agent(question: str, conv_history: list, session) -> dict:
    """Cortex AgentにリクエストしてSSEストリームを処理する"""
    host = f"https://{_snowflake.get_snowflake_env_var('SNOWFLAKE_HOST')}"
    db = session.get_current_database()
    schema = session.get_current_schema()

    messages = conv_history + [
        {"role": "user", "content": [{"type": "text", "text": question}]}
    ]

    payload = {
        "model": AGENT_MODEL,
        "messages": messages,
        "system": SYSTEM_PROMPT,
        "tools": [
            {
                "tool_spec": {
                    "type": "cortex_analyst_text_to_sql",
                    "name": "impact_analysis_tool"
                },
                "tool_resources": {
                    "semantic_model": SEMANTIC_MODEL_STAGE
                }
            },
            {
                "tool_spec": {
                    "type": "cortex_search_service",
                    "name": "source_code_search_tool"
                },
                "tool_resources": {
                    "cortex_search_service": f"{db}.{schema}.{SEARCH_SERVICE_NAME}"
                }
            }
        ],
        "tool_choice": "auto",
        "stream": True
    }

    resp = requests.post(
        f"{host}/api/v2/cortex/agents/execute",
        json=payload,
        headers={
            "Authorization": f"Bearer {_snowflake.get_snowflake_env_var('SNOWFLAKE_JWT_TOKEN')}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT",
        },
        stream=True,
        timeout=120
    )

    if resp.status_code != 200:
        return {
            "answer": f"エラーが発生しました (HTTP {resp.status_code}): {resp.text}",
            "used_tools": [],
            "sql": None
        }

    answer_text = ""
    used_tools = []
    generated_sql = None

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

        if event_type == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                answer_text += delta.get("text", "")

        elif event_type == "tool_use":
            tool_name = event.get("name", "")
            if tool_name and tool_name not in used_tools:
                used_tools.append(tool_name)

        # Cortex Analystが生成したSQLを抽出
        elif event_type == "tool_result":
            tool_result = event.get("content", {})
            if isinstance(tool_result, dict) and "sql" in str(tool_result):
                try:
                    generated_sql = tool_result.get("sql", None)
                except Exception:
                    pass

    return {
        "answer": answer_text,
        "used_tools": used_tools,
        "sql": generated_sql
    }

# ============================================================
# UI ヘルパー関数
# ============================================================

def render_tool_badges(used_tools: list):
    """使用されたツール名をバッジ形式で表示する"""
    if not used_tools:
        return
    cols = st.columns(len(used_tools))
    for i, tool in enumerate(used_tools):
        label = TOOL_LABELS.get(tool, tool)
        is_analyst = "Analyst" in label
        color = "#1E88E5" if is_analyst else "#43A047"
        cols[i].markdown(
            f'<span style="background-color:{color};color:white;padding:3px 10px;'
            f'border-radius:12px;font-size:12px;font-weight:bold;">{label}</span>',
            unsafe_allow_html=True
        )

def render_chat_message(role: str, content: str, used_tools=None, sql=None):
    """チャットメッセージを表示する"""
    with st.chat_message(role):
        if used_tools:
            render_tool_badges(used_tools)
            st.markdown("")

        st.markdown(content)

        if sql:
            with st.expander("生成されたSQL", expanded=False):
                st.code(sql, language="sql")

# ============================================================
# メインアプリ
# ============================================================

def main():
    st.set_page_config(
        page_title="社内システム保守支援チャットボット",
        page_icon="🤖",
        layout="wide"
    )

    st.title("社内システム保守支援チャットボット")
    st.caption("Cortex Analyst (影響調査) + Cortex Search (ソースコード解説) ハイブリッドエージェント")

    # セッション取得
    session = get_session()

    # 会話履歴の初期化
    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "conv_api_history" not in st.session_state:
        st.session_state.conv_api_history = []

    # ============================================================
    # サイドバー
    # ============================================================
    with st.sidebar:
        st.header("設定・操作")

        if st.button("会話をリセット", type="secondary", use_container_width=True):
            st.session_state.messages = []
            st.session_state.conv_api_history = []
            st.rerun()

        st.divider()

        st.subheader("質問例")
        for q in EXAMPLE_QUESTIONS:
            if st.button(q, use_container_width=True, key=f"example_{q[:20]}"):
                st.session_state["preset_question"] = q
                st.rerun()

        st.divider()

        st.subheader("ツール説明")
        st.markdown("""
        **影響調査 (Cortex Analyst)**
        - テーブル・ジョブのCRUD分析
        - 構造化メタデータへのSQL生成

        **ソースコード解説 (Cortex Search)**
        - ソースコード・概要テキスト検索
        - 処理内容の自然言語説明
        """)

    # ============================================================
    # チャット履歴の表示
    # ============================================================
    for msg in st.session_state.messages:
        render_chat_message(
            role=msg["role"],
            content=msg["content"],
            used_tools=msg.get("used_tools"),
            sql=msg.get("sql")
        )

    # ============================================================
    # メッセージ入力・処理
    # ============================================================
    # プリセット質問がある場合はそれを使用
    preset = st.session_state.pop("preset_question", None)

    if user_input := (preset or st.chat_input("質問を入力してください...")):
        # ユーザーメッセージを表示・保存
        st.session_state.messages.append({"role": "user", "content": user_input})
        render_chat_message("user", user_input)

        # エージェント呼び出し
        with st.chat_message("assistant"):
            with st.spinner("回答を生成中..."):
                start = time.time()
                result = call_cortex_agent(
                    user_input,
                    st.session_state.conv_api_history,
                    session
                )
                elapsed = time.time() - start

            # ツールバッジ表示
            render_tool_badges(result["used_tools"])
            if result["used_tools"]:
                st.markdown("")

            # 回答表示
            st.markdown(result["answer"])

            # SQL表示（Analyst使用時）
            if result.get("sql"):
                with st.expander("生成されたSQL", expanded=False):
                    st.code(result["sql"], language="sql")

            # 応答時間表示
            st.caption(f"応答時間: {elapsed:.1f}秒")

        # 履歴に保存
        st.session_state.messages.append({
            "role": "assistant",
            "content": result["answer"],
            "used_tools": result["used_tools"],
            "sql": result.get("sql")
        })

        # APIリクエスト用の会話履歴を更新
        st.session_state.conv_api_history.append(
            {"role": "user", "content": [{"type": "text", "text": user_input}]}
        )
        st.session_state.conv_api_history.append(
            {"role": "assistant", "content": [{"type": "text", "text": result["answer"]}]}
        )

        # 履歴が長くなりすぎないよう最新10ターンに制限
        if len(st.session_state.conv_api_history) > 20:
            st.session_state.conv_api_history = st.session_state.conv_api_history[-20:]


if __name__ == "__main__":
    main()
