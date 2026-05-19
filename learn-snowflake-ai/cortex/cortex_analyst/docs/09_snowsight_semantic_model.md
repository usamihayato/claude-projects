# Snowsight GUI でセマンティックモデルを作成する

## 概要

Snowsight の `AI & ML > Semantic Models` を使えば、**YAML を手書きせずに GUI だけでセマンティックモデルを作成できます**。

- AI がテーブルのカラム・型を読み取り、description・measures・relationships を自動提案
- 生成された YAML をブラウザ上で編集・保存
- ステージへの PUT コマンドも不要（Save to Stage ボタン一発）

---

## 手順

### Step 1: Semantic Models 画面を開く

Snowsight のサイドメニューから:

```
AI & ML
  └── Semantic Models   ← ここをクリック
```

> `AI & ML` が見えない場合はロールに `CORTEX_USER` 権限が付与されているか確認する。

---

### Step 2: 新規モデルを作成する

画面右上の **`+ Semantic Model`** をクリック。

以下のダイアログが表示される:

```
┌────────────────────────────────────────┐
│  New Semantic Model                    │
│                                        │
│  Name: [sales_analyst_model      ]     │
│                                        │
│  Database:  [ANALYST_DEMO_DB     ]     │
│  Schema:    [ANALYST_SCHEMA      ]     │
│                                        │
│  Stage:     [SEMANTIC_MODEL_STAGE]     │
│  File name: [sales_analyst_model.yaml] │
│                                        │
│              [ Cancel ] [ Create ]     │
└────────────────────────────────────────┘
```

| 項目 | 入力値 |
|---|---|
| Name | `sales_analyst_model` |
| Database | `ANALYST_DEMO_DB` |
| Schema | `ANALYST_SCHEMA` |
| Stage | `SEMANTIC_MODEL_STAGE` |
| File name | `03_semantic_model.yaml`（既存ファイル名に合わせる場合） |

---

### Step 3: テーブルを追加する

`Create` 後、エディタ画面が開く。左ペインの **`+ Add Table`** をクリック。

```
┌──────────────────────────────────────────────────────────┐
│  Add Table                                               │
│                                                          │
│  Database > Schema > Table を選択:                       │
│                                                          │
│  ANALYST_DEMO_DB                                         │
│    ANALYST_SCHEMA                                        │
│      ☑ SALES_ORDERS                                      │
│      ☑ CUSTOMERS                                         │
│      ☑ PRODUCTS                                          │
│      ☑ SALES_TARGETS                                     │
│                                                          │
│                          [ Add Tables ]                  │
└──────────────────────────────────────────────────────────┘
```

4テーブルすべてにチェックを入れて `Add Tables` をクリック。

---

### Step 4: AI による自動生成を確認する

テーブルを追加すると、AI が自動で以下を生成する:

**自動生成される内容:**
- テーブルの `description`（テーブル名・カラム名から推測）
- 各カラムの `description`
- 数値カラムの `measures`（SUM・COUNT・AVG）
- DATE 型カラムの `time_dimensions`
- 主キー・外部キーに基づく `relationships`

**画面構成（3ペイン）:**

```
┌──────────────┬───────────────────────────────┬──────────────────────┐
│ テーブル一覧 │  エディタ（YAML プレビュー）  │  プレビューパネル    │
│              │                               │                      │
│ SALES_ORDERS │  name: sales_analyst_model    │  テーブル情報        │
│ CUSTOMERS    │  tables:                      │  カラム一覧          │
│ PRODUCTS     │    - name: sales_orders       │  Verified Queries    │
│ SALES_TARGETS│      description: ...         │                      │
│              │      columns: ...             │                      │
│  + Add Table │      measures: ...            │                      │
└──────────────┴───────────────────────────────┴──────────────────────┘
```

---

### Step 5: description・measures を日本語で編集する

AI 生成の description は英語になる場合があるため、日本語に書き直す。

**GUI 上の編集方法（左ペインのテーブルをクリック）:**

```
SALES_ORDERS テーブルの設定画面
┌─────────────────────────────────────────────────────┐
│ Table Description                                   │
│ [売上注文テーブル。1行が1注文を表す。              ]  │
│ [キャンセル注文（status = cancelled）は除外すること] │
│                                                     │
│ Columns                                             │
│  status   [注文ステータス。pending/confirmed/...  ] │
│  region   [販売地域。東日本/西日本/海外            ] │
│                                                     │
│ Measures                                            │
│  + Add Measure                                      │
│  total_sales  [SUM(CASE WHEN status != 'cancel...)] │
└─────────────────────────────────────────────────────┘
```

