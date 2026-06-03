-- ============================================================
-- Cortex Search Service セットアップ
-- ============================================================
-- 対象: T_<システム名>_SRC テーブル
-- 検索対象: ai_summary（事前生成の概要テキスト）
-- 用途: ソースコード解説・障害調査支援

-- ============================================================
-- 1. Cortex Search Service の作成
-- ============================================================
-- search_column: ai_summaryにモジュール名・機能名・ファイル名を結合したsearch_content
-- attributes: フィルタとして使用できるカラム（module_name, function_name等）
-- target_lag: 日次でインデックスを更新（バッチ後のデータ反映に合わせて調整）

CREATE OR REPLACE CORTEX SEARCH SERVICE SRC_SEARCH_SERVICE
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
            -- ai_summaryに識別情報を付加して検索精度を向上
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
-- 2. 動作確認: 直接SQLでセマンティック検索をテスト
-- ============================================================

-- 基本的な検索テスト
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'SRC_SEARCH_SERVICE',
        '{
            "query": "受注データを処理するプログラムの概要を教えて",
            "columns": ["file_name", "module_name", "function_name", "search_content", "source_code"],
            "limit": 5
        }'
    )
) AS search_result;

-- モジュール名でフィルタした検索テスト
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'SRC_SEARCH_SERVICE',
        '{
            "query": "エラー処理の実装方法",
            "columns": ["file_name", "module_name", "function_name", "search_content"],
            "filter": {"@eq": {"module_name": "〇〇モジュール"}},
            "limit": 3
        }'
    )
) AS filtered_result;

-- ============================================================
-- 3. ai_summaryが未設定のレコードを確認
-- ============================================================

-- ai_summaryがNULLのレコード（インデックス対象外）を確認
SELECT
    COUNT(*) AS total_records,
    COUNT(ai_summary) AS has_summary,
    COUNT(*) - COUNT(ai_summary) AS missing_summary,
    ROUND(COUNT(ai_summary) / COUNT(*) * 100, 1) AS coverage_pct
FROM T_<システム名>_SRC;

-- ai_summaryが未生成のレコードを一覧表示
SELECT file_name, module_name, function_name, ajs_name
FROM T_<システム名>_SRC
WHERE ai_summary IS NULL
ORDER BY module_name, file_name;

-- ============================================================
-- 4. ai_summaryの再生成（未生成レコード対応）
-- ============================================================
-- source_codeからai_summaryを生成する場合はCortex Completeを使用
-- 実行前にsource_codeカラムのサイズを確認すること（超大きい場合はトリミング推奨）

UPDATE T_<システム名>_SRC
SET
    ai_summary = SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large2',
        '以下のSQLプログラムの処理内容を200〜300文字で日本語で説明してください。'
        || '処理の目的、対象テーブル、主要な処理ステップを含めてください。\n\n'
        || '```sql\n'
        || LEFT(source_code, 8000)  -- トークン制限対策でトリミング
        || '\n```'
    ),
    update_at = CURRENT_TIMESTAMP()
WHERE ai_summary IS NULL
  AND source_code IS NOT NULL
  AND LENGTH(source_code) > 0;

-- ============================================================
-- 5. Cortex Search Service の状態確認
-- ============================================================

SHOW CORTEX SEARCH SERVICES LIKE 'SRC_SEARCH_SERVICE';

-- インデックス対象レコード数を確認
SELECT
    COUNT(*) AS indexed_records
FROM T_<システム名>_SRC
WHERE ai_summary IS NOT NULL;
