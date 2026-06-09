"""
Cortex Agent 評価自動実行スクリプト
難易度別（L1→L2→L3）にテストケースを実行し、結果をT_EVAL_RESULTSに記録する。

必要パッケージ:
    pip install snowflake-connector-python

使い方:
    python evaluate_agent.py --tool_type hybrid
    python evaluate_agent.py --tool_type search_only
    python evaluate_agent.py --tool_type hybrid --level 1   # L1のみ実行

接続情報は環境変数で渡す:
    export SF_ACCOUNT=xxx.ap-northeast-1.aws
    export SF_USER=your_user
    export SF_PASSWORD=your_password   # またはキーペア認証
    export SF_DATABASE=YOUR_DB
    export SF_SCHEMA=YOUR_SCHEMA
    export SF_WAREHOUSE=YOUR_WH
"""

import argparse
import json
import os
import sys
import time

import snowflake.connector

# ============================================================
# 接続設定（環境変数から取得）
# ============================================================
SF_CONFIG = {
    "account":   os.environ.get("SF_ACCOUNT"),
    "user":      os.environ.get("SF_USER"),
    "password":  os.environ.get("SF_PASSWORD"),
    "database":  os.environ.get("SF_DATABASE"),
    "schema":    os.environ.get("SF_SCHEMA"),
    "warehouse": os.environ.get("SF_WAREHOUSE"),
}

# ============================================================
# 難易度別合格基準
# ============================================================
PASS_CRITERIA = {
    1: {"accuracy_pct": 85.0, "relevance_score": 4.0, "tool_match_pct": None},
    2: {"accuracy_pct": 80.0, "relevance_score": 3.5, "tool_match_pct": 90.0},
    3: {"accuracy_pct": 70.0, "relevance_score": 3.0, "tool_match_pct": 85.0},
}

# ============================================================
# テストケース定義
# ============================================================
# expected: 影響調査(A/B)の場合は期待するジョブ名・ファイル名のリスト
#           解説(C/D)の場合は None（人手評価のため）
#           複合(E)の場合は None（人手評価のため）
# expected_tools: エージェントが使うべきツール名のリスト（順序あり）

