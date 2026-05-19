-- ============================================================
-- Verified Queries の管理・追加ガイド
-- ============================================================
-- Verified Queries は YAML ファイル（03_semantic_model.yaml）内の
-- verified_queries セクションに定義する。
-- このファイルは以下の目的で使用する:
--   1. 新しい Verified Query の正解 SQL を検証・テスト
--   2. YAML に追加する前の SQL をここで動作確認
--   3. 既存の Verified Queries の一覧管理
-- ============================================================

USE ROLE     ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- ============================================================
-- 現在の Verified Queries 一覧（03_semantic_model.yaml に登録済み）
-- ============================================================

-- 1. monthly_sales_trend: 月別の売上合計と注文件数の推移を教えて
-- 2. top5_products_last_month: 先月の売上上位5商品は？
-- 3. sales_by_category: カテゴリ別の売上合計と構成比
-- 4. sales_by_customer_segment: 法人顧客と個人顧客の売上比較
-- 5. region_monthly_sales: 地域別の月次売上推移
-- 6. this_year_sales_total: 今年の売上合計は？
-- 7. top_customers_ytd: 今年の売上上位顧客トップ10
-- 8. cancelled_rate_by_category: カテゴリ別のキャンセル率

-- ============================================================
-- 既存 Verified Queries の動作確認
-- ============================================================

-- 1. monthly_sales_trend の検証
SELECT
    DATE_TRUNC('MONTH', order_date) AS month,
    SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END) AS total_sales,
    COUNT(CASE WHEN status != 'cancelled' THEN order_id END)           AS order_count
FROM SALES_ORDERS
GROUP BY 1
ORDER BY 1;

-- 2. top5_products_last_month の検証
SELECT
    product_name,
    SUM(total_amount) AS total_sales,
    COUNT(order_id)   AS order_count
FROM SALES_ORDERS
WHERE
    status != 'cancelled'
    AND DATE_TRUNC('MONTH', order_date)
        = DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
GROUP BY product_name
ORDER BY total_sales DESC
LIMIT 5;

-- 3. sales_by_category の検証
SELECT
    category,
    SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END)  AS total_sales,
    ROUND(
        SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END) * 100.0
        / SUM(SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END)) OVER (),
        1
    ) AS sales_ratio_pct
FROM SALES_ORDERS
GROUP BY category
ORDER BY total_sales DESC;

-- ============================================================
-- 新規追加候補の SQL（YAML に追加する前に動作確認する）
-- ============================================================

-- 候補 A: 前年同月比
-- question: "今月の売上は昨年の同月と比べてどうか？"
SELECT
    YEAR(order_date)                                                        AS year,
    MONTH(order_date)                                                       AS month,
    SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END)       AS total_sales
FROM SALES_ORDERS
WHERE
    (YEAR(order_date) = YEAR(CURRENT_DATE()) AND MONTH(order_date) = MONTH(CURRENT_DATE()))
    OR (YEAR(order_date) = YEAR(CURRENT_DATE()) - 1 AND MONTH(order_date) = MONTH(CURRENT_DATE()))
GROUP BY 1, 2
ORDER BY 1;

-- 候補 B: 商品別の粗利率
-- question: "商品別の粗利率を教えて"
SELECT
    o.product_name,
    o.category,
    SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END)           AS total_sales,
    SUM(CASE WHEN o.status != 'cancelled' THEN p.cost_price * o.quantity ELSE 0 END) AS total_cost,
    ROUND(
        (SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END)
         - SUM(CASE WHEN o.status != 'cancelled' THEN p.cost_price * o.quantity ELSE 0 END)
        ) * 100.0
        / NULLIF(SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END), 0),
        1
    ) AS gross_margin_pct
FROM SALES_ORDERS o
LEFT JOIN PRODUCTS p ON o.product_id = p.product_id
GROUP BY o.product_name, o.category
ORDER BY gross_margin_pct DESC;

-- 候補 C: 目標達成率
-- question: "今月の売上目標達成率は？"
SELECT
    t.region,
    t.category,
    t.target_amount,
    COALESCE(SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END), 0) AS actual_sales,
    ROUND(
        COALESCE(SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END), 0)
        * 100.0 / NULLIF(t.target_amount, 0),
        1
    ) AS achievement_rate_pct
FROM SALES_TARGETS t
LEFT JOIN SALES_ORDERS o
    ON t.region       = o.region
    AND t.category    = o.category
    AND t.target_year  = YEAR(o.order_date)
    AND t.target_month = MONTH(o.order_date)
WHERE
    t.target_year  = YEAR(CURRENT_DATE())
    AND t.target_month = MONTH(CURRENT_DATE())
GROUP BY t.region, t.category, t.target_amount
ORDER BY achievement_rate_pct DESC;

-- 候補 D: 都道府県別の売上
-- question: "都道府県別の売上ランキング"
SELECT
    c.prefecture,
    SUM(CASE WHEN o.status != 'cancelled' THEN o.total_amount ELSE 0 END) AS total_sales,
    COUNT(CASE WHEN o.status != 'cancelled' THEN o.order_id END)           AS order_count
FROM SALES_ORDERS o
LEFT JOIN CUSTOMERS c ON o.customer_id = c.customer_id
GROUP BY c.prefecture
ORDER BY total_sales DESC;

-- ============================================================
-- YAML への追加手順
-- ============================================================
-- 上記の SQL が期待通りに動作したら、03_semantic_model.yaml の
-- verified_queries セクションに以下の形式で追加する:
--
-- verified_queries:
--   - name: yoy_comparison
--     question: "今月の売上は昨年の同月と比べてどうか？"
--     sql: |
--       SELECT ... (上記の検証済み SQL)
--
-- 追加後、ステージに再アップロード（PUT）して反映する。
