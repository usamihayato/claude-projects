# Cortex Analyst サンプル実装

## 概要

このドキュメントでは、売上データを題材に Cortex Analyst を実際に動かすまでの手順を、ステップバイステップで説明します。

```
ステップ0: 環境準備
ステップ1: サンプルデータ投入
ステップ2: セマンティックモデル作成・ステージにアップロード
ステップ3: Cortex Analyst を呼び出して質問する
ステップ4: 生成 SQL の確認・動的実行
ステップ5: ストアドプロシージャ化
```

対応する SQL ファイル: `../sql/01_setup.sql` 〜 `../sql/05_stored_procedures.sql`

---

## ステップ0: 環境準備

```sql
-- ロール設定
USE ROLE ACCOUNTADMIN;

-- ロール・権限付与
CREATE ROLE IF NOT EXISTS ANALYST_USER;
GRANT ROLE ANALYST_USER TO USER <あなたのユーザー名>;

-- Cortex 機能の利用権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ANALYST_USER;

-- DB・スキーマ・ウェアハウス作成
CREATE DATABASE IF NOT EXISTS ANALYST_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS ANALYST_DEMO_DB.ANALYST_SCHEMA;
CREATE WAREHOUSE IF NOT EXISTS ANALYST_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

-- セマンティックモデル YAML を保存するステージ
CREATE STAGE IF NOT EXISTS ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE
    DIRECTORY = (ENABLE = TRUE);
```

---

## ステップ1: サンプルデータ投入

3つのテーブルを作成し、デモ用データを投入します。

```sql
USE ROLE ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- 売上注文テーブル
CREATE OR REPLACE TABLE SALES_ORDERS (
    ORDER_ID        VARCHAR(20)   NOT NULL,
    ORDER_DATE      DATE          NOT NULL,
    CUSTOMER_ID     VARCHAR(20)   NOT NULL,
    PRODUCT_ID      VARCHAR(20)   NOT NULL,
    PRODUCT_NAME    VARCHAR(100)  NOT NULL,
    CATEGORY        VARCHAR(50)   NOT NULL,
    QUANTITY        NUMBER(10, 0) NOT NULL,
    UNIT_PRICE      NUMBER(10, 2) NOT NULL,
    TOTAL_AMOUNT    NUMBER(12, 2) NOT NULL,
    REGION          VARCHAR(20)   NOT NULL,
    STATUS          VARCHAR(20)   NOT NULL
);

-- 顧客マスタ
CREATE OR REPLACE TABLE CUSTOMERS (
    CUSTOMER_ID     VARCHAR(20)   NOT NULL,
    CUSTOMER_NAME   VARCHAR(100)  NOT NULL,
    SEGMENT         VARCHAR(50)   NOT NULL,   -- 法人 / 個人
    PREFECTURE      VARCHAR(20)   NOT NULL
);

-- 商品マスタ
CREATE OR REPLACE TABLE PRODUCTS (
    PRODUCT_ID      VARCHAR(20)   NOT NULL,
    PRODUCT_NAME    VARCHAR(100)  NOT NULL,
    CATEGORY        VARCHAR(50)   NOT NULL,
    COST_PRICE      NUMBER(10, 2) NOT NULL
);
```

データは `../sql/02_sample_data.sql` で投入します。

---

## ステップ2: セマンティックモデル作成・ステージへアップロード

### 2-1. YAML ファイルの内容

`../sql/03_semantic_model.yaml` に完全な定義があります。主要部分の抜粋:

```yaml
name: sales_analyst_model
description: |
  売上分析モデル。SALES_ORDERS（売上注文）・CUSTOMERS（顧客）・PRODUCTS（商品）
  の3テーブルを対象に、売上集計・顧客分析・商品分析が可能。

tables:
  - name: sales_orders
    description: "売上注文テーブル"
    base_table:
      database: ANALYST_DEMO_DB
      schema: ANALYST_SCHEMA
      table: SALES_ORDERS
    measures:
      - name: total_sales
        description: "売上合計（キャンセル除く・税抜）"
        expr: SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END)
        data_type: NUMBER
      - name: order_count
        description: "注文件数（キャンセル除く）"
        expr: COUNT(CASE WHEN status != 'cancelled' THEN order_id END)
        data_type: NUMBER
    time_dimensions:
      - column_name: order_date

relationships:
  - name: orders_to_customers
    left_table: sales_orders
    right_table: customers
    join_type: LEFT
    relationship_columns:
      - left_column: customer_id
        right_column: customer_id
```

### 2-2. ステージへアップロード

ローカルの YAML ファイルをステージに PUT します（Snowflake CLI または SnowSQL から実行）:

