# ============================================================
# Cortex Analyst デモアプリ（Streamlit in Snowflake）
# 自然言語で質問 → SQL 生成 → 表・グラフで表示
#
# デプロイ方法:
#   Snowsight > Projects > Streamlit > + Streamlit App
#   ウェアハウス: ANALYST_WH
#   データベース: ANALYST_DEMO_DB, スキーマ: ANALYST_SCHEMA
#   このコードを貼り付けて Run をクリック
# ============================================================

import streamlit as st
import snowflake.snowpark.context as snowpark_context
import _snowflake
import json
import pandas as pd
import altair as alt

SEMANTIC_MODEL = "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"

# ============================================================
# コア関数
# ============================================================

def call_cortex_analyst(question: str, chat_history: list) -> dict:
    """Cortex Analyst に質問し、生成 SQL とテキスト回答を返す。"""
    messages = chat_history + [
        {"role": "user", "content": [{"type": "text", "text": question}]}
    ]

    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {}, {},
        {"messages": messages, "semantic_model_file": SEMANTIC_MODEL},
        None,
        30000
    )

    resp_json = json.loads(response["content"])
    result = {
        "text": "",
        "sql": "",
        "warnings": resp_json.get("warnings", [])
    }
    for item in resp_json.get("message", {}).get("content", []):
        if item["type"] == "text":
            result["text"] = item["text"]
        elif item["type"] == "sql":
            result["sql"] = item["statement"]

    return result


def execute_sql(sql: str) -> pd.DataFrame:
    """生成 SQL を実行して pandas DataFrame で返す。"""
    session = snowpark_context.get_active_session()
    return session.sql(sql).to_pandas()


def render_chart(df: pd.DataFrame):
    """DataFrame の列構成を判断して棒グラフ or 折れ線グラフを自動選択。"""
    numeric_cols = df.select_dtypes(include="number").columns.tolist()
    if not numeric_cols:
        return

    y_col = numeric_cols[0]
    date_cols = [c for c in df.columns if any(k in c.lower() for k in ["date", "month", "year", "week"])]
    str_cols  = df.select_dtypes(include="object").columns.tolist()

    if date_cols:
        x_col = date_cols[0]
        color_col = [c for c in str_cols if c != x_col]
        encode_kwargs = dict(
            x=alt.X(x_col, title=x_col),
            y=alt.Y(y_col, title=y_col),
            tooltip=df.columns.tolist()
        )
        if color_col and len(df[color_col[0]].unique()) <= 10:
            encode_kwargs["color"] = alt.Color(color_col[0])

        chart = (
            alt.Chart(df)
            .mark_line(point=True)
            .encode(**encode_kwargs)
            .properties(height=320)
            .interactive()
        )
        st.altair_chart(chart, use_container_width=True)

    elif str_cols:
        x_col = str_cols[0]
        top_n = df.nlargest(20, y_col)
        chart = (
            alt.Chart(top_n)
            .mark_bar()
            .encode(
                x=alt.X(x_col, sort="-y", title=x_col),
                y=alt.Y(y_col, title=y_col),
                color=alt.Color(x_col, legend=None),
                tooltip=top_n.columns.tolist()
            )
            .properties(height=320)
        )
        st.altair_chart(chart, use_container_width=True)


# ============================================================
# セッション初期化
# ============================================================

if "messages" not in st.session_state:
    st.session_state.messages = []
if "history_for_analyst" not in st.session_state:
    st.session_state.history_for_analyst = []
if "pending_question" not in st.session_state:
    st.session_state.pending_question = None

# ============================================================
# UI レイアウト
# ============================================================

st.set_page_config(
    page_title="データ分析アシスタント",
    page_icon="📊",
    layout="wide"
)

st.title("📊 データ分析アシスタント")
st.caption("売上データについて自然言語で質問してください。Powered by Snowflake Cortex Analyst")

