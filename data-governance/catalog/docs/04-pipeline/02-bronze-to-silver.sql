-- ============================================================================
-- データパイプライン (2/2): Bronze → Silver（名寄せ・正規化・競合検知）
-- 対象: Snowflake
-- 前提: 01_bronze.sql, 02_silver.sql（DDL）実行済み、Bronze層にデータ投入済み
-- 参照: docs/04-pipeline/00-overview.md
--       docs/02-data-transformation/01-conversion-policy.md（名寄せルール）
-- ============================================================================


-- ============================================================================
-- 1. 正規化用 UDF（表記揺れの吸収）
--    名寄せ時の一致判定の前に、値を正規化する
-- ============================================================================

CREATE OR REPLACE FUNCTION DG_CATALOG.SILVER.UDF_NORMALIZE_LABEL(P_VALUE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    -- 全角英数字 → 半角は TRANSLATE で主要なものをカバー
    -- 前後空白の除去、連続空白の圧縮、末尾の定型サフィックス除去
    TRIM(
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    TRANSLATE(
                        P_VALUE,
                        'ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ０１２３４５６７８９（）　',
                        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789() '
                    ),
                    '\\s+', ' '        -- 連続空白を1つに圧縮
                ),
                '(区分|コード|CD|cd|等)$', ''  -- 末尾の定型サフィックスを除去
            ),
            '\\s+$', ''  -- サフィックス除去後の末尾空白を再除去
        )
    )
$$;


-- ============================================================================
-- 2. ソース種別 → 優先度の変換 UDF
--    変換方針 2章の優先順位に対応
-- ============================================================================

CREATE OR REPLACE FUNCTION DG_CATALOG.SILVER.UDF_SOURCE_PRIORITY(P_SOURCE_TYPE VARCHAR)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
    CASE
        WHEN P_SOURCE_TYPE IN ('設計書', 'コードマスタ(Excel)') THEN 1  -- 最優先
        WHEN P_SOURCE_TYPE = '画面定義' THEN 2
        WHEN P_SOURCE_TYPE = 'ソースコード' THEN 3
        ELSE 99
    END
$$;


