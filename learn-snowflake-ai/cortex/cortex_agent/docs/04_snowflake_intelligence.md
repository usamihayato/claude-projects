# Snowflake Intelligence

## Snowflake Intelligence とは

Snowflake Intelligence は、**Cortex Agent の上に Snowflake がフロントエンド UI を被せたマネージドサービス**です。データソースを登録するだけで、コーディング不要のチャット型分析 UI が手に入ります。

> 「Cortex Agent = エンジン」  
> 「Snowflake Intelligence = エンジン ＋ 完成した車体」

---

## Cortex Search との統合について（重要）

「Intelligence は Cortex Search に対応していない」と思われがちですが、**正確には以下の通りです。**

| 接続方式 | Cortex Search 対応 | 説明 |
|---|---|---|
| **Semantic Model 直接接続** | ❌ 不可 | Cortex Analyst のみ動作。ドキュメント検索は対象外 |
| **Cortex Agent 経由** | ✅ 可能 | Agent のツールとして Cortex Search を組み込める |

```
【誤解】
Intelligence → Cortex Search（直接接続） … ❌

【正しいアーキテクチャ】
Intelligence → Cortex Agent → Cortex Analyst（構造化データ）
                            → Cortex Search  （ドキュメント検索）
```

**つまり、Agent をデータソースとして登録すれば、Intelligence から Analyst + Search の統合が実現できます。**

---

## 2つの利用パターン

| パターン | 構成 | 向いているケース |
|---|---|---|
| **シンプル構成** | セマンティックモデル直接接続 | 数値データの質問応答のみ必要な場合 |
| **統合構成（推奨）** | Cortex Agent 経由（Analyst + Search） | データ分析 + 社内ドキュメント調査を統合したい場合 |

---

## Streamlit in Snowflake との比較

| 比較軸 | Snowflake Intelligence | Streamlit in Snowflake |
|---|---|---|
| セットアップ | エージェント設定を登録するだけ | Python でアプリを実装する |
| コーディング | **不要** | 必要 |
| UI | Snowflake 提供のチャット UI（洗練済み） | 自前実装（自由度高い） |
| グラフ表示 | 自動（棒・折れ線・テーブル等） | 自前で Altair 等を実装 |
| Cortex Search 統合 | ✅（Agent 経由で対応） | ✅（実装次第） |
| カスタマイズ | 限定的（システムプロンプトで調整） | **完全に自由** |
| エンドユーザー共有 | **簡単**（URL 共有・Snowsight から直接） | Streamlit デプロイが必要 |
| 向いている用途 | **BIセルフサービス・エンドユーザー向け** | 開発者デモ・社内ツール構築 |

---

## パターン 1: シンプル構成（セマンティックモデル直接接続）

数値データの Q&A のみ必要な場合の最小構成です。

### 手順（5分）

```
1. Snowsight > AI & ML > Intelligence
2. + Create Intelligence App → 名前入力 → Create
3. + Add Data Source
     Type: Semantic Model File
     Stage: ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE
     File: 03_semantic_model.yaml
4. Warehouse: ANALYST_WH → Publish
```

**質問例:**

```
・「月別の売上合計を教えて」
・「先月の売上上位5商品は？」
・「それをさらに地域別に分けて」（マルチターン）
```

---

## パターン 2: 統合構成（Cortex Agent 経由）← 推奨

Cortex Analyst（数値分析）と Cortex Search（ドキュメント検索）を統合したエージェントを Intelligence に登録します。

---

### Step 1: 前提リソースの確認

以下が作成済みであることを確認します。

```sql
-- ① セマンティックモデルがステージに存在すること
LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE;
-- → 03_semantic_model.yaml が表示されればOK

-- ② Cortex Search Service が存在すること
SHOW CORTEX SEARCH SERVICES IN SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA;
-- → COMPANY_DOC_SEARCH が表示されればOK
```

未作成の場合は以下を参照してください。
- セマンティックモデル: `../cortex_analyst/sql/03_semantic_model.yaml`
- Cortex Search: `../cortex_search_rag/sql/05_cortex_search_setup.sql` および `03_cortex_agent_demo.md` Step 1

---

### Step 2: Cortex Agent のオーケストレーション設計

Intelligence に登録するエージェントの動作を**システムプロンプト**で制御します。これが「Cortex Agent の細かいオーケストレーション設定」にあたります。

#### システムプロンプト（推奨テンプレート）

