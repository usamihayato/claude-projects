# Cortex を使った RAG サンプル

## 概要

このドキュメントでは、Snowflake Cortex を使って RAG を段階的に実装します。SQL のみで完結するシンプルな実装から始め、徐々に実用的な構成に発展させます。

---

## ステップ 0: 環境準備

```sql
-- ロールとウェアハウスの設定
USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;

-- RAG用データベースの作成
CREATE DATABASE IF NOT EXISTS RAG_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS RAG_DEMO_DB.RAG_SCHEMA;
USE SCHEMA RAG_DEMO_DB.RAG_SCHEMA;

-- Cortex権限の付与（ADMINロールが必要）
USE ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;
USE ROLE SYSADMIN;
```

---

## ステップ 1: ドキュメントテーブルの準備

```sql
-- ドキュメント格納テーブル
CREATE OR REPLACE TABLE documents (
    doc_id      VARCHAR PRIMARY KEY,
    doc_name    VARCHAR,
    doc_content VARCHAR,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- サンプルドキュメントの挿入（社内規定の例）
INSERT INTO documents (doc_id, doc_name, doc_content) VALUES
('DOC001', '有給休暇規定',
'有給休暇は入社から6ヶ月経過後に10日付与されます。その後は1年ごとに勤続年数に応じて最大20日まで増加します。
有給休暇の申請は原則として3営業日前までに直属の上長に申請してください。
繁忙期（3月、9月）は有給取得を制限する場合があります。
未使用の有給休暇は翌年度に最大20日まで繰り越すことができます。
退職時には残存有給休暇を消化するか、会社の規定に従い買取の対象となります。'),

('DOC002', '在宅勤務規定',
'在宅勤務（テレワーク）は週3日まで利用可能です。
在宅勤務を行う際は、前日の18時までにチームSlackチャンネルに申告してください。
勤務時間は通常の就業時間（9:00〜18:00）に準じます。
在宅勤務中はビデオ会議ツールにオンライン状態を維持してください。
セキュリティ上の理由から、公共のWi-Fiでの業務は禁止されています。VPNの使用を必須とします。
在宅勤務に必要な機器（ノートPC、モニター）は会社が貸与します。'),

('DOC003', '経費精算規定',
'経費精算は発生日から30日以内に申請してください。
交通費は実費精算です。新幹線はグリーン車不可、飛行機はエコノミークラスのみ対象です。
接待費の上限は1人あたり10,000円です。4名以上の接待は事前に部長承認が必要です。
領収書は原本またはスキャンデータの提出が必要です。レシートも有効です。
海外出張の経費はドル建てで精算し、出張日の為替レートを適用します。
月額交通定期代は毎月25日に給与と合わせて支給されます。'),

('DOC004', 'セキュリティポリシー',
'パスワードは12文字以上で、英大文字・英小文字・数字・特殊文字を含む必要があります。
パスワードは90日ごとに変更が必須です。
多要素認証（MFA）は全システムで必須です。
業務データの個人端末への保存は禁止されています。
不審なメールを受信した場合はITセキュリティチームに即座に報告してください。
外部へのデータ持ち出しには情報セキュリティ責任者の承認が必要です。'),

('DOC005', 'Snowflake利用ガイド',
'Snowflakeの仮想ウェアハウスは使用後は必ず停止してください。自動停止は5分に設定されています。
本番環境へのアクセスは申請ベースで付与されます。開発・検証用は開発環境を使用してください。
クエリ実行前にWHERE句でデータを絞り込み、フルスキャンを避けてください。
新しいテーブル作成時はデータ型とクラスタリングキーを適切に設定してください。
Cortex LLM機能はCREDIT消費があるため、本番利用前に必ず検証環境でテストしてください。
データのロード・アンロードはSnowflake推奨のファイルフォーマット（Parquet/CSV）を使用してください。');
```

---

## ステップ 2: チャンキング処理

