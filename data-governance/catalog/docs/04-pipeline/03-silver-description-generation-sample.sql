-- ============================================================================
-- お試し実装: Bronze原文（主根拠） + Cortex Search（社内ガイドRAG・参考情報）による
-- 1テーブル分の COLUMN_DESCRIPTION_CANDIDATE 生成
-- 対象: Snowflake
-- 前提:
--   ・03-schema-design/ddl/02_silver.sql（STG_COLUMN_CANDIDATE への列追加後）実行済み
--   ・SILVER.STG_COLUMN_CANDIDATE に対象テーブルの名寄せ結果
--     （COLUMN_LOGICAL_NAME_CANDIDATE, SOURCE_RAW_IDS）が投入済み
--     （04-pipeline/02-bronze-to-silver.sql 実行後）
--   ・社内ガイドの検索用 Cortex Search Service が作成済み（未作成なら0.を先に実行）
-- 注意: 動作確認用サンプル。列名・サービス名・本番プロンプト・使用モデルは
--       環境に合わせて置き換える（02-data-transformation/01-conversion-policy.md
--       4.4節・8章を参照）。社内ガイドの検索結果は「Bronze原文の理解を補う参考情報」
--       として扱い、説明文の主根拠にはしない（トレーサビリティ上の理由。4.4節参照）
-- ============================================================================

-- 0. Cortex Search Service（未作成の場合のみ）
CREATE OR REPLACE CORTEX SEARCH SERVICE DG_CATALOG.META.SVC_INTERNAL_GUIDE_SEARCH
    ON GUIDE_CONTENT                          -- ★検索対象の本文列名に置き換える
    ATTRIBUTES GUIDE_TITLE, GUIDE_URL         -- ★引用に使いたい付帯列
    WAREHOUSE = <利用する仮想ウェアハウス名>    -- ★置き換える
    TARGET_LAG = '1 day'
AS (
    SELECT GUIDE_CONTENT, GUIDE_TITLE, GUIDE_URL
    FROM <社内ガイドDB>.<スキーマ>.<パース済みガイドテーブル>   -- ★置き換える
);

-- 1. 対象（1テーブル分）
WITH TARGET AS (
    SELECT
        STG_ID, TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME,
        COLUMN_LOGICAL_NAME_CANDIDATE, SOURCE_RAW_IDS
    FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE
    WHERE TABLE_PHYSICAL_NAME = 'T_CLAIM'      -- ★お試し対象テーブルに置き換える
),
-- 2. Bronze原文（主根拠）を SOURCE_RAW_IDS から復元
BRONZE_TEXT AS (
    SELECT
        t.STG_ID,
        LISTAGG(
            '[' || raw.SOURCE_TYPE || '] ' ||
            COALESCE(raw.COLUMN_LOGICAL_NAME_RAW, '') || ' : ' ||
            COALESCE(raw.RAW_CONTENT:original_text::VARCHAR, ''),
            CHR(10)
        ) WITHIN GROUP (ORDER BY raw.RAW_ID) AS SOURCE_TEXT
    FROM TARGET t,
         LATERAL FLATTEN(INPUT => t.SOURCE_RAW_IDS) f
    JOIN DG_CATALOG.BRONZE.RAW_COLUMN_DEFINITION raw
      ON raw.RAW_ID = f.VALUE::NUMBER
    GROUP BY t.STG_ID
),
-- 3. 日本語カラム名（名寄せ後の論理名候補）でCortex Searchを検索（参考情報）
GUIDE_TEXT AS (
    SELECT
        t.STG_ID,
        (
            SELECT LISTAGG(
                       '[' || v.value:GUIDE_TITLE::VARCHAR || '] ' ||
                       v.value:GUIDE_CONTENT::VARCHAR,
                       CHR(10)
                   )
            FROM TABLE(
                FLATTEN(
                    INPUT => PARSE_JSON(
                        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                            'DG_CATALOG.META.SVC_INTERNAL_GUIDE_SEARCH',
                            OBJECT_CONSTRUCT(
                                'query', t.COLUMN_LOGICAL_NAME_CANDIDATE,
                                'columns', ARRAY_CONSTRUCT('GUIDE_CONTENT', 'GUIDE_TITLE', 'GUIDE_URL'),
                                'limit', 3
                            )::VARCHAR
                        )
                    ):results
                )
            ) v
        ) AS GUIDE_TEXT
    FROM TARGET t
),
-- 4. Bronze原文（主根拠）＋社内ガイド（参考情報）を渡して要約生成
GENERATED AS (
    SELECT
        t.STG_ID,
        SNOWFLAKE.CORTEX.COMPLETE(
            'llama3.1-70b',   -- ★利用可能なCortexモデルに置き換える
            CONCAT(
                'あなたはデータカタログ整備の担当者です。',
                '以下の[原文情報]は、ある列について複数のソース（設計書・ソースコード・',
                '画面定義等）から抽出した一次情報です。[参考:社内ガイド]は同じ列名で',
                '社内ドキュメントを検索した参考情報であり、一次情報ではありません。',
                '[原文情報]を主な根拠とし、[参考:社内ガイド]は[原文情報]の理解を補う',
                '目的でのみ利用してください。どちらにも書かれていない情報を推測して',
                '補ってはいけません。当該列の業務的な意味を1〜2文の日本語で簡潔に',
                '要約してください。判断できない場合は「原文からは判断できません」とだけ',
                '出力してください。',
                CHR(10), CHR(10),
                '--- [原文情報] ---', CHR(10), b.SOURCE_TEXT, CHR(10), CHR(10),
                '--- [参考:社内ガイド] ---', CHR(10), COALESCE(g.GUIDE_TEXT, '(該当なし)')
            )
        ) AS COLUMN_DESCRIPTION_CANDIDATE
    FROM TARGET t
    JOIN BRONZE_TEXT b ON b.STG_ID = t.STG_ID
    LEFT JOIN GUIDE_TEXT g ON g.STG_ID = t.STG_ID
)
MERGE INTO DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE AS TGT
USING GENERATED AS SRC
    ON TGT.STG_ID = SRC.STG_ID
WHEN MATCHED THEN UPDATE SET
    COLUMN_DESCRIPTION_CANDIDATE = SRC.COLUMN_DESCRIPTION_CANDIDATE,
    DESCRIPTION_GENERATED_BY     = 'AI',
    DESCRIPTION_MODEL_VERSION    = 'llama3.1-70b',
    DESCRIPTION_GENERATED_AT     = CURRENT_TIMESTAMP();

-- 結果確認
SELECT STG_ID, TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME,
       COLUMN_LOGICAL_NAME_CANDIDATE, COLUMN_DESCRIPTION_CANDIDATE,
       DESCRIPTION_GENERATED_BY, DESCRIPTION_MODEL_VERSION, DESCRIPTION_GENERATED_AT
FROM DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE
WHERE TABLE_PHYSICAL_NAME = 'T_CLAIM';
