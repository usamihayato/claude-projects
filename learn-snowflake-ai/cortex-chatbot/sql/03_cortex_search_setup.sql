-- ============================================================
-- Cortex Search Service セットアップ（2サービス構成）
-- ============================================================
-- AI_SUMMARY_SEARCH_SERVICE : ai_summary（自然文概要）インデックス
--   → 処理概要説明・障害調査・機能フロー質問に使用
-- SOURCE_CODE_SEARCH_SERVICE: source_code（コード本文）インデックス
--   → カラム処理追跡・変数マッピング・詳細ロジック解析に使用

-- ============================================================
-- 1. AI概要文検索サービス（AI_SUMMARY_SEARCH_SERVICE）
-- ============================================================
-- ai_summaryに識別情報を付加して検索精度を向上
-- source_code はレスポンスカラムとして保持（引用表示用）

CREATE OR REPLACE CORTEX SEARCH SERVICE AI_SUMMARY_SEARCH_SERVICE
    ON search_content
    ATTRIBUTES module_name, function_name, ajs_name, system_name, file_name
    WAREHOUSE = <WH_NAME>
    TARGET_LAG = '1 day'
    AS (
        SELECT
            source_id,
            file_name,
            module_name,
            function_name,
            ajs_name,
            net_name,
            system_name,
            ai_summary
                || ' モジュール名: ' || COALESCE(module_name, '')
                || ' 機能名: ' || COALESCE(function_name, '')
                || ' ファイル名: ' || COALESCE(file_name, '')
                || ' ジョブ名: ' || COALESCE(ajs_name, '')
                AS search_content,
            source_code,
            created_at
        FROM T_<システム名>_SRC
        WHERE ai_summary IS NOT NULL
    );

-- ============================================================
-- 2. ソースコード本文検索サービス（SOURCE_CODE_SEARCH_SERVICE）
-- ============================================================
-- source_code（SQL本文・バッチスクリプト）を直接インデックス
-- カラム処理追跡・変数マッピング・詳細ロジック解析に使用
-- ai_summary はレスポンスカラムとして保持（コンテキスト補完用）
--
-- コスト注意: source_code はテキストが長くインデックスサイズが大きいため、
-- AI_SUMMARY_SEARCH_SERVICE より固定費（アイドル税）が高くなる。

CREATE OR REPLACE CORTEX SEARCH SERVICE SOURCE_CODE_SEARCH_SERVICE
    ON source_code
    ATTRIBUTES module_name, function_name, ajs_name, system_name, file_name
    WAREHOUSE = <WH_NAME>
    TARGET_LAG = '1 day'
    AS (
        SELECT
            source_id,
            file_name,
            module_name,
            function_name,
            ajs_name,
            net_name,
            system_name,
            ai_summary,
            source_code,
            created_at
        FROM T_<システム名>_SRC
        WHERE source_code IS NOT NULL
    );

-- ============================================================
-- 3. 互換性維持: 旧 SRC_SEARCH_SERVICE（移行完了後に削除可）
-- ============================================================
-- 旧サービス名 SRC_SEARCH_SERVICE は AI_SUMMARY_SEARCH_SERVICE に移行。
-- 既存の参照がある場合は切り替え後に削除すること。
-- DROP CORTEX SEARCH SERVICE SRC_SEARCH_SERVICE;

-- ============================================================
-- 4. 動作確認: AI_SUMMARY_SEARCH_SERVICE
-- ============================================================

-- 基本的な処理概要検索テスト
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'AI_SUMMARY_SEARCH_SERVICE',
        '{
            "query": "受注データを処理するプログラムの概要を教えて",
            "columns": ["file_name", "module_name", "function_name", "search_content"],
            "limit": 5
        }'
    )
) AS search_result;

-- モジュール名でフィルタした障害調査テスト
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'AI_SUMMARY_SEARCH_SERVICE',
        '{
            "query": "エラー処理の実装方法",
            "columns": ["file_name", "module_name", "function_name", "search_content"],
            "filter": {"@eq": {"module_name": "〇〇モジュール"}},
            "limit": 3
        }'
    )
) AS filtered_result;

-- ============================================================
-- 5. 動作確認: SOURCE_CODE_SEARCH_SERVICE
-- ============================================================

-- カラム処理追跡テスト（.datファイルの固定長解析など）
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'SOURCE_CODE_SEARCH_SERVICE',
        '{
            "query": "〇〇.datファイルの6カラム目を処理してINSERTしているプログラム",
            "columns": ["file_name", "module_name", "function_name", "ai_summary", "source_code"],
            "limit": 5
        }'
    )
) AS source_code_result;

-- ============================================================
-- 6. インデックス対象レコード数の確認
-- ============================================================

SELECT
    COUNT(*) AS total_records,
    COUNT(ai_summary) AS ai_summary_indexed,
    COUNT(source_code) AS source_code_indexed,
    ROUND(COUNT(ai_summary) / COUNT(*) * 100, 1) AS ai_summary_coverage_pct,
    ROUND(COUNT(source_code) / COUNT(*) * 100, 1) AS source_code_coverage_pct
FROM T_<システム名>_SRC;

-- ============================================================
-- 7. ai_summaryの再生成（未生成レコード対応）
-- ============================================================

UPDATE T_<システム名>_SRC
SET
    ai_summary = SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        '以下のSQLプログラムの処理内容を200〜300文字で日本語で説明してください。'
        || '処理の目的、対象テーブル、主要な処理ステップを含めてください。\n\n'
        || '```sql\n'
        || LEFT(source_code, 8000)
        || '\n```'
    ),
    update_at = CURRENT_TIMESTAMP()
WHERE ai_summary IS NULL
  AND source_code IS NOT NULL
  AND LENGTH(source_code) > 0;

-- ============================================================
-- 8. Cortex Search Service の状態確認
-- ============================================================

SHOW CORTEX SEARCH SERVICES LIKE 'AI_SUMMARY_SEARCH_SERVICE';
SHOW CORTEX SEARCH SERVICES LIKE 'SOURCE_CODE_SEARCH_SERVICE';
