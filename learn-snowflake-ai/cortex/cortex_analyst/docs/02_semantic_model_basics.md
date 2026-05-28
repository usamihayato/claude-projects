# セマンティックモデル 基礎

## セマンティックモデルとは

セマンティックモデルは、**LLM（大規模言語モデル）への「テーブル設計書」** です。

Cortex Analyst が自然言語を SQL に変換するとき、Snowflake のテーブルがどんな意味を持つかを理解するために使います。

### なぜ必要か？

LLM は SQL を書けますが、あなたの会社のテーブル名・カラム名・ビジネスルールを知りません。

```
❌ LLM が知らないこと
- "order_amt" が税込か税抜か
- "status = 2" が「承認済み」を意味すること
- sales と customers を JOIN するキーは何か

✅ セマンティックモデルで教えること
- カラムの意味・単位・ビジネス定義
- テーブル間のリレーション
- 「売上」という指標の計算式
```

---

## `measures` vs `facts` — 混乱しやすいポイント

> 「実装したとき `fact` を使った気がする」という場合、それは **Semantic View** 形式（ネイティブ Snowflake オブジェクト）を使ったためです。

| 形式 | キー名 | 集計の定義方法 |
|---|---|---|
| **Cortex Analyst YAML**（ステージに置くファイル） | `measures` | `expr: SUM(...)` で集計式を直接記述 |
| **Semantic View**（ネイティブ Snowflake オブジェクト） | `facts` + `metrics` | `facts` は行レベルの生数値列、`metrics` が集計定義 |

**本ドキュメントで扱う YAML ファイル形式では `measures` が正しいキー名です。**

Semantic View 形式との比較:

```yaml
# ── Cortex Analyst YAML（ステージファイル）形式 ──
measures:
  - name: total_sales
    expr: SUM(total_amount)        # ← 集計式を expr に直接書く
    data_type: NUMBER

# ── Semantic View 形式 ──
facts:
  - name: total_amount             # ← 行レベルの生数値列
    expr: total_amount
    data_type: NUMBER

metrics:
  - name: total_sales
    expr: SUM(total_amount)        # ← 集計は metrics に分離
    data_type: NUMBER
```

---

## YAML の基本構造

```yaml
name: モデル名（識別子）
description: このモデルの説明（LLMが読む）

tables:
  - name: テーブル名（論理名）
    description: テーブルの説明
    base_table:
      database: DB名
      schema: スキーマ名
      table: 実テーブル名

    # 物理カラムの定義（全カラムを列挙）
    columns:
      - name: カラム名
        description: カラムの説明（ビジネス定義・コード値の意味を書く）
        data_type: VARCHAR / NUMBER / DATE / BOOLEAN
        sample_values:      # カテゴリ値がある場合
          - "値1"
          - "値2"

    # 時系列カラムの指定（月次・年次集計を正確にするために定義）
    time_dimensions:
      - column_name: カラム名（DATE/TIMESTAMP型のカラム）
        description: このカラムの説明

    # 集計指標の定義（← YAML 形式では measures。facts ではない）
    measures:
      - name: 指標名
        description: 指標の説明
        expr: SUM(カラム名)    # 集計式を直接記述
        data_type: NUMBER
        # default_aggregation: sum  # expr にカラム名だけ書く場合の別記法

relationships:  # テーブル間の JOIN 定義
  - name: リレーション名
    left_table: 左テーブル名
    right_table: 右テーブル名
    join_type: LEFT / INNER / FULL
    relationship_columns:
      - left_column: 結合キー（左）
        right_column: 結合キー（右）

verified_queries:  # 正解 SQL（LLMの精度向上に使う）
  - name: クエリ名
    question: "自然言語の質問例"
    sql: |
      SELECT ...
```

> **⚠️ `primary_entity` というキーは存在しません。**  
> `dimensions` という独立したキーも YAML ファイル形式では通常使いません。カテゴリ列は `columns` に定義し、`time_dimensions` と `measures` だけを別途宣言するのが標準構成です。

---

## 各フィールドの詳細解説

### `tables[].columns`

```yaml
columns:
  - name: order_amount
    description: "注文金額（税抜・円単位）"
    data_type: NUMBER
    
  - name: status_code
    description: |
      注文ステータスコード。
      1=未確認, 2=確認済み, 3=出荷済み, 4=完了, 9=キャンセル
    data_type: NUMBER
    sample_values:
      - "1"
      - "2"
      - "3"
```

`description` にビジネス定義・コード値の意味・単位を書くのが最重要ポイントです。

### `tables[].measures`（集計指標）

**YAML ファイル形式で集計指標を定義するキーは `measures` です。`facts` ではありません。**

集計式の書き方には2通りあります。

```yaml
# 書き方 A: expr に集計式を直接記述（推奨）
measures:
  - name: total_sales
    description: "売上合計（税抜金額の合計）"
    expr: SUM(order_amount)          # ← SUM/COUNT/AVG を直接書く
    data_type: NUMBER

  - name: order_count
    description: "注文件数"
    expr: COUNT(DISTINCT order_id)
    data_type: NUMBER

# 書き方 B: カラム名だけ書いて default_aggregation で集計方法を指定
measures:
  - name: total_sales
    description: "売上合計"
    expr: order_amount               # ← カラム名だけ
    data_type: NUMBER
    default_aggregation: sum         # ← 集計方法を別フィールドで指定
```

