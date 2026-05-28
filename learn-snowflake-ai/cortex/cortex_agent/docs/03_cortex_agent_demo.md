# Cortex Agent デモ: Analyst + Search 統合

## デモシナリオ

**「先月の売上低下カテゴリを調べて、関連する社内施策のドキュメントも合わせて確認したい」**

このタスクは単一ツールでは完結しません:

```
Cortex Analyst だけ → 売上数値は出るが、施策ドキュメントにアクセスできない
Cortex Search だけ  → ドキュメントは探せるが、実際の売上数値を分析できない

Cortex Agent       → 両方を自律的に組み合わせて回答できる
```

---

## 前提条件

| 項目 | 内容 |
|---|---|
| データベース | `ANALYST_DEMO_DB` |
| スキーマ | `ANALYST_SCHEMA` |
| 構造化データ | `SALES_ORDERS`, `PRODUCTS`, `CUSTOMERS` テーブル |
| セマンティックモデル | `@SEMANTIC_MODEL_STAGE/03_semantic_model.yaml` |
| ドキュメントデータ | `COMPANY_DOCS` テーブル（社内規定・施策・マニュアル） |
| Cortex Search Service | `COMPANY_DOC_SEARCH` |

---

## Step 1: ドキュメントデータと Cortex Search Service の準備

```sql
-- 社内ドキュメントテーブルの作成
CREATE OR REPLACE TABLE ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOCS (
    doc_id      NUMBER AUTOINCREMENT PRIMARY KEY,
    doc_name    VARCHAR(200),
    category    VARCHAR(100),
    content     TEXT,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- サンプルデータ投入（社内施策・規定ドキュメント）
INSERT INTO COMPANY_DOCS (doc_name, category, content) VALUES
('2024年Q4 家電カテゴリ施策', 'キャンペーン',
 '2024年10月より、家電カテゴリにおいて競合他社の大型セールに対抗するため、
  割引率を通常の10%から15%に引き上げた。ただし在庫調整の観点から一部製品を
  対象外とした。11月の売上は施策前比較で8%減少した。原因として、対象外製品の
  売上低下が主因と分析している。'),
('東日本エリア配送遅延報告', '物流',
 '2024年11月、東日本エリアにおける物流パートナーの人員不足により、
  平均配送日数が2日から4日に増加した。顧客満足度調査では配送遅延を理由とした
  キャンセルが前月比12%増加。家電カテゴリを中心に影響が大きかった。'),
('2025年Q1 重点施策', 'キャンペーン',
 '2025年第1四半期の重点施策として、電子書籍・ゲームカテゴリへの注力を決定。
  広告予算を家電カテゴリから電子書籍・ゲームへ30%移行する。'),
('経費申請規定 2024年版', '社内規定',
 '経費申請の締め切りは毎月20日。申請金額が10万円を超える場合は部長承認が必要。
  交通費・宿泊費・接待費のカテゴリ別に上限額が設定されている。');

-- Cortex Search Service の作成
CREATE OR REPLACE CORTEX SEARCH SERVICE ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH
  ON content
  ATTRIBUTES doc_name, category
  WAREHOUSE = ANALYST_WH
  TARGET_LAG = '1 hour'
  AS (
    SELECT doc_id, doc_name, category, content
    FROM   ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOCS
  );
```

---

## Step 2: Streamlit in Snowflake でエージェントチャット UI を実装

