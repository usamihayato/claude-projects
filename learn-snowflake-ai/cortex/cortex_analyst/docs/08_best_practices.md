# Cortex Analyst ベストプラクティス

## 1. セマンティックモデル設計の 10 の鉄則

### 鉄則 1: description は「LLM への手紙」として書く

```yaml
# ❌ 悪い例（技術的すぎる・英語のみ）
columns:
  - name: order_amt
    description: order amount

# ✅ 良い例（ビジネス定義・日本語・補足情報あり）
columns:
  - name: order_amt
    description: |
      注文金額（税抜・円単位）。
      キャンセル注文も含む全注文の金額が入っている。
      売上集計時は status != 'cancelled' で除外すること。
```

### 鉄則 2: コード値は必ず説明する

```yaml
# ✅ コード値の意味を明示
- name: status
  description: |
    注文ステータス。
    pending=処理中, confirmed=確定, shipped=出荷済み,
    completed=完了, cancelled=キャンセル
  sample_values: ["pending", "confirmed", "shipped", "completed", "cancelled"]
```

### 鉄則 3: measures でビジネスロジックを封じ込める

ビジネスルール（キャンセル除外・税抜計算等）を `measures` に定義することで、LLM が毎回同じルールを適用するようになる。

```yaml
measures:
  - name: net_sales
    description: "純売上（キャンセル・返品除く、税抜）"
    expr: SUM(CASE WHEN status NOT IN ('cancelled', 'returned') THEN total_amount ELSE 0 END)
    data_type: NUMBER
```

### 鉄則 4: テーブル数は最小限に留める

1つのセマンティックモデルに含めるテーブルは 10 テーブル以下を目安にする。多すぎると:
- LLM の推論精度が落ちる
- 意図しない JOIN が生成されるリスクが増える

**解決策**: 用途別に複数のセマンティックモデルを作成し、質問の種類によって切り替える。

### 鉄則 5: Verified Queries は最低 5〜10 件登録する

```yaml
verified_queries:
  # よくある質問を網羅する
  - name: monthly_sales          # 月次売上
  - name: top_products           # 商品ランキング
  - name: by_region              # 地域別
  - name: by_customer_segment    # 顧客セグメント別
  - name: yoy_comparison         # 前年比
```

### 鉄則 6: relationships を全テーブル分定義する

JOIN を LLM に正しく推論させるには、全テーブルのリレーションを定義する必要がある。1 つでも欠けると、そのテーブルをまたぐ質問が失敗する。

### 鉄則 7: time_dimensions を忘れない

```yaml
time_dimensions:
  - column_name: order_date
```

これがないと「先月」「今年」「前四半期」といった時間軸の質問が正しく処理されない。

### 鉄則 8: モデル名・テーブル名は意味のある英語にする

セマンティックモデルの `name` フィールドは LLM が内部で参照する識別子。意味のない名前（t1, tbl_01 等）は避ける。

```yaml
# ❌ 悪い例
tables:
  - name: t1

# ✅ 良い例
tables:
  - name: sales_orders
```

### 鉄則 9: YAML の構文エラーを事前チェックする

```bash
# Python で YAML の構文チェック
python3 -c "import yaml; yaml.safe_load(open('03_semantic_model.yaml'))"
```

構文エラーがあると Cortex Analyst が完全にエラーになる。

### 鉄則 10: 本番前に代表質問でテストする

```sql
-- セマンティックモデルを更新したら必ずテスト実行
CALL analyst_to_sql('先月の売上合計は？');
CALL analyst_to_sql('商品カテゴリ別の売上ランキング');
CALL analyst_to_sql('東日本と西日本の売上比較');
CALL analyst_to_sql('法人顧客の平均注文金額');
CALL analyst_to_sql('今年の月次売上推移');
```

---

## 2. よくある質問と対処

### Q1: 回答が「データを取得できませんでした」になる

**原因と対処:**
1. セマンティックモデルの `base_table` のDB名・スキーマ名・テーブル名が間違っている → 実際のテーブルと一致しているか確認
2. ステージの YAML ファイルが古いバージョン → `PUT` で再アップロード
3. 権限不足 → `GRANT CORTEX_USER` が付与されているか確認

