# MCP 経由で Cortex Analyst / Cortex Search を使う

## 概要

Snowflake MCP Server が接続済みの状態で、Claude に自然言語で話しかけるだけで  
Cortex Analyst（自然言語→SQL）と Cortex Search（ドキュメント検索）を呼び出せます。

**エンジニアが書くコード: ゼロ。**

---

## 前提

- [02_snowflake_mcp_setup.md](02_snowflake_mcp_setup.md) のセットアップ完了済み
- `ANALYST_DEMO_DB.ANALYST_SCHEMA` にサンプルデータが投入済み
  （[cortex_analyst/sql/02_sample_data.sql](../../cortex/cortex_analyst/sql/02_sample_data.sql) 参照）
- セマンティックモデル YAML がステージにアップロード済み

---

## パターン 1: SQL 実行（execute_query）

Snowflake MCP の最も基本的な使い方。Claude が SQL を書いて実行します。

### Claude への話しかけ方

```
「ANALYST_DEMO_DB の SALES_ORDERS テーブルから、
  先月の売上上位5商品を調べて」
```

### Claude の動き（内部）

```
1. list_tables でテーブル構成を把握
   → SALES_ORDERS, CUSTOMERS, PRODUCTS, SALES_TARGETS を確認

2. describe_table(SALES_ORDERS) でスキーマを確認
   → ORDER_DATE, PRODUCT_NAME, TOTAL_AMOUNT, STATUS などを把握

3. execute_query で SQL を実行
   SELECT product_name,
          SUM(total_amount) AS total_sales
   FROM   sales_orders
   WHERE  status != 'cancelled'
     AND  DATE_TRUNC('MONTH', order_date)
            = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
   GROUP  BY product_name
   ORDER  BY total_sales DESC
   LIMIT  5

4. 結果を自然言語で返す
```

### ポイント

- **Claude がスキーマを自動把握する**: カラム名・型・意味を `describe_table` で取得して SQL を生成
- **ビジネスルールは description から推測**: `status != 'cancelled'` のような条件は、テーブルのコメントや会話の文脈から判断
- スキーマコメント（`COMMENT = '...'`）が充実していると精度が上がる

---

## パターン 2: Cortex Analyst を MCP 経由で呼ぶ

Cortex Analyst をストアドプロシージャとして定義済みなら、`execute_query` でプロシージャを呼び出せます。

### Claude への話しかけ方

```
「ANALYST_DEMO_DB の analyst_to_sql プロシージャを使って、
  '先月の売上上位5商品' を聞いてみて。
  生成された SQL も教えて」
```

### Claude の動き

```
1. execute_query で Cortex Analyst を呼び出す
   CALL ANALYST_DEMO_DB.ANALYST_SCHEMA.analyst_to_sql(
     '先月の売上上位5商品は？'
   );

2. レスポンスの JSON をパース
   → generated_sql: SELECT product_name, SUM(...) ...
   → text_answer: "先月の売上上位5商品をお知らせします。"

3. 生成 SQL をさらに execute_query で実行して結果を取得

4. テキスト・SQL・結果を整理して回答
```

### ダイレクトに Cortex Analyst を呼ぶ SQL

Claude に以下を伝えると、直接 REST API 経由の呼び出しもできます:

```
「以下の SQL を実行して結果を返して:

SELECT SNOWFLAKE.CORTEX.COMPLETE(
  'snowflake-arctic-instruct',
  CONCAT(
    'あなたはデータアナリストです。以下のデータについて日本語で分析してください:\n',
    (SELECT LISTAGG(product_name || ': ' || total_amount, '\n')
     FROM (
       SELECT product_name, SUM(total_amount) AS total_amount
       FROM sales_orders
       WHERE status != 'cancelled'
       GROUP BY product_name
       ORDER BY total_amount DESC
       LIMIT 5
     ))
  )
) AS analysis;」
```

---

## パターン 3: Cortex Search を MCP 経由で呼ぶ

Cortex Search Service が作成済みであれば、`execute_query` で検索できます。

### Claude への話しかけ方

```
「ANALYST_DEMO_DB の COMPANY_DOC_SEARCH サービスを使って
  '経費申請 期限' で検索して、結果を教えて」
```