-- ============================================================================
-- 3. Bronze → Silver: 列名定義の名寄せプロシージャ
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.SILVER.SP_MATCH_COLUMN_DEFINITIONS(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_MERGED_COUNT NUMBER;
BEGIN
    -- 名寄せバッチレコード作成
    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '名寄せ', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '名寄せ'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    -- Silver へ MERGE（テーブル物理名 + 列物理名を名寄せ単位とする）
    MERGE INTO DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE AS tgt
    USING (
        -- Bronze から名寄せ単位ごとに集約する CTE
        WITH raw_with_priority AS (
            SELECT
                r.RAW_ID,
                r.TABLE_PHYSICAL_NAME,
                r.COLUMN_PHYSICAL_NAME,
                r.COLUMN_LOGICAL_NAME_RAW,
                r.SOURCE_TYPE,
                DG_CATALOG.SILVER.UDF_SOURCE_PRIORITY(r.SOURCE_TYPE) AS PRIORITY,
                DG_CATALOG.SILVER.UDF_NORMALIZE_LABEL(r.COLUMN_LOGICAL_NAME_RAW) AS NORMALIZED_NAME,
                r.SOURCE_IDENTIFIER
            FROM DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION r
            WHERE r.COLUMN_LOGICAL_NAME_RAW IS NOT NULL
        ),
        grouped AS (
            SELECT
                TABLE_PHYSICAL_NAME,
                COLUMN_PHYSICAL_NAME,
                -- ソース数
                COUNT(DISTINCT RAW_ID) AS SOURCE_COUNT,
                -- 正規化後のユニークな値の数
                COUNT(DISTINCT NORMALIZED_NAME) AS DISTINCT_NORMALIZED_COUNT,
                -- 最優先ソースの値を採用候補とする
                -- （同一優先度内で複数の異なる値がある場合も最初の1つを暫定採用）
                ARRAY_AGG(RAW_ID) AS RAW_ID_LIST,
                -- 候補値の詳細（レビュー用）
                ARRAY_AGG(
                    OBJECT_CONSTRUCT(
                        'raw_id', RAW_ID,
                        'source_type', SOURCE_TYPE,
                        'priority', PRIORITY,
                        'original_value', COLUMN_LOGICAL_NAME_RAW,
                        'normalized_value', NORMALIZED_NAME,
                        'source_identifier', SOURCE_IDENTIFIER
                    )
                ) AS CANDIDATE_DETAIL
            FROM raw_with_priority
            GROUP BY TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME
        ),
        -- 最優先の値を取得
        best_candidate AS (
            SELECT
                g.TABLE_PHYSICAL_NAME,
                g.COLUMN_PHYSICAL_NAME,
                g.SOURCE_COUNT,
                g.DISTINCT_NORMALIZED_COUNT,
                g.RAW_ID_LIST,
                g.CANDIDATE_DETAIL,
                -- 最も優先度が高いソースの論理名を採用
                (
                    SELECT rp.COLUMN_LOGICAL_NAME_RAW
                    FROM raw_with_priority rp
                    WHERE rp.TABLE_PHYSICAL_NAME = g.TABLE_PHYSICAL_NAME
                      AND rp.COLUMN_PHYSICAL_NAME = g.COLUMN_PHYSICAL_NAME
                    ORDER BY rp.PRIORITY ASC
                    LIMIT 1
                ) AS BEST_LOGICAL_NAME
            FROM grouped g
        )
        SELECT
            TABLE_PHYSICAL_NAME,
            COLUMN_PHYSICAL_NAME,
            BEST_LOGICAL_NAME,
            -- 正規化後の値が2種以上 → 競合
            IFF(DISTINCT_NORMALIZED_COUNT > 1, TRUE, FALSE) AS CONFLICT_FLAG,
            -- ソースが1件のみ → 要確認
            IFF(SOURCE_COUNT = 1, TRUE, FALSE) AS NEEDS_REVIEW_FLAG,
            CANDIDATE_DETAIL AS CANDIDATE_VALUES,
            RAW_ID_LIST AS SOURCE_RAW_IDS
        FROM best_candidate
    ) AS src
    ON  tgt.TABLE_PHYSICAL_NAME  = src.TABLE_PHYSICAL_NAME
    AND tgt.COLUMN_PHYSICAL_NAME = src.COLUMN_PHYSICAL_NAME
    WHEN MATCHED THEN UPDATE SET
        tgt.COLUMN_LOGICAL_NAME_CANDIDATE = src.BEST_LOGICAL_NAME,
        tgt.CONFLICT_FLAG                 = src.CONFLICT_FLAG,
        tgt.NEEDS_REVIEW_FLAG             = src.NEEDS_REVIEW_FLAG,
        tgt.CANDIDATE_VALUES              = src.CANDIDATE_VALUES,
        tgt.SOURCE_RAW_IDS                = src.SOURCE_RAW_IDS,
        tgt.MATCHING_BATCH_ID             = :V_BATCH_ID,
        tgt.UPDATED_AT                    = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        COLUMN_LOGICAL_NAME_CANDIDATE,
        CONFLICT_FLAG,
        NEEDS_REVIEW_FLAG,
        CANDIDATE_VALUES,
        SOURCE_RAW_IDS,
        MATCHING_BATCH_ID,
        UPDATED_AT
    ) VALUES (
        src.TABLE_PHYSICAL_NAME,
        src.COLUMN_PHYSICAL_NAME,
        src.BEST_LOGICAL_NAME,
        src.CONFLICT_FLAG,
        src.NEEDS_REVIEW_FLAG,
        src.CANDIDATE_VALUES,
        src.SOURCE_RAW_IDS,
        :V_BATCH_ID,
        CURRENT_TIMESTAMP()
    );

    SET V_MERGED_COUNT = (
        SELECT COUNT(*)
        FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE
        WHERE MATCHING_BATCH_ID = :V_BATCH_ID
    );

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '名寄せ結果: ' || :V_MERGED_COUNT::VARCHAR || '件'
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN '列名定義の名寄せ完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR || ', 件数=' || :V_MERGED_COUNT::VARCHAR;

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
-- 4. Bronze → Silver: 区分値定義の名寄せプロシージャ
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.SILVER.SP_MATCH_CODE_VALUE_DEFINITIONS(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_BATCH_ID NUMBER;
    V_MERGED_COUNT NUMBER;
BEGIN
    INSERT INTO DG_CATALOG.META.COLLECTION_BATCH (
        BATCH_TYPE, SOURCE_SYSTEM_ID, STARTED_AT, STATUS
    ) VALUES (
        '名寄せ', :P_SOURCE_SYSTEM_ID, CURRENT_TIMESTAMP(), '実行中'
    );

    SET V_BATCH_ID = (
        SELECT MAX(BATCH_ID)
        FROM DG_CATALOG.META.COLLECTION_BATCH
        WHERE BATCH_TYPE = '名寄せ'
          AND SOURCE_SYSTEM_ID = :P_SOURCE_SYSTEM_ID
    );

    MERGE INTO DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE AS tgt
    USING (
        WITH raw_with_priority AS (
            SELECT
                r.RAW_ID,
                r.TABLE_PHYSICAL_NAME,
                r.COLUMN_PHYSICAL_NAME,
                -- 判別列の正規化（NULLはNULLのまま保持 = 共通扱い）
                TRIM(r.CONTEXT_NAME_RAW) AS CONTEXT_NAME,
                TRIM(r.CONTEXT_VALUE_RAW) AS CONTEXT_VALUE,
                r.CODE_VALUE,
                r.CODE_LABEL_RAW,
                r.CODE_DESCRIPTION_RAW,
                r.SOURCE_TYPE,
                DG_CATALOG.SILVER.UDF_SOURCE_PRIORITY(r.SOURCE_TYPE) AS PRIORITY,
                DG_CATALOG.SILVER.UDF_NORMALIZE_LABEL(r.CODE_LABEL_RAW) AS NORMALIZED_LABEL,
                r.SOURCE_IDENTIFIER
            FROM DG_CATALOG.BRONZE.RAW_CODE_VALUE_DEFINITION r
        ),
        -- 名寄せ単位: テーブル + 列 + 判別列 + 判別値 + コード値
        grouped AS (
            SELECT
                TABLE_PHYSICAL_NAME,
                COLUMN_PHYSICAL_NAME,
                CONTEXT_NAME,
                CONTEXT_VALUE,
                CODE_VALUE,
                COUNT(DISTINCT RAW_ID) AS SOURCE_COUNT,
                COUNT(DISTINCT NORMALIZED_LABEL) AS DISTINCT_NORMALIZED_COUNT,
                ARRAY_AGG(RAW_ID) AS RAW_ID_LIST,
                ARRAY_AGG(
                    OBJECT_CONSTRUCT(
                        'raw_id', RAW_ID,
                        'source_type', SOURCE_TYPE,
                        'priority', PRIORITY,
                        'original_label', CODE_LABEL_RAW,
                        'normalized_label', NORMALIZED_LABEL,
                        'description', CODE_DESCRIPTION_RAW,
                        'source_identifier', SOURCE_IDENTIFIER
                    )
                ) AS CANDIDATE_DETAIL
            FROM raw_with_priority
            GROUP BY
                TABLE_PHYSICAL_NAME,
                COLUMN_PHYSICAL_NAME,
                CONTEXT_NAME,
                CONTEXT_VALUE,
                CODE_VALUE
        ),
        best_candidate AS (
            SELECT
                g.*,
                -- 最も優先度が高いソースの表示ラベルを採用
                (
                    SELECT rp.CODE_LABEL_RAW
                    FROM raw_with_priority rp
                    WHERE rp.TABLE_PHYSICAL_NAME  = g.TABLE_PHYSICAL_NAME
                      AND rp.COLUMN_PHYSICAL_NAME = g.COLUMN_PHYSICAL_NAME
                      AND NVL(rp.CONTEXT_NAME, '___NULL___') = NVL(g.CONTEXT_NAME, '___NULL___')
                      AND NVL(rp.CONTEXT_VALUE, '___NULL___')       = NVL(g.CONTEXT_VALUE, '___NULL___')
                      AND rp.CODE_VALUE           = g.CODE_VALUE
                    ORDER BY rp.PRIORITY ASC
                    LIMIT 1
                ) AS BEST_LABEL,
                (
                    SELECT rp.CODE_DESCRIPTION_RAW
                    FROM raw_with_priority rp
                    WHERE rp.TABLE_PHYSICAL_NAME  = g.TABLE_PHYSICAL_NAME
                      AND rp.COLUMN_PHYSICAL_NAME = g.COLUMN_PHYSICAL_NAME
                      AND NVL(rp.CONTEXT_NAME, '___NULL___') = NVL(g.CONTEXT_NAME, '___NULL___')
                      AND NVL(rp.CONTEXT_VALUE, '___NULL___')       = NVL(g.CONTEXT_VALUE, '___NULL___')
                      AND rp.CODE_VALUE           = g.CODE_VALUE
                    ORDER BY rp.PRIORITY ASC
                    LIMIT 1
                ) AS BEST_DESCRIPTION
            FROM grouped g
        ),
        -- 判別列の後発見検知:
        -- 同一テーブル・列で CONTEXT_NAME IS NULL（共通）と
        -- CONTEXT_NAME IS NOT NULL（コンテキスト付き）が共存する場合、
        -- 共通側に NEEDS_REVIEW_FLAG を強制的に立てる
        context_detection AS (
            SELECT DISTINCT
                TABLE_PHYSICAL_NAME,
                COLUMN_PHYSICAL_NAME
            FROM best_candidate
            WHERE CONTEXT_NAME IS NOT NULL
        )
        SELECT
            bc.TABLE_PHYSICAL_NAME,
            bc.COLUMN_PHYSICAL_NAME,
            bc.CONTEXT_NAME,
            bc.CONTEXT_VALUE,
            bc.CODE_VALUE,
            bc.BEST_LABEL,
            bc.BEST_DESCRIPTION,
            IFF(bc.DISTINCT_NORMALIZED_COUNT > 1, TRUE, FALSE) AS CONFLICT_FLAG,
            -- 要確認: ソース1件のみ、または判別列の後発見による共通レコードの不正確化
            IFF(
                bc.SOURCE_COUNT = 1
                OR (bc.CONTEXT_NAME IS NULL AND cd.TABLE_PHYSICAL_NAME IS NOT NULL),
                TRUE,
                FALSE
            ) AS NEEDS_REVIEW_FLAG,
            bc.CANDIDATE_DETAIL AS CANDIDATE_VALUES,
            bc.RAW_ID_LIST AS SOURCE_RAW_IDS
        FROM best_candidate bc
        LEFT JOIN context_detection cd
            ON  cd.TABLE_PHYSICAL_NAME  = bc.TABLE_PHYSICAL_NAME
            AND cd.COLUMN_PHYSICAL_NAME = bc.COLUMN_PHYSICAL_NAME
    ) AS src
    ON  tgt.TABLE_PHYSICAL_NAME  = src.TABLE_PHYSICAL_NAME
    AND tgt.COLUMN_PHYSICAL_NAME = src.COLUMN_PHYSICAL_NAME
    AND NVL(tgt.CONTEXT_NAME, '___NULL___') = NVL(src.CONTEXT_NAME, '___NULL___')
    AND NVL(tgt.CONTEXT_VALUE, '___NULL___')       = NVL(src.CONTEXT_VALUE, '___NULL___')
    AND tgt.CODE_VALUE           = src.CODE_VALUE
    WHEN MATCHED THEN UPDATE SET
        tgt.CODE_LABEL_CANDIDATE       = src.BEST_LABEL,
        tgt.CODE_DESCRIPTION_CANDIDATE = src.BEST_DESCRIPTION,
        tgt.CONFLICT_FLAG              = src.CONFLICT_FLAG,
        tgt.NEEDS_REVIEW_FLAG          = src.NEEDS_REVIEW_FLAG,
        tgt.CANDIDATE_VALUES           = src.CANDIDATE_VALUES,
        tgt.SOURCE_RAW_IDS             = src.SOURCE_RAW_IDS,
        tgt.MATCHING_BATCH_ID          = :V_BATCH_ID,
        tgt.UPDATED_AT                 = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        TABLE_PHYSICAL_NAME,
        COLUMN_PHYSICAL_NAME,
        CONTEXT_NAME,
        CONTEXT_VALUE,
        CODE_VALUE,
        CODE_LABEL_CANDIDATE,
        CODE_DESCRIPTION_CANDIDATE,
        CONFLICT_FLAG,
        NEEDS_REVIEW_FLAG,
        CANDIDATE_VALUES,
        SOURCE_RAW_IDS,
        MATCHING_BATCH_ID,
        UPDATED_AT
    ) VALUES (
        src.TABLE_PHYSICAL_NAME,
        src.COLUMN_PHYSICAL_NAME,
        src.CONTEXT_NAME,
        src.CONTEXT_VALUE,
        src.CODE_VALUE,
        src.BEST_LABEL,
        src.BEST_DESCRIPTION,
        src.CONFLICT_FLAG,
        src.NEEDS_REVIEW_FLAG,
        src.CANDIDATE_VALUES,
        src.SOURCE_RAW_IDS,
        :V_BATCH_ID,
        CURRENT_TIMESTAMP()
    );

    SET V_MERGED_COUNT = (
        SELECT COUNT(*)
        FROM DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE
        WHERE MATCHING_BATCH_ID = :V_BATCH_ID
    );

    UPDATE DG_CATALOG.META.COLLECTION_BATCH
    SET COMPLETED_AT = CURRENT_TIMESTAMP(),
        STATUS = '成功',
        REMARKS = '名寄せ結果: ' || :V_MERGED_COUNT::VARCHAR || '件'
    WHERE BATCH_ID = :V_BATCH_ID;

    RETURN '区分値定義の名寄せ完了。BATCH_ID=' || :V_BATCH_ID::VARCHAR || ', 件数=' || :V_MERGED_COUNT::VARCHAR;

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
-- 5. Bronze → Silver 一括実行プロシージャ
-- ============================================================================