```bash
# Snowflake CLI 経由
snow stage copy ./sql/03_semantic_model.yaml @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE

# または SnowSQL 経由
PUT file:///path/to/cortex_analyst/sql/03_semantic_model.yaml
    @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE
    AUTO_COMPRESS=FALSE;
```

アップロード確認:
```sql
LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE;
```

---

## ステップ3: Cortex Analyst を呼び出して質問する

`../sql/04_analyst_api_call.sql` の内容を参照してください。

Cortex Analyst の呼び出しは、Python ストアドプロシージャ経由で REST API を使います。

```sql
-- analyst_to_sql ストアドプロシージャの作成（詳細は 05_stored_procedures.sql）
CREATE OR REPLACE PROCEDURE analyst_to_sql(question VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

def run(session, question: str):
    resp = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {}, {},
        {
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": question}]}
            ],
            "semantic_model_file": "@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml"
        },
        None, 30000
    )
    return json.loads(resp["content"])
$$;
```

呼び出し例:

```sql
-- 質問1: 月別売上
CALL analyst_to_sql('月別の売上合計を教えて');

-- 質問2: 商品ランキング
CALL analyst_to_sql('先月の売上上位5商品は？');

-- 質問3: 顧客セグメント別
CALL analyst_to_sql('法人顧客と個人顧客の売上比率は？');

-- 質問4: 地域別トレンド
CALL analyst_to_sql('東日本と西日本の今年の売上推移を比較して');
```

---

## ステップ4: 生成 SQL の確認・動的実行

Cortex Analyst のレスポンスには生成 SQL が含まれます。これを確認・実行できます。

```sql
-- レスポンス構造の確認
SELECT
    resp:message:content AS content,
    resp:message:content[0]:type::VARCHAR AS content_type,
    resp:message:content[0]:text::VARCHAR AS text_answer,
    resp:message:content[1]:type::VARCHAR AS sql_type,
    resp:message:content[1]:statement::VARCHAR AS generated_sql
FROM (
    SELECT analyst_to_sql('先月の売上上位5商品は？') AS resp
);
```

レスポンスの JSON 構造:
```json
{
  "message": {
    "role": "analyst",
    "content": [
      {
        "type": "text",
        "text": "先月の売上上位5商品を集計しました。"
      },
      {
        "type": "sql",
        "statement": "SELECT product_name, SUM(total_amount) AS total_sales FROM sales_orders WHERE ..."
      }
    ]
  },
  "request_id": "...",
  "warnings": []
}
```

生成 SQL を動的に実行する手順（ストアドプロシージャ）:

```sql
-- analyst_execute: 質問 → SQL 生成 → 実行 → 結果返却
CREATE OR REPLACE PROCEDURE analyst_execute(question VARCHAR)
RETURNS TABLE()
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

def run(session, question: str):
    # Cortex Analyst で SQL 生成
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
    
    # SQL 抽出
    generated_sql = ""
    for item in resp_json.get("message", {}).get("content", []):
        if item.get("type") == "sql":
            generated_sql = item["statement"]
            break
    
    if not generated_sql:
        return session.create_dataframe([{"error": "SQLが生成されませんでした"}])
    
    # 生成 SQL を実行して結果を返す
    return session.sql(generated_sql)
$$;

-- 使用例
CALL analyst_execute('先月の売上上位5商品は？');
CALL analyst_execute('カテゴリ別の売上構成比を教えて');
```

---

## ステップ5: 品質を確認する

生成 SQL が正しいかを確認する方法:

```sql
-- 生成 SQL を目視確認して、期待通りかチェックする
SET question = '先月の売上合計は？';
CALL analyst_to_sql($question);

-- 結果が期待値と合っているか検証用クエリ（手動で書いた SQL）
SELECT SUM(total_amount) AS total_sales
FROM SALES_ORDERS
WHERE
    status != 'cancelled'
    AND DATE_TRUNC('MONTH', order_date) = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()));
```

精度が低い場合の改善策:

1. **`description` を充実させる**: カラムの意味・コード値の説明を追加
2. **`verified_queries` を追加**: その質問の正解 SQL を登録する
3. **`measures` で計算ロジックを定義**: キャンセル除外・税込税抜などのビジネスルールを明示

---

## まとめ: 実装フロー

```
01_setup.sql       → 環境準備（DB・テーブル・ステージ作成）
       ↓
02_sample_data.sql → デモデータ投入
       ↓
03_semantic_model.yaml → YAML 作成 → ステージに PUT
       ↓
04_analyst_api_call.sql → REST API 呼び出しのテスト
       ↓
05_stored_procedures.sql → 再利用可能なプロシージャとして整備
```

次は [04_demo_app.md](04_demo_app.md) で Streamlit チャット UI を作ります。
