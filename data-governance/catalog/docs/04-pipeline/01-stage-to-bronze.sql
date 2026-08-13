-- ============================================================================
-- データパイプライン (1/2): Stage → Bronze（ステージからの取り込み）
-- 対象: Snowflake
-- 前提: 01_bronze.sql（DDL）実行済み
-- 参照: docs/04-pipeline/00-overview.md
--
-- 処理フロー:
--   xlsx (landing/) → UDF①(Python) → parsed/<YYYYMMDD>/<シート名>.csv
--                                         ↓
--                     UDF②(Python) → structured/<YYYYMMDD>/<シート名>.csv
--                                         ↓
--                     SP（本ファイル） → Bronze テーブル（COPY INTO）
--
--   UDF①②は Python（openpyxl）で実装済み（別管理）。
--   本ファイルは structured CSV → Bronze の COPY INTO プロシージャを定義する。
-- ============================================================================


-- ============================================================================
-- 1. ファイルアップロード例
--    ステージ・ファイルフォーマット定義は 03-schema-design/ddl/01_bronze.sql を参照
-- ============================================================================

-- 原本 xlsx のアップロード（landing/ ディレクトリ配下）
-- PUT file:///data/code_master_v2.xlsx @DG_CATALOG.BRONZE.STG_FILES/landing/20260726/ AUTO_COMPRESS=FALSE;

-- ステージ上のファイル確認
-- LIST @DG_CATALOG.BRONZE.STG_FILES/landing/;
-- LIST @DG_CATALOG.BRONZE.STG_FILES/parsed/;
-- LIST @DG_CATALOG.BRONZE.STG_FILES/structured/;


-- ============================================================================
-- 2. structured CSV → Bronze 取り込みプロシージャ（区分値定義）
--    UDF② が出力した structured/<YYYYMMDD>/<シート名>.csv を
--    RAW_CODE_VALUE_DEFINITION へ COPY INTO する。
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_FROM_STRUCTURED(
    P_SOURCE_SYSTEM_ID  NUMBER,
    P_DATE_DIR          VARCHAR DEFAULT NULL  -- 対象日付ディレクトリ（例: '20260726'）。NULL なら全件
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_ROW_COUNT NUMBER;
    V_PATH VARCHAR;
BEGIN
    -- パス組み立て
    SET V_PATH = CASE
        WHEN :P_DATE_DIR IS NOT NULL THEN 'structured/' || :P_DATE_DIR || '/'
        ELSE 'structured/'
    END;

    -- バッチレコード作成
    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '収集', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '収集'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    -- structured CSV → Bronze テーブルへ COPY INTO
    -- structured CSV のヘッダ列順:
    --   SOURCE_TYPE, SOURCE_IDENTIFIER, SOURCE_LOCATION, SOURCE_VERSION,
    --   TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME,
    --   CONTEXT_NAME_RAW, CONTEXT_VALUE_RAW,
    --   CODE_VALUE, CODE_LABEL_RAW, CODE_DESCRIPTION_RAW, RAW_CONTENT
    COPY INTO DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
        BATCH_ID,
        SOURCE_TYPE,
        SOURCE_IDENTIFIER,
        SOURCE_LOCATION,
        SOURCE_VERSION,
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        CONTEXT_NAME_RAW,
        CONTEXT_VALUE_RAW,
        CODE_VALUE,
        CODE_LABEL_RAW,
        CODE_DESCRIPTION_RAW,
        RAW_CONTENT,
        EXTRACTED_AT
    )
    FROM (
        SELECT
            :V_BATCH_ID,
            $1,   -- SOURCE_TYPE
            $2,   -- SOURCE_IDENTIFIER
            $3,   -- SOURCE_LOCATION
            $4,   -- SOURCE_VERSION
            $5,   -- TABLE_PHYSICAL_NAME
            $6,   -- COLUMN_PHYSICAL_NAME
            $7,   -- CONTEXT_NAME_RAW
            $8,   -- CONTEXT_VALUE_RAW
            $9,   -- CODE_VALUE
            $10,  -- CODE_LABEL_RAW
            $11,  -- CODE_DESCRIPTION_RAW
            TRY_PARSE_JSON($12),  -- RAW_CONTENT
            CURRENT_TIMESTAMP()
        FROM @DG_CATALOG.BRONZE.STG_FILES/
    )
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_STRUCTURED_CSV')
    PATTERN = :V_PATH || '.*\\.csv'
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;

    SET V_ROW_COUNT = (
        SELECT COUNT(*)
        FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION
        WHERE BATCH_ID = :V_BATCH_ID
    );

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '区分値定義 取り込み件数: ' || :V_ROW_COUNT::VARCHAR
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN '区分値定義の取り込み完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR || ', 件数=' || :V_ROW_COUNT::VARCHAR;

EXCEPTION
    WHEN OTHER THEN
        UPDATE DG_CATALOG.META.COLLECTION_BATCH
        SET COMPLETED_AT = CURRENT_TIMESTAMP(),
            STATUS = '失敗',
            REMARKS = SQLERRM
        WHERE BATCH_ID = :V_BATCH_ID;
        RAISE;
