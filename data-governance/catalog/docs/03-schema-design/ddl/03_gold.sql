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
    COLUMN_MASTER_ID     NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    TABLE_PHYSICAL_NAME   VARCHAR(200)    NOT NULL
        COMMENT '対象テーブル物理名',
    COLUMN_PHYSICAL_NAME  VARCHAR(200)    NOT NULL
        COMMENT '対象列物理名',
    COLUMN_LOGICAL_NAME   VARCHAR(500)    NOT NULL
        COMMENT '確定した論理名（業務名・日本語カラム名）',
    DATA_TYPE              VARCHAR(100)
        COMMENT '列のデータ型。実データカタログ（対象DBの物理スキーマ）との突合結果。名寄せ対象ではなくTABLE_PHYSICAL_NAME+COLUMN_PHYSICAL_NAMEで直接突き合わせて反映する',
    DATA_LENGTH             VARCHAR(50)
        COMMENT '列の桁数・長さ（例: 10、小数は10,2等）。実データカタログとの突合結果',
    KEY_TYPE                VARCHAR(20)
        COMMENT 'PK / FK / UK のいずれか。該当しない場合はNULL。実データカタログとの突合結果',
    IS_NULLABLE              BOOLEAN
        COMMENT 'NULL許可かどうか。実データカタログとの突合結果',
    ORDINAL_POSITION         NUMBER
        COMMENT 'テーブル内での列の並び順。実データカタログとの突合結果',
    COLUMN_DESCRIPTION    VARCHAR(1000)
        COMMENT '列の説明文。生成AIがBronze原文を主根拠に要約したもの（社内ガイドのCortex Search結果は参考情報として利用）。DESCRIPTION_GENERATED_BYで生成主体（AI/HUMAN）を判別。抜き取り監査（META.AI_DESCRIPTION_AUDIT_LOG）で人手修正されることもある',
    CODE_VALUE_SUMMARY     VARCHAR(4000)
        COMMENT 'この列が区分値を持つ場合の、コード値と表示ラベルの辞書形式要約（例: 01: 申請中, 02: 承認済み）。DIM_CODE_VALUE_MASTERの現在有効なレコードから機械的に生成する。COLUMN_DESCRIPTIONとは別カラムとして保持し、最終的にどちらをどう見せるかは利用側の成果物選択に委ねる',
    DESCRIPTION_GENERATED_BY   VARCHAR(50)
        COMMENT 'COLUMN_DESCRIPTIONの生成主体。AI / HUMAN（SILVER.STG_COLUMN_CANDIDATEから引き継ぎ）',
    DESCRIPTION_MODEL_VERSION  VARCHAR(200)
        COMMENT '使用したCortexモデル名・バージョン（AI生成時のみ）',
    DESCRIPTION_GENERATED_AT   TIMESTAMP_NTZ
        COMMENT 'COLUMN_DESCRIPTIONの生成日時',
    PHYSICAL_SCHEMA_MATCHED_AT TIMESTAMP_NTZ
        COMMENT 'DATA_LENGTH/KEY_TYPE/IS_NULLABLE/ORDINAL_POSITIONを実データカタログと突き合わせた日時',
    VALID_FROM            DATE            NOT NULL
        COMMENT 'このバージョンの有効開始日（SCD Type2）',
    VALID_TO              DATE
        COMMENT '有効終了日。NULLなら現在有効',
    IS_CURRENT             BOOLEAN         DEFAULT TRUE
        COMMENT '現在有効なレコードかどうか。通常の参照はIS_CURRENT=TRUEのみを対象とする',
    SOURCE_STG_ID          NUMBER          REFERENCES DG_CATALOG.SILVER.STG_COLUMN_CANDIDATE(STG_ID)
        COMMENT 'FK: SILVER.STG_COLUMN_CANDIDATE（確定根拠。トレーサビリティ用）',
    REVIEWED_BY            VARCHAR(200)    DEFAULT 'SYSTEM'
        COMMENT 'レビュー・確定した担当者。自動昇格の場合はSYSTEM',
    REVIEWED_AT            TIMESTAMP_NTZ
        COMMENT 'レビュー・確定日時',
    CREATED_AT             TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Gold層への格納日時'
)
COMMENT = '列定義マスタ（確定版）。対象DBの列1件につき現在有効な行が1件（IS_CURRENT=TRUE）。物理名⇔論理名の対応に加え、AI生成の説明文・区分値の辞書要約・実データカタログとの突合結果（データ型/桁数/キー種別/NULL可否/並び順）を1行にまとめて保持する。SCD Type2相当の版管理を持つ';

