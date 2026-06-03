-- ============================================================
-- 社内システム保守支援チャットボット 環境セットアップ
-- ============================================================

-- データベース・スキーマ・ウェアハウスは既存のものを使用する想定
-- 必要に応じて以下の変数を実環境に合わせて変更する
-- DB_NAME     : チャットボット用DB（または既存システムDB）
-- SCHEMA_NAME : 既存メタデータテーブルと同一スキーマ推奨
-- WH_NAME     : 既存のウェアハウス名

-- ============================================================
-- 1. セマンティックモデル格納用ステージの作成
-- ============================================================

-- Cortex AnalystはセマンティックモデルYAMLをSnowflakeステージに配置する必要がある
CREATE STAGE IF NOT EXISTS CHATBOT_MODELS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Cortex Analystのセマンティックモデルを格納するステージ';

-- ステージにYAMLをアップロードするコマンド（SnowSQLまたはSnowsight経由）
-- PUT file:///local/path/to/semantic_model.yaml @CHATBOT_MODELS_STAGE AUTO_COMPRESS=FALSE;

-- ============================================================
-- 2. Cortex Search用セマンティックビューの作成
-- ============================================================

-- T_システム名_SRCを検索最適化した形で公開するビュー
-- 実際のテーブル名はシステム名に合わせて変更すること
-- 例: T_ORDERMS_SRC → T_<システム名>_SRC

CREATE OR REPLACE VIEW V_SRC_SEARCH AS
SELECT
    source_id,
    file_name,
    module_name,
    function_name,
    ajs_name,
    net_name,
    system_name,
    -- 検索精度向上のためai_summaryにモジュール名・機能名・ファイル名を付加
    ai_summary
        || ' モジュール名: ' || COALESCE(module_name, '')
        || ' 機能名: ' || COALESCE(function_name, '')
        || ' ファイル名: ' || COALESCE(file_name, '')
        || ' ジョブ名: ' || COALESCE(ajs_name, '')
        AS search_content,
    source_code,
    created_at
FROM T_<システム名>_SRC
WHERE ai_summary IS NOT NULL;

-- ============================================================
-- 3. 評価結果記録テーブルの作成
-- ============================================================

CREATE TABLE IF NOT EXISTS T_EVAL_RESULTS (
    eval_id          NUMBER AUTOINCREMENT PRIMARY KEY,
    test_case_id     VARCHAR(10)    COMMENT 'テストケースID (例: A-01)',
    category         VARCHAR(5)     COMMENT 'カテゴリ (A/B/C/D/E)',
    question         VARCHAR(2000)  COMMENT '質問文',
    tool_type        VARCHAR(50)    COMMENT '比較タイプ: search_only / hybrid',
    used_tool        VARCHAR(200)   COMMENT '実際に使用されたツール名',
    answer           VARCHAR(20000) COMMENT 'エージェントの回答',
    expected         VARCHAR(20000) COMMENT '期待する回答（正解）',
    is_correct       BOOLEAN        COMMENT '影響調査の正解フラグ',
    recall_score     FLOAT          COMMENT '再現率 (影響調査用)',
    precision_score  FLOAT          COMMENT '適合率 (影響調査用)',
    relevance_score  INTEGER        COMMENT '関連性スコア 1-5 (解説/障害調査用)',
    tool_match       BOOLEAN        COMMENT 'ツール選択が期待どおりか',
    response_sec     FLOAT          COMMENT 'API応答時間（秒）',
    eval_date        TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================
-- 4. 動作確認クエリ
-- ============================================================

-- セマンティックビューのレコード数確認
SELECT COUNT(*) AS src_record_count FROM V_SRC_SEARCH;

-- CRUDメタデータテーブルの確認
SELECT
    COUNT(*) AS crud_record_count,
    COUNT(DISTINCT ajs_name) AS unique_jobs,
    COUNT(DISTINCT table_name_jp) AS unique_tables,
    COUNT(DISTINCT module_name) AS unique_modules
FROM T_<システム名>_CRUD;