CREATE OR REPLACE PROCEDURE DG_CATALOG.SILVER.SP_MATCH_ALL(
    P_SOURCE_SYSTEM_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_RESULT_COL VARCHAR;
    V_RESULT_CODE VARCHAR;
BEGIN
    CALL DG_CATALOG.SILVER.SP_MATCH_COLUMN_DEFINITIONS(:P_SOURCE_SYSTEM_ID)
        INTO V_RESULT_COL;
    CALL DG_CATALOG.SILVER.SP_MATCH_CODE_VALUE_DEFINITIONS(:P_SOURCE_SYSTEM_ID)
        INTO V_RESULT_CODE;

    RETURN V_RESULT_COL || ' | ' || V_RESULT_CODE;
END;
$$;


-- ============================================================================
-- 6. 名寄せ結果の確認クエリ（レビュー用）
-- ============================================================================

-- 6.1 列名定義: 競合・要確認レコードの一覧
-- SELECT
--     STG_ID,
--     TABLE_PHYSICAL_NAME,
--     COLUMN_PHYSICAL_NAME,
--     COLUMN_LOGICAL_NAME_CANDIDATE,
--     CONFLICT_FLAG,
--     NEEDS_REVIEW_FLAG,
--     CANDIDATE_VALUES
-- FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE
-- WHERE CONFLICT_FLAG = TRUE OR NEEDS_REVIEW_FLAG = TRUE
-- ORDER BY TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME;

-- 6.2 区分値定義: 競合・要確認レコードの一覧
-- SELECT
--     STG_ID,
--     TABLE_PHYSICAL_NAME,
--     COLUMN_PHYSICAL_NAME,
--     CONTEXT_NAME,
--     CONTEXT_VALUE,
--     CODE_VALUE,
--     CODE_LABEL_CANDIDATE,
--     CONFLICT_FLAG,
--     NEEDS_REVIEW_FLAG,
--     CANDIDATE_VALUES
-- FROM DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE
-- WHERE CONFLICT_FLAG = TRUE OR NEEDS_REVIEW_FLAG = TRUE
-- ORDER BY TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME, CODE_VALUE;

-- 6.3 名寄せサマリ（テーブル単位の集計）
-- SELECT
--     TABLE_PHYSICAL_NAME,
--     COUNT(*) AS TOTAL_COLUMNS,
--     SUM(IFF(CONFLICT_FLAG, 1, 0)) AS CONFLICT_COUNT,
--     SUM(IFF(NEEDS_REVIEW_FLAG, 1, 0)) AS REVIEW_NEEDED_COUNT,
--     SUM(IFF(NOT CONFLICT_FLAG AND NOT NEEDS_REVIEW_FLAG, 1, 0)) AS AUTO_PROMOTE_READY
-- FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE
-- GROUP BY TABLE_PHYSICAL_NAME
-- ORDER BY TABLE_PHYSICAL_NAME;

-- 6.4 トレーサビリティ確認（Silver → Bronze の出典追跡）
-- SELECT
--     s.STG_ID,
--     s.TABLE_PHYSICAL_NAME,
--     s.COLUMN_PHYSICAL_NAME,
--     s.COLUMN_LOGICAL_NAME_CANDIDATE,
--     r.RAW_ID,
--     r.SOURCE_TYPE,
--     r.SOURCE_IDENTIFIER,
--     r.COLUMN_LOGICAL_NAME_RAW
-- FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE s,
--      LATERAL FLATTEN(INPUT => s.SOURCE_RAW_IDS) f
-- JOIN DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION r
--     ON r.RAW_ID = f.VALUE::NUMBER
-- WHERE s.STG_ID = <対象STG_ID>
-- ORDER BY r.RAW_ID;


-- ============================================================================
-- 7. 実行例
-- ============================================================================

-- (1) 列名定義の名寄せ実行
-- CALL DG_CATALOG.SILVER.SP_MATCH_COLUMN_DEFINITIONS(1);

-- (2) 区分値定義の名寄せ実行
-- CALL DG_CATALOG.SILVER.SP_MATCH_CODE_VALUE_DEFINITIONS(1);

-- (3) 一括実行
-- CALL DG_CATALOG.SILVER.SP_MATCH_ALL(1);

-- (4) Stage → Bronze → Silver の全パイプライン実行
-- CALL DG_CATALOG.BRONZE.SP_LOAD_ALL_FROM_STAGE(1);
-- CALL DG_CATALOG.SILVER.SP_MATCH_ALL(1);
