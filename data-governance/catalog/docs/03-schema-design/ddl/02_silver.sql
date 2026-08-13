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
    STG_ID                        NUMBER         AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    TABLE_PHYSICAL_NAME            VARCHAR(200)   NOT NULL
        COMMENT '対象テーブル物理名',
    COLUMN_PHYSICAL_NAME           VARCHAR(200)   NOT NULL
        COMMENT '対象列物理名',
    COLUMN_LOGICAL_NAME_CANDIDATE  VARCHAR(500)
        COMMENT '名寄せ後の論理名候補。複数ソースの優先順位に基づく暫定採用値でまだ確定していない（確定後はGOLD.DIM_COLUMN_MASTER.COLUMN_LOGICAL_NAMEへ反映）',
    CONFLICT_FLAG                  BOOLEAN        DEFAULT FALSE
        COMMENT 'ソース間で内容が一致しない場合にTRUE。人によるレビュー対象',
    NEEDS_REVIEW_FLAG              BOOLEAN        DEFAULT FALSE
        COMMENT '該当ソースが1件のみ等、要確認の場合にTRUE',
    CANDIDATE_VALUES               VARIANT
        COMMENT '各ソースでの値・優先度・出典の一覧（競合内容の詳細）',
    SOURCE_RAW_IDS                 ARRAY
        COMMENT '集約元となったBRONZE.RAW_COLUMN_DEFINITION.RAW_IDの一覧（トレーサビリティ確保用）',
    COLUMN_DESCRIPTION_CANDIDATE   VARCHAR(1000)
        COMMENT '生成AIによる列説明文候補。SOURCE_RAW_IDSに紐づくBronze原文のみを主根拠に要約する（社内ガイドのCortex Search結果は参考情報として利用するのみで根拠にはしない。conversion-policy.md 4.4節参照）。まだGoldに反映されていない下書き',
    DESCRIPTION_GENERATED_BY       VARCHAR(50)    DEFAULT 'AI'
        COMMENT '説明文候補の生成主体。AI / HUMAN',
    DESCRIPTION_MODEL_VERSION      VARCHAR(200)
        COMMENT '生成に使用したCortexモデル名・バージョン（AI生成時のみ）',
    DESCRIPTION_GENERATED_AT       TIMESTAMP_NTZ
        COMMENT '説明文候補の生成日時',
    MATCHING_BATCH_ID              NUMBER         REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID)
        COMMENT 'FK: META.COLLECTION_BATCH（名寄せ実行バッチ）',
    UPDATED_AT                     TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
        COMMENT '更新日時'
)
COMMENT = '列名（物理名→論理名）の名寄せ候補。複数のBronzeレコードをTABLE_PHYSICAL_NAME+COLUMN_PHYSICAL_NAMEで集約した中間テーブルで、まだ確定していない（列名は「_CANDIDATE」＝候補のまま）。競合フラグ・要確認フラグが立っていなければGOLD.DIM_COLUMN_MASTERへ自動昇格する';

-- ----------------------------------------------------------------------------
-- SILVER: 区分値対応の名寄せ候補
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE (
    STG_ID                        NUMBER         AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    TABLE_PHYSICAL_NAME            VARCHAR(200)   NOT NULL
        COMMENT '区分値が使われる対象テーブルの物理名',
    COLUMN_PHYSICAL_NAME           VARCHAR(200)   NOT NULL
        COMMENT '区分値が格納される列の物理名',
    CONTEXT_NAME            VARCHAR(200)
        COMMENT '判別列の物理名（正規化後）。区分値の意味がコンテキストに依存しない場合はNULL（＝共通）。詳細はGOLD.DIM_CODE_VALUE_MASTERのコメントを参照',
    CONTEXT_VALUE                  VARCHAR(200)
        COMMENT '判別列の値（正規化後）。コンテキストに依存しない場合はNULL（＝共通）',
    CODE_VALUE                     VARCHAR(200)   NOT NULL
        COMMENT '区分値（コード値）',
    CODE_LABEL_CANDIDATE           VARCHAR(500)
        COMMENT '名寄せ後の表示ラベル候補。まだ確定していない（確定後はGOLD.DIM_CODE_VALUE_MASTER.CODE_LABELへ反映）',
    CODE_DESCRIPTION_CANDIDATE     VARCHAR(1000)
        COMMENT '名寄せ後の補足説明候補',
    CONFLICT_FLAG                  BOOLEAN        DEFAULT FALSE
        COMMENT 'ソース間で内容が一致しない場合にTRUE。人によるレビュー対象',
    NEEDS_REVIEW_FLAG              BOOLEAN        DEFAULT FALSE
        COMMENT '要確認の場合にTRUE（判別列の後発見時も強制的にTRUE）',
    CANDIDATE_VALUES               VARIANT
        COMMENT '各ソースでの値・優先度・出典の一覧（競合内容の詳細）',
    SOURCE_RAW_IDS                 ARRAY
        COMMENT '集約元となったBRONZE.RAW_CODE_VALUE_DEFINITION.RAW_IDの一覧（トレーサビリティ確保用）',
    MATCHING_BATCH_ID              NUMBER         REFERENCES DG_CATALOG.META.COLLECTION_BATCH(BATCH_ID)
        COMMENT 'FK: META.COLLECTION_BATCH（名寄せ実行バッチ）',
    UPDATED_AT                     TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
        COMMENT '更新日時'
)
COMMENT = '区分値（コード値→表示ラベル）の名寄せ候補。TABLE_PHYSICAL_NAME+COLUMN_PHYSICAL_NAME+CONTEXT_NAME+CONTEXT_VALUE+CODE_VALUEを単位に集約した中間テーブルで、まだ確定していない。競合フラグ・要確認フラグが立っていなければGOLD.DIM_CODE_VALUE_MASTERへ自動昇格する';
