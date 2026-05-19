# Cortex Analyst の差別化ポイント

## 比較対象

Cortex Analyst と競合する主なカテゴリ:

1. **従来の BI ツール**（Tableau / Power BI / Looker）
2. **外部 Text-to-SQL サービス**（OpenAI + LangChain など）
3. **Snowflake 内の他のアプローチ**（Cortex Search RAG / 手動 SQL）

---

## 1. 従来の BI ツールとの比較

| 比較軸 | Tableau / Power BI | Cortex Analyst |
|---|---|---|
| 質問方法 | ダッシュボードのフィルタ操作 | **自然言語**で自由に質問 |
| アドホック分析 | レポート開発が必要 | 追加開発なしで即時回答 |
| 必要スキル | BI ツール操作スキル | 日本語が書ければ使える |
| 未定義の集計軸 | 開発者に依頼 | その場で質問して即回答 |
| SQL の透明性 | 非表示（ブラックボックス） | **生成 SQL が見える** |
| データ移動 | ETL でデータを移動する場合あり | Snowflake のデータを直接参照 |
| セキュリティ | BI ツール独自の権限管理 | Snowflake の行レベルセキュリティが適用 |

### BI ツールが優位な場面
- 高度なビジュアライゼーション（地図、複雑なインタラクティブグラフ）
- 大規模ダッシュボードの共有・運用
- 定型レポートの自動配信

### Cortex Analyst が優位な場面
- 「急ぎで数字を確認したい」アドホック分析
- BI ツールに慣れていないユーザーへのセルフサービス提供
- 既存の Snowflake 投資をそのまま活用

---

## 2. 外部 Text-to-SQL（OpenAI + LangChain 等）との比較

| 比較軸 | OpenAI + LangChain | Cortex Analyst |
|---|---|---|
| データの場所 | **データがOpenAI に送信される可能性あり** | **データは Snowflake 内で処理完結** |
| セットアップ工数 | API キー、外部接続、プロキシ設定が必要 | Snowflake 内で完結、追加接続不要 |
| セマンティック定義 | プロンプトエンジニアリングで対応 | YAML で構造化された定義 |
| Snowflakeの権限 | 外部システムからのクエリ = 権限管理が複雑 | Snowflake のロール・RLS がそのまま適用 |
| 運用コスト | APIコスト + インフラコスト | Snowflake クレジット消費のみ |
| LLM モデル | GPT-4 / Claude など選択可 | Snowflake が管理するモデル |
| 監査ログ | 別途設定が必要 | Snowflake の ACCESS_HISTORY に残る |

### データガバナンスの観点

```
❌ 外部 LLM サービス経由の場合
  Snowflake テーブル定義 / カラム名 → 外部 API に送信
  ※ 機密性の高いスキーマ情報が外部に出る可能性

✅ Cortex Analyst の場合
  すべての処理が Snowflake VPC 内で完結
  テーブル定義・データが外部に出ない
```

---

## 3. Cortex Search RAG との使い分け

| 比較軸 | Cortex Search（RAG） | Cortex Analyst |
|---|---|---|
| 対象データ | **非構造化**（PDF・テキスト・マニュアル） | **構造化**（テーブル・数値・集計） |
| 回答の性質 | 文書からの抜粋・要約 | クエリ実行結果（数値・集計） |
| 質問パターン | 「〜とは？」「〜の方法は？」 | 「〜の件数は？」「〜の合計は？」 |
| 事前準備 | ドキュメントのアップロード・チャンキング | セマンティックモデル YAML の定義 |
| 適した業務 | FAQBot・規定検索・手順確認 | BIセルフサービス・KPI確認・集計 |

### 組み合わせが最強

```
「今月の経費超過申請件数と、経費精算の申請方法を一緒に教えて」

  ↓ 件数の部分
  Cortex Analyst → 経費テーブルを集計して件数を回答

  ↓ 申請方法の部分
  Cortex Search → 経費精算規定ドキュメントを検索して手順を回答
```

詳細は [07_analyst_rag_integration.md](07_analyst_rag_integration.md) を参照。

---

## 4. Snowflake の強み：3つの差別化戦略

### 戦略 1: データ主権の保証

```
Cortex Analyst を選ぶ最大の理由:
「データを外に出さずに AI 分析ができる」

・金融・医療・個人情報を含む企業でも導入しやすい
・データが Snowflake VPC を出ない
・テーブル定義（スキーマ情報）も外部に送信しない
```

### 戦略 2: 既存 DWH 資産のゼロコピー活用

```
従来の BI 導入 = データを別システムに複製する

Cortex Analyst = 既存の Snowflake テーブルにそのまま接続
  → 複製コスト ゼロ
  → データの鮮度が常に最新
  → 管理するシステムが増えない
```

### 戦略 3: Snowflake の行レベルセキュリティ（RLS）が自動適用

```sql
-- Snowflake で設定した RLS は Cortex Analyst でも有効
CREATE ROW ACCESS POLICY dept_rls ON sales_orders
AS (dept_code VARCHAR) RETURNS BOOLEAN ->
    dept_code = CURRENT_ROLE() OR CURRENT_ROLE() = 'ADMIN';

-- Cortex Analyst 経由での質問でも、
-- ユーザーが見えるデータのみが集計される
CALL analyst_execute('今月の売上合計は？');
-- → 営業部ユーザーなら営業部データのみ集計
-- → 管理者なら全データ集計
```

---

## まとめ: Cortex Analyst を選ぶべき状況

| 状況 | 推奨 |
|---|---|
| Snowflake DWH がある + 非エンジニアへの分析開放 | **Cortex Analyst** |
| 規制業種（金融・医療）でデータを外に出せない | **Cortex Analyst** |
| PDF・マニュアルへの Q&A が主目的 | Cortex Search (RAG) |
| 高度なビジュアル・定型ダッシュボード | Tableau / Power BI |
| Snowflake を使っていない + 外部 LLM でよい | OpenAI + LangChain |

---

## 次のステップ

- [06_advanced_semantic_model.md](06_advanced_semantic_model.md) — セマンティックモデルの高度な設定
- [07_analyst_rag_integration.md](07_analyst_rag_integration.md) — Cortex Search との統合