-- ----------------------------------------------------------------------------
-- GOLD: 判別列（コンテキスト）値マスタ
--   判別列には2種類ある：
--     (a) 対象DBに実在する物理列の値（例: product_type_cd = '01'）
--     (b) 実在する物理列がなく、本プロジェクト側で人手により分類したもの
--         （CONTEXT_NAMEに固定識別子、例 'MANUAL_PRODUCT_CLASSIFICATION' を用いる。
--          実際の識別子名は運用開始時に確定する）
--   いずれの場合も、CONTEXT_VALUEの表示名（CONTEXT_LABEL）は本マスタで統制し、
--   自由記述による表記揺れ（「商品A」「商品Ａ」等）を防ぐ。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.GOLD.DIM_CONTEXT_MASTER (
    CONTEXT_MASTER_ID    NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    CONTEXT_NAME   VARCHAR(200)    NOT NULL
        COMMENT '判別列の物理名（実在する場合）、または人手分類の固定識別子（実在しない場合。例: MANUAL_PRODUCT_CLASSIFICATION）',
    CONTEXT_VALUE          VARCHAR(200)    NOT NULL
        COMMENT '判別列の値、または分類コード（例: COMMON, PRODUCT_A）。DIM_CODE_VALUE_MASTER.CONTEXT_VALUEから参照される',
    CONTEXT_LABEL           VARCHAR(500)    NOT NULL
        COMMENT '表示名（例: 共通, 商品A）。将来的な呼称変更はここだけ変更すればよく、DIM_CODE_VALUE_MASTER側の値は変わらない',
    IS_COMMON                BOOLEAN         DEFAULT FALSE
        COMMENT 'コンテキストによらず共通適用される分類を表すレコードかどうか（商品別カタログ等での判別に使用）',
    DESCRIPTION               VARCHAR(1000)
        COMMENT '分類の定義・判断根拠（あれば）',
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT '登録日時',
    UPDATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT '更新日時'
)
COMMENT = '判別列（コンテキスト）の値マスタ。CONTEXT_NAME+CONTEXT_VALUEの組み合わせごとに表示名を管理する。対象DBに実在する判別列の値と、本プロジェクトで人手分類した値の両方を扱う。DIM_CODE_VALUE_MASTER.CONTEXT_NAME/CONTEXT_VALUEが「コンテキストなし」を表すNULLの場合は本マスタの対象外（NULL自体は本マスタに登録しない）';