```sql
-- チャンク格納テーブル
CREATE OR REPLACE TABLE document_chunks (
    chunk_id    NUMBER AUTOINCREMENT PRIMARY KEY,
    doc_id      VARCHAR,
    doc_name    VARCHAR,
    chunk_text  VARCHAR,
    chunk_index NUMBER,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- シンプルなチャンキング（文単位で分割）
-- 実際の運用では SPLIT_BY_CHARACTER_LENGTH などを使用
INSERT INTO document_chunks (doc_id, doc_name, chunk_text, chunk_index)
SELECT
    d.doc_id,
    d.doc_name,
    TRIM(f.value::VARCHAR) AS chunk_text,
    f.index AS chunk_index
FROM documents d,
    LATERAL FLATTEN(input => SPLIT(d.doc_content, '\n')) f
WHERE TRIM(f.value::VARCHAR) != '';

-- チャンク確認
SELECT doc_name, chunk_index, LEFT(chunk_text, 80) AS preview
FROM document_chunks
ORDER BY doc_id, chunk_index;
```

---

## ステップ 3: ベクトル埋め込みの生成

```sql
-- ベクトル付きチャンクテーブル
CREATE OR REPLACE TABLE document_chunks_vec (
    chunk_id    NUMBER PRIMARY KEY,
    doc_id      VARCHAR,
    doc_name    VARCHAR,
    chunk_text  VARCHAR,
    chunk_index NUMBER,
    chunk_vec   VECTOR(FLOAT, 768)  -- 768次元ベクトル
);

-- 埋め込みの生成（EMBED_TEXT_768を使用）
INSERT INTO document_chunks_vec
SELECT
    chunk_id,
    doc_id,
    doc_name,
    chunk_text,
    chunk_index,
    SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        chunk_text
    ) AS chunk_vec
FROM document_chunks;

-- 件数確認
SELECT COUNT(*) AS total_chunks FROM document_chunks_vec;

-- サンプル確認（ベクトルの最初の5要素を表示）
SELECT
    chunk_id,
    doc_name,
    LEFT(chunk_text, 50) AS preview,
    VECTOR_TO_ARRAY(chunk_vec)[0]::FLOAT AS vec_dim1,
    VECTOR_TO_ARRAY(chunk_vec)[1]::FLOAT AS vec_dim2
FROM document_chunks_vec
LIMIT 5;
```

---

## ステップ 4: ベクトル検索の実装

```sql
-- 検索用のクエリベクトルを生成して類似検索を実行
-- 例: 「有給休暇は何日もらえますか？」という質問

SET query_text = '有給休暇は何日もらえますか？';

-- クエリのベクトル化 + 類似検索
WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_text
    ) AS vec
)
SELECT
    c.doc_name,
    c.chunk_text,
    VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS similarity_score
FROM document_chunks_vec c, query_vec q
ORDER BY similarity_score DESC
LIMIT 3;
```

---

## ステップ 5: RAG の完成形（検索 + LLM 回答生成）

```sql
-- ========================================
-- RAG クエリの完成形
-- ========================================
SET query_text = '在宅勤務はどのように申請すればいいですか？';

-- Step 1: 類似チャンクを取得
WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_text
    ) AS vec
),
top_chunks AS (
    SELECT
        c.doc_name,
        c.chunk_text,
        VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS similarity_score
    FROM document_chunks_vec c, query_vec q
    ORDER BY similarity_score DESC
    LIMIT 3
),
-- Step 2: コンテキストを結合
context_combined AS (
    SELECT LISTAGG(
        '【出典: ' || doc_name || '】\n' || chunk_text,
        '\n\n'
    ) AS context_text
    FROM top_chunks
    WHERE similarity_score > 0.5  -- 類似度閾値
)
-- Step 3: LLMで回答生成
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'snowflake-arctic',
    CONCAT(
        'あなたは社内規定に詳しいアシスタントです。',
        '以下の社内文書を参考に、質問に日本語で回答してください。',
        '文書に記載のない情報は「規定に記載がありません」と答えてください。\n\n',
        '=== 参考文書 ===\n',
        context_text,
        '\n\n=== 質問 ===\n',
        $query_text
    )
) AS answer
FROM context_combined;
```

---

## ステップ 6: 再利用可能なストアドプロシージャ化

