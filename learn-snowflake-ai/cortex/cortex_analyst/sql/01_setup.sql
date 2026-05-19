-- ============================================================
-- Cortex Analyst デモ環境セットアップ
-- 実行順: このファイルを最初に実行する
-- ============================================================

-- ============================================================
-- Step 0: ロール・権限の設定
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- デモ用ロール作成
CREATE ROLE IF NOT EXISTS ANALYST_USER;

-- 実行するユーザーにロールを付与（<YOUR_USERNAME> を置き換えること）
-- GRANT ROLE ANALYST_USER TO USER <YOUR_USERNAME>;

-- Cortex 機能の利用権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ANALYST_USER;

-- ============================================================
-- Step 1: データベース・スキーマ・ウェアハウス
-- ============================================================

CREATE DATABASE IF NOT EXISTS ANALYST_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS ANALYST_DEMO_DB.ANALYST_SCHEMA;

CREATE WAREHOUSE IF NOT EXISTS ANALYST_WH
    WAREHOUSE_SIZE    = 'SMALL'
    AUTO_SUSPEND      = 60
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- ロールへの権限付与
GRANT ALL ON DATABASE  ANALYST_DEMO_DB                     TO ROLE ANALYST_USER;
GRANT ALL ON SCHEMA    ANALYST_DEMO_DB.ANALYST_SCHEMA      TO ROLE ANALYST_USER;
GRANT ALL ON WAREHOUSE ANALYST_WH                          TO ROLE ANALYST_USER;

-- ============================================================
-- Step 2: ステージ（セマンティックモデル YAML 保存用）
-- ============================================================

USE ROLE    ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

CREATE STAGE IF NOT EXISTS SEMANTIC_MODEL_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Cortex Analyst 用セマンティックモデル YAML を格納するステージ';

-- ============================================================
-- Step 3: テーブル定義
-- ============================================================

-- 売上注文テーブル
CREATE OR REPLACE TABLE SALES_ORDERS (
    ORDER_ID        VARCHAR(20)   NOT NULL COMMENT '注文ID（主キー）',
    ORDER_DATE      DATE          NOT NULL COMMENT '注文日',
    CUSTOMER_ID     VARCHAR(20)   NOT NULL COMMENT '顧客ID（CUSTOMERS テーブルと結合）',
    PRODUCT_ID      VARCHAR(20)   NOT NULL COMMENT '商品ID（PRODUCTS テーブルと結合）',
    PRODUCT_NAME    VARCHAR(100)  NOT NULL COMMENT '商品名（非正規化・JOIN 不要で使える）',
    CATEGORY        VARCHAR(50)   NOT NULL COMMENT '商品カテゴリ（電子機器/食品/衣類/書籍/スポーツ）',
    QUANTITY        NUMBER(10, 0) NOT NULL COMMENT '注文数量',
    UNIT_PRICE      NUMBER(10, 2) NOT NULL COMMENT '単価（税抜・円）',
    TOTAL_AMOUNT    NUMBER(12, 2) NOT NULL COMMENT '合計金額 = QUANTITY × UNIT_PRICE（税抜・円）',
    REGION          VARCHAR(20)   NOT NULL COMMENT '販売地域（東日本/西日本/海外）',
    STATUS          VARCHAR(20)   NOT NULL COMMENT 'ステータス: pending=処理中, confirmed=確定, shipped=出荷済み, completed=完了, cancelled=キャンセル'
);

-- 顧客マスタ
CREATE OR REPLACE TABLE CUSTOMERS (
    CUSTOMER_ID     VARCHAR(20)   NOT NULL COMMENT '顧客ID（主キー）',
    CUSTOMER_NAME   VARCHAR(100)  NOT NULL COMMENT '顧客名',
    SEGMENT         VARCHAR(20)   NOT NULL COMMENT '顧客セグメント: 法人 / 個人',
    PREFECTURE      VARCHAR(20)   NOT NULL COMMENT '都道府県',
    REGISTERED_DATE DATE          NOT NULL COMMENT '登録日'
);

-- 商品マスタ
CREATE OR REPLACE TABLE PRODUCTS (
    PRODUCT_ID      VARCHAR(20)   NOT NULL COMMENT '商品ID（主キー）',
    PRODUCT_NAME    VARCHAR(100)  NOT NULL COMMENT '商品名',
    CATEGORY        VARCHAR(50)   NOT NULL COMMENT 'カテゴリ（電子機器/食品/衣類/書籍/スポーツ）',
    COST_PRICE      NUMBER(10, 2) NOT NULL COMMENT '原価（税抜・円）',
    LIST_PRICE      NUMBER(10, 2) NOT NULL COMMENT '定価（税抜・円）',
    IS_ACTIVE       BOOLEAN       NOT NULL DEFAULT TRUE COMMENT '販売中フラグ'
);

-- 売上目標テーブル
CREATE OR REPLACE TABLE SALES_TARGETS (
    TARGET_YEAR     NUMBER(4,0)   NOT NULL COMMENT '目標年度',
    TARGET_MONTH    NUMBER(2,0)   NOT NULL COMMENT '目標月（1〜12）',
    REGION          VARCHAR(20)   NOT NULL COMMENT '地域（東日本/西日本/海外）',
    CATEGORY        VARCHAR(50)   NOT NULL COMMENT 'カテゴリ',
    TARGET_AMOUNT   NUMBER(12, 2) NOT NULL COMMENT '売上目標金額（税抜・円）'
);

-- ============================================================
-- Step 4: 確認クエリ
-- ============================================================

SHOW TABLES IN SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA;
LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE;
