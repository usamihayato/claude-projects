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
    SOURCE_SYSTEM_ID          NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    SOURCE_SYSTEM_NAME        VARCHAR(200)    NOT NULL
        COMMENT '収集対象システム名（画面あり業務システム）',
    REPOSITORY_URL            VARCHAR(500)
        COMMENT 'ソースコードリポジトリの参照先',
    DOCUMENT_REPOSITORY_PATH  VARCHAR(500)
        COMMENT '設計書の格納場所',
    OWNER                     VARCHAR(200)
        COMMENT 'システム所管部署・担当者',
    REMARKS                   VARCHAR(1000)
        COMMENT '備考',
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT '登録日時'
)
COMMENT = '収集対象システム（画面あり業務システムなど）の管理台帳';

-- ----------------------------------------------------------------------------
-- META: 収集・変換バッチ管理
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.META.COLLECTION_BATCH (
    BATCH_ID                 NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    BATCH_TYPE                VARCHAR(20)     NOT NULL
        COMMENT 'バッチ種別。収集 / 名寄せ / 昇格 のいずれか',
    SOURCE_SYSTEM_ID           NUMBER          REFERENCES DG_CATALOG.META.SOURCE_SYSTEM(SOURCE_SYSTEM_ID)
        COMMENT 'FK: META.SOURCE_SYSTEM',
    STARTED_AT                TIMESTAMP_NTZ
        COMMENT '実行開始日時',
    COMPLETED_AT               TIMESTAMP_NTZ
        COMMENT '実行完了日時',
    STATUS                    VARCHAR(20)     DEFAULT '実行中'
        COMMENT '実行ステータス。実行中 / 成功 / 失敗',
    REMARKS                   VARCHAR(1000)
        COMMENT '備考（失敗時のエラー内容等）'
)
COMMENT = '収集・名寄せ・昇格バッチの実行管理';

-- ----------------------------------------------------------------------------
-- META: 抽出対象シート管理
--   Excel の目次シートから取得したシート一覧を管理する。
--   Python UDF が目次シートを読み取り、このテーブルと突合して処理対象を決定する。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.META.SOURCE_SHEET (
    SOURCE_SHEET_ID           NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    SOURCE_SYSTEM_ID          NUMBER          REFERENCES DG_CATALOG.META.SOURCE_SYSTEM(SOURCE_SYSTEM_ID)
        COMMENT 'FK: META.SOURCE_SYSTEM',
    FILE_NAME                 VARCHAR(500)    NOT NULL
        COMMENT '元の Excel ファイル名',
    SHEET_NAME                VARCHAR(200)    NOT NULL
        COMMENT 'シート名（目次シートに記載された名称）',
    TABLE_PHYSICAL_NAME       VARCHAR(200)
        COMMENT '対応するテーブル物理名（判明している場合）',
    COLUMN_PHYSICAL_NAME      VARCHAR(200)
        COMMENT '対応するカラム物理名（判明している場合）',
    SHEET_TYPE                VARCHAR(50)
        COMMENT 'シートの種別（区分値一覧 / 列定義 / その他）',
    IS_ACTIVE                 BOOLEAN         DEFAULT TRUE
        COMMENT '処理対象かどうか（FALSEで除外可能）',
    REMARKS                   VARCHAR(1000)
        COMMENT '備考',
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT '登録日時',
    UPDATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT '更新日時'
)
COMMENT = 'Excelの目次シートから取得したシート一覧。UDF①がこのテーブルと突合して処理対象シートを決定する';

-- ----------------------------------------------------------------------------
-- BRONZE: 列名定義の抽出結果（メタ情報付き生データ）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION (
    RAW_ID                    NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    BATCH_ID                  NUMBER          REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID)
        COMMENT 'FK: META.COLLECTION_BATCH（収集実行バッチ）',
    SOURCE_TYPE                VARCHAR(20)     NOT NULL
        COMMENT '出典種別。設計書 / ソースコード / 画面定義 / コードマスタ(Excel)',
    SOURCE_IDENTIFIER          VARCHAR(500)    NOT NULL
        COMMENT '出典の識別情報（ファイルパス／リポジトリ名／ドキュメント名）',
    SOURCE_LOCATION            VARCHAR(500)
        COMMENT '出典内の詳細位置（シート名／行番号／クラス名など）',
    SOURCE_VERSION             VARCHAR(200)
        COMMENT 'ドキュメントバージョン／コミットハッシュ',
    TABLE_PHYSICAL_NAME        VARCHAR(200)    NOT NULL
        COMMENT '対象テーブル物理名',
    COLUMN_PHYSICAL_NAME       VARCHAR(200)    NOT NULL
        COMMENT '対象列物理名',
    COLUMN_LOGICAL_NAME_RAW    VARCHAR(500)
        COMMENT '抽出された論理名候補（正規化前。ソースによって表記が揺れうる）',
    RAW_CONTENT                VARIANT
        COMMENT '抽出元の生データ（原文をそのまま保持）',
    EXTRACTED_AT               TIMESTAMP_NTZ
        COMMENT '抽出日時',
    CREATED_AT                 TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Bronze層への格納日時'
)
COMMENT = '列名定義（物理名→論理名）の抽出結果。ソース1件につき1行のメタ情報付き生データ。複数ソースの統合・名寄せはSILVER.STG_COLUMN_CANDIDATEで行う（本テーブル自体は他Bronzeレコードと合成しない）';

