# Cortex Agent 詳細仕様

## Cortex Agent とは

Cortex Agent は、**複数の Cortex ツールを自律的にオーケストレーションできる Snowflake のエージェント基盤**です。LLM がツールの選択・実行を担い、ユーザーはゴールを自然言語で指定するだけで済みます。

---

## Cortex Search / Analyst との違い

| 比較軸 | Cortex Search | Cortex Analyst | Cortex Agent |
|---|---|---|---|
| 役割 | ドキュメント検索 | NL → SQL | ツールのオーケストレーター |
| 呼び出し方 | SQL 関数 / REST API | REST API | REST API |
| ツール数 | 1（検索のみ） | 1（SQL 生成のみ） | 複数（動的に選択） |
| 複数ステップ | ✗ | ✗ | ✓ |
| 用途 | RAG の検索層 | データ集計・分析 | 複合的なタスク |

---

## 対応ツール一覧

Cortex Agent に登録できるツールの種類:

| ツール種別 | 定義方法 | 用途 |
|---|---|---|
| `cortex_analyst_text_to_sql` | セマンティックモデルの YAML パスを指定 | 構造化データへの NL クエリ |
| `cortex_search_service` | Cortex Search Service 名を指定 | ドキュメント検索・RAG |
| `sql_exec` | カスタム SQL を直接指定 | 任意の SQL 実行 |
| `generic` | 外部関数・REST API を指定 | 外部システム連携 |

---

## REST API

### エンドポイント

```
POST /api/v2/cortex/agents/execute
```

### リクエスト構造

```json
{
  "model": "llama3.1-70b",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "先月の売上上位5商品を教えて。また、その商品の社内評価レポートも調べて"
        }
      ]
    }
  ],
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "sales_analyst"
      },
      "tool_choice": "auto",
      "tool_resources": {
        "semantic_model_file": "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search_service",
        "name": "doc_search"
      },
      "tool_resources": {
        "cortex_search_service": "ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH"
      }
    }
  ],
  "tool_choice": "auto",
  "response_format": {
    "type": "text"
  }
}
```

### レスポンス構造（SSE ストリーム）

```
data: {"type": "message.delta", "delta": {"content": [{"type": "tool_use", "tool_use": {"name": "sales_analyst", "input": {"query": "先月の売上上位5商品"}}}]}}
data: {"type": "message.delta", "delta": {"content": [{"type": "tool_results", ...}]}}
data: {"type": "message.delta", "delta": {"content": [{"type": "text", "text": "先月の売上上位5商品は..."}]}}
data: {"type": "message.stop"}
```

レスポンスは **Server-Sent Events（SSE）** 形式でストリーミングされます。

---

## ツール定義の書き方

### Cortex Analyst ツール

```json
{
  "tool_spec": {
    "type": "cortex_analyst_text_to_sql",
    "name": "sales_analyst"
  },
  "tool_resources": {
    "semantic_model_file": "@DB.SCHEMA.STAGE/model.yaml"
  }
}
```

### Cortex Search ツール

```json
{
  "tool_spec": {
    "type": "cortex_search_service",
    "name": "doc_search"
  },
  "tool_resources": {
    "cortex_search_service": "DB.SCHEMA.SERVICE_NAME"
  }
}
```

### SQL 直接実行ツール

```json
{
  "tool_spec": {
    "type": "sql_exec",
    "name": "custom_query",
    "description": "任意の集計 SQL を実行する"
  }
}
```

---

## Python での呼び出しサンプル

```python
import requests
import json
import os

SNOWFLAKE_ACCOUNT = os.environ["SNOWFLAKE_ACCOUNT"]
TOKEN = os.environ["SNOWFLAKE_TOKEN"]  # JWT or OAuth token

url = f"https://{SNOWFLAKE_ACCOUNT}.snowflakecomputing.com/api/v2/cortex/agents/execute"

headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
    "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT"
}

payload = {
    "model": "llama3.1-70b",
    "messages": [
        {
            "role": "user",
            "content": [{"type": "text", "text": "先月の売上上位5商品と、その商品の社内評価を教えて"}]
        }
    ],
    "tools": [
        {
            "tool_spec": {
                "type": "cortex_analyst_text_to_sql",
                "name": "sales_analyst"
            },
            "tool_resources": {
                "semantic_model_file": "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
            }
        },
        {
            "tool_spec": {
                "type": "cortex_search_service",
                "name": "doc_search"
            },
            "tool_resources": {
                "cortex_search_service": "ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH"
            }
        }
    ]
}

response = requests.post(url, headers=headers, json=payload, stream=True)

for line in response.iter_lines():
    if line.startswith(b"data: "):
        data = json.loads(line[6:])
        if data.get("type") == "message.delta":
            for content in data["delta"].get("content", []):
                if content["type"] == "text":
                    print(content["text"], end="", flush=True)
```

---

## Streamlit in Snowflake からの呼び出し

Streamlit in Snowflake では `_snowflake.send_snow_api_request()` を使用します。

```python
import streamlit as st
import _snowflake
import json

def call_cortex_agent(user_message: str) -> str:
    payload = {
        "model": "llama3.1-70b",
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": user_message}]
            }
        ],
        "tools": [
            {
                "tool_spec": {
                    "type": "cortex_analyst_text_to_sql",
                    "name": "sales_analyst"
                },
                "tool_resources": {
                    "semantic_model_file": "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
                }
            },
            {
                "tool_spec": {
                    "type": "cortex_search_service",
                    "name": "doc_search"
                },
                "tool_resources": {
                    "cortex_search_service": "ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH"
                }
            }
        ]
    }

    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/agents/execute",
        {},
        {},
        payload,
        None,
        60000
    )

    # SSE レスポンスをパース
    answer = ""
    for line in response["content"].split("\n"):
        if line.startswith("data: "):
            try:
                data = json.loads(line[6:])
                for content in data.get("delta", {}).get("content", []):
                    if content.get("type") == "text":
                        answer += content["text"]
            except json.JSONDecodeError:
                pass

    return answer

# Streamlit UI
st.title("Cortex Agent デモ")

if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.write(msg["content"])

if prompt := st.chat_input("質問を入力してください"):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.write(prompt)

    with st.chat_message("assistant"):
        with st.spinner("考え中..."):
            answer = call_cortex_agent(prompt)
        st.write(answer)
    st.session_state.messages.append({"role": "assistant", "content": answer})
```

---

## 利用可能な LLM モデル

Cortex Agent で指定できる主要モデル:

```
"llama3.1-70b"           → 高精度・バランス型（デフォルト推奨）
"llama3.1-8b"            → 軽量・高速
"claude-3-5-sonnet"      → 高い推論精度（Anthropic）
"mistral-large2"         → 多言語対応
"snowflake-arctic"       → コスト効率重視
```

---

## 権限設定

```sql
-- Cortex Agent の利用に必要な権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ANALYST_USER;

-- Cortex Search Service の参照権限
GRANT USAGE ON CORTEX SEARCH SERVICE ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH
  TO ROLE ANALYST_USER;

-- ステージへのアクセス権限（セマンティックモデル YAML）
GRANT READ ON STAGE ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE
  TO ROLE ANALYST_USER;
```

---

## 関連ドキュメント

- [01_agent_overview.md](01_agent_overview.md) — AI エージェントとは
- [03_cortex_agent_demo.md](03_cortex_agent_demo.md) — Analyst + Search 統合デモ
- [04_snowflake_intelligence.md](04_snowflake_intelligence.md) — マネージド UI（Snowflake Intelligence）
