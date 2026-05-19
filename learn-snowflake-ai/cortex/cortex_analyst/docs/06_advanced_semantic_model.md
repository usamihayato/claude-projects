# セマンティックモデル 高度な設定

## 概要

[02_semantic_model_basics.md](02_semantic_model_basics.md) の基礎に続き、実務で必要になる高度な設定を解説します。

---

## 1. 計算指標（measures）の高度な定義

### 条件付き集計

```yaml
measures:
  - name: cancelled_order_rate
    description: "キャンセル率（キャンセル件数 / 全注文件数）"
    expr: |
      ROUND(
        COUNT(CASE WHEN status = 'cancelled' THEN order_id END) * 100.0
        / NULLIF(COUNT(order_id), 0),
        2
      )
    data_type: NUMBER

  - name: new_customer_sales
    description: "新規顧客（初回注文）の売上合計"
    expr: |
      SUM(
        CASE
          WHEN order_id IN (
            SELECT MIN(order_id)
            FROM sales_orders
            GROUP BY customer_id
          )
          THEN total_amount
          ELSE 0
        END
      )
    data_type: NUMBER
```

### 前期比・累計

```yaml
  - name: ytd_sales
    description: "年初来売上累計（今年の1月1日から現在まで）"
    expr: |
      SUM(
        CASE
          WHEN YEAR(order_date) = YEAR(CURRENT_DATE())
            AND status != 'cancelled'
          THEN total_amount ELSE 0
        END
      )
    data_type: NUMBER
```

### 利益率

```yaml
  - name: gross_margin_rate
    description: "粗利率（%）= (売上 - 原価) / 売上 × 100"
    expr: |
      ROUND(
        (SUM(total_amount) - SUM(cost_price * quantity))
        / NULLIF(SUM(total_amount), 0) * 100,
        1
      )
    data_type: NUMBER
```

---

## 2. テーブルリレーション（複数テーブルの JOIN）

### 基本的なリレーション定義

```yaml
relationships:
  # 売上 → 顧客
  - name: orders_to_customers
    left_table: sales_orders
    right_table: customers
    join_type: LEFT
    relationship_columns:
      - left_column: customer_id
        right_column: customer_id

  # 売上 → 商品
  - name: orders_to_products
    left_table: sales_orders
    right_table: products
    join_type: LEFT
    relationship_columns:
      - left_column: product_id
        right_column: product_id

  # 売上 → 売上目標（複合キー結合）
  - name: orders_to_targets
    left_table: sales_orders
    right_table: sales_targets
    join_type: LEFT
    relationship_columns:
      - left_column: region
        right_column: region
      - left_column: category
        right_column: category
```

### リレーション定義時の注意

- `join_type` は `INNER`, `LEFT`, `FULL` が使用可能。通常は `LEFT` を推奨（データが片側にない場合でも集計が壊れない）
- 複合キー（複数列で JOIN）も定義可能
- 循環参照（A→B→A）は避ける

---

## 3. Verified Queries（正解 SQL の登録）

Verified Queries は、**よく使われる質問に対して正解 SQL を事前登録しておく機能**です。

### なぜ重要か

```
LLM が SQL を生成 → 稀に誤る（ハルシネーション）
  例: キャンセル除外を忘れる
  例: 日付の集計粒度がずれる

Verified Queries を登録 → 類似質問に正解 SQL を使う
  → 精度が安定する
  → ビジネスルール（キャンセル除外等）が確実に反映される
```

### 登録方法

```yaml
verified_queries:
  - name: monthly_sales_trend
    question: "月別の売上合計と注文件数の推移を教えて"
    sql: |
      SELECT
        DATE_TRUNC('MONTH', order_date) AS month,
        SUM(total_amount)               AS total_sales,
        COUNT(order_id)                 AS order_count
      FROM sales_orders
      WHERE status != 'cancelled'
      GROUP BY 1
      ORDER BY 1

  - name: top5_products_last_month
    question: "先月の売上上位5商品は？"
    sql: |
      SELECT
        product_name,
        SUM(total_amount) AS total_sales,
        COUNT(order_id)   AS order_count
      FROM sales_orders
      WHERE
        status != 'cancelled'
        AND DATE_TRUNC('MONTH', order_date)
            = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
      GROUP BY product_name
      ORDER BY total_sales DESC
      LIMIT 5

  - name: sales_by_customer_segment
    question: "顧客セグメント別（法人・個人）の売上比率"
    sql: |
      SELECT
        c.segment,
        SUM(o.total_amount)                                       AS total_sales,
        ROUND(SUM(o.total_amount) * 100.0 / SUM(SUM(o.total_amount)) OVER (), 1)
                                                                  AS sales_ratio_pct
      FROM sales_orders  o
      JOIN customers     c ON o.customer_id = c.customer_id
      WHERE o.status != 'cancelled'
      GROUP BY c.segment
      ORDER BY total_sales DESC

  - name: region_category_matrix
    question: "地域別・カテゴリ別の売上クロス集計"
    sql: |
      SELECT
        region,
        category,
        SUM(total_amount) AS total_sales
      FROM sales_orders
      WHERE status != 'cancelled'
      GROUP BY region, category
      ORDER BY region, total_sales DESC
```

