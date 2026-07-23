-- ============================================================================
-- 区分値カタログ DDL (3/3): Gold層（確定済みマスタ。版管理あり）
-- 対象: Snowflake
-- 前提: 01_bronze.sql, 02_silver.sql 実行済み
-- 参照: docs/03-schema-design/01-architecture.md, 02-table-definitions.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- GOLD: 列定義マスタ（物理名 ⇔ 論理名。SCD Type2 相当の版管理）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.GOLD.DIM_COLUMN_MASTER (
    COLUMN_MASTER_ID     NUMBER          AUTOINCREMENT PRIMARY KEY,
    TABLE_PHYSICAL_NAME   VARCHAR(200)    NOT NULL,
    COLUMN_PHYSICAL_NAME  VARCHAR(200)    NOT NULL,
    COLUMN_LOGICAL_NAME   VARCHAR(500)    NOT NULL,          -- 確定した論理名（業務名）
    DATA_TYPE              VARCHAR(100),                     -- 列のデータ型（実データカタログの形式に合わせて保持）
    COLUMN_DESCRIPTION    VARCHAR(1000),                      -- 人手による説明文
    CODE_VALUE_SUMMARY     VARCHAR(4000),                     -- DIM_CODE_VALUE_MASTERから機械生成した区分値要約（例: 01: ABCD, 02: EFGH）
    VALID_FROM            DATE            NOT NULL,
    VALID_TO              DATE,                              -- NULL = 現在有効
    IS_CURRENT             BOOLEAN         DEFAULT TRUE,
    SOURCE_STG_ID          NUMBER          REFERENCES DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE(STG_ID),
    REVIEWED_BY            VARCHAR(200)    DEFAULT 'SYSTEM', -- 自動昇格の場合は SYSTEM
    REVIEWED_AT            TIMESTAMP_NTZ,
    CREATED_AT             TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- GOLD: 区分値マスタ（コード値 ⇔ 表示ラベル。SCD Type2 相当の版管理）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER (
    CODE_VALUE_MASTER_ID   NUMBER          AUTOINCREMENT PRIMARY KEY,
    TABLE_PHYSICAL_NAME     VARCHAR(200)    NOT NULL,
    COLUMN_PHYSICAL_NAME    VARCHAR(200)    NOT NULL,
    CONTEXT_COLUMN_NAME      VARCHAR(200),                    -- 判別列の物理名（コンテキストがなければNULL＝共通）
    CONTEXT_VALUE            VARCHAR(200),                    -- 判別列の値（コンテキストがなければNULL＝共通）
    CODE_VALUE               VARCHAR(200)    NOT NULL,
    CODE_LABEL               VARCHAR(500)    NOT NULL,        -- 確定した表示ラベル
    CODE_DESCRIPTION         VARCHAR(1000),
    VALID_FROM               DATE            NOT NULL,
    VALID_TO                 DATE,                            -- NULL = 現在有効
    IS_CURRENT                BOOLEAN         DEFAULT TRUE,
    SOURCE_STG_ID             NUMBER          REFERENCES DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE(STG_ID),
    REVIEWED_BY               VARCHAR(200)    DEFAULT 'SYSTEM',
    REVIEWED_AT               TIMESTAMP_NTZ,
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- 参照高速化用インデックス相当（Snowflakeはクラスタリングキーで代替）
-- 対象DBとのJOIN（テーブル物理名・列物理名・コード値での検索）が主用途のため設定
-- ----------------------------------------------------------------------------
ALTER TABLE DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER
    CLUSTER BY (TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME, CONTEXT_COLUMN_NAME);

ALTER TABLE DG_CATALOG.GOLD.DIM_COLUMN_MASTER
    CLUSTER BY (TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME);
