# Snowflake Intelligence

## Snowflake Intelligence とは

Snowflake Intelligence は、**セマンティックモデルを渡すだけで、すぐに使えるチャット型データ分析 UI が手に入る**マネージドサービスです。

Cortex Analyst の機能をベースに、Snowflake がフロントエンド UI まで提供します。Streamlit アプリのコーディングは不要。

> 「Cortex Analyst = エンジン」  
> 「Snowflake Intelligence = エンジン ＋ 完成した車体」

---

## Streamlit in Snowflake との比較

| 比較軸 | Snowflake Intelligence | Streamlit in Snowflake |
|---|---|---|
| セットアップ | セマンティックモデルを登録するだけ | Python でアプリを実装する |
| コーディング | **不要** | 必要 |
| UI | Snowflake 提供のチャット UI（洗練済み） | 自前実装（自由度高い） |
| グラフ表示 | 自動（棒・折れ線・テーブル等） | 自前で Altair 等を実装 |
| カスタマイズ | 限定的 | **完全に自由** |
| 複数データソース統合 | ○（複数セマンティックモデルを統合可） | 実装次第 |
| エンドユーザー共有 | **簡単**（URL 共有・Snowsight から直接） | Streamlit デプロイが必要 |
| 向いている用途 | **BIセルフサービス・エンドユーザー向け** | 開発者デモ・社内ツール構築 |

### 結論: デモ用途なら Snowflake Intelligence が最速

- セマンティックモデルが既にあれば、**追加コードゼロでデモ可能**
- UI が洗練されているため、ビジネスユーザーへのプレゼンに最適
- Streamlit は「こういうアプリを自社開発できる」という開発者向けのアピールに使う

---

## セットアップ手順

### Step 1: Snowsight から Intelligence を開く

```
Snowsight サイドメニュー
  └── AI & ML
        └── Intelligence   ← ここをクリック
```

> 表示されない場合: アカウントの設定でプレビュー機能を有効化する、またはロールに適切な権限が必要。

---

### Step 2: Intelligence アプリを作成する

**`+ Create Intelligence App`** をクリック。

```
┌────────────────────────────────────────────────────┐
│  Create Intelligence App                           │
│                                                    │
│  App Name:  [売上分析アシスタント            ]     │
│  Description: [売上・商品・顧客データを      ]     │
│               [自然言語で分析できます         ]     │
│                                                    │
│                      [ Cancel ] [ Create ]         │
└────────────────────────────────────────────────────┘
```

---

### Step 3: セマンティックモデルを登録する

作成後、設定画面で **`+ Add Data Source`** をクリック。

```
Add Data Source
┌────────────────────────────────────────────────────┐
│  Source Type:                                      │
│  ● Semantic Model File （YAML）← 既存 YAML を使う │
│  ○ Semantic View                                   │
│                                                    │
│  Stage:   ANALYST_DEMO_DB.ANALYST_SCHEMA           │
│           .SEMANTIC_MODEL_STAGE                    │
│  File:    03_semantic_model.yaml                   │
│                                                    │
│                      [ Cancel ] [ Add ]            │
└────────────────────────────────────────────────────┘
```

`03_semantic_model.yaml`（既に作成済み）を選択して `Add`。

---

### Step 4: ウェアハウスを設定する

```
Settings > Compute
  Warehouse: ANALYST_WH
```

---

### Step 5: 公開・共有する

`Publish` をクリックするとアプリが有効化される。

```
共有方法:
  - Snowsight 上でチームメンバーに直接共有
  - URL をコピーして配布（Snowflake アカウントへのログインは必要）
```

---

## 画面構成

```
┌─────────────────────────────────────────────────────────────────┐
│  売上分析アシスタント                           [Snowflake]      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  どのようなことをお手伝いできますか？                           │
│                                                                 │
│  おすすめの質問:                                                │
│  ・先月の売上上位5商品は？                                      │
│  ・カテゴリ別の売上構成比を見せて                               │
│  ・東日本と西日本の売上推移を比較して                           │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  チャット履歴エリア                                             │
│                                                                 │
│  ユーザー: 先月の売上上位5商品は？                              │
│                                                                 │
│  AI: 先月の売上上位5商品をお知らせします。                      │
│      ┌────────────────────────────────────┐                    │
│      │  [棒グラフ自動表示]                │                    │
│      └────────────────────────────────────┘                    │
│      ┌─────────────────────────────────────────┐               │
│      │ 商品名          │ 売上     │ 件数       │               │
│      │ ノートPC Pro 15 │ 4,200千円│ 42        │               │
│      │ スマートフォン  │ 3,800千円│ 76        │               │
│      └─────────────────────────────────────────┘               │
│      ▶ SQL を見る                                               │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  質問を入力...                                      [ 送信 ]   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Snowflake Intelligence のできること・できないこと

### できること

- 自然言語 → SQL 生成 → 結果表示（Cortex Analyst の全機能）
- グラフの自動選択・表示（棒・折れ線・テーブル）
- マルチターン会話（「それをさらに地域別に分けて」が使える）
- 複数のセマンティックモデルをまたいだ質問
- SQL の透明性表示（`SQL を見る` の展開）
- Verified Queries の活用

### できないこと・制限

- UI デザインのカスタマイズ（ロゴ・色・レイアウト変更不可）
- Streamlit のような独自ロジック（承認フロー・通知など）の組み込み
- Cortex Search（ドキュメント検索）との統合（現時点では構造化データのみ）
- アプリの埋め込み（外部サイトへの iframe 埋め込みは非対応）

---

## デモシナリオ（5分でできる最小構成）

前提: `03_semantic_model.yaml` がステージにある状態

```
1. Snowsight > AI & ML > Intelligence
2. + Create Intelligence App → 名前入力 → Create
3. + Add Data Source → YAML ファイルを選択 → Add
4. ウェアハウスを設定 → Publish
5. チャットで質問してデモ（所要時間: 5分以内）
```

**デモで見せたい質問例:**

```
1. 「月別の売上合計を教えて」
   → 折れ線グラフでトレンドを表示

2. 「先月の売上上位5商品は？」
   → 棒グラフ + テーブルで表示

3. 「それをさらに地域別に分けて」（マルチターン）
   → 前の質問の文脈を引き継いで回答

4. 「法人と個人の売上比率は？」
   → 円グラフ or 棒グラフで表示

5. SQL を展開して「こういう SQL が自動生成されている」を見せる
```

---

## 3サービスの使い分けまとめ

| シナリオ | 推奨 |
|---|---|
| 今すぐデモしたい（コードなし） | **Snowflake Intelligence** |
| セマンティックモデルを GUI で作りたい | **Snowsight Semantic Models** |
| 自社ブランドのチャット UI が欲しい | Streamlit in Snowflake |
| Cortex Search（文書検索）と統合したい | Streamlit in Snowflake |
| 承認フローや通知などの独自ロジックが必要 | Streamlit in Snowflake |

---

## 関連ドキュメント

- [09_snowsight_semantic_model.md](../cortex_analyst/docs/09_snowsight_semantic_model.md) — セマンティックモデルの GUI 作成手順
- [04_demo_app.md](../cortex_analyst/docs/04_demo_app.md) — Streamlit での自前アプリ実装
- [07_analyst_rag_integration.md](../cortex_analyst/docs/07_analyst_rag_integration.md) — Cortex Search との統合（Streamlit 推奨）