TEST_CASES = [
    # --------------------------------------------------
    # L1 基礎
    # --------------------------------------------------
    {
        "id": "A-01", "category": "A", "difficulty_level": 1,
        "question": "受注テーブルを使用しているジョブをすべて教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,  # 実環境の正解データを設定してください
    },
    {
        "id": "A-02", "category": "A", "difficulty_level": 1,
        "question": "受注テーブルを更新（UPDATE）しているプログラムは？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-03", "category": "A", "difficulty_level": 1,
        "question": "受注テーブルに対してINSERTしているジョブを教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-04", "category": "A", "difficulty_level": 1,
        "question": "受注テーブルをDELETEしているジョブは？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-05", "category": "A", "difficulty_level": 1,
        "question": "JOB_ORDER_001が参照しているテーブル一覧を教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-06", "category": "A", "difficulty_level": 1,
        "question": "受注処理ネットに含まれるジョブをすべて教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-08", "category": "A", "difficulty_level": 1,
        "question": "ファイル出力が発生する機能はどれですか？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-09", "category": "A", "difficulty_level": 1,
        "question": "CSVファイルを取り込んでいるジョブを教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "A-10", "category": "A", "difficulty_level": 1,
        "question": "order_insert.sqlを実行しているジョブ名を教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "C-01", "category": "C", "difficulty_level": 1,
        "question": "order_insert.sqlはどんな処理をしているプログラムですか？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-04", "category": "C", "difficulty_level": 1,
        "question": "order_insert.sqlが参照しているテーブルはどれですか？（コードから教えて）",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-06", "category": "C", "difficulty_level": 1,
        "question": "order_insert.sqlの処理を新人向けに分かりやすく説明してください",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-10", "category": "C", "difficulty_level": 1,
        "question": "order_insert.sqlの概要をまとめてください",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    # --------------------------------------------------
    # L2 応用
    # --------------------------------------------------
    {
        "id": "A-07", "category": "A", "difficulty_level": 2,
        "question": "受注処理モジュールに含まれる機能の一覧を教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "B-01", "category": "B", "difficulty_level": 2,
        "question": "受注テーブルをUPDATEかつDELETEしているプログラムは？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "B-02", "category": "B", "difficulty_level": 2,
        "question": "受注処理モジュールで受注テーブルを参照しているジョブは？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "B-03", "category": "B", "difficulty_level": 2,
        "question": "CRUDのいずれかの操作がある機能をテーブル別に集計して",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "B-04", "category": "B", "difficulty_level": 2,
        "question": "ファイル出力とファイル取り込みの両方がある機能は？",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "C-02", "category": "C", "difficulty_level": 2,
        "question": "受注処理モジュールの処理内容を教えてください",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-03", "category": "C", "difficulty_level": 2,
        "question": "受注登録機能の処理フローを順を追って説明してください",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-05", "category": "C", "difficulty_level": 2,
        "question": "受注取り込みバッチはどんなデータを処理していますか？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-07", "category": "C", "difficulty_level": 2,
        "question": "order_insert.sqlの中で最も重要な処理は何ですか？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-08", "category": "C", "difficulty_level": 2,
        "question": "受注登録機能はどのような条件で動作しますか？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "C-09", "category": "C", "difficulty_level": 2,
        "question": "受注処理モジュールの処理で注意すべき点はありますか？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "D-01", "category": "D", "difficulty_level": 2,
        "question": "受注取り込みバッチが異常終了した場合に確認すべき箇所を教えて",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "D-02", "category": "D", "difficulty_level": 2,
        "question": "order_insert.sqlでデータが0件になる原因として考えられるものは？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "E-01", "category": "E", "difficulty_level": 2,
        "question": "受注テーブルを更新しているジョブのソースコードを解説して",
        "expected_tools": ["impact_analysis_tool", "source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "E-02", "category": "E", "difficulty_level": 2,
        "question": "受注テーブルへのCRUDをしているプログラムのうち、削除処理の処理内容を教えて",
        "expected_tools": ["impact_analysis_tool", "source_code_search_tool"],
        "expected": None,
    },
    # --------------------------------------------------
    # L3 発展
    # --------------------------------------------------
    {
        "id": "B-05", "category": "B", "difficulty_level": 3,
        "question": "受注テーブルを操作しているジョブのジョブネット名も教えて",
        "expected_tools": ["impact_analysis_tool"],
        "expected": None,
    },
    {
        "id": "D-03", "category": "D", "difficulty_level": 3,
        "question": "受注テーブルのデータが想定外に削除される原因を調べて",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "D-04", "category": "D", "difficulty_level": 3,
        "question": "受注登録機能でタイムアウトが発生する可能性がある箇所は？",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "D-05", "category": "D", "difficulty_level": 3,
        "question": "受注取り込みバッチの実行後にデータ不整合が起きた。原因を探して",
        "expected_tools": ["source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "E-03", "category": "E", "difficulty_level": 3,
        "question": "受注登録機能を担当するジョブを教えて、処理概要も教えて",
        "expected_tools": ["impact_analysis_tool", "source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "E-04", "category": "E", "difficulty_level": 3,
        "question": "受注取り込みバッチが落ちた。まず影響範囲を調べ、次にソースコードを確認したい",
        "expected_tools": ["impact_analysis_tool", "source_code_search_tool"],
        "expected": None,
    },
    {
        "id": "E-05", "category": "E", "difficulty_level": 3,
        "question": "受注テーブルを参照しているジョブ一覧と、そのうち最も複雑なプログラムの解説をして",
        "expected_tools": ["impact_analysis_tool", "source_code_search_tool"],
        "expected": None,
    },
]

# ============================================================
# Snowflake 接続
# ============================================================

def get_connection():
    missing = [k for k, v in SF_CONFIG.items() if not v]
    if missing:
        sys.exit(f"[ERROR] 環境変数が未設定です: {missing}")
    return snowflake.connector.connect(**SF_CONFIG)


# ============================================================
# エージェント呼び出し（SP_CHATBOT_AGENTを使用）
# ============================================================

def call_agent(conn, question: str) -> dict:
    """
    SP_CHATBOT_AGENT ストアドプロシージャを呼び出す。
    戻り値: {"answer": str, "used_tools": list[str]}
    """
    cur = conn.cursor()
    try:
        cur.execute(
            "CALL SP_CHATBOT_AGENT(%s, PARSE_JSON('[]'))",
            (question,)
        )
        row = cur.fetchone()
        result = json.loads(row[0]) if row else {}
        return {
            "answer":     result.get("answer", ""),
            "used_tools": result.get("used_tools", []),
        }
    finally:
        cur.close()


# ============================================================
# 結果をT_EVAL_RESULTSに記録
# ============================================================

def insert_result(conn, case: dict, tool_type: str,
                  answer: str, used_tools: list,
                  response_sec: float):
    """評価結果をT_EVAL_RESULTSに1件INSERTする"""
    expected_tools = case.get("expected_tools", [])

    # ツール選択が期待どおりか（順序は問わず、すべてのツールが使われているか）
    tool_match = all(t in used_tools for t in expected_tools)

    # 影響調査（A/B）の正解判定は expected が設定されている場合のみ自動判定
    # 設定されていない場合は None（人手評価待ち）
    is_correct = None
    if case.get("expected") is not None:
        answer_lower = answer.lower()
        is_correct = all(e.lower() in answer_lower
                        for e in case["expected"])

    cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO T_EVAL_RESULTS
                (test_case_id, category, difficulty_level,
                 question, tool_type, used_tool,
                 answer, expected, is_correct, tool_match, response_sec)
            VALUES
                (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            case["id"],
            case["category"],
            case["difficulty_level"],
            case["question"],
            tool_type,
            json.dumps(used_tools, ensure_ascii=False),
            answer,
            json.dumps(case.get("expected"), ensure_ascii=False),
            is_correct,
            tool_match,
            response_sec,
        ))
    finally:
        cur.close()


# ============================================================
# 難易度別合格判定
# ============================================================

def calc_level_score(conn, tool_type: str, level: int) -> dict:
    """T_EVAL_RESULTSから指定レベルのスコアを集計して返す"""
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT
                AVG(CASE WHEN category IN ('A','B') AND is_correct IS NOT NULL
                         THEN CASE WHEN is_correct THEN 1.0 ELSE 0.0 END
                    END) * 100                                   AS accuracy_pct,
                AVG(CASE WHEN category IN ('C','D','E')
                         THEN relevance_score END)              AS avg_relevance,
                AVG(CASE WHEN tool_match IS NOT NULL
                         THEN CASE WHEN tool_match THEN 1.0 ELSE 0.0 END
                    END) * 100                                   AS tool_match_pct
            FROM T_EVAL_RESULTS
            WHERE difficulty_level = %s
              AND tool_type = %s
        """, (level, tool_type))
        row = cur.fetchone()
        return {
            "accuracy_pct":  round(row[0] or 0, 1),
            "avg_relevance": round(row[1] or 0, 2),
            "tool_match_pct": round(row[2] or 0, 1),
        }
    finally:
        cur.close()


def meets_criteria(level: int, score: dict) -> bool:
    """合格基準を満たしているか判定する"""
    criteria = PASS_CRITERIA[level]
    ok_accuracy = score["accuracy_pct"] >= criteria["accuracy_pct"]
    ok_relevance = score["avg_relevance"] >= criteria["relevance_score"]
    ok_tool = (criteria["tool_match_pct"] is None
               or score["tool_match_pct"] >= criteria["tool_match_pct"])
    return ok_accuracy and ok_relevance and ok_tool


# ============================================================
# メイン実行
# ============================================================

def run(tool_type: str, start_level: int):
    conn = get_connection()
    try:
        for level in [1, 2, 3]:
            if level < start_level:
                continue

            level_cases = [c for c in TEST_CASES
                           if c["difficulty_level"] == level]
            print(f"\n{'='*60}")
            print(f"  L{level} 評価開始  ({len(level_cases)}件 / tool_type={tool_type})")
            print(f"{'='*60}")

            for case in level_cases:
                print(f"  [{case['id']}] {case['question'][:40]}...")
                start = time.time()
                try:
                    result = call_agent(conn, case["question"])
                except Exception as e:
                    print(f"    [ERROR] {e}")
                    result = {"answer": f"ERROR: {e}", "used_tools": []}
                elapsed = round(time.time() - start, 2)

                insert_result(conn, case, tool_type,
                              result["answer"], result["used_tools"], elapsed)
                print(f"    ツール: {result['used_tools']}  ({elapsed}秒)")

            # 合格判定（C/D/Eのrelevance_scoreは人手入力後に再集計が必要）
            score = calc_level_score(conn, tool_type, level)
            passed = meets_criteria(level, score)

            print(f"\n  --- L{level} 結果 ---")
            print(f"  影響調査 正解率:    {score['accuracy_pct']}%"
                  f"  (基準: {PASS_CRITERIA[level]['accuracy_pct']}%)")
            print(f"  コード解説 スコア:  {score['avg_relevance']}"
                  f"  (基準: {PASS_CRITERIA[level]['relevance_score']}"
                  f"  ※人手評価前は0)")
            if PASS_CRITERIA[level]["tool_match_pct"]:
                print(f"  ツール選択精度:    {score['tool_match_pct']}%"
                      f"  (基準: {PASS_CRITERIA[level]['tool_match_pct']}%)")

            if passed:
                if level < 3:
                    print(f"\n  ✅ L{level} 合格 → L{level+1}へ進みます")
                else:
                    print(f"\n  ✅ L{level} 合格 → 全レベル完了")
            else:
                print(f"\n  ❌ L{level} 不合格 → セマンティックモデル・プロンプトを見直してください")
                print(f"     ※ C/D/Eカテゴリのrelevance_scoreは人手評価後に再実行してください")
                break

    finally:
        conn.close()


# ============================================================
# エントリポイント
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cortex Agent 評価実行スクリプト")
    parser.add_argument(
        "--tool_type",
        choices=["hybrid", "search_only"],
        required=True,
        help="比較タイプ: hybrid（Analyst+Search）/ search_only（Searchのみ）"
    )
    parser.add_argument(
        "--level",
        type=int,
        choices=[1, 2, 3],
        default=1,
        help="開始難易度レベル（デフォルト: 1）"
    )
    args = parser.parse_args()
    run(args.tool_type, args.level)
