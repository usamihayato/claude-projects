-- ============================================================
-- サンプルデータ投入
-- 実行順: 01_setup.sql の後に実行
-- ============================================================

USE ROLE     ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- ============================================================
-- 顧客マスタ（20件）
-- ============================================================

INSERT INTO CUSTOMERS (CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, PREFECTURE, REGISTERED_DATE) VALUES
('C001', '株式会社東京商事',     '法人', '東京都',   '2022-01-15'),
('C002', '大阪貿易株式会社',     '法人', '大阪府',   '2022-03-01'),
('C003', '田中 太郎',            '個人', '神奈川県', '2022-04-20'),
('C004', '鈴木 花子',            '個人', '愛知県',   '2022-06-10'),
('C005', '北海道システムズ',      '法人', '北海道',   '2022-07-01'),
('C006', '九州テクノロジー株式会社','法人','福岡県',  '2022-09-15'),
('C007', '佐藤 健一',            '個人', '東京都',   '2022-10-01'),
('C008', '株式会社名古屋物産',   '法人', '愛知県',   '2022-11-20'),
('C009', '山田 美咲',            '個人', '大阪府',   '2023-01-05'),
('C010', '仙台ソリューションズ', '法人', '宮城県',   '2023-02-14'),
('C011', '渡辺 隆',              '個人', '埼玉県',   '2023-03-30'),
('C012', '広島インダストリー',   '法人', '広島県',   '2023-05-01'),
('C013', '木村 奈々',            '個人', '千葉県',   '2023-06-20'),
('C014', '横浜フィナンシャル',   '法人', '神奈川県', '2023-08-01'),
('C015', '中村 勇気',            '個人', '福岡県',   '2023-09-15'),
('C016', '京都クラフト株式会社', '法人', '京都府',   '2023-10-01'),
('C017', '加藤 朋子',            '個人', '大阪府',   '2023-11-20'),
('C018', '石川 誠',              '個人', '静岡県',   '2024-01-10'),
('C019', '東北エンタープライズ', '法人', '宮城県',   '2024-02-01'),
('C020', '林 早苗',              '個人', '神奈川県', '2024-03-15');

-- ============================================================
-- 商品マスタ（20件）
-- ============================================================

INSERT INTO PRODUCTS (PRODUCT_ID, PRODUCT_NAME, CATEGORY, COST_PRICE, LIST_PRICE, IS_ACTIVE) VALUES
('P001', 'ノートPC Pro 15',       '電子機器', 80000,  120000, TRUE),
('P002', 'ノートPC Air 13',       '電子機器', 60000,   95000, TRUE),
('P003', 'スマートフォン X',      '電子機器', 40000,   75000, TRUE),
('P004', 'タブレット 10インチ',   '電子機器', 25000,   45000, TRUE),
('P005', 'ワイヤレスイヤホン',    '電子機器',  5000,   12000, TRUE),
('P006', 'スマートウォッチ',      '電子機器', 18000,   35000, TRUE),
('P007', 'オーガニックコーヒー豆','食品',      1500,    3200, TRUE),
('P008', '抹茶スイーツセット',    '食品',      2000,    4500, TRUE),
('P009', 'プレミアムチョコレート','食品',      1200,    2800, TRUE),
('P010', '機能性栄養補助食品',    '食品',      3000,    6500, TRUE),
('P011', 'カジュアルTシャツ',     '衣類',       800,    2500, TRUE),
('P012', 'ビジネスシャツ',        '衣類',      2500,    6800, TRUE),
('P013', 'デニムジーンズ',        '衣類',      3000,    7500, TRUE),
('P014', 'ウルトラライトジャケット','衣類',    8000,   18000, TRUE),
('P015', 'プログラミング入門書',  '書籍',       900,    2200, TRUE),
('P016', 'データ分析実践ガイド',  '書籍',      1200,    2800, TRUE),
('P017', 'ビジネス英語テキスト',  '書籍',       800,    1980, TRUE),
('P018', 'ランニングシューズ',    'スポーツ',  6000,   14000, TRUE),
('P019', 'ヨガマット',            'スポーツ',  2000,    4800, TRUE),
('P020', 'スポーツドリンク 24本', 'スポーツ',  2400,    4500, TRUE);

-- ============================================================
-- 売上目標テーブル（2024年・2025年）
-- ============================================================

INSERT INTO SALES_TARGETS (TARGET_YEAR, TARGET_MONTH, REGION, CATEGORY, TARGET_AMOUNT)
SELECT
    yr, mn, region, category,
    base_amt * (1 + (RANDOM()::NUMBER(3,2)) * 0.2 - 0.1)