END;
$$;


-- ============================================================================
-- 3. structured CSV → Bronze 取り込みプロシージャ（列名定義）
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_COLUMN_DEF_FROM_STRUCTURED(
    P_SOURCE_SYSTEM_ID  NUMBER,
    P_DATE_DIR          VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_ROW_COUNT NUMBER;
    V_PATH VARCHAR;
BEGIN
    SET V_PATH = CASE
        WHEN :P_DATE_DIR IS NOT NULL THEN 'structured/' || :P_DATE_DIR || '/'
        ELSE 'structured/'
    END;

    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '収集', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '収集'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    -- structured CSV のヘッダ列順:
    --   SOURCE_TYPE, SOURCE_IDENTIFIER, SOURCE_LOCATION, SOURCE_VERSION,
    --   TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME,
    --   COLUMN_LOGICAL_NAME_RAW, RAW_CONTENT
    COPY INTO DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION (
        BATCH_ID,
        SOURCE_TYPE,
        SOURCE_IDENTIFIER,
        SOURCE_LOCATION,
        SOURCE_VERSION,
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        COLUMN_LOGICAL_NAME_RAW,
        RAW_CONTENT,
        EXTRACTED_AT
    )
    FROM (
        SELECT
            :V_BATCH_ID,
            $1,   -- SOURCE_TYPE
            $2,   -- SOURCE_IDENTIFIER
            $3,   -- SOURCE_LOCATION
            $4,   -- SOURCE_VERSION
            $5,   -- TABLE_PHYSICAL_NAME
            $6,   -- COLUMN_PHYSICAL_NAME
            $7,   -- COLUMN_LOGICAL_NAME_RAW
            TRY_PARSE_JSON($8),  -- RAW_CONTENT
            CURRENT_TIMESTAMP()
        FROM @DG_CATALOG.BRONZE.STG_FILES/
    )
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_STRUCTURED_CSV')
    PATTERN = :V_PATH || '.*\\.csv'
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;

    SET V_ROW_COUNT = (
        SELECT COUNT(*)
        FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION
        WHERE BATCH_ID = :V_BATCH_ID
    );

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '列名定義 取り込み件数: ' || :V_ROW_COUNT::VARCHAR
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN '列名定義の取り込み完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR || ', 件数=' || :V_ROW_COUNT::VARCHAR;

EXCEPTION
    WHEN OTHER THEN
        UPDATE DG_CATALOG.META.COLLECTION_BATCH
        SET COMPLETED_AT = CURRENT_TIMESTAMP(),
            STATUS = '失敗',
            REMARKS = SQLERRM
        WHERE BATCH_ID = :V_BATCH_ID;
        RAISE;
END;
$$;


-- ============================================================================
-- 4. structured CSV → Bronze 取り込みプロシージャ（JSON: AI 抽出結果）
--    extraction/ ディレクトリの JSON を Bronze へ展開する
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_EXTRACTION_JSON(
    P_SOURCE_SYSTEM_ID  NUMBER,
    P_DATE_DIR          VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_COL_COUNT NUMBER;
    V_CODE_COUNT NUMBER;
    V_PATH VARCHAR;
BEGIN
    SET V_PATH = CASE
        WHEN :P_DATE_DIR IS NOT NULL THEN 'extraction/' || :P_DATE_DIR || '/'
        ELSE 'extraction/'
    END;

    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '収集', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '収集'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    CREATE TEMPORARY TABLE IF NOT EXISTS DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON (
        RAW_DATA VARIANT
    );
    TRUNCATE TABLE DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON;

    COPY INTO DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON
    FROM @DG_CATALOG.BRONZE.STG_FILES/
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_EXTRACTION_JSON')
    PATTERN = :V_PATH || '.*\\.json'
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;

    INSERT INTO DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION (
        BATCH_ID, SOURCE_TYPE, SOURCE_IDENTIFIER, SOURCE_LOCATION, SOURCE_VERSION,
        TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME, COLUMN_LOGICAL_NAME_RAW,
        RAW_CONTENT, EXTRACTED_AT
    )
    SELECT
        :V_BATCH_ID,
        j.RAW_DATA:source_type::VARCHAR,
        j.RAW_DATA:source_identifier::VARCHAR,
        e.VALUE:source_location::VARCHAR,
        j.RAW_DATA:source_version::VARCHAR,
        e.VALUE:table_physical_name::VARCHAR,
        e.VALUE:column_physical_name::VARCHAR,
        e.VALUE:column_logical_name_raw::VARCHAR,
        e.VALUE,
        CURRENT_TIMESTAMP()
    FROM DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON j,
         LATERAL FLATTEN(INPUT => j.RAW_DATA:extractions) e
    WHERE e.VALUE:extraction_type::VARCHAR = 'column';

    INSERT INTO DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
        BATCH_ID, SOURCE_TYPE, SOURCE_IDENTIFIER, SOURCE_LOCATION, SOURCE_VERSION,
        TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME,
        CONTEXT_NAME_RAW, CONTEXT_VALUE_RAW,
        CODE_VALUE, CODE_LABEL_RAW, CODE_DESCRIPTION_RAW,
        RAW_CONTENT, EXTRACTED_AT
    )
    SELECT
        :V_BATCH_ID,
        j.RAW_DATA:source_type::VARCHAR,
        j.RAW_DATA:source_identifier::VARCHAR,
        e.VALUE:source_location::VARCHAR,
        j.RAW_DATA:source_version::VARCHAR,
        e.VALUE:table_physical_name::VARCHAR,
        e.VALUE:column_physical_name::VARCHAR,
        e.VALUE:context_column_name_raw::VARCHAR,
        e.VALUE:context_value_raw::VARCHAR,
        e.VALUE:code_value::VARCHAR,
        e.VALUE:code_label_raw::VARCHAR,
        e.VALUE:code_description_raw::VARCHAR,
        e.VALUE,
        CURRENT_TIMESTAMP()
    FROM DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON j,
         LATERAL FLATTEN(INPUT => j.RAW_DATA:extractions) e
    WHERE e.VALUE:extraction_type::VARCHAR = 'code_value';

    SET V_COL_COUNT = (
        SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION WHERE BATCH_ID = :V_BATCH_ID
    );
    SET V_CODE_COUNT = (
        SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION WHERE BATCH_ID = :V_BATCH_ID
    );

    DROP TABLE IF EXISTS DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON;

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '列名: ' || :V_COL_COUNT::VARCHAR || '件, 区分値: ' || :V_CODE_COUNT::VARCHAR || '件'
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN 'AI抽出結果の取り込み完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR
        || ', 列名=' || :V_COL_COUNT::VARCHAR || '件, 区分値=' || :V_CODE_COUNT::VARCHAR || '件';

EXCEPTION
    WHEN OTHER THEN
        DROP TABLE IF EXISTS DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON;
        UPDATE DG_CATALOG.META.COLLECTION_BATCH
        SET COMPLETED_AT = CURRENT_TIMESTAMP(),
            STATUS = '失敗',
            REMARKS = SQLERRM
        WHERE BATCH_ID = :V_BATCH_ID;
        RAISE;
END;
$$;


-- ============================================================================
-- 5. 実行例
-- ============================================================================

-- ========================================
-- 全体フロー（Excel → parsed → structured → Bronze）
-- ========================================

-- (1) 事前準備: 収集対象システムの登録
-- INSERT INTO DG_CATALOG.META.SOURCE_SYSTEM (SOURCE_SYSTEM_NAME, OWNER)
-- VALUES ('画面あり業務システムA', '業務部門X');

-- (2) 抽出対象シートの登録（目次シートから取得した内容を登録）
-- INSERT INTO DG_CATALOG.META.SOURCE_SHEET
--     (SOURCE_SYSTEM_ID, FILE_NAME, SHEET_NAME, TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME, SHEET_TYPE)
-- VALUES
--     (1, 'code_master_v2.xlsx', '請求ステータス', 'T_CLAIM', 'clm_stat_cd', '区分値一覧'),
--     (1, 'code_master_v2.xlsx', '商品区分',       'T_CLAIM', 'product_type_cd', '区分値一覧');

-- (3) 原本 xlsx のアップロード
-- PUT file:///data/code_master_v2.xlsx @DG_CATALOG.BRONZE.STG_FILES/landing/20260726/ AUTO_COMPRESS=FALSE;

-- (4) UDF①: xlsx → parsed CSV（Python UDF。別管理）
--     META.SOURCE_SHEET と突合し、対象シートを parsed/ へ出力
--     → @DG_CATALOG.BRONZE.STG_FILES/parsed/20260726/請求ステータス.csv
--     → @DG_CATALOG.BRONZE.STG_FILES/parsed/20260726/商品区分.csv

-- (5) UDF②: parsed CSV → structured CSV（Python UDF。別管理）
--     parsed CSV を読み取り、Bronze 構造にマッピングした CSV を出力
--     → @DG_CATALOG.BRONZE.STG_FILES/structured/20260726/請求ステータス.csv
--     → @DG_CATALOG.BRONZE.STG_FILES/structured/20260726/商品区分.csv

-- (6) structured CSV → Bronze（本ファイルの SP）
-- CALL DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_FROM_STRUCTURED(1, '20260726');

-- (7) 確認
-- LIST @DG_CATALOG.BRONZE.STG_FILES/parsed/20260726/;
-- LIST @DG_CATALOG.BRONZE.STG_FILES/structured/20260726/;
-- SELECT * FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION ORDER BY RAW_ID DESC LIMIT 20;
-- SELECT * FROM DG_CATALOG.META.COLLECTION_BATCH ORDER BY BATCH_ID DESC LIMIT 5;
