# Cortex Analyst 概要

## Cortex Analyst とは

Snowflake Cortex Analyst は、**自然言語で書いた質問を SQL に変換し、構造化データに対して直接回答を返す**フルマネージドの Text-to-SQL サービスです。

> 「先月の売上上位 5 商品を教えて」と入力するだけで、Snowflake が SQL を生成・実行し、集計結果を返します。

データエンジニアが SQL を書かなくても、ビジネスユーザーが自分でデータを分析できるようになることが目標です。

---

## Cortex Search との違い

| 比較軸 | Cortex Analyst | Cortex Search (RAG) |
|---|---|---|
| 対象データ | **構造化データ**（テーブル・列・数値） | **非構造化データ**（ドキュメント・テキスト） |
| 入力 | 自然言語の質問 | 自然言語の質問 |
| 処理内容 | 自然言語 → SQL 生成 → 実行 | テキスト検索 → 関連文書取得 → LLM 回答 |
| 回答の根拠 | Snowflake テーブルのデータ | ドキュメント（PDF・テキスト等） |
| 向いている質問 | 「何件？」「合計は？」「ランキングは？」 | 「規定によると？」「マニュアルには？」 |
| セマンティックモデル | **必須**（YAML で定義） | 不要 |

### 使い分けのイメージ

```
「昨年の営業部の経費総額は？」  →  Cortex Analyst（数値集計）
「経費精算の申請方法を教えて」  →  Cortex Search（規定ドキュメント検索）
```

---

## アーキテクチャ

```
ユーザーの質問（自然言語）
        │
        ▼
┌─────────────────────────────────────────┐
│           Cortex Analyst                │
│                                         │
│  ① 質問を解析                           │
│       │                                 │
│       ▼                                 │
│  ② セマンティックモデル（YAML）を参照    │◄── テーブル定義・指標・ビジネス用語
│       │                                 │
│       ▼                                 │
│  ③ SQL を生成                           │
│       │                                 │
│       ▼                                 │
│  ④ Snowflake テーブルを実行             │◄── 実際のデータ
│       │                                 │
│       ▼                                 │
│  ⑤ 結果を自然言語で整形                 │
└─────────────────────────────────────────┘
        │
        ▼
   回答 ＋ 生成 SQL（透明性）
```

### 重要なポイント

- **セマンティックモデルが鍵**: テーブルの意味・指標の計算方法・テーブル間の関係を YAML で定義することで、LLM が正確な SQL を生成できるようになる
- **SQL の透明性**: 生成された SQL が必ず返ってくるため、回答の根拠を確認できる
- **データはSnowflake内**: クエリ実行は Snowflake 内で完結し、データが外部に出ない

---

## 主なユースケース

### 1. BI セルフサービス
経営者や営業担当者が自分でデータを分析できる。SQL スキル不要。

```
「今月の売上は先月比何%増加した？」
「地域別・商品カテゴリ別の売上ランキングを見せて」
```

### 2. 経営ダッシュボードへの組み込み
定型レポートに加え、「その場でアドホック質問」ができるようになる。

```
「このグラフの数字が低い原因は何？」
「去年の同じ時期と比較して」
```

### 3. データカタログ・データ品質チェック
エンジニアが手作業で SQL を書かなくても、データの概況を素早く確認できる。

```
「NULL が多い列はどれ？」
「先月登録した新規顧客数は？」
```

---

## クイックスタート

最もシンプルな Cortex Analyst の呼び出し（Python ストアドプロシージャ経由）:

```python
import snowflake.snowpark as snowpark
import _snowflake
import json

def ask_analyst(session, question: str, model_stage: str, model_file: str) -> str:
    """
    Cortex Analyst に自然言語で質問し、生成 SQL と回答を返す。
    """
    response = _snowflake.send_snow_api_request(
        "POST",
        "/api/v2/cortex/analyst/message",
        {},
        {},
        {
            "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
            "semantic_model_file": f"@{model_stage}/{model_file}"
        },
        None,
        10000  # タイムアウト（ミリ秒）
    )
    
    resp_json = json.loads(response["content"])
    
    # 生成されたSQL と テキスト回答を返す
    result = {"sql": "", "text": ""}
    for item in resp_json.get("message", {}).get("content", []):
        if item["type"] == "sql":
            result["sql"] = item["statement"]
        elif item["type"] == "text":
            result["text"] = item["text"]
    
    return json.dumps(result, ensure_ascii=False)
$$;
```

呼び出し例:
```sql
-- セマンティックモデルをステージにアップロード後
PUT file:///path/to/sales_model.yaml @ANALYST_STAGE AUTO_COMPRESS=FALSE;

-- 自然言語で質問
CALL ask_analyst(
    '先月の売上上位5商品を教えて',
    'ANALYST_STAGE',
    'sales_model.yaml'
);
```

---

## Cortex Analyst の制約・注意点

| 項目 | 内容 |
|---|---|
| データ形式 | 構造化データ（テーブル）のみ。PDFや自由テキストは扱えない |
| セマンティックモデル | 必ず YAML で定義が必要。未定義のテーブルは参照不可 |
| 複雑な分析 | 高度な統計・機械学習は対象外（通常の集計・フィルタが中心） |
| 対応リージョン | Snowflake のサービスリージョンによって利用可否が異なる |
| コスト | Cortex Analyst の呼び出しにはクレジット消費が発生 |

---

## 次のステップ

- [02_semantic_model_basics.md](02_semantic_model_basics.md) — セマンティックモデルの構造を学ぶ
- [03_analyst_sample.md](03_analyst_sample.md) — 実際に動かしてみる