```python
import streamlit as st
import _snowflake
import json
import pandas as pd

# ページ設定
st.set_page_config(page_title="Cortex Agent デモ", layout="wide")
st.title("Cortex Agent — 売上データ × 社内ドキュメント統合アシスタント")

SEMANTIC_MODEL = "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
SEARCH_SERVICE = "ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH"
MODEL = "llama3.1-70b"

def build_payload(messages: list) -> dict:
    return {
        "model": MODEL,
        "messages": messages,
        "tools": [
            {
                "tool_spec": {
                    "type": "cortex_analyst_text_to_sql",
                    "name": "sales_analyst"
                },
                "tool_resources": {
                    "semantic_model_file": SEMANTIC_MODEL
                }
            },
            {
                "tool_spec": {
                    "type": "cortex_search_service",
                    "name": "doc_search"
                },
                "tool_resources": {
                    "cortex_search_service": SEARCH_SERVICE
                }
            }
        ]
    }

def parse_sse_response(raw: str) -> tuple[str, list[dict]]:
    """SSE レスポンスをパースして (テキスト回答, ツール使用ログ) を返す"""
    answer = ""
    tool_uses = []

    for line in raw.split("\n"):
        if not line.startswith("data: "):
            continue
        try:
            data = json.loads(line[6:])
            contents = data.get("delta", {}).get("content", [])
            for c in contents:
                if c.get("type") == "text":
                    answer += c["text"]
                elif c.get("type") == "tool_use":
                    tool_uses.append({
                        "tool": c["tool_use"]["name"],
                        "input": c["tool_use"].get("input", {})
                    })
        except json.JSONDecodeError:
            pass

    return answer, tool_uses

def call_agent(messages: list) -> tuple[str, list[dict]]:
    payload = build_payload(messages)
    response = _snowflake.send_snow_api_request(
        "POST", "/api/v2/cortex/agents/execute",
        {}, {}, payload, None, 60000
    )
    return parse_sse_response(response.get("content", ""))

# 会話履歴の初期化
if "history" not in st.session_state:
    st.session_state.history = []
if "tool_log" not in st.session_state:
    st.session_state.tool_log = []

# サイドバー: ツール実行ログ
with st.sidebar:
    st.header("ツール実行ログ")
    if st.session_state.tool_log:
        for log in st.session_state.tool_log:
            st.info(f"🔧 **{log['tool']}**\n\n{json.dumps(log['input'], ensure_ascii=False, indent=2)}")
    else:
        st.caption("まだツールは実行されていません")

    st.divider()
    st.subheader("おすすめの質問")
    examples = [
        "先月の売上が最も低下したカテゴリを教えて",
        "家電カテゴリの売上低下の原因を調べて",
        "先月の売上上位5商品と、その商品に関する社内施策を調べて"
    ]
    for ex in examples:
        if st.button(ex, use_container_width=True):
            st.session_state.pending_input = ex

# チャット履歴表示
for msg in st.session_state.history:
    with st.chat_message(msg["role"]):
        st.write(msg["content"])

# ペンディング入力の処理（おすすめ質問クリック時）
pending = st.session_state.pop("pending_input", None)

if prompt := (st.chat_input("質問を入力してください") or pending):
    # ユーザーメッセージを表示・履歴に追加
    st.session_state.history.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.write(prompt)

    # API 用のメッセージ形式に変換
    api_messages = [
        {
            "role": msg["role"],
            "content": [{"type": "text", "text": msg["content"]}]
        }
        for msg in st.session_state.history
    ]

    with st.chat_message("assistant"):
        with st.spinner("分析中（Cortex Analyst + Cortex Search を使用中）..."):
            answer, tool_uses = call_agent(api_messages)

        st.write(answer)

        # ツールログを更新
        st.session_state.tool_log.extend(tool_uses)

    st.session_state.history.append({"role": "assistant", "content": answer})
    st.rerun()
```

---

## Step 3: デモフロー（実演手順）

### 質問 1: 売上低下カテゴリの特定

```
入力: 「先月の売上が最も低下したカテゴリを教えて」

Agent の動き:
  1. sales_analyst ツールを選択
  2. Cortex Analyst が SQL を生成・実行
     SELECT category,
            SUM(CASE WHEN month = '先月' THEN total_amount END) AS last_month,
            SUM(CASE WHEN month = '先々月' THEN total_amount END) AS prev_month,
            (last_month - prev_month) / prev_month * 100 AS change_pct
     FROM   sales_orders
     GROUP  BY category
     ORDER  BY change_pct ASC
  3. 結果を自然言語で回答

出力例: 「先月最も売上が低下したカテゴリは『家電』で、前月比 -15.3% でした」
```

### 質問 2: 原因調査（複合タスク）

```
入力: 「家電カテゴリの売上低下の原因を調べて」

Agent の動き:
  1. sales_analyst で家電カテゴリの詳細データを取得
  2. doc_search で「家電」「売上低下」「施策」を検索
  3. 両方の結果を統合して原因仮説を回答

出力例:
「家電カテゴリの売上は先月比 -15.3% でした。
社内ドキュメントによると、以下の2点が主因として考えられます:

1. 10月からのキャンペーン対象外製品の影響
   （2024年Q4 家電カテゴリ施策ドキュメントより）

2. 東日本エリアでの配送遅延（平均2日→4日）
   （東日本エリア配送遅延報告より）

これらが重なり、特に東日本での家電購入キャンセルが増加したと推察されます。」
```

---

## Step 4: ストアドプロシージャ化（バッチ・定期レポート用）