どちらも動作しますが、CASE WHEN などの条件付き集計が必要な場合は書き方 A が必須です。

measures に書いたものが「売上合計を教えて」のような質問に使われます。

### `tables[].time_dimensions`（時系列）

```yaml
time_dimensions:
  - column_name: order_date
    description: "注文日"
```

これを定義することで「先月の売上」「今年の月次推移」のような時間軸の質問が精度よく動きます。

### `relationships`（テーブル結合）

```yaml
relationships:
  - name: orders_to_customers
    left_table: sales_orders
    right_table: customers
    join_type: LEFT
    relationship_columns:
      - left_column: customer_id
        right_column: customer_id
```

LLM が自動的に JOIN を推論するために必要です。定義がないと複数テーブルをまたぐ質問が失敗します。

### `verified_queries`（正解 SQL）

```yaml
verified_queries:
  - name: monthly_sales
    question: "月別の売上合計を教えて"
    sql: |
      SELECT
        DATE_TRUNC('MONTH', order_date) AS month,
        SUM(order_amount) AS total_sales
      FROM sales_orders
      WHERE status_code != 9
      GROUP BY 1
      ORDER BY 1 DESC
```

類似した質問が来たとき、LLM は生成 SQL の代わりにこの正解 SQL を優先して使います。精度が上がり、ハルシネーション（誤った SQL 生成）を防ぎます。

---

## シンプルなサンプル YAML（売上テーブル1枚）

```yaml
name: simple_sales_model
description: |
  売上注文データの分析モデル。
  sales_orders テーブルを対象に、売上集計・トレンド分析が可能。

tables:
  - name: sales_orders
    description: "売上注文テーブル。1行が1注文を表す。"
    base_table:
      database: ANALYST_DEMO_DB
      schema: ANALYST_SCHEMA
      table: SALES_ORDERS
    columns:
      - name: order_id
        description: "注文ID（主キー）"
        data_type: VARCHAR
      - name: order_date
        description: "注文日"
        data_type: DATE
      - name: customer_id
        description: "顧客ID"
        data_type: VARCHAR
      - name: product_name
        description: "商品名"
        data_type: VARCHAR
      - name: category
        description: "商品カテゴリ（例: 電子機器, 食品, 衣類）"
        data_type: VARCHAR
      - name: quantity
        description: "注文数量"
        data_type: NUMBER
      - name: unit_price
        description: "単価（円・税抜）"
        data_type: NUMBER
      - name: total_amount
        description: "合計金額 = quantity × unit_price（税抜・円）"
        data_type: NUMBER
      - name: region
        description: "販売地域（東日本/西日本/海外）"
        data_type: VARCHAR
      - name: status
        description: |
          注文ステータス。
          pending=処理中, confirmed=確定, shipped=出荷済み, completed=完了, cancelled=キャンセル
        data_type: VARCHAR
    time_dimensions:
      - column_name: order_date
        description: "注文日（時系列分析に使用）"
    measures:
      - name: total_sales
        description: "売上合計（キャンセル除く）"
        expr: SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END)
        data_type: NUMBER
      - name: order_count
        description: "注文件数（キャンセル除く）"
        expr: COUNT(CASE WHEN status != 'cancelled' THEN order_id END)
        data_type: NUMBER
      - name: avg_order_value
        description: "平均注文金額"
        expr: AVG(CASE WHEN status != 'cancelled' THEN total_amount END)
        data_type: NUMBER

verified_queries:
  - name: top_products_last_month
    question: "先月の売上上位5商品を教えて"
    sql: |
      SELECT
        product_name,
        SUM(total_amount) AS total_sales,
        COUNT(order_id) AS order_count
      FROM sales_orders
      WHERE
        status != 'cancelled'
        AND DATE_TRUNC('MONTH', order_date) = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
      GROUP BY product_name
      ORDER BY total_sales DESC
      LIMIT 5
```

---

## よくある設計ミスと対処

| ミス | 症状 | 対処 |
|---|---|---|
| `facts` キーを使う | YAML ファイル形式ではパースエラーまたは無視される | YAML ファイルでは `measures` を使う。`facts` は Semantic View 形式のキー |
| `primary_entity` キーを使う | 存在しないキーのため無視される | このキーは YAML 形式に存在しない。カテゴリ列は `columns` に定義する |
| `description` が空・英語のみ | 日本語の質問に対応できず、엉뚱な SQL が生成される | 日本語でビジネス定義を必ず書く |
| コード値の説明なし | `status = 2` の意味が不明で条件句が誤る | `description` にコード値とラベルを列挙する |
| `measures` を定義しない | 「合計」「平均」の質問でカラム指定が曖昧になる | よく使う集計は `measures` として登録する |
| `relationships` を省略 | 複数テーブルをまたぐ質問が失敗する | 全テーブルの JOIN キーを定義する |
| `verified_queries` がゼロ | 正解が分かりやすい質問でもハルシネーションが起きる | 代表的な質問 5〜10 件は登録しておく |

---

## 次のステップ

- [03_analyst_sample.md](03_analyst_sample.md) — 実際にセマンティックモデルを作って動かす
- [06_advanced_semantic_model.md](06_advanced_semantic_model.md) — 複数テーブル・計算指標の高度な定義方法