### Claude が実行する SQL

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH',
    OBJECT_CONSTRUCT(
        'query',   '経費申請 期限',
        'columns', ARRAY_CONSTRUCT('content', 'doc_name'),
        'limit',   3
    )
);
```

---

## パターン 4: 複数ツールを組み合わせた自律的なタスク

MCP 経由で Claude が複数のツールを自律的に組み合わせます。

### Claude への話しかけ方（複合タスク）

```
「以下をやって:
  1. SALES_ORDERS テーブルの今月のカテゴリ別売上を調べる
  2. 先月との比較をして増減率を計算する
  3. 売上が10%以上落ちているカテゴリがあれば教えて」
```

### Claude の動き（自律的に複数ステップを実行）

```
Step 1: describe_table(SALES_ORDERS) でスキーマ確認

Step 2: execute_query で今月のカテゴリ別売上を取得
        SELECT category, SUM(total_amount) AS this_month
        FROM sales_orders
        WHERE status != 'cancelled'
          AND DATE_TRUNC('MONTH', order_date) = DATE_TRUNC('MONTH', CURRENT_DATE())
        GROUP BY category

Step 3: execute_query で先月のカテゴリ別売上を取得
        SELECT category, SUM(total_amount) AS last_month
        FROM sales_orders
        WHERE status != 'cancelled'
          AND DATE_TRUNC('MONTH', order_date)
              = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
        GROUP BY category

Step 4: 両方の結果を JOIN して増減率を計算（Python で処理）

Step 5: 10%以上減少しているカテゴリを抽出して報告
```

---

## パターン 5: スキーマ調査・テーブル設計レビュー

MCP の `list_tables`, `describe_table`, `get_ddl` を活用したスキーマ調査。

### Claude への話しかけ方

```
「ANALYST_DEMO_DB の ANALYST_SCHEMA にあるテーブルを全部確認して、
  テーブル間のリレーションを図にして」
```

```
「SALES_ORDERS テーブルの DDL を見て、
  Cortex Analyst のセマンティックモデルの YAML ドラフトを作って」
```

この使い方が特に強力で、**テーブル定義からセマンティックモデルの YAML を自動生成させる**ことができます。

---

## MCP vs API の実際の使い分け

### MCP が向いている場面

```
✅ アドホック分析（「この数字を調べて」「なぜ落ちた？」）
✅ 開発中のデバッグ・調査（Claude Code 上でテーブル構造を確認しながら開発）
✅ セマンティックモデルの YAML ドラフト生成
✅ Verified Queries のアイデア出し
✅ データ品質チェック（NULL が多いカラムを探す、等）
```

### REST API / SDK が向いている場面

```
✅ 本番アプリへの Cortex Analyst 組み込み
✅ 定期バッチ処理
✅ 特定の質問セットを自動実行するパイプライン
✅ Streamlit アプリのバックエンド
```

---

## Claude Code での実践例

Claude Code のターミナル上で、MCP が有効な状態で以下を試してみてください:

```
「Snowflake の ANALYST_DEMO_DB に接続して、
  SALES_ORDERS テーブルの基本的なデータ品質を確認して。
  - 件数
  - NULL がある列
  - STATUS の値分布
  - ORDER_DATE の範囲
  を教えて」
```

Claude が複数の SQL を自律的に実行して結果をまとめて返します。

---

## 接続確認用クイックテスト

MCP 接続後、最初に試す質問:

```
1. 「Snowflake に接続できている？テーブル一覧を教えて」
   → list_tables が動くか確認

2. 「SALES_ORDERS テーブルの件数は？」
   → execute_query が動くか確認

3. 「SALES_ORDERS の STATUS カラムの値の種類を教えて」
   → スキーマ理解 + SQL 生成が正しいか確認
```

---

## まとめ: MCP を使った Snowflake 活用フロー

```
開発フェーズ（Claude Code + MCP）
  → テーブル調査・セマンティックモデル YAML 生成
  → Cortex Analyst の Verified Queries アイデア出し
  → データ品質チェック

デモフェーズ（Claude Desktop + MCP or Snowflake Intelligence）
  → 自然言語でデータ分析を実演
  → Cortex Search でドキュメント検索を実演

本番フェーズ（REST API or Snowflake Intelligence）
  → アプリへの Cortex Analyst 組み込み
  → エンドユーザー向けチャット UI の提供
```

---

## 関連ドキュメント

- [01_mcp_overview.md](01_mcp_overview.md) — MCP の概要・API との違い
- [02_snowflake_mcp_setup.md](02_snowflake_mcp_setup.md) — セットアップ手順
- [../../cortex/cortex_agent/docs/04_snowflake_intelligence.md](../../cortex/cortex_agent/docs/04_snowflake_intelligence.md) — Snowflake Intelligence との使い分け