**編集ポイント（優先度順）:**

1. **コード値カラムの description** — `status`, `region`, `category` などに値の意味を追記
2. **measures の計算式** — キャンセル除外ロジック等のビジネスルールを反映
3. **テーブル全体の description** — 用途とデータの特性を記述

---

### Step 6: Relationships を確認・追加する

左ペイン下部の **`Relationships`** タブをクリック。

AI が主キー・外部キーを推測して自動的にリレーションを提案する。

```
Relationships タブ
┌─────────────────────────────────────────────────────┐
│ + Add Relationship                                  │
│                                                     │
│ ✓ sales_orders → customers                         │
│   customer_id = customer_id  [LEFT JOIN]            │
│                                                     │
│ ✓ sales_orders → products                          │
│   product_id = product_id    [LEFT JOIN]            │
└─────────────────────────────────────────────────────┘
```

自動生成されていない場合は `+ Add Relationship` から手動追加する。

---

### Step 7: Verified Queries を登録する

右ペインの **`Verified Queries`** タブから登録できる。

```
Verified Queries
┌─────────────────────────────────────────────────────┐
│ + Add Verified Query                                │
│                                                     │
│ Question: [先月の売上上位5商品は？              ]   │
│                                                     │
│ SQL:                                                │
│ SELECT product_name, SUM(total_amount) AS ...      │
│ FROM SALES_ORDERS                                   │
│ WHERE status != 'cancelled' AND ...                 │
│                                                     │
│ Name: [top5_products_last_month          ]          │
│                              [ Save Query ]         │
└─────────────────────────────────────────────────────┘
```

**Verified Queries のおすすめ登録方法:**
1. 左のチャット欄で質問を入力
2. Cortex Analyst が SQL を生成
3. 生成 SQL が正しければ `Save as Verified Query` ボタンで即座に登録

これが最も効率的な Verified Queries の蓄積方法。

---

### Step 8: モデルをテストする（インラインチャット）

エディタ画面の右下に**チャット入力欄**がある。

```
┌─────────────────────────────────────────────────┐
│  Try asking questions about your data...        │
│                                                 │
│  先月の売上上位5商品は？                        │
│  ──────────────────────────────────────         │
│  [生成 SQL が表示される]                        │
│                                                 │
│  [SQL が正しければ Save as Verified Query]      │
└─────────────────────────────────────────────────┘
```

質問して SQL が正しければ、そのまま Verified Queries に追加できる。精度が悪ければ description を修正して再テスト。

---

### Step 9: ステージに保存する

画面右上の **`Save`** をクリック。

```
Save Semantic Model
┌───────────────────────────────────────────────┐
│  Stage: @ANALYST_DEMO_DB.ANALYST_SCHEMA       │
│         .SEMANTIC_MODEL_STAGE                 │
│  File:  03_semantic_model.yaml                │
│                                               │
│                   [ Cancel ] [ Save ]         │
└───────────────────────────────────────────────┘
```

`Save` をクリックすると YAML がステージに自動 PUT される。
CLI や SnowSQL での `PUT` コマンドは不要。

---

## YAML 手書きとの比較

| 比較軸 | YAML 手書き | Snowsight GUI |
|---|---|---|
| セットアップ時間 | 30〜60 分（設計書を読んで書く） | **5〜10 分**（AI 自動生成 + 修正） |
| YAML 知識 | 必要 | **不要** |
| インラインテスト | なし（別途 CALL で確認） | **GUI 上でその場でテスト** |
| Verified Queries 登録 | YAML に手動追記 | **チャット結果からワンクリック** |
| バージョン管理 | Git 管理が容易 | Git 管理は別途必要（YAML をダウンロード） |
| デモ映え | コードベース | **GUI でビジュアルに説明できる** |

---

## デモ実施のポイント

Snowsight GUI でセマンティックモデルを作るデモは以下の順で流すと伝わりやすい:

1. 「テーブルを選ぶだけで AI が自動生成する」（Step 3〜4）
2. 「description を日本語で補正する」（Step 5）
3. 「チャットでテストしながら Verified Queries を蓄積する」（Step 7〜8）
4. 「Save ボタンで即デプロイ」（Step 9）

**所要時間: 10〜15 分でライブデモ可能。**

---

## 次のステップ

- [04_snowflake_intelligence.md](../../cortex_agent/docs/04_snowflake_intelligence.md) — さらに簡単な Snowflake Intelligence でのデモ方法
- [08_best_practices.md](08_best_practices.md) — セマンティックモデル品質向上のベストプラクティス
