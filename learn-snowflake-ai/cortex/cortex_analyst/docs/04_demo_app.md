# Cortex Analyst デモアプリ（Streamlit in Snowflake）

## 概要

Streamlit in Snowflake（SiS）を使い、Cortex Analyst を呼び出す**チャット型データ分析 UI** を構築します。

```
ユーザーが自然言語で質問
        ↓
Cortex Analyst が SQL を生成
        ↓
Snowflake でクエリ実行
        ↓
テーブル・グラフ・生成 SQL を UI に表示
```

完全なソースコード: `../sql/08_streamlit_app.py`

---

## アーキテクチャ

```
ブラウザ（ユーザー）
        │  自然言語の質問
        ▼
┌────────────────────────────────────────────────────┐
│              Streamlit in Snowflake                 │
│                                                     │
│  ┌──────────────────┐  ┌─────────────────────────┐ │
│  │  チャット UI      │  │  結果表示エリア          │ │
│  │  （質問入力）     │  │  ・テキスト回答          │ │
│  │                  │  │  ・データテーブル         │ │
│  │                  │  │  ・棒グラフ / 折れ線      │ │
│  │                  │  │  ・生成 SQL（展開表示）   │ │
│  └──────────────────┘  └─────────────────────────┘ │
│                ↑                                    │
│      Cortex Analyst REST API 呼び出し               │
│                ↑                                    │
│      セマンティックモデル（YAML）参照                │
│                ↑                                    │
│      Snowflake テーブルへのクエリ実行               │
└────────────────────────────────────────────────────┘
```

---

## セットアップ

### 1. 前提条件

- `01_setup.sql` で DB・スキーマ・ウェアハウスが作成済み
- `02_sample_data.sql` でサンプルデータが投入済み
- `03_semantic_model.yaml` がステージにアップロード済み

### 2. Streamlit アプリの作成

Snowflake UI（Snowsight）から:

1. **Projects** → **Streamlit** → **+ Streamlit App**
2. アプリ名: `cortex_analyst_demo`
3. ウェアハウス: `ANALYST_WH`
4. データベース: `ANALYST_DEMO_DB`、スキーマ: `ANALYST_SCHEMA`

### 3. コードの貼り付け

`../sql/08_streamlit_app.py` の内容を Streamlit エディタに貼り付けて **Run** をクリック。

---

## アプリのコード解説

### 主要構成

```python
# 主要ライブラリ
import streamlit as st
import snowflake.snowpark.context as snowpark_context
import _snowflake
import json
import pandas as pd
import altair as alt
```

### Cortex Analyst 呼び出し関数

```python
def call_cortex_analyst(question: str, chat_history: list) -> dict:
    """
    Cortex Analyst に質問を送り、生成 SQL とテキスト回答を返す。
    chat_history に会話履歴を含めることでマルチターン対話が可能。
    """
    session = snowpark_context.get_active_session()
    
    messages = chat_history + [
        {"role": "user", "content": [{"type": "text", "text": question}]}
    ]
    
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {}, {},
        {
            "messages": messages,
            "semantic_model_file": (
                "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
            )
        },
        None,
        30000
    )
    
    resp_json = json.loads(response["content"])
    result = {"text": "", "sql": "", "warnings": resp_json.get("warnings", [])}
    
    for item in resp_json.get("message", {}).get("content", []):
        if item["type"] == "text":
            result["text"] = item["text"]
        elif item["type"] == "sql":
            result["sql"] = item["statement"]
    
    return result
```

### SQL 実行関数

```python
def execute_sql(sql: str) -> pd.DataFrame:
    """生成された SQL を実行し、pandas DataFrame で返す。"""
    session = snowpark_context.get_active_session()
    return session.sql(sql).to_pandas()
```

### チャット UI の構成