# サイドバー
with st.sidebar:
    st.header("質問例")
    example_questions = [
        "月別の売上合計を教えて",
        "先月の売上上位5商品は？",
        "カテゴリ別の売上構成比",
        "法人と個人の売上比較",
        "今年の地域別売上推移",
        "キャンセル率が高いカテゴリは？",
        "今年の売上上位顧客トップ10",
    ]
    for q in example_questions:
        if st.button(q, use_container_width=True, key=f"ex_{q}"):
            st.session_state.pending_question = q

    st.divider()
    if st.button("会話をリセット", use_container_width=True):
        st.session_state.messages = []
        st.session_state.history_for_analyst = []
        st.session_state.pending_question = None
        st.rerun()

    st.header("セマンティックモデル")
    st.caption("対象テーブル")
    st.code("SALES_ORDERS\nCUSTOMERS\nPRODUCTS\nSALES_TARGETS", language="text")

# ============================================================
# チャット履歴の表示
# ============================================================

chat_container = st.container()

with chat_container:
    for msg in st.session_state.messages:
        role  = msg["role"]
        content = msg["content"]

        if role == "user":
            with st.chat_message("user"):
                st.write(content["text"])

        else:  # assistant
            with st.chat_message("assistant"):
                if content.get("text"):
                    st.write(content["text"])

                if content.get("warnings"):
                    for w in content["warnings"]:
                        st.warning(f"⚠️ {w.get('message', w)}")

                if content.get("df") is not None:
                    df = content["df"]
                    if not df.empty:
                        st.dataframe(df, use_container_width=True, hide_index=True)
                        if len(df) > 1:
                            render_chart(df)
                    else:
                        st.info("該当するデータが見つかりませんでした。")

                if content.get("sql"):
                    with st.expander("生成された SQL を見る", expanded=False):
                        st.code(content["sql"], language="sql")

# ============================================================
# 質問の処理
# ============================================================

question = st.chat_input("質問を入力してください...")

if st.session_state.pending_question:
    question = st.session_state.pending_question
    st.session_state.pending_question = None

if question:
    # ユーザーメッセージを記録
    st.session_state.messages.append({
        "role": "user",
        "content": {"text": question}
    })

    with st.chat_message("user"):
        st.write(question)

    with st.chat_message("assistant"):
        with st.spinner("分析中..."):
            # Cortex Analyst を呼び出す
            analyst_result = call_cortex_analyst(
                question,
                st.session_state.history_for_analyst
            )

            # テキスト回答表示
            if analyst_result["text"]:
                st.write(analyst_result["text"])

            # 警告表示
            if analyst_result["warnings"]:
                for w in analyst_result["warnings"]:
                    st.warning(f"⚠️ {w.get('message', w)}")

            # SQL 実行とデータ表示
            df = None
            if analyst_result["sql"]:
                try:
                    df = execute_sql(analyst_result["sql"])
                    if not df.empty:
                        st.dataframe(df, use_container_width=True, hide_index=True)
                        if len(df) > 1:
                            render_chart(df)
                    else:
                        st.info("該当するデータが見つかりませんでした。")
                except Exception as e:
                    st.error(f"クエリ実行エラー: {str(e)}")

                with st.expander("生成された SQL を見る", expanded=False):
                    st.code(analyst_result["sql"], language="sql")

    # メッセージ履歴に追加
    st.session_state.messages.append({
        "role": "assistant",
        "content": {
            "text": analyst_result["text"],
            "sql":  analyst_result["sql"],
            "df":   df,
            "warnings": analyst_result["warnings"]
        }
    })

    # Cortex Analyst 用の会話履歴を更新（マルチターン対応）
    st.session_state.history_for_analyst.append({
        "role": "user",
        "content": [{"type": "text", "text": question}]
    })
    if analyst_result["sql"]:
        st.session_state.history_for_analyst.append({
            "role": "analyst",
            "content": [{"type": "sql", "statement": analyst_result["sql"]}]
        })
    # 履歴は最新 10 ターン分のみ保持（コンテキスト長の節約）
    if len(st.session_state.history_for_analyst) > 20:
        st.session_state.history_for_analyst = st.session_state.history_for_analyst[-20:]
