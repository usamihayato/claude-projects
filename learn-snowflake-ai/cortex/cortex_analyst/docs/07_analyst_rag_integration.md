# Cortex Analyst + Cortex Search 統合

## 概要

Cortex Analyst（構造化データ分析）と Cortex Search（ドキュメント検索）を組み合わせることで、**「数値データと社内ルールの両方を一度に回答できる」ハイブリッドアーキテクチャ**を実現します。

---

## いつどちらを使うか

### 判断フローチャート

```
ユーザーの質問
        │
        ▼
  「数値・件数・金額・ランキングを知りたい？」
        │
    YES ↓           NO ↓
Cortex Analyst    「規定・マニュアル・FAQを知りたい？」
（SQL 生成・実行）        │
                    YES ↓           NO ↓
                Cortex Search     汎用 LLM
                （ドキュメント検索）（COMPLETE 関数）
```

### 具体的な質問例

| 質問 | 使うサービス |
|---|---|
| 先月の売上合計は？ | Cortex Analyst |
| 経費精算の申請方法を教えて | Cortex Search (RAG) |
| 今月の経費超過申請件数と、申請の注意事項を教えて | **両方（ハイブリッド）** |
| 商品カテゴリ別の売上ランキング | Cortex Analyst |
| セキュリティポリシーに関する Q&A | Cortex Search (RAG) |
| 有給残日数と、取得方法の規定 | **両方（ハイブリッド）** |

---

## ハイブリッドアーキテクチャ

```
ユーザーの質問（自然言語）
        │
        ▼
┌─────────────────────────────────────────┐
│           ルーティング判定              │
│  構造化？非構造化？両方？              │
└───────────┬─────────────────────────────┘
            │
    ┌───────┴────────┐
    ↓                ↓
Cortex Analyst    Cortex Search
（SQL 生成・実行）  （ドキュメント検索）
    ↓                ↓
  数値データ       関連ドキュメント
    └───────┬────────┘
            ↓
   コンテキスト統合
            ↓
   CORTEX.COMPLETE（LLM）
            ↓
      統合した回答
```

---

## 実装パターン

### パターン 1: 並列呼び出し（最も実用的）

```python
def hybrid_analyst_search(session, question: str) -> dict:
    """
    Cortex Analyst と Cortex Search を並列で呼び出し、
    両方の結果をコンテキストとして LLM に渡す。
    """
    import threading, json, _snowflake
    
    results = {"analyst": None, "search": None}
    
    def call_analyst():
        resp = _snowflake.send_snow_api_request(
            "POST", "/api/v2/cortex/analyst/message",
            {}, {},
            {
                "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
                "semantic_model_file": "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
            },
            None, 30000
        )
        resp_json = json.loads(resp["content"])
        for item in resp_json.get("message", {}).get("content", []):
            if item["type"] == "sql":
                # SQL を実行してデータを取得
                df = session.sql(item["statement"]).to_pandas()
                results["analyst"] = df.to_string(index=False)
                break
    
    def call_search():
        search_resp = session.sql(f"""
            SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH',
                OBJECT_CONSTRUCT(
                    'query', '{question.replace("'", "''")}',
                    'columns', ['content', 'doc_name'],
                    'limit', 3
                )
            )
        """).collect()[0][0]
        results["search"] = search_resp
    
    # 並列実行
    t1 = threading.Thread(target=call_analyst)
    t2 = threading.Thread(target=call_search)
    t1.start(); t2.start()
    t1.join(); t2.join()
    
    return results
```

### パターン 2: シーケンシャル呼び出し（順番に処理）

```sql
-- 07_analyst_rag_hybrid.sql に完全実装あり
CALL analyst_rag_hybrid('今月の経費超過件数と、経費精算の注意点を教えて');
```

処理フロー:
1. Cortex Analyst → 経費超過件数を SQL で集計
2. Cortex Search → 経費精算規定ドキュメントを検索
3. 両方の結果を 1 つのプロンプトに統合
4. `SNOWFLAKE.CORTEX.COMPLETE` で総合回答を生成

---

## サンプル: 経費管理ハイブリッド Q&A

### 質問
「田中さんの今月の経費申請状況と、申請期限について教えて」

### 処理

**ステップ 1: Cortex Analyst（構造化データ）**
```sql
-- Cortex Analyst が生成する SQL
SELECT
    e.emp_name,
    SUM(ex.amount)   AS total_amount,
    COUNT(ex.id)     AS application_count,
    MAX(ex.status)   AS latest_status
FROM expense_applications ex
JOIN employees e ON ex.employee_id = e.employee_id
WHERE
    e.emp_name LIKE '%田中%'
    AND DATE_TRUNC('MONTH', ex.applied_date) = DATE_TRUNC('MONTH', CURRENT_DATE())
GROUP BY e.emp_name
```

結果:
```
emp_name | total_amount | application_count | latest_status
田中 太郎 | 45,000       | 3                 | 承認済み
```

**ステップ 2: Cortex Search（ドキュメント検索）**
```
検索クエリ: 「経費申請 期限」
検索結果: 経費精算規定.pdf
  → 「毎月末日までに申請すること。翌月5日以降の申請は受理されません。」
```

**ステップ 3: 統合プロンプト**
```
あなたは社内のデータアシスタントです。
以下の情報を元に質問に回答してください。

【構造化データ（今月の申請状況）】
田中 太郎: 合計 45,000円、3件申請、最新ステータス: 承認済み

【社内規定（経費申請に関するドキュメント）】
経費精算規定.pdf: 毎月末日までに申請すること。翌月5日以降の申請は受理されません。

【質問】
田中さんの今月の経費申請状況と、申請期限について教えて
```

**ステップ 4: LLM 回答**
```
田中太郎さんの今月の経費申請状況をお伝えします。

申請件数: 3件
申請合計金額: 45,000円
ステータス: 承認済み

なお、経費精算規定によると、申請期限は毎月末日です。
翌月5日以降の申請は受理されませんのでご注意ください。
```

---

## 実装の詳細

完全な実装は `../sql/07_analyst_rag_hybrid.sql` を参照してください。

### 主要ストアドプロシージャ

```python
# analyst_rag_hybrid(question VARCHAR) → VARCHAR
# 1. Cortex Analyst で SQL 生成 + 実行
# 2. Cortex Search でドキュメント検索
# 3. コンテキスト統合
# 4. CORTEX.COMPLETE で回答生成
```

---

## Cortex Search サービスの前提

このハイブリッドを使うには、Cortex Search が `cortex search_rag` 側でセットアップされている必要があります。

```sql
-- cortex search_rag のドキュメント検索サービスを参照
-- ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH

-- または新規に作成（社内規定ドキュメントがある場合）
CREATE OR REPLACE CORTEX SEARCH SERVICE COMPANY_DOC_SEARCH
    ON content
    ATTRIBUTES doc_name, category
    WAREHOUSE = ANALYST_WH
    TARGET_LAG = '1 hour'
    AS
    SELECT content, doc_name, category
    FROM company_documents;
```

---

## 次のステップ

- [08_best_practices.md](08_best_practices.md) — 本番運用のベストプラクティス
- `../sql/07_analyst_rag_hybrid.sql` — ハイブリッド実装の完全コード