```sql
CREATE OR REPLACE PROCEDURE ANALYST_DEMO_DB.ANALYST_SCHEMA.agent_report(
    user_query VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, user_query: str) -> str:
    payload = {
        "model": "llama3.1-70b",
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": user_query}]
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

    import _snowflake
    response = _snowflake.send_snow_api_request(
        "POST", "/api/v2/cortex/agents/execute",
        {}, {}, payload, None, 60000
    )

    answer = ""
    for line in response.get("content", "").split("\n"):
        if line.startswith("data: "):
            try:
                data = json.loads(line[6:])
                for c in data.get("delta", {}).get("content", []):
                    if c.get("type") == "text":
                        answer += c["text"]
            except:
                pass
    return answer
$$;

-- 呼び出し例
CALL ANALYST_DEMO_DB.ANALYST_SCHEMA.agent_report(
    '先月の売上低下カテゴリと、その原因に関する社内ドキュメントを調べてレポートして'
);
```

---

## Step 5: Snowflake Intelligence から利用する（ノーコード版）

Streamlit アプリを実装せずに、同じ Analyst + Search 統合を **Snowflake Intelligence** の UI で実現できます。  
Intelligence に「Agent データソース」として登録するのがポイントです。

> ⚠️ Intelligence の「Semantic Model 直接接続」では Cortex Search は使えません。  
> **「Agent」タイプのデータソース**として登録することで Cortex Search が利用可能になります。

### Intelligence への登録手順

```
1. Snowsight > AI & ML > Intelligence
2. + Create Intelligence App → 名前入力 → Create
3. + Add Data Source
     Type: Agent（← Semantic Model ではなく Agent を選ぶ）
4. 以下を設定する:
```

**システムプロンプト（オーケストレーション制御）:**

```
あなたはEC事業の売上分析と社内情報の調査を一体的に支援するビジネスアシスタントです。

## ツール使い分けのルール

### sales_analyst（Cortex Analyst）を使う場面
- 売上・注文件数・売上高などの数値を知りたい場合
- 商品・カテゴリ・期間・地域などでデータを絞り込みたい場合
- 前月比・前年比など時系列比較が必要な場合
- ランキング・集計・トレンド分析が必要な場合

### doc_search（Cortex Search）を使う場面
- キャンペーン・施策の背景や詳細を調べる場合
- 配送・物流・在庫に関する社内報告や規定を確認する場合
- 売上数値の原因・背景を社内ドキュメントで裏付けたい場合

### 両方を組み合わせて使う場面
- 「なぜ売上が下がったか」のように数値と原因の両方が必要な場合
- 施策の効果を定量的に検証したい場合

## 回答スタイル
- 必ず日本語で回答する
- 数値を引用する際は期間・集計軸を明示する
- ドキュメントを引用する際はドキュメント名を明示する
- 複数の情報源を組み合わせた場合は、データとドキュメントの根拠をそれぞれ分けて示す
```

**ツール設定:**

```
Tool 1:
  Name: sales_analyst
  Type: cortex_analyst_text_to_sql
  Semantic Model: @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml

Tool 2:
  Name: doc_search
  Type: cortex_search_service
  Service: ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH

Model: claude-3-5-sonnet（または llama3.1-70b）
Warehouse: ANALYST_WH
```

```
5. Warehouse: ANALYST_WH
6. → Add → Publish
```

### Streamlit vs Intelligence の使い分け

| 用途 | 推奨 |
|---|---|
| 社内ユーザー向けセルフサービス分析 | **Snowflake Intelligence** |
| 独自ブランド・独自ロジックが必要 | **Streamlit in Snowflake** |
| バックエンド API として使いたい | **Cortex Agent REST API** |

---

## まとめ: Cortex Agent が解決する課題

```
課題: 「データ分析とドキュメント調査を別々にやるのが手間」

解決:
  Cortex Agent が Analyst（SQL 生成）+ Search（ドキュメント検索）を
  自律的に組み合わせて、1つの自然言語質問から統合回答を生成

フロントエンドの選択肢:
  ✓ Streamlit in Snowflake → コーディングで柔軟な UI を作れる
  ✓ Snowflake Intelligence → コード不要でチャット UI が即完成
    └── いずれも「Agent ツール構成」は同じ。フロントだけ違う

効果:
  ✓ エンジニアがオーケストレーションコードを書かなくていい
  ✓ データとドキュメントを横断した根拠ある分析が自動でできる
  ✓ マルチターン会話でブラッシュアップできる
```

---

## 関連ドキュメント

- [02_cortex_agent.md](02_cortex_agent.md) — REST API 仕様・ツール定義
- [04_snowflake_intelligence.md](04_snowflake_intelligence.md) — Intelligence への詳細登録手順・オーケストレーション設計
- [../cortex_search_rag/docs/05_demo_app.md](../cortex_search_rag/docs/05_demo_app.md) — Cortex Search 単体の Streamlit アプリ
- [../cortex_analyst/docs/04_demo_app.md](../cortex_analyst/docs/04_demo_app.md) — Cortex Analyst 単体の Streamlit アプリ
