-- ============================================================================
-- 区分値カタログ DDL (2/3): Silver層（名寄せ中の中間テーブル）
-- 対象: Snowflake
-- 前提: 01_bronze.sql 実行済み
-- 参照: docs/03-schema-design/01-architecture.md, 02-table-definitions.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SILVER: 列名対応の名寄せ候補
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE (
    STG_ID                        NUMBER         AUTOINCREMENT PRIMARY KEY,
    TABLE_PHYSICAL_NAME            VARCHAR(200)   NOT NULL,
    COLUMN_PHYSICAL_NAME           VARCHAR(200)   NOT NULL,
    COLUMN_LOGICAL_NAME_CANDIDATE  VARCHAR(500),                -- 優先順位に基づく暫定採用値
    CONFLICT_FLAG                  BOOLEAN        DEFAULT FALSE, -- ソース間で内容が不一致
    NEEDS_REVIEW_FLAG              BOOLEAN        DEFAULT FALSE, -- 単一ソースのみ等、要確認
    CANDIDATE_VALUES               VARIANT,                      -- 各ソースの値・優先度・出典一覧
    SOURCE_RAW_IDS                 ARRAY,                        -- BRONZE.RAW_COLUMN_DEFINITION.RAW_ID の一覧
    COLUMN_DESCRIPTION_CANDIDATE   VARCHAR(1000),                -- 生成AIによる列説明文候補（SOURCE_RAW_IDSの原文のみを根拠に要約）
    DESCRIPTION_GENERATED_BY       VARCHAR(50)    DEFAULT 'AI',  -- AI / HUMAN
    DESCRIPTION_MODEL_VERSION      VARCHAR(200),                 -- 使用したCortexモデル名・バージョン（AI生成時のみ）
    DESCRIPTION_GENERATED_AT       TIMESTAMP_NTZ,                -- 説明文候補の生成日時
    MATCHING_BATCH_ID              NUMBER         REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID),
    UPDATED_AT                     TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- SILVER: 区分値対応の名寄せ候補
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE (
    STG_ID                        NUMBER         AUTOINCREMENT PRIMARY KEY,
    TABLE_PHYSICAL_NAME            VARCHAR(200)   NOT NULL,
    COLUMN_PHYSICAL_NAME           VARCHAR(200)   NOT NULL,
    CONTEXT_COLUMN_NAME            VARCHAR(200),                 -- 判別列の物理名（正規化後。コンテキストがなければNULL）
    CONTEXT_VALUE                  VARCHAR(200),                 -- 判別列の値（正規化後。コンテキストがなければNULL）
    CODE_VALUE                     VARCHAR(200)   NOT NULL,
    CODE_LABEL_CANDIDATE           VARCHAR(500),                 -- 名寄せ後の表示ラベル候補
    CODE_DESCRIPTION_CANDIDATE     VARCHAR(1000),
    CONFLICT_FLAG                  BOOLEAN        DEFAULT FALSE,
    NEEDS_REVIEW_FLAG              BOOLEAN        DEFAULT FALSE,
    CANDIDATE_VALUES               VARIANT,                      -- 各ソースの値・優先度・出典一覧
    SOURCE_RAW_IDS                 ARRAY,                        -- BRONZE.RAW_CODE_VALUE_DEFINITION.RAW_ID の一覧
    MATCHING_BATCH_ID              NUMBER         REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID),
    UPDATED_AT                     TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
);