```sql
-- RAG検索ストアドプロシージャ
CREATE OR REPLACE PROCEDURE rag_search(
    query_text VARCHAR,
    top_k      NUMBER DEFAULT 3,
    threshold  FLOAT DEFAULT 0.5,
    model_name VARCHAR DEFAULT 'snowflake-arctic'
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    result VARCHAR;
BEGIN
    WITH query_vec AS (
        SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
            'snowflake-arctic-embed-m',
            :query_text
        ) AS vec
    ),
    top_chunks AS (
        SELECT
            c.doc_name,
            c.chunk_text,
            VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) AS similarity_score
        FROM document_chunks_vec c, query_vec q
        WHERE VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) >= :threshold
        ORDER BY similarity_score DESC
        LIMIT :top_k
    ),
    context_combined AS (
        SELECT
            CASE
                WHEN COUNT(*) = 0 THEN NULL
                ELSE LISTAGG(
                    '【出典: ' || doc_name || '】\n' || chunk_text,
                    '\n\n'
                )
            END AS context_text
        FROM top_chunks
    )
    SELECT CASE
        WHEN context_text IS NULL
        THEN '関連する文書が見つかりませんでした。'
        ELSE SNOWFLAKE.CORTEX.COMPLETE(
            :model_name,
            CONCAT(
                'あなたは社内規定に詳しいアシスタントです。',
                '以下の社内文書を参考に、質問に日本語で回答してください。',
                '文書に記載のない情報は「規定に記載がありません」と答えてください。\n\n',
                '=== 参考文書 ===\n',
                context_text,
                '\n\n=== 質問 ===\n',
                :query_text
            )
        )
    END INTO result
    FROM context_combined;

    RETURN result;
END;
$$;

-- プロシージャのテスト
CALL rag_search('経費精算の締め切りはいつですか？');
CALL rag_search('パスワードの要件を教えてください', 3, 0.4, 'llama3.1-70b');
CALL rag_search('存在しないトピックについて質問する', 3, 0.7);
```

---

## ステップ 7: 出典付き回答（回答根拠の明示）

```sql
-- 出典情報付きの回答生成
SET query_text = 'セキュリティに関するルールを教えてください';

WITH query_vec AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
        'snowflake-arctic-embed-m',
        $query_text
    ) AS vec
),
top_chunks AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec) DESC) AS rank,
        c.doc_name,
        c.chunk_text,
        ROUND(VECTOR_COSINE_SIMILARITY(c.chunk_vec, q.vec), 4) AS score
    FROM document_chunks_vec c, query_vec q
    ORDER BY score DESC
    LIMIT 3
),
context_with_refs AS (
    SELECT
        LISTAGG(
            '[' || rank || '] 【' || doc_name || '】: ' || chunk_text,
            '\n\n'
        ) AS context_text,
        LISTAGG(
            '[' || rank || '] ' || doc_name || ' (スコア: ' || score || ')',
            '\n'
        ) AS sources_text
    FROM top_chunks
)
SELECT
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        CONCAT(
            '以下の文書[1][2][3]を参考に質問に答えてください。',
            '回答の各文には参照した文書番号を[1]のように明記してください。\n\n',
            context_text,
            '\n\n質問: ', $query_text
        )
    ) AS answer,
    sources_text AS sources
FROM context_with_refs;
```

---

## パフォーマンス最適化のヒント

```sql
-- ベクトルカラムにインデックスを活用（Cortex Search Service が推奨）
-- 大量データの場合は Cortex Search Service を使用（次章参照）

-- バッチ処理での埋め込み生成（効率化）
-- Snowflakeのマルチクラスタウェアハウスで並列処理
ALTER WAREHOUSE COMPUTE_WH SET
    MAX_CLUSTER_COUNT = 3
    MIN_CLUSTER_COUNT = 1
    SCALING_POLICY = 'ECONOMY';

-- 埋め込みの定期更新（新しいドキュメントの追加）
CREATE OR REPLACE TASK update_embeddings_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 2 * * * Asia/Tokyo'  -- 毎日午前2時
AS
INSERT INTO document_chunks_vec
SELECT
    chunk_id,
    doc_id,
    doc_name,
    chunk_text,
    chunk_index,
    SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', chunk_text)
FROM document_chunks
WHERE chunk_id NOT IN (SELECT chunk_id FROM document_chunks_vec);

ALTER TASK update_embeddings_task RESUME;
```

---

## 次のステップ

- [Cortex Search の詳細](./03_cortex_search.md) — より高度な検索機能を活用
- [他サービスとの差別化](./05_differentiation.md) — ビジネス価値を最大化する
