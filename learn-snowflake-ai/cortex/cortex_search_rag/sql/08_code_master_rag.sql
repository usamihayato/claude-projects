-- ============================================================
-- パターン1: コードマスタ + JOIN による変換レイヤー
-- ============================================================
-- 目的:
--   物理カラム名・コード値を持つ「生のソーステーブル」を
--   コードマスタとのJOINでビジネス可読な形に変換してからRAGに活用する。
--
--   [変換フロー]
--   EXPENSE_RAW (STAT_FLG='02', DEPT_CD='001')
--       ↓ code_master JOIN
--   v_expense_readable (ステータス='承認済', 部署='人事部')
--       ↓ LISTAGG でテキスト化
--   CORTEX.COMPLETE に渡す
-- ============================================================

USE ROLE SYSADMIN;
USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 1: 生ソーステーブルの作成（物理名・コード値を再現）
-- ============================================================

-- 社員マスタ（物理カラム名）
CREATE OR REPLACE TABLE EMP_MST (
    EMP_CD    VARCHAR(10) NOT NULL PRIMARY KEY,  -- 社員コード
    EMP_NM    VARCHAR(100) NOT NULL,              -- 社員名
    DEPT_CD   VARCHAR(10) NOT NULL,               -- 部署コード
    ROLE_CD   VARCHAR(10),                        -- 役職コード
    HIRE_DT   DATE,                               -- 入社日
    ANN_LV    NUMBER DEFAULT 10,                  -- 年間付与日数
    USED_LV   NUMBER DEFAULT 0,                   -- 取得済日数
    UPD_TS    TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 経費申請テーブル（物理カラム名・コード値）
CREATE OR REPLACE TABLE EXPENSE_TBL (
    APP_ID    VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    EMP_CD    VARCHAR(10) REFERENCES EMP_MST(EMP_CD),
    CAT_CD    VARCHAR(10) NOT NULL,               -- 費用区分コード
    AMT       NUMBER NOT NULL,                    -- 金額
    APP_DT    DATE DEFAULT CURRENT_DATE(),        -- 申請日
    STAT_FLG  VARCHAR(2) DEFAULT '01',            -- ステータスフラグ
    BIKO      VARCHAR(500),                       -- 備考
    CRE_TS    TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================
-- Step 2: コードマスタテーブルの作成
-- ============================================================

CREATE OR REPLACE TABLE CODE_MST (
    CODE_TYPE  VARCHAR(20) NOT NULL,  -- コード種別
    CODE_VAL   VARCHAR(10) NOT NULL,  -- コード値
    CODE_LBL   VARCHAR(100) NOT NULL, -- ラベル（表示名）
    SORT_NO    NUMBER DEFAULT 0,      -- 表示順
    PRIMARY KEY (CODE_TYPE, CODE_VAL)
);

-- コードマスタデータ投入
INSERT INTO CODE_MST (CODE_TYPE, CODE_VAL, CODE_LBL, SORT_NO) VALUES
-- 部署コード
('DEPT', '001', '人事部',         1),
('DEPT', '002', '経理部',         2),
('DEPT', '003', '情報システム部',  3),
('DEPT', '004', '営業部',         4),
-- 役職コード
('ROLE', '10',  '部長',   1),
('ROLE', '20',  '課長',   2),
('ROLE', '30',  '主任',   3),
('ROLE', '40',  '担当',   4),
-- 費用区分コード
('CAT', 'T',   '交通費', 1),
('CAT', 'E',   '接待費', 2),
('CAT', 'B',   '出張費', 3),
('CAT', 'S',   '消耗品', 4),
-- ステータスフラグ
('STAT', '01', '申請中', 1),
('STAT', '02', '承認済', 2),
('STAT', '03', '却下',   3);

-- ============================================================
-- Step 3: サンプルデータ投入（コード値で）
-- ============================================================

TRUNCATE TABLE EMP_MST;
INSERT INTO EMP_MST (EMP_CD, EMP_NM, DEPT_CD, ROLE_CD, HIRE_DT, ANN_LV, USED_LV) VALUES
('E001', '山田 太郎', '001', '20', '2018-04-01', 20, 5),
('E002', '鈴木 花子', '002', '30', '2020-10-01', 15, 8),
('E003', '田中 一郎', '003', '40', '2021-07-01', 12, 2),
('E004', '佐藤 美咲', '004', '40', '2023-04-01', 10, 3),
('E005', '伊藤 健二', '001', '40', '2022-01-15', 12, 7);

TRUNCATE TABLE EXPENSE_TBL;
INSERT INTO EXPENSE_TBL (EMP_CD, CAT_CD, AMT, APP_DT, STAT_FLG, BIKO) VALUES
('E001', 'E', 45000, '2026-03-10', '02', '取引先4名との会食（新宿）'),
('E001', 'T',  3200, '2026-03-12', '02', '出張交通費（東京↔横浜）'),
('E002', 'E', 28000, '2026-03-15', '01', '仕入先3名との懇親会'),
('E002', 'S',  4500, '2026-03-18', '02', '事務用品購入'),
('E003', 'B',120000, '2026-03-05', '02', '大阪出張（2泊3日）'),
('E003', 'T',  2400, '2026-03-20', '01', 'セミナー参加交通費'),
('E004', 'E', 52000, '2026-03-08', '03', '接待費上限超過のため'),
('E005', 'T',  1800, '2026-03-22', '01', '顧客訪問交通費');

-- ============================================================
-- Step 4: 変換ビューの作成（コードマスタJOIN）
-- ============================================================

CREATE OR REPLACE VIEW V_EXPENSE_READABLE AS
SELECT
    e.EMP_CD                            AS 社員コード,
    e.EMP_NM                            AS 社員名,
    dept.CODE_LBL                       AS 部署,
    role_m.CODE_LBL                     AS 役職,
    TO_CHAR(e.HIRE_DT, 'YYYY年MM月DD日') AS 入社日,
    e.ANN_LV                            AS 年間付与日数,
    e.USED_LV                           AS 取得済日数,
    (e.ANN_LV - e.USED_LV)             AS 有給残日数,
    ea.APP_ID                           AS 申請ID,
    cat.CODE_LBL                        AS 費用区分,
    ea.AMT                              AS 金額,
    TO_CHAR(ea.APP_DT, 'YYYY年MM月DD日') AS 申請日,
    stat.CODE_LBL                       AS ステータス,
    ea.BIKO                             AS 備考
FROM EXPENSE_TBL ea
JOIN EMP_MST    e     ON ea.EMP_CD   = e.EMP_CD
JOIN CODE_MST   dept  ON dept.CODE_TYPE  = 'DEPT' AND dept.CODE_VAL  = e.DEPT_CD
JOIN CODE_MST   role_m ON role_m.CODE_TYPE = 'ROLE' AND role_m.CODE_VAL = e.ROLE_CD
JOIN CODE_MST   cat   ON cat.CODE_TYPE   = 'CAT'  AND cat.CODE_VAL   = ea.CAT_CD
JOIN CODE_MST   stat  ON stat.CODE_TYPE  = 'STAT' AND stat.CODE_VAL  = ea.STAT_FLG;

-- 確認: 変換前
SELECT EMP_CD, DEPT_CD, CAT_CD, STAT_FLG, AMT FROM EXPENSE_TBL LIMIT 3;

-- 確認: 変換後
SELECT 社員名, 部署, 費用区分, ステータス, 金額, 備考 FROM V_EXPENSE_READABLE LIMIT 3;

-- ============================================================
-- Step 5: 変換ビューを使ったハイブリッドRAG
-- ============================================================

-- ---- 例: 却下された申請の対処方法を聞く ----
SET query_text = '却下された経費申請について、規定に照らした対処方法を教えてください';

WITH
-- [A] ビューから却下データを取得（コードは既にラベルに変換済み）
structured_context AS (
    SELECT LISTAGG(
        社員名 || '（' || 部署 || ' / ' || 役職 || '）'
        || ' : ' || 費用区分 || ' ¥' || TO_CHAR(金額, '999,999')
        || ' 申請日: ' || 申請日
        || ' 備考: ' || 備考,
        '\n'
    ) AS ctx
    FROM V_EXPENSE_READABLE
    WHERE ステータス = '却下'
),
-- [B] 経費規定ドキュメントを Cortex Search で取得
doc_context AS (
    SELECT LISTAGG(
        '【' || r.value:doc_name::VARCHAR || '】\n' || r.value:content::VARCHAR,
        '\n\n'
    ) AS ctx
    FROM (
        SELECT PARSE_JSON(
            SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'company_doc_search',
                CONCAT(
                    '{"query": "', $query_text, '",',
                    '"columns": ["doc_name", "content"],',
                    '"filter": {"@eq": {"category": "財務規定"}},',
                    '"limit": 2}'
                )
            )
        ) AS result
    ),
    LATERAL FLATTEN(input => result:results) r
)
SELECT
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '経費担当アシスタントとして、以下の規定とデータを元に具体的に回答してください。\n\n',
            '=== 経費精算規定 ===\n', dc.ctx, '\n\n',
            '=== 却下された申請データ ===\n', sc.ctx,
            '\n\n質問: ', $query_text
        )
    ) AS 回答
FROM structured_context sc, doc_context dc;


-- ============================================================
-- Step 6: 複数コード種別にまたがるクエリ例
-- ============================================================

-- ---- 例: 部署・役職・ステータスをすべてラベルで集計 ----
SELECT
    部署,
    役職,
    ステータス,
    COUNT(*)        AS 件数,
    SUM(金額)       AS 合計金額,
    MAX(金額)       AS 最大金額
FROM V_EXPENSE_READABLE
GROUP BY 部署, 役職, ステータス
ORDER BY 部署, 役職, ステータス;

-- ---- 例: 有給残 × 部署サマリ（ビューから社員情報も取得可能） ----
SELECT DISTINCT
    部署,
    社員名,
    年間付与日数,
    取得済日数,
    有給残日数
FROM V_EXPENSE_READABLE
ORDER BY 有給残日数;