```python
st.set_page_config(page_title="Cortex Analyst デモ", layout="wide")
st.title("データ分析アシスタント")
st.caption("売上データについて自然言語で質問してください")

# サイドバー: セマンティックモデル情報・使い方
with st.sidebar:
    st.header("使い方")
    st.write("質問例:")
    examples = [
        "先月の売上合計は？",
        "商品カテゴリ別の売上上位5件",
        "東日本と西日本の月別売上推移",
        "法人顧客の平均注文金額",
    ]
    for ex in examples:
        if st.button(ex, key=ex):
            st.session_state.pending_question = ex

# チャット履歴の表示
for msg in st.session_state.get("messages", []):
    with st.chat_message(msg["role"]):
        st.write(msg["content"]["text"])
        if msg["role"] == "assistant" and msg["content"].get("sql"):
            # データテーブル・グラフ表示
            df = msg["content"].get("df")
            if df is not None and not df.empty:
                st.dataframe(df, use_container_width=True)
                # 数値列が2列以上あればグラフ表示
                _render_chart(df)
            # 生成 SQL は折りたたみ表示
            with st.expander("生成された SQL を見る"):
                st.code(msg["content"]["sql"], language="sql")
```

### グラフ自動レンダリング

```python
def _render_chart(df: pd.DataFrame):
    """
    DataFrame の列構成を判断して自動的に適切なグラフを表示する。
    - 日付列 + 数値列 → 折れ線グラフ
    - カテゴリ列 + 数値列 → 棒グラフ
    """
    numeric_cols = df.select_dtypes(include="number").columns.tolist()
    date_cols = [c for c in df.columns if "date" in c.lower() or "month" in c.lower()]
    str_cols = df.select_dtypes(include="object").columns.tolist()
    
    if not numeric_cols:
        return
    
    y_col = numeric_cols[0]
    
    if date_cols:
        # 折れ線グラフ
        x_col = date_cols[0]
        chart = alt.Chart(df).mark_line(point=True).encode(
            x=alt.X(x_col, title=x_col),
            y=alt.Y(y_col, title=y_col),
            tooltip=df.columns.tolist()
        ).properties(height=300)
        st.altair_chart(chart, use_container_width=True)
    elif str_cols:
        # 棒グラフ
        x_col = str_cols[0]
        chart = alt.Chart(df).mark_bar().encode(
            x=alt.X(x_col, sort="-y", title=x_col),
            y=alt.Y(y_col, title=y_col),
            tooltip=df.columns.tolist()
        ).properties(height=300)
        st.altair_chart(chart, use_container_width=True)
```

---

## 画面構成イメージ

```
┌──────────────────────────────────────────────────────────────┐
│  データ分析アシスタント                              [Snowflake]  │
├──────────────┬───────────────────────────────────────────────┤
│  使い方      │                                               │
│  ─────────  │  ユーザー: 先月の売上上位5商品は？             │
│  質問例:    │                                               │
│  ・先月の   │  アシスタント: 先月の売上上位5商品をお知らせ  │
│    売上合計  │  します。                                     │
│  ・カテゴリ  │                                               │
│    別売上   │  ┌─────────────────────────────────────────┐  │
│  ・月別推移  │  │ product_name  │ total_sales │ cnt      │  │
│             │  ├───────────────┼─────────────┼──────────┤  │
│             │  │ ノートPC      │ 4,200,000   │  42     │  │
│             │  │ スマートフォン │ 3,800,000   │  76     │  │
│             │  │ タブレット    │ 2,100,000   │  35     │  │
│             │  └─────────────────────────────────────────┘  │
│             │                                               │
│             │  [棒グラフ表示]                               │
│             │                                               │
│             │  ▶ 生成された SQL を見る                      │
│             │                                               │
│             ├───────────────────────────────────────────────┤
│             │  質問を入力...                        [送信]  │
└──────────────┴───────────────────────────────────────────────┘
```

---

## デプロイ手順

1. Snowsight で Streamlit アプリを作成（前述の手順）
2. `08_streamlit_app.py` の内容を貼り付け
3. **Run** ボタンで実行
4. URL を共有してデモ実施

### 権限の設定（デモ参加者向け）

```sql
-- デモ参加者のロールにアプリのアクセス権限を付与
GRANT USAGE ON DATABASE ANALYST_DEMO_DB TO ROLE DEMO_USER;
GRANT USAGE ON SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA TO ROLE DEMO_USER;
GRANT SELECT ON ALL TABLES IN SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA TO ROLE DEMO_USER;
GRANT READ ON STAGE ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE TO ROLE DEMO_USER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DEMO_USER;
```

---

## 次のステップ

- [05_differentiation.md](05_differentiation.md) — 競合ツールとの差別化ポイント
- [06_advanced_semantic_model.md](06_advanced_semantic_model.md) — セマンティックモデルの高度な設定
