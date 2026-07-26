-- ============================================================================
-- 区分値カタログ DDL (1/3): データベース・スキーマ作成 + META層 + Bronze層
-- 対象: Snowflake
-- 参照: docs/03-schema-design/01-architecture.md, 02-table-definitions.md
-- ============================================================================

CREATE DATABASE IF NOT EXISTS DG_CATALOG;

CREATE SCHEMA IF NOT EXISTS DG_CATALOG.META;
CREATE SCHEMA IF NOT EXISTS DG_CATALOG.BRONZE;
CREATE SCHEMA IF NOT EXISTS DG_CATALOG.SILVER;
CREATE SCHEMA IF NOT EXISTS DG_CATALOG.GOLD;

-- ----------------------------------------------------------------------------
-- META: 収集対象システム管理
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.META.SOURCE_SYSTEM (
    SOURCE_SYSTEM_ID          NUMBER          AUTOINCREMENT PRIMARY KEY,
    SOURCE_SYSTEM_NAME        VARCHAR(200)    NOT NULL,      -- 収集対象システム名（画面あり業務システム）
    REPOSITORY_URL            VARCHAR(500),                  -- ソースコードリポジトリの参照先
    DOCUMENT_REPOSITORY_PATH  VARCHAR(500),                  -- 設計書の格納場所
    OWNER                     VARCHAR(200),                  -- システム所管部署・担当者
    REMARKS                   VARCHAR(1000),
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- META: 収集・変換バッチ管理
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.META.COLLECTION_BATCH (
    BATCH_ID                 NUMBER          AUTOINCREMENT PRIMARY KEY,
    BATCH_TYPE                VARCHAR(20)     NOT NULL,      -- 収集 / 名寄せ / 昇格
    SOURCE_SYSTEM_ID           NUMBER          REFERENCES DG_CATALOG.META.SOURCE_SYSTEM(SOURCE_SYSTEM_ID),
    STARTED_AT                TIMESTAMP_NTZ,
    COMPLETED_AT               TIMESTAMP_NTZ,
    STATUS                    VARCHAR(20)     DEFAULT '実行中',  -- 実行中 / 成功 / 失敗
    REMARKS                   VARCHAR(1000)
);

-- ----------------------------------------------------------------------------
-- BRONZE: 列名定義の抽出結果（メタ情報付き生データ）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION (
    RAW_ID                    NUMBER          AUTOINCREMENT PRIMARY KEY,
    BATCH_ID                  NUMBER          REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID),
    SOURCE_TYPE                VARCHAR(20)     NOT NULL,     -- 設計書 / ソースコード / 画面定義 / コードマスタ(Excel)
    SOURCE_IDENTIFIER          VARCHAR(500)    NOT NULL,     -- ファイルパス／リポジトリ名／ドキュメント名
    SOURCE_LOCATION            VARCHAR(500),                 -- シート名／行番号／クラス名など詳細位置
    SOURCE_VERSION             VARCHAR(200),                 -- ドキュメントバージョン／コミットハッシュ
    TABLE_PHYSICAL_NAME        VARCHAR(200)    NOT NULL,
    COLUMN_PHYSICAL_NAME       VARCHAR(200)    NOT NULL,
    COLUMN_LOGICAL_NAME_RAW    VARCHAR(500),                 -- 抽出された論理名候補（正規化前）
    RAW_CONTENT                VARIANT,                      -- 抽出元の生データ（原文）
    EXTRACTED_AT               TIMESTAMP_NTZ,
    CREATED_AT                 TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- BRONZE: 区分値定義の抽出結果（メタ情報付き生データ）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
    RAW_ID                    NUMBER          AUTOINCREMENT PRIMARY KEY,
    BATCH_ID                  NUMBER          REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID),
    SOURCE_TYPE                VARCHAR(20)     NOT NULL,     -- 設計書 / ソースコード / 画面定義 / コードマスタ(Excel)
    SOURCE_IDENTIFIER          VARCHAR(500)    NOT NULL,
    SOURCE_LOCATION            VARCHAR(500),
    SOURCE_VERSION             VARCHAR(200),
    TABLE_PHYSICAL_NAME        VARCHAR(200)    NOT NULL,
    COLUMN_PHYSICAL_NAME       VARCHAR(200)    NOT NULL,     -- 区分値が格納される列
    CONTEXT_COLUMN_NAME_RAW    VARCHAR(200),                 -- 区分値の意味を左右する判別列の物理名（コンテキストがなければNULL）
    CONTEXT_VALUE_RAW          VARCHAR(200),                 -- 判別列の値（正規化前。コンテキストがなければNULL）
    CODE_VALUE                 VARCHAR(200)    NOT NULL,     -- 区分値（コード値）
    CODE_LABEL_RAW             VARCHAR(500),                 -- 抽出された表示ラベル候補（正規化前）
    CODE_DESCRIPTION_RAW       VARCHAR(1000),
    RAW_CONTENT                VARIANT,
    EXTRACTED_AT               TIMESTAMP_NTZ,
    CREATED_AT                 TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- BRONZE: ファイルフォーマット定義
-- ----------------------------------------------------------------------------

-- 列名定義 CSV 用（設計書・コードマスタ由来）
CREATE FILE FORMAT IF NOT EXISTS DG_CATALOG.BRONZE.FF_COLUMN_DEF_CSV
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- 区分値定義 CSV 用（設計書・コードマスタ由来）
CREATE FILE FORMAT IF NOT EXISTS DG_CATALOG.BRONZE.FF_CODE_VALUE_CSV
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- AI 抽出結果 JSON 用（ソースコード・画面定義由来）
CREATE FILE FORMAT IF NOT EXISTS DG_CATALOG.BRONZE.FF_EXTRACTION_JSON
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    ENABLE_OCTAL = FALSE
    ALLOW_DUPLICATE = FALSE;

-- ----------------------------------------------------------------------------
-- BRONZE: 内部ステージ定義
-- ----------------------------------------------------------------------------

-- 列名定義ファイル用ステージ
CREATE STAGE IF NOT EXISTS DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES
    FILE_FORMAT = DG_CATALOG.BRONZE.FF_COLUMN_DEF_CSV
    COMMENT = '列名定義の抽出結果ファイルを配置するステージ';

-- 区分値定義ファイル用ステージ
CREATE STAGE IF NOT EXISTS DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES
    FILE_FORMAT = DG_CATALOG.BRONZE.FF_CODE_VALUE_CSV
    COMMENT = '区分値定義の抽出結果ファイルを配置するステージ';

-- AI 抽出結果ファイル用ステージ
CREATE STAGE IF NOT EXISTS DG_CATALOG.BRONZE.STG_EXTRACTION_JSON_FILES
    FILE_FORMAT = DG_CATALOG.BRONZE.FF_EXTRACTION_JSON
    COMMENT = 'AI抽出結果（JSON）ファイルを配置するステージ';