```sql
-- テーブルの存在確認
SHOW TABLES LIKE 'SALES_ORDERS' IN SCHEMA ANALYST_DEMO_DB.ANALYST_SCHEMA;

-- ステージのファイル確認
LIST @ANALYST_DEMO_DB.ANALYST_SCHEMA.SEMANTIC_MODEL_STAGE;
```

### Q2: 生成 SQL が意図と違う WHERE 句を使う

**原因**: コード値や条件の説明が不十分。

**対処**: `description` にフィルタ条件の説明を追加する。または `verified_queries` に正解 SQL を登録する。

```yaml
# description にビジネスルールを明示
- name: status
  description: |
    注文ステータス。売上集計では必ず status != 'cancelled' で
    キャンセルを除外すること。
```

### Q3: 複数テーブルをまたぐ質問でエラーになる

**原因**: `relationships` が未定義、または JOIN キーが間違っている。

**対処**:
```sql
-- 実際に正しい JOIN が書けるか手動で確認
SELECT o.order_id, c.customer_name
FROM sales_orders o
JOIN customers c ON o.customer_id = c.customer_id
LIMIT 5;

-- 確認できたら relationships に追加
```

### Q4: 「その情報はわかりません」と返ってくる

**原因**: 質問がセマンティックモデルで定義されたテーブルの範囲外。

**対処**: 質問の内容を確認し、必要であれば関連テーブルをモデルに追加する。または Cortex Search（ドキュメント検索）へルーティングする。

---

## 3. パフォーマンス最適化

### Verified Queries の積極活用

Cortex Analyst は Verified Queries に一致する質問を優先して使います。これにより:
- 応答速度が向上（LLM の SQL 生成が不要）
- ハルシネーションが減少
- 一貫性のある回答が得られる

頻繁に来る質問は全て Verified Queries に登録することを推奨。

### ウェアハウスのサイズ選択

```sql
-- 通常の集計クエリは SMALL で十分
CREATE WAREHOUSE ANALYST_WH WAREHOUSE_SIZE = 'SMALL';

-- 大量データの集計が多い場合は MEDIUM に変更
ALTER WAREHOUSE ANALYST_WH SET WAREHOUSE_SIZE = 'MEDIUM';
```

### クエリ結果キャッシュ

Snowflake の結果キャッシュ（Result Cache）は Cortex Analyst が生成した SQL にも適用されます。同じ SQL が再実行されるとキャッシュから返るため、コスト削減になります。

---

## 4. 本番運用チェックリスト

### デプロイ前

- [ ] セマンティックモデル YAML の構文チェック完了
- [ ] 全テーブルの `description` が日本語で記述されている
- [ ] `measures` にビジネスロジックが定義されている
- [ ] `relationships` が全テーブル分定義されている
- [ ] `verified_queries` が 5 件以上登録されている
- [ ] 代表質問 10 件でテスト済み
- [ ] ステージに最新 YAML がアップロードされている
- [ ] デモユーザーへの権限付与完了

### デモ後・本番運用中

- [ ] ユーザーからフィードバックのあった質問を `verified_queries` に追加
- [ ] 精度が低い質問は `description` を改善して再テスト
- [ ] セマンティックモデルの変更時は必ず全テスト実施
- [ ] テーブルスキーマ変更時はモデルを同期更新

---

## 5. セマンティックモデルのバージョン管理

セマンティックモデル YAML はソースコード管理（Git）に含めることを強く推奨します。

```
cortex_analyst/
└── sql/
    ├── 03_semantic_model.yaml        ← 現行バージョン
    └── archived/
        ├── 03_semantic_model_v1.yaml ← 旧バージョン（参照用）
        └── 03_semantic_model_v2.yaml
```

変更時のフロー:
1. YAML を編集
2. 動作テスト（代表質問でチェック）
3. ステージに `PUT`（`AUTO_COMPRESS=FALSE`）
4. Git にコミット

---

## 関連ドキュメント

- [02_semantic_model_basics.md](02_semantic_model_basics.md) — 基礎
- [06_advanced_semantic_model.md](06_advanced_semantic_model.md) — 高度な設定
- [07_analyst_rag_integration.md](07_analyst_rag_integration.md) — Cortex Search との統合
- `../sql/03_semantic_model.yaml` — 実際に動く YAML サンプル