-- ----------------------------------------------------------------------------
-- GOLD: 区分値マスタ（コード値 ⇔ 表示ラベル。SCD Type2 相当の版管理）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER (
    CODE_VALUE_MASTER_ID   NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    TABLE_PHYSICAL_NAME     VARCHAR(200)    NOT NULL
        COMMENT '区分値が使われる対象テーブルの物理名',
    COLUMN_PHYSICAL_NAME    VARCHAR(200)    NOT NULL
        COMMENT '区分値が格納される列の物理名',
    CONTEXT_NAME      VARCHAR(200)
        COMMENT '判別列（同一テーブル内の別列。例: 商品種別コード）の物理名、または人手分類の固定識別子。区分値の意味がコンテキストに依存しない場合はNULL（＝全ケース共通の定義）。NULLでない場合はGOLD.DIM_CONTEXT_MASTERで表示名を管理する',
    CONTEXT_VALUE            VARCHAR(200)
        COMMENT 'CONTEXT_NAMEで指定した判別列の実際の値、または分類コード（例: product_type_cd = "01"）。コンテキストに依存しない場合はNULL。NULLでない場合はGOLD.DIM_CONTEXT_MASTER（CONTEXT_NAME+CONTEXT_VALUE）のFK相当',
    CODE_VALUE               VARCHAR(200)    NOT NULL
        COMMENT '区分値そのもの（コード値。例: "01"）',
    CODE_LABEL               VARCHAR(500)    NOT NULL
        COMMENT 'このコード値の確定した表示ラベル（例: "申請中"）。TABLE_PHYSICAL_NAME+COLUMN_PHYSICAL_NAME+CONTEXT_NAME+CONTEXT_VALUE+CODE_VALUEの組み合わせで一意に決まる',
    CODE_DESCRIPTION         VARCHAR(1000)
        COMMENT '表示ラベルだけでは伝わらない補足説明（あれば）',
    VALID_FROM               DATE            NOT NULL
        COMMENT 'このラベルの有効開始日（SCD Type2）',
    VALID_TO                 DATE
        COMMENT '有効終了日。NULLなら現在有効。判別列が後から見つかった場合は、それまで共通扱いだったレコードの発見日をここに設定して無効化する',
    IS_CURRENT                BOOLEAN         DEFAULT TRUE
        COMMENT '現在有効なレコードかどうか。通常の参照はIS_CURRENT=TRUEのみを対象とする',
    SOURCE_STG_ID             NUMBER          REFERENCES DG_CATALOG.SILVER.STG_CODE_VALUE_CANDIDATE(STG_ID)
        COMMENT 'FK: SILVER.STG_CODE_VALUE_CANDIDATE（確定根拠。トレーサビリティ用）',
    REVIEWED_BY               VARCHAR(200)    DEFAULT 'SYSTEM'
        COMMENT 'レビュー・確定した担当者。自動昇格の場合はSYSTEM',
    REVIEWED_AT               TIMESTAMP_NTZ
        COMMENT 'レビュー・確定日時',
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Gold層への格納日時'
)
COMMENT = '区分値マスタ（確定版）。「あるテーブルのある列のあるコード値」が何を意味するか（表示ラベル）を1行で表す。同じコード値でも、同じ行にある別の列（判別列=CONTEXT_NAME。例: 商品種別コード）の値によって意味が変わることがあるため、判別列とその値もキーの一部として持つ（判別列が無いコード値はCONTEXT_NAME/CONTEXT_VALUEがともにNULL=全ケース共通の意味）。実質的な一意キーはTABLE_PHYSICAL_NAME+COLUMN_PHYSICAL_NAME+CONTEXT_NAME+CONTEXT_VALUE+CODE_VALUE+IS_CURRENT。対象DBの実データとJOINしてラベルを引く際は、判別列がある列は判別列の値も一致条件に加え、ヒットしなければCONTEXT_VALUE IS NULLの共通行にCOALESCEでフォールバックする（クエリ例は02-table-definitions.md 5章を参照）';

-- ----------------------------------------------------------------------------
-- META: AI生成説明文の抜き取り監査ログ
--   GOLD.DIM_COLUMN_MASTER 作成後に定義（FK依存のため本ファイル内に配置）
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DG_CATALOG.META.AI_DESCRIPTION_AUDIT_LOG (
    AUDIT_ID                NUMBER          AUTOINCREMENT PRIMARY KEY
        COMMENT 'PK',
    COLUMN_MASTER_ID         NUMBER          REFERENCES DG_CATALOG.GOLD.DIM_COLUMN_MASTER(COLUMN_MASTER_ID)
        COMMENT 'FK: GOLD.DIM_COLUMN_MASTER（監査対象レコード）',
    SAMPLED_AT                TIMESTAMP_NTZ  NOT NULL
        COMMENT 'サンプリング日時',
    AUDITOR                   VARCHAR(200)    NOT NULL
        COMMENT '監査担当者',
    VERDICT                   VARCHAR(50)     NOT NULL
        COMMENT '判定結果。妥当 / 要修正 / 誤り',
    CORRECTED_DESCRIPTION     VARCHAR(1000)
        COMMENT '要修正・誤りの場合の修正案（GOLD.DIM_COLUMN_MASTER.COLUMN_DESCRIPTIONへの反映案）',
    REMARKS                   VARCHAR(1000)
        COMMENT '備考',
    CREATED_AT                TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'ログ登録日時'
)
COMMENT = 'GOLD.DIM_COLUMN_MASTER.COLUMN_DESCRIPTION（AI生成説明文）に対する事後の抜き取り監査結果を記録する運用ログ。全件レビューは行わず、定期的にサンプリングした結果のみ記録する（Bronze/Silver/Goldのいずれでもない運用メタデータ。META.SOURCE_SYSTEM等と同じ位置づけ）';

-- ----------------------------------------------------------------------------
-- 参照高速化用インデックス相当（Snowflakeはクラスタリングキーで代替）
-- 対象DBとのJOIN（テーブル物理名・列物理名・コード値での検索）が主用途のため設定
-- ----------------------------------------------------------------------------
ALTER TABLE DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER
    CLUSTER BY (TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME, CONTEXT_NAME);

ALTER TABLE DG_CATALOG.GOLD.DIM_COLUMN_MASTER
    CLUSTER BY (TABLE_PHYSICAL_NAME, COLUMN_PHYSICAL_NAME);