### 登録のコツ

- 実際にユーザーから来た質問をそのまま登録する
- 同じ質問を言い換えたものを複数登録しても有効
- SQL にコメントは不要（シンプルに保つ）
- CURRENT_DATE() のような動的関数も使える

---

## 4. 時系列データの設定

### time_dimensions の詳細設定

```yaml
tables:
  - name: sales_orders
    time_dimensions:
      - column_name: order_date
        description: "注文日。月次・週次・日次の集計に使う。"
```

これにより以下のような質問が正確に解釈されます:
- 「今月の〜」→ `DATE_TRUNC('MONTH', order_date) = DATE_TRUNC('MONTH', CURRENT_DATE())`
- 「先月の〜」→ `DATE_TRUNC('MONTH', order_date) = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))`
- 「今年の月次推移」→ `YEAR(order_date) = YEAR(CURRENT_DATE()) GROUP BY DATE_TRUNC('MONTH', order_date)`

### 複数の日付列がある場合

```yaml
tables:
  - name: projects
    time_dimensions:
      - column_name: start_date
        description: "プロジェクト開始日"
      - column_name: end_date
        description: "プロジェクト終了日（完了前は NULL）"
      - column_name: created_at
        description: "レコード作成日時"
```

---

## 5. フィルタ条件・サンプル値の設定

### sample_values でコード値を教える

```yaml
columns:
  - name: status
    description: |
      注文ステータス。
      pending=処理中, confirmed=確定, shipped=出荷済み, completed=完了, cancelled=キャンセル
    data_type: VARCHAR
    sample_values:
      - "pending"
      - "confirmed"
      - "shipped"
      - "completed"
      - "cancelled"

  - name: region
    description: "販売地域"
    data_type: VARCHAR
    sample_values:
      - "東日本"
      - "西日本"
      - "海外"
```

`sample_values` を設定することで、「東日本の売上」のような質問で LLM が正しい値を WHERE 句に使えます。

---

## 6. 派生テーブル（Derived Table）

集計済みビューをセマンティックモデルのテーブルとして登録することも可能です。

```yaml
tables:
  - name: monthly_summary
    description: "月次売上サマリ（事前集計済み）"
    base_table:
      database: ANALYST_DEMO_DB
      schema: ANALYST_SCHEMA
      table: V_MONTHLY_SALES_SUMMARY  # ← VIEWを指定
    columns:
      - name: month
        description: "集計月（YYYY-MM-01 形式）"
        data_type: DATE
      - name: total_sales
        description: "月次売上合計"
        data_type: NUMBER
      - name: order_count
        description: "注文件数"
        data_type: NUMBER
```

---

## セマンティックモデル設計チェックリスト

| 項目 | 確認内容 |
|---|---|
| tables | 全テーブルが登録されているか |
| description | 全テーブル・全カラムに日本語の説明があるか |
| コード値 | status など値が限定されるカラムに sample_values があるか |
| measures | よく使う集計（合計・件数・平均・率）が定義されているか |
| time_dimensions | 日付・日時カラムが登録されているか |
| relationships | 全テーブルの JOIN キーが定義されているか |
| verified_queries | 代表的な質問 5 件以上が登録されているか |

---

## 次のステップ

- [07_analyst_rag_integration.md](07_analyst_rag_integration.md) — Cortex Search との統合
- [08_best_practices.md](08_best_practices.md) — 本番運用のベストプラクティス
- `../sql/03_semantic_model.yaml` — 実際に動く完全な YAML