-- ----------------------------------------------------------------------------
-- BRONZE: 区分値定義の抽出結果（メタ情報付き生データ）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
    RAW_ID                    NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    BATCH_ID                  NUMBER          REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID)
        COMMENT 'FK: META.COLLECTION_BATCH（収集実行バッチ）',
    SOURCE_TYPE                VARCHAR(20)     NOT NULL
        COMMENT '出典種別。設計書 / ソースコード / 画面定義 / コードマスタ(Excel)',
    SOURCE_IDENTIFIER          VARCHAR(500)    NOT NULL
        COMMENT '出典の識別情報（ファイルパス／リポジトリ名／ドキュメント名）',
    SOURCE_LOCATION            VARCHAR(500)
        COMMENT '出典内の詳細位置（シート名／行番号／クラス名など）',
    SOURCE_VERSION             VARCHAR(200)
        COMMENT 'ドキュメントバージョン／コミットハッシュ',
    TABLE_PHYSICAL_NAME        VARCHAR(200)    NOT NULL
        COMMENT '対象テーブル物理名',
    COLUMN_PHYSICAL_NAME       VARCHAR(200)    NOT NULL
        COMMENT '区分値が格納される列の物理名',
    CONTEXT_NAME_RAW    VARCHAR(200)
        COMMENT '区分値の意味を左右する判別列（同一テーブル内の別列。例: 商品種別コード）の物理名。コンテキストに依存しない場合はNULL',
    CONTEXT_VALUE_RAW          VARCHAR(200)
        COMMENT '判別列の値（正規化前）。コンテキストに依存しない場合はNULL',
    CODE_VALUE                 VARCHAR(200)    NOT NULL
        COMMENT '区分値（コード値。型が混在しうるため文字列で保持）',
    CODE_LABEL_RAW             VARCHAR(500)
        COMMENT '抽出された表示ラベル候補（正規化前）',
    CODE_DESCRIPTION_RAW       VARCHAR(1000)
        COMMENT '補足説明（原文にあれば）',
    RAW_CONTENT                VARIANT
        COMMENT '抽出元の生データ（原文をそのまま保持）',
    EXTRACTED_AT               TIMESTAMP_NTZ
        COMMENT '抽出日時',
    CREATED_AT                 TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Bronze層への格納日時'
)
COMMENT = '区分値定義（コード値→表示ラベル）の抽出結果。ソース1件につき1行のメタ情報付き生データ。同じコード値でも判別列（CONTEXT_NAME_RAW）の値によって意味が変わるケースがあるため、判別列も合わせて保持する（詳細はGOLD.DIM_CODE_VALUE_MASTERのコメントを参照）';

-- ----------------------------------------------------------------------------
-- BRONZE: ファイルフォーマット定義
-- ----------------------------------------------------------------------------

-- 構造化済み CSV 用（structured/ ディレクトリの CSV を COPY INTO する際に使用）
CREATE FILE FORMAT IF NOT EXISTS DG_CATALOG.BRONZE.FF_STRUCTURED_CSV
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    COMMENT = 'structured/ ディレクトリの構造化済みCSVをBronzeへCOPY INTOする際に使用するファイルフォーマット';

-- AI 抽出結果 JSON 用（ソースコード・画面定義由来）
CREATE FILE FORMAT IF NOT EXISTS DG_CATALOG.BRONZE.FF_EXTRACTION_JSON
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    ENABLE_OCTAL = FALSE
    ALLOW_DUPLICATE = FALSE
    COMMENT = 'extraction/ ディレクトリのAI抽出結果JSON（ソースコード・画面定義由来）をBronzeへ取り込む際に使用するファイルフォーマット';

-- ----------------------------------------------------------------------------
-- BRONZE: 内部ステージ定義（1ステージ・ディレクトリで管理）
--
--   @DG_CATALOG.BRONZE.STG_FILES/
--   ├── landing/<YYYYMMDD>/       ← 原本ファイル（xlsx）
--   ├── parsed/<YYYYMMDD>/        ← UDF① で xlsx → CSV 化した中間ファイル
--   ├── structured/<YYYYMMDD>/    ← UDF② で構造化した CSV（COPY INTO のソース）
--   ├── extraction/<YYYYMMDD>/    ← AI 抽出結果（JSON）
--   └── archive/<YYYYMMDD>/       ← 処理済みファイルの退避先
-- ----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS DG_CATALOG.BRONZE.STG_FILES
    COMMENT = '区分値カタログ用ファイルステージ（ディレクトリで用途を分離）';
-- FILE_FORMAT はステージに紐づけない（landing は Python UDF でパース、
-- structured は COPY INTO 時に FORMAT_NAME で指定する）
