-- ============================================================================
-- データパイプライン (1/2): Stage → Bronze（ステージからの取り込み）
-- 対象: Snowflake
-- 前提: 01_bronze.sql（DDL）実行済み
-- 参照: docs/04-pipeline/00-overview.md
-- ============================================================================

-- ============================================================================
-- 1. ファイルアップロード例（SnowSQL / クライアントから実行）
--    ファイルフォーマット・ステージ定義は 03-schema-design/ddl/01_bronze.sql を参照
-- ============================================================================

-- 列名定義 CSV のアップロード
-- PUT file:///path/to/column_definitions.csv @DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES AUTO_COMPRESS=TRUE;

-- 区分値定義 CSV のアップロード
-- PUT file:///path/to/code_value_definitions.csv @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES AUTO_COMPRESS=TRUE;

-- AI 抽出結果 JSON のアップロード
-- PUT file:///path/to/extraction_results.json @DG_CATALOG.BRONZE.STG_EXTRACTION_JSON_FILES AUTO_COMPRESS=TRUE;

-- ステージ上のファイル確認
-- LIST @DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES;
-- LIST @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES;
-- LIST @DG_CATALOG.BRONZE.STG_EXTRACTION_JSON_FILES;


-- ============================================================================
-- 2. Stage → Bronze 取り込みプロシージャ（CSV: 列名定義）
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_COLUMN_DEF_FROM_STAGE(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_ROW_COUNT NUMBER;
BEGIN
    -- バッチレコード作成
    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '収集', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    -- 直前に採番された BATCH_ID を取得
    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '収集'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    -- ステージ上の CSV → Bronze テーブルへ COPY INTO
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
            TRY_PARSE_JSON($8),  -- RAW_CONTENT（JSON文字列→VARIANT）
            CURRENT_TIMESTAMP()
        FROM @DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES
    )
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_COLUMN_DEF_CSV')
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;

    -- 取り込み件数の確認
    SET V_ROW_COUNT = (
        SELECT COUNT(*)
        FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION
        WHERE BATCH_ID = :V_BATCH_ID
    );

    -- バッチ完了
    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '取り込み件数: ' || :V_ROW_COUNT::VARCHAR
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
-- 3. Stage → Bronze 取り込みプロシージャ（CSV: 区分値定義）
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_DEF_FROM_STAGE(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_ROW_COUNT NUMBER;
BEGIN
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

    -- ステージ上の CSV → Bronze テーブルへ COPY INTO
    COPY INTO DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
        BATCH_ID,
        SOURCE_TYPE,
        SOURCE_IDENTIFIER,
        SOURCE_LOCATION,
        SOURCE_VERSION,
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        CONTEXT_COLUMN_NAME_RAW,
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
            $7,   -- CONTEXT_COLUMN_NAME_RAW
            $8,   -- CONTEXT_VALUE_RAW
            $9,   -- CODE_VALUE
            $10,  -- CODE_LABEL_RAW
            $11,  -- CODE_DESCRIPTION_RAW
            TRY_PARSE_JSON($12),  -- RAW_CONTENT
            CURRENT_TIMESTAMP()
        FROM @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES
    )
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_CODE_VALUE_CSV')
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
        REMARKS = '取り込み件数: ' || :V_ROW_COUNT::VARCHAR
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
-- 4. Stage → Bronze 取り込みプロシージャ（JSON: AI 抽出結果）
--    ソースコード・画面定義からの AI 抽出結果を Bronze へ展開する
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_EXTRACTION_JSON_FROM_STAGE(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_COL_COUNT NUMBER;
    V_CODE_COUNT NUMBER;
BEGIN
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

    -- JSON をステージングテーブル（一時テーブル）に読み込み
    CREATE TEMPORARY TABLE IF NOT EXISTS DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON (
        RAW_DATA VARIANT
    );
    TRUNCATE TABLE DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON;

    COPY INTO DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON
    FROM @DG_CATALOG.BRONZE.STG_EXTRACTION_JSON_FILES
    FILE_FORMAT = (FORMAT_NAME = 'DG_CATALOG.BRONZE.FF_EXTRACTION_JSON')
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;

    -- JSON 内の列名定義（extraction_type = 'column'）を展開して Bronze へ INSERT
    INSERT INTO DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION (
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
    SELECT
        :V_BATCH_ID,
        j.RAW_DATA:source_type::VARCHAR,
        j.RAW_DATA:source_identifier::VARCHAR,
        e.VALUE:source_location::VARCHAR,
        j.RAW_DATA:source_version::VARCHAR,
        e.VALUE:table_physical_name::VARCHAR,
        e.VALUE:column_physical_name::VARCHAR,
        e.VALUE:column_logical_name_raw::VARCHAR,
        e.VALUE,   -- 抽出元の JSON 要素をそのまま VARIANT で保持
        CURRENT_TIMESTAMP()
    FROM DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON j,
         LATERAL FLATTEN(INPUT => j.RAW_DATA:extractions) e
    WHERE e.VALUE:extraction_type::VARCHAR = 'column';

    -- JSON 内の区分値定義（extraction_type = 'code_value'）を展開して Bronze へ INSERT
    INSERT INTO DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION (
        BATCH_ID,
        SOURCE_TYPE,
        SOURCE_IDENTIFIER,
        SOURCE_LOCATION,
        SOURCE_VERSION,
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        CONTEXT_COLUMN_NAME_RAW,
        CONTEXT_VALUE_RAW,
        CODE_VALUE,
        CODE_LABEL_RAW,
        CODE_DESCRIPTION_RAW,
        RAW_CONTENT,
        EXTRACTED_AT
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

    -- 件数集計
    SET V_COL_COUNT = (
        SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION
        WHERE BATCH_ID = :V_BATCH_ID
    );
    SET V_CODE_COUNT = (
        SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION
        WHERE BATCH_ID = :V_BATCH_ID
    );

    DROP TABLE IF EXISTS DG_CATALOG.BRONZE.TMP_EXTRACTION_JSON;

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '列名定義: ' || :V_COL_COUNT::VARCHAR || '件, 区分値定義: ' || :V_CODE_COUNT::VARCHAR || '件'
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN 'AI抽出結果の取り込み完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR
        || ', 列名=' || :V_COL_COUNT::VARCHAR || '件'
        || ', 区分値=' || :V_CODE_COUNT::VARCHAR || '件';

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
-- 5. 一括実行プロシージャ（全ステージの取り込みをまとめて実行）
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.BRONZE.SP_LOAD_ALL_FROM_STAGE(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_RESULT_COL VARCHAR;
    V_RESULT_CODE VARCHAR;
    V_RESULT_JSON VARCHAR;
BEGIN
    CALL DG_CATALOG.BRONZE.SP_LOAD_COLUMN_DEF_FROM_STAGE(:P_SOURCE_SYSTEM_ID)
        INTO V_RESULT_COL;
    CALL DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_DEF_FROM_STAGE(:P_SOURCE_SYSTEM_ID)
        INTO V_RESULT_CODE;
    CALL DG_CATALOG.BRONZE.SP_LOAD_EXTRACTION_JSON_FROM_STAGE(:P_SOURCE_SYSTEM_ID)
        INTO V_RESULT_JSON;

    RETURN V_RESULT_COL || ' | ' || V_RESULT_CODE || ' | ' || V_RESULT_JSON;
END;
$$;


-- ============================================================================
-- 6. 実行例
-- ============================================================================

-- (1) 事前準備: 収集対象システムの登録
-- INSERT INTO DG_CATALOG.META.SOURCE_SYSTEM (SOURCE_SYSTEM_NAME, REPOSITORY_URL, OWNER)
-- VALUES ('画面あり業務システムA', 'https://git.example.com/system-a', '業務部門X');

-- (2) ファイルアップロード（SnowSQL）
-- PUT file:///data/extracts/column_defs_20260723.csv @DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES;
-- PUT file:///data/extracts/code_value_defs_20260723.csv @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES;
-- PUT file:///data/extracts/ai_extraction_20260723.json @DG_CATALOG.BRONZE.STG_EXTRACTION_JSON_FILES;

-- (3) 取り込み実行（個別）
-- CALL DG_CATALOG.BRONZE.SP_LOAD_COLUMN_DEF_FROM_STAGE(1);
-- CALL DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_DEF_FROM_STAGE(1);
-- CALL DG_CATALOG.BRONZE.SP_LOAD_EXTRACTION_JSON_FROM_STAGE(1);

-- (4) 取り込み実行（一括）
-- CALL DG_CATALOG.BRONZE.SP_LOAD_ALL_FROM_STAGE(1);

-- (5) 取り込み結果の確認
-- SELECT * FROM DG_CATALOG.META.COLLECTION_BATCH ORDER BY BATCH_ID DESC LIMIT 5;
-- SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION WHERE BATCH_ID = <対象BATCH_ID>;
-- SELECT COUNT(*) FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION WHERE BATCH_ID = <対象BATCH_ID>;