FROM (
    SELECT 2024 AS yr UNION ALL SELECT 2025
) y
CROSS JOIN (
    SELECT 1 AS mn UNION ALL SELECT 2 UNION ALL SELECT 3
    UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6
    UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
    UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12
) m
CROSS JOIN (
    SELECT '東日本' AS region, 2000000 AS base_amt UNION ALL
    SELECT '西日本',           1500000             UNION ALL
    SELECT '海外',             1000000
) r
CROSS JOIN (
    SELECT '電子機器' AS category UNION ALL
    SELECT '食品'                 UNION ALL
    SELECT '衣類'                 UNION ALL
    SELECT '書籍'                 UNION ALL
    SELECT 'スポーツ'
) c;

-- ============================================================
-- 売上注文テーブル（2024年1月〜2025年4月: 約500件）
-- ============================================================

-- 2024年の売上データ
INSERT INTO SALES_ORDERS
    (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PRODUCT_ID, PRODUCT_NAME, CATEGORY, QUANTITY, UNIT_PRICE, TOTAL_AMOUNT, REGION, STATUS)
SELECT
    'ORD-' || LPAD(SEQ4()::VARCHAR, 5, '0'),
    DATEADD('DAY', UNIFORM(0, 364, RANDOM()), '2024-01-01')::DATE,
    'C' || LPAD(UNIFORM(1, 20, RANDOM())::VARCHAR, 3, '0'),
    p.PRODUCT_ID,
    p.PRODUCT_NAME,
    p.CATEGORY,
    UNIFORM(1, 5, RANDOM()),
    p.LIST_PRICE,
    UNIFORM(1, 5, RANDOM()) * p.LIST_PRICE,
    CASE UNIFORM(1, 3, RANDOM())
        WHEN 1 THEN '東日本'
        WHEN 2 THEN '西日本'
        ELSE '海外'
    END,
    CASE UNIFORM(1, 10, RANDOM())
        WHEN 1 THEN 'cancelled'
        WHEN 2 THEN 'pending'
        ELSE 'completed'
    END
FROM TABLE(GENERATOR(ROWCOUNT => 400)) g
JOIN (SELECT ROW_NUMBER() OVER (ORDER BY PRODUCT_ID) AS rn, * FROM PRODUCTS) p
  ON p.rn = UNIFORM(1, 20, RANDOM());

-- 2025年の売上データ（1月〜4月）
INSERT INTO SALES_ORDERS
    (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PRODUCT_ID, PRODUCT_NAME, CATEGORY, QUANTITY, UNIT_PRICE, TOTAL_AMOUNT, REGION, STATUS)
SELECT
    'ORD-' || LPAD((400 + SEQ4())::VARCHAR, 5, '0'),
    DATEADD('DAY', UNIFORM(0, 132, RANDOM()), '2025-01-01')::DATE,
    'C' || LPAD(UNIFORM(1, 20, RANDOM())::VARCHAR, 3, '0'),
    p.PRODUCT_ID,
    p.PRODUCT_NAME,
    p.CATEGORY,
    UNIFORM(1, 5, RANDOM()),
    p.LIST_PRICE,
    UNIFORM(1, 5, RANDOM()) * p.LIST_PRICE,
    CASE UNIFORM(1, 3, RANDOM())
        WHEN 1 THEN '東日本'
        WHEN 2 THEN '西日本'
        ELSE '海外'
    END,
    CASE UNIFORM(1, 10, RANDOM())
        WHEN 1 THEN 'cancelled'
        WHEN 2 THEN 'pending'
        ELSE 'completed'
    END
FROM TABLE(GENERATOR(ROWCOUNT => 150)) g
JOIN (SELECT ROW_NUMBER() OVER (ORDER BY PRODUCT_ID) AS rn, * FROM PRODUCTS) p
  ON p.rn = UNIFORM(1, 20, RANDOM());

-- TOTAL_AMOUNT を QUANTITY × UNIT_PRICE で再計算（整合性確保）
UPDATE SALES_ORDERS SET TOTAL_AMOUNT = QUANTITY * UNIT_PRICE;

-- ============================================================
-- データ確認
-- ============================================================

SELECT '顧客マスタ'    AS tbl, COUNT(*) AS cnt FROM CUSTOMERS
UNION ALL
SELECT '商品マスタ',         COUNT(*) FROM PRODUCTS
UNION ALL
SELECT '売上目標',           COUNT(*) FROM SALES_TARGETS
UNION ALL
SELECT '売上注文',           COUNT(*) FROM SALES_ORDERS;

-- 売上サマリ確認
SELECT
    DATE_TRUNC('MONTH', ORDER_DATE) AS month,
    REGION,
    COUNT(*)                        AS order_count,
    SUM(TOTAL_AMOUNT)               AS total_sales
FROM SALES_ORDERS
WHERE STATUS != 'cancelled'
GROUP BY 1, 2
ORDER BY 1, 2;