```
あなたはEC事業の売上分析と社内情報の調査を一体的に支援するビジネスアシスタントです。

## ツール使い分けのルール

### sales_analyst（Cortex Analyst）を使う場面
- 売上・注文件数・売上高などの数値を知りたい場合
- 商品・カテゴリ・期間・地域などでデータを絞り込みたい場合
- 前月比・前年比など時系列比較が必要な場合
- ランキング・集計・トレンド分析が必要な場合

### doc_search（Cortex Search）を使う場面
- キャンペーン・施策の背景や詳細を調べる場合
- 配送・物流・在庫に関する社内報告や規定を確認する場合
- 売上数値の原因・背景を社内ドキュメントで裏付けたい場合

### 両方を組み合わせて使う場面
- 「なぜ売上が下がったか」のように数値と原因の両方が必要な場合
- 施策の効果を定量的に検証したい場合
- データ分析の結果に対して背景・経緯のドキュメントを追加提示したい場合

## 回答スタイル
- 必ず日本語で回答する
- 数値を引用する際は期間・集計軸を明示する（例:「2024年11月のカテゴリ別売上では…」）
- ドキュメントを引用する際はドキュメント名を明示する（例:「東日本エリア配送遅延報告によると…」）
- 複数の情報源を組み合わせた場合は、データとドキュメントの根拠をそれぞれ分けて示す
- 「わかりません」と言う前に必ず両方のツールで検索を試みる
```

#### ツール選択ポリシー設定

| 設定項目 | 推奨値 | 理由 |
|---|---|---|
| `tool_choice` | `auto` | LLM が質問内容に応じて最適なツールを自律選択 |
| 複数ツール同時使用 | 許可 | 複合質問で Analyst + Search を並行実行できる |
| モデル | `claude-3-5-sonnet` または `llama3.1-70b` | 推論精度が高く、ツール選択の判断が安定する |

---

### Step 3: Intelligence にエージェントを登録する

#### 3-1. Intelligence アプリを作成

```
Snowsight > AI & ML > Intelligence > + Create Intelligence App

  App Name:    売上分析アシスタント（データ × ドキュメント統合）
  Description: 売上データと社内ドキュメントを横断して分析できます
```

#### 3-2. データソースとして Cortex Agent を追加

`+ Add Data Source` をクリックし、タイプを **Agent** に選択します。

```
Add Data Source
┌────────────────────────────────────────────────────────────────┐
│  Source Type:                                                  │
│  ○ Semantic Model File (YAML)                                  │
│  ● Agent  ← これを選択                                         │
│                                                                │
│  ── Agent の設定 ──────────────────────────────────────────    │
│                                                                │
│  Model: [claude-3-5-sonnet          ▼]                        │
│                                                                │
│  System Prompt:                                               │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ あなたはEC事業の売上分析と社内情報の調査を一体的に       │ │
│  │ 支援するビジネスアシスタントです。                       │ │
│  │                                                          │ │
│  │ ## ツール使い分けのルール                                │ │
│  │ （上記のシステムプロンプトをここに入力）                 │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  ── ツール ────────────────────────────────────────────────    │
│                                                                │
│  + Add Tool                                                    │
│    ┌─ Tool 1: Cortex Analyst ──────────────────────────────┐  │
│    │ Name: sales_analyst                                   │  │
│    │ Type: cortex_analyst_text_to_sql                      │  │
│    │ Semantic Model:                                       │  │
│    │   ANALYST_DEMO_DB.ANALYST_SCHEMA                      │  │
│    │   .SEMANTIC_MODEL_STAGE/03_semantic_model.yaml        │  │
│    └───────────────────────────────────────────────────────┘  │
│    ┌─ Tool 2: Cortex Search ───────────────────────────────┐  │
│    │ Name: doc_search                                      │  │
│    │ Type: cortex_search_service                           │  │
│    │ Service:                                              │  │
│    │   ANALYST_DEMO_DB.ANALYST_SCHEMA.COMPANY_DOC_SEARCH   │  │
│    └───────────────────────────────────────────────────────┘  │
│                                                                │
│  Warehouse: [ANALYST_WH            ▼]                         │
│                                                                │
│                          [ Cancel ] [ Add ]                    │
└────────────────────────────────────────────────────────────────┘
```

#### 3-3. 公開

`Publish` をクリックするとアプリが有効化されます。

```
共有方法:
  - Snowsight 上でチームメンバーに直接共有
  - URL をコピーして配布（Snowflake アカウントへのログインは必要）
```

---

### Step 4: 画面構成と動作確認

登録後の Intelligence 画面:

```
┌─────────────────────────────────────────────────────────────────┐
│  売上分析アシスタント（データ × ドキュメント統合）  [Snowflake] │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  どのようなことをお手伝いできますか？                           │
│                                                                 │
│  おすすめの質問:                                                │
│  ・先月の売上が最も低下したカテゴリは？                         │
│  ・家電カテゴリの売上低下の原因を調べて                         │
│  ・先月の上位商品と、それに関する社内施策を合わせて教えて       │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  ユーザー: 家電カテゴリの売上低下の原因を調べて                 │
│                                                                 │
│  AI: 家電カテゴリの売上は先月比 -15.3% でした。                 │
│      ┌──────────────────────────────────────────────────────┐  │
│      │  [折れ線グラフ: 家電カテゴリ月別売上推移]            │  │
│      └──────────────────────────────────────────────────────┘  │
│                                                                 │
│      社内ドキュメントによると、以下の2点が主因です:             │
│                                                                 │
│      1. キャンペーン対象外製品の影響                            │
│         （出典: 2024年Q4 家電カテゴリ施策）                     │
│                                                                 │
│      2. 東日本エリアでの配送遅延（平均2日→4日）                 │
│         （出典: 東日本エリア配送遅延報告）                      │
│                                                                 │
│      ▶ 使用ツール: sales_analyst, doc_search                    │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  質問を入力...                                      [ 送信 ]   │
└─────────────────────────────────────────────────────────────────┘
```

---

## デモシナリオ（5分でできる統合デモ）

前提: セマンティックモデル YAML + Cortex Search Service が作成済みの状態

```
1. Snowsight > AI & ML > Intelligence
2. + Create Intelligence App → 名前入力 → Create
3. + Add Data Source → Type: Agent を選択
4. システムプロンプトを入力（上記テンプレートをコピー）
5. ツール追加: sales_analyst（Analyst）+ doc_search（Search）
6. ウェアハウスを設定 → Publish

所要時間: 約5〜10分（システムプロンプト入力込み）
```

**デモで見せたい質問の流れ:**

```
質問 1: 「月別の売上合計を教えて」
  → sales_analyst が動作 → 折れ線グラフでトレンド表示
  ※ Cortex Analyst だけが呼ばれることを確認

質問 2: 「東日本エリアの配送に関する社内報告を教えて」
  → doc_search が動作 → 配送遅延報告ドキュメントを引用
  ※ Cortex Search だけが呼ばれることを確認

質問 3: 「先月の家電カテゴリの売上低下の原因を調べて」
  → sales_analyst + doc_search の両方が動作
  ※ 2つのツールが組み合わさることをアピール

質問 4: 「2025年Q1の重点施策と、それに連動した売上計画は？」
  → doc_search で施策ドキュメント取得
  → sales_analyst で関連カテゴリのデータ取得
  ※ 複合タスクの自律解決を見せる
```

---

## できること・できないこと

### できること

- 自然言語 → SQL 生成 → 結果表示（Cortex Analyst の全機能）
- **Cortex Search によるドキュメント検索（Agent 経由）**← 追加
- グラフの自動選択・表示（棒・折れ線・テーブル）
- マルチターン会話
- SQL の透明性表示（`使用ツールを見る` の展開）
- システムプロンプトによるオーケストレーション制御
- Verified Queries の活用

### できないこと・制限

- UI デザインのカスタマイズ（ロゴ・色・レイアウト変更不可）
- Streamlit のような独自ロジック（承認フロー・通知など）の組み込み
- Cortex Search の **直接接続**（Agent 経由なら可）
- アプリの埋め込み（外部サイトへの iframe 埋め込みは非対応）

---

## 4サービスの使い分けまとめ（更新版）

| シナリオ | 推奨 |
|---|---|
| 今すぐデモしたい（数値データのみ） | **Snowflake Intelligence（シンプル構成）** |
| 数値データ + 社内ドキュメントを統合したい | **Snowflake Intelligence（Agent 構成）** |
| セマンティックモデルを GUI で作りたい | **Snowsight Semantic Models** |
| 自社ブランドのチャット UI が欲しい | Streamlit in Snowflake |
| 承認フローや通知などの独自ロジックが必要 | Streamlit in Snowflake |
| バックエンド API として Cortex Agent を使いたい | Cortex Agent REST API 直接呼び出し |

---

## 関連ドキュメント

- [02_cortex_agent.md](02_cortex_agent.md) — Cortex Agent の REST API 仕様・ツール定義
- [03_cortex_agent_demo.md](03_cortex_agent_demo.md) — Streamlit でのデモ実装（コーディング版）
- [09_snowsight_semantic_model.md](../cortex_analyst/docs/09_snowsight_semantic_model.md) — セマンティックモデルの GUI 作成手順
