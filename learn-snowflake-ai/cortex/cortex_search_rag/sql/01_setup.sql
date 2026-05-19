-- ============================================================
-- Snowflake Cortex RAG デモ: 環境セットアップ
-- ============================================================
-- 実行前に ACCOUNTADMIN ロールが必要です

-- ============================================================
-- Step 1: ロール・権限の設定
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- Cortex 機能の利用権限を付与
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;

-- ============================================================
-- Step 2: データベース・スキーマの作成
-- ============================================================
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS RAG_DEMO_DB
    COMMENT = 'Snowflake Cortex RAG デモ用データベース';

CREATE SCHEMA IF NOT EXISTS RAG_DEMO_DB.RAG_SCHEMA
    COMMENT = 'RAG デモ用スキーマ';

USE DATABASE RAG_DEMO_DB;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;

-- ============================================================
-- Step 3: ウェアハウスの設定
-- ============================================================
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 300       -- 5分で自動停止
    AUTO_RESUME = TRUE
    COMMENT = 'RAG デモ用ウェアハウス';

USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- Step 4: ステージの作成（ファイルアップロード用）
-- ============================================================
CREATE STAGE IF NOT EXISTS doc_stage
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'ドキュメントファイル保存用ステージ';

-- ============================================================
-- Step 5: テーブルの作成
-- ============================================================

-- 元のドキュメントテーブル
CREATE TABLE IF NOT EXISTS documents (
    doc_id      VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    doc_name    VARCHAR NOT NULL,
    doc_content VARCHAR NOT NULL,
    file_type   VARCHAR DEFAULT 'txt',
    category    VARCHAR,
    department  VARCHAR,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- チャンクテーブル（ベクトルなし）
CREATE TABLE IF NOT EXISTS document_chunks (
    chunk_id    NUMBER AUTOINCREMENT PRIMARY KEY,
    doc_id      VARCHAR REFERENCES documents(doc_id),
    doc_name    VARCHAR,
    chunk_text  VARCHAR NOT NULL,
    chunk_index NUMBER,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- チャンクテーブル（ベクトルあり）
CREATE TABLE IF NOT EXISTS document_chunks_vec (
    chunk_id    NUMBER PRIMARY KEY,
    doc_id      VARCHAR,
    doc_name    VARCHAR,
    chunk_text  VARCHAR NOT NULL,
    chunk_index NUMBER,
    chunk_vec   VECTOR(FLOAT, 768),
    embed_model VARCHAR DEFAULT 'snowflake-arctic-embed-m',
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- アップロードドキュメント管理テーブル（Streamlitアプリ用）
CREATE TABLE IF NOT EXISTS uploaded_documents (
    doc_id       VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    file_name    VARCHAR NOT NULL,
    file_type    VARCHAR,
    raw_content  VARCHAR,
    chunk_count  NUMBER DEFAULT 0,
    uploaded_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    uploaded_by  VARCHAR DEFAULT CURRENT_USER()
);

-- ベクトル付きチャンクテーブル（Streamlitアプリ用）
CREATE TABLE IF NOT EXISTS doc_chunks_with_vec (
    chunk_id    NUMBER AUTOINCREMENT PRIMARY KEY,
    doc_id      VARCHAR,
    file_name   VARCHAR NOT NULL,
    chunk_text  VARCHAR NOT NULL,
    chunk_index NUMBER,
    chunk_vec   VECTOR(FLOAT, 768),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Cortex Search 用ドキュメントテーブル
CREATE TABLE IF NOT EXISTS company_documents (
    doc_id       VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    doc_name     VARCHAR NOT NULL,
    category     VARCHAR,
    department   VARCHAR,
    content      VARCHAR NOT NULL,
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- RAG 品質ログテーブル
CREATE TABLE IF NOT EXISTS rag_quality_log (
    log_id          VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    query           VARCHAR,
    answer          VARCHAR,
    retrieved_chunks VARIANT,
    max_similarity  FLOAT,
    avg_similarity  FLOAT,
    model_used      VARCHAR,
    latency_ms      NUMBER,
    user_feedback   VARCHAR,
    logged_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================
-- 確認
-- ============================================================
SHOW TABLES IN SCHEMA RAG_DEMO_DB.RAG_SCHEMA;
SHOW STAGES IN SCHEMA RAG_DEMO_DB.RAG_SCHEMA;

SELECT CURRENT_DATABASE(), CURRENT_SCHEMA(), CURRENT_WAREHOUSE(), CURRENT_ROLE();
