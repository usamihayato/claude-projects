-- ============================================================
-- Cortex Analyst + Cortex Search ハイブリッド実装
-- 構造化データの数値回答 + 社内規定ドキュメント検索を統合
-- ============================================================
-- 前提:
--   - 05_stored_procedures.sql でプロシージャ定義済み
--   - Cortex Search Service（COMPANY_DOC_SEARCH）が存在すること
--     存在しない場合は Step 1 のコメントアウトを外して作成する
-- ============================================================

USE ROLE     ANALYST_USER;
USE DATABASE ANALYST_DEMO_DB;
USE SCHEMA   ANALYST_SCHEMA;
USE WAREHOUSE ANALYST_WH;

-- ============================================================
-- Step 1: Cortex Search Service の作成（ドキュメントがある場合）
-- cortex search_rag 側のサービスがある場合はそちらを参照してもよい
-- ============================================================

-- 社内規定ドキュメントテーブル（未作成の場合）
CREATE TABLE IF NOT EXISTS COMPANY_DOCUMENTS (
    DOC_ID      VARCHAR(20) NOT NULL,
    DOC_NAME    VARCHAR(200) NOT NULL,
    CATEGORY    VARCHAR(50) NOT NULL,
    CONTENT     VARCHAR NOT NULL
);

-- サンプルドキュメント（経費・有給規定）
INSERT INTO COMPANY_DOCUMENTS (DOC_ID, DOC_NAME, CATEGORY, CONTENT)
SELECT doc_id, doc_name, category, content
FROM VALUES
    ('D001', '経費精算規定', '経費',
     '経費精算規定 第1条 目的: 本規定は社員の業務上の経費精算手続きを定める。' ||
     '第2条 申請期限: 経費の申請は毎月末日までとする。翌月5日以降は受理しない。' ||
     '第3条 上限金額: 1件あたりの経費上限は10万円とする。10万円を超える場合は事前承認が必要。' ||
     '第4条 証憑: 領収書の添付が必須。領収書のない経費は受理しない。' ||
     '第5条 交通費: 新幹線はグリーン車不可。飛行機はエコノミークラスまで。'),
    ('D002', '年次有給休暇規定', '人事',
     '年次有給休暇規定 第1条 付与日数: 入社6ヶ月後に10日付与。以降1年ごとに1日加算（最大20日）。' ||
     '第2条 申請方法: 有給申請は取得希望日の3営業日前までに申請すること。' ||
     '第3条 時間単位有給: 1時間単位での取得が可能。1日を8時間換算。' ||
     '第4条 繰越: 当年未使用分は翌年に繰越可能（最大40日まで）。' ||
     '第5条 買取: 退職時に未使用分の買取は行わない。'),
    ('D003', '在宅勤務規定', '人事',
     '在宅勤務規定 第1条 対象者: 入社6ヶ月以上の正社員・契約社員。' ||
     '第2条 申請: 在宅勤務は前日18時までにチームリーダーの承認を得ること。' ||
     '第3条 頻度: 週最大3日まで在宅勤務可能。' ||
     '第4条 セキュリティ: 社外では会社支給PCのみ使用可。私物PCの業務利用は禁止。' ||
     '第5条 コアタイム: 在宅勤務時も10時〜15時はコアタイムとして応答必須。'),
    ('D004', '出張規定', '経費',
     '出張規定 第1条 事前申請: 出張は3営業日前までに出張申請書を提出すること。' ||
     '第2条 宿泊費上限: 国内出張の宿泊費上限は1泊15,000円（東京・大阪は20,000円）。' ||
     '第3条 日当: 国内出張は1日3,000円の日当を支給。日帰りは2,000円。' ||
     '第4条 海外出張: 海外出張は部長以上の承認が必要。旅券・ビザ費用は会社負担。' ||
     '第5条 精算期限: 出張精算は帰社後5営業日以内に行うこと。')
ON (DOC_ID);

-- Cortex Search Service の作成
CREATE OR REPLACE CORTEX SEARCH SERVICE ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH
    ON CONTENT
    ATTRIBUTES DOC_NAME, CATEGORY
    WAREHOUSE = ANALYST_WH
    TARGET_LAG = '1 HOUR'
    AS
    SELECT CONTENT, DOC_NAME, CATEGORY
    FROM COMPANY_DOCUMENTS;

