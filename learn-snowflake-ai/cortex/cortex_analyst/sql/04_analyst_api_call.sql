-- ============================================================
-- Cortex Analyst REST API 呼び出し
-- 実行順: 05_stored_procedures.sql でプロシージャ作成後に実行
-- ============================================================

USE ROLE     ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- ============================================================
-- Step 1: セマンティックモデルをステージにアップロード
--   ローカルから実行する場合（Snowflake CLI / SnowSQL）:
--   PUT file:///path/to/03_semantic_model.yaml
--       @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE
--       AUTO_COMPRESS=FALSE;
-- ============================================================

-- アップロード確認
LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE;

-- ============================================================
-- Step 2: Cortex Analyst を呼び出す（analyst_to_sql プロシージャ）
--   プロシージャの定義は 05_stored_procedures.sql を参照
-- ============================================================

-- 質問 1: 月次売上推移
CALL analyst_to_sql('月別の売上合計を教えて');

-- 質問 2: 商品ランキング
CALL analyst_to_sql('先月の売上上位5商品は？');

-- 質問 3: 顧客セグメント別
CALL analyst_to_sql('法人顧客と個人顧客の売上比率は？');

-- 質問 4: 地域別トレンド
CALL analyst_to_sql('東日本と西日本の今年の月次売上を比較して');

-- 質問 5: キャンセル分析
CALL analyst_to_sql('カテゴリ別のキャンセル率を教えて');

-- ============================================================
-- Step 3: レスポンスの構造を確認する
-- ============================================================

-- レスポンス JSON の各フィールドを展開して確認
SELECT
    resp:request_id::VARCHAR                       AS request_id,
    resp:message:content[0]:type::VARCHAR          AS first_content_type,
    resp:message:content[0]:text::VARCHAR          AS text_answer,
    resp:message:content[1]:type::VARCHAR          AS second_content_type,
    resp:message:content[1]:statement::VARCHAR     AS generated_sql,
    ARRAY_SIZE(resp:warnings)                      AS warning_count
FROM (
    SELECT analyst_to_sql('先月の売上上位5商品は？') AS resp
);

-- ============================================================
-- Step 4: 生成 SQL を確認する（コピー & 手動実行）
-- ============================================================

-- 生成 SQL のみを抽出
SELECT
    resp:message:content[1]:statement::VARCHAR AS generated_sql
FROM (
    SELECT analyst_to_sql('カテゴリ別の売上構成比') AS resp
);

-- ============================================================
-- Step 5: analyst_execute（SQL 生成 + 即時実行）の利用
-- ============================================================

-- 生成した SQL を即座に実行して結果を返す
CALL analyst_execute('今月の売上合計は？');
CALL analyst_execute('商品カテゴリ別の売上合計ランキング');
CALL analyst_execute('今年の法人顧客の売上合計');

-- ============================================================
-- Step 6: 複数質問を連続して実行（テスト用）
-- ============================================================

SELECT '月次売上'              AS question, analyst_to_sql('月別の売上合計を教えて'):message:content[1]:statement::VARCHAR AS sql
UNION ALL
SELECT '先月上位5商品',         analyst_to_sql('先月の売上上位5商品は？'):message:content[1]:statement::VARCHAR
UNION ALL
SELECT 'カテゴリ別構成比',      analyst_to_sql('カテゴリ別の売上構成比'):message:content[1]:statement::VARCHAR
UNION ALL
SELECT '顧客セグメント別',      analyst_to_sql('法人顧客と個人顧客の売上比較'):message:content[1]:statement::VARCHAR
UNION ALL
SELECT 'キャンセル率',          analyst_to_sql('カテゴリ別のキャンセル率'):message:content[1]:statement::VARCHAR;

-- ============================================================
-- Step 7: REST API の警告メッセージを確認する
--   Cortex Analyst が質問の曖昧さを検知した場合、
--   warnings フィールドにメッセージが入る
-- ============================================================

SELECT
    resp:warnings AS warnings,
    ARRAY_SIZE(resp:warnings) AS warning_count
FROM (
    SELECT analyst_to_sql('売上を教えて') AS resp  -- 曖昧な質問で警告が出る可能性
);