-- ============================================================
-- Step 2: ハイブリッド検索プロシージャ（analyst + search）
-- ============================================================

CREATE OR REPLACE PROCEDURE analyst_rag_hybrid(question VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS $$
import _snowflake
import json

SEMANTIC_MODEL = '@ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE/03_semantic_model.yaml'
SEARCH_SERVICE = 'ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH'

def call_analyst(question: str) -> dict:
    """Cortex Analyst を呼び出して SQL を生成・実行する。"""
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {}, {},
        {
            "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
            "semantic_model_file": SEMANTIC_MODEL
        },
        None, 30000
    )
    resp_json = json.loads(response["content"])

    result = {"sql": "", "text": ""}
    for item in resp_json.get("message", {}).get("content", []):
        if item.get("type") == "sql":
            result["sql"] = item["statement"]
        elif item.get("type") == "text":
            result["text"] = item.get("text", "")
    return result

def run(session, question: str) -> str:
    # 1. Cortex Analyst で SQL 生成 + 実行
    analyst_result = call_analyst(question)
    structured_context = ""

    if analyst_result["sql"]:
        try:
            df = session.sql(analyst_result["sql"]).limit(20).to_pandas()
            structured_context = f"【構造化データ集計結果】\n{df.to_string(index=False)}"
        except Exception as e:
            structured_context = f"【構造化データ】取得エラー: {str(e)}"
    else:
        structured_context = "【構造化データ】該当データなし"

    # 2. Cortex Search でドキュメント検索
    q_escaped = question.replace("'", "''")
    search_resp = session.sql(f"""
        SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            '{SEARCH_SERVICE}',
            OBJECT_CONSTRUCT(
                'query',   '{q_escaped}',
                'columns', ARRAY_CONSTRUCT('content', 'doc_name'),
                'limit',   3
            )
        )::VARCHAR AS result
    """).collect()[0][0]

    search_json = json.loads(search_resp)
    doc_context = "【関連ドキュメント】\n"
    for r in search_json.get("results", []):
        doc_name = r.get("doc_name", "不明")
        content  = r.get("content", "")[:400]
        doc_context += f"--- {doc_name} ---\n{content}\n\n"

    # 3. 統合プロンプトで LLM に回答生成を依頼
    prompt = f"""あなたは社内のデータアシスタントです。
以下の情報を元に、ユーザーの質問に日本語で回答してください。
情報がない部分は「不明」と回答し、推測で回答しないでください。

{structured_context}

{doc_context}

【ユーザーの質問】
{question}
"""

    answer = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic-instruct', $1) AS answer",
        [prompt]
    ).collect()[0][0]

    return answer
$$;

-- ============================================================
-- Step 3: 実行サンプル
-- ============================================================

-- サンプル 1: 構造化データ（売上）+ ドキュメント（経費規定）
CALL analyst_rag_hybrid('今月の経費関連カテゴリの売上状況と、経費申請期限を教えて');

-- サンプル 2: 構造化データ（注文件数）+ ドキュメント（出張規定）
CALL analyst_rag_hybrid('今年の売上上位商品と、出張時の経費申請ルールを教えて');

-- サンプル 3: ドキュメント中心
CALL analyst_rag_hybrid('在宅勤務は週何日まで可能か？');

-- サンプル 4: 構造化データ中心
CALL analyst_rag_hybrid('カテゴリ別の売上ランキングを教えて');

-- ============================================================
-- Step 4: Cortex Analyst のみ vs ハイブリッド の比較
-- ============================================================

-- Cortex Analyst のみ（数値は正確だがドキュメント情報なし）
CALL analyst_execute('先月の売上合計は？');

-- ハイブリッド（数値 + ドキュメント補足）
CALL analyst_rag_hybrid('先月の売上合計と、売上に関する社内規定があれば教えて');

-- ============================================================
-- Step 5: Cortex Search のみ（ドキュメント検索ベースライン）
-- ============================================================

SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH',
    OBJECT_CONSTRUCT(
        'query',   '経費申請 期限',
        'columns', ARRAY_CONSTRUCT('content', 'doc_name', 'category'),
        'limit',   2
    )
);
