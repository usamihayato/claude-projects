# 物理カラム名・コード値への対応パターン

実際のシステムではカラム名が `DEPT_CD`、値が `'01'` のような形式が多いです。
RAGに活用するには「LLMに渡す前に人が読める形に変換する」レイヤーが必要です。

---

## パターン1: コードマスタ + VIEW による変換

`sql/08_code_master_rag.sql` のサンプル。

### テーブル構成

```
EXPENSE_TBL (EMP_CD, CAT_CD='E', STAT_FLG='03', AMT)
    ↓ JOIN
CODE_MST (CODE_TYPE='CAT', CODE_VAL='E', CODE_LBL='接待費')
CODE_MST (CODE_TYPE='STAT', CODE_VAL='03', CODE_LBL='却下')
    ↓
V_EXPENSE_READABLE (費用区分='接待費', ステータス='却下', 金額=52000)
    ↓ LISTAGG
LLMへのコンテキスト: 「佐藤 美咲（営業部）: 接待費 ¥52,000 [却下]」
```

### コードマスタの構造

```sql
CREATE TABLE CODE_MST (
    CODE_TYPE  VARCHAR(20),   -- 'DEPT' / 'CAT' / 'STAT' / 'ROLE'
    CODE_VAL   VARCHAR(10),   -- '001', 'E', '03'
    CODE_LBL   VARCHAR(100),  -- '人事部', '接待費', '却下'
    PRIMARY KEY (CODE_TYPE, CODE_VAL)
);
```

### 変換ビューの作成

```sql
CREATE VIEW V_EXPENSE_READABLE AS
SELECT
    e.EMP_NM                AS 社員名,
    dept.CODE_LBL           AS 部署,
    role_m.CODE_LBL         AS 役職,
    cat.CODE_LBL            AS 費用区分,
    ea.AMT                  AS 金額,
    TO_CHAR(ea.APP_DT, 'YYYY年MM月DD日') AS 申請日,
    stat.CODE_LBL           AS ステータス,
    ea.BIKO                 AS 備考
FROM EXPENSE_TBL ea
JOIN EMP_MST   e      ON ea.EMP_CD    = e.EMP_CD
JOIN CODE_MST  dept   ON dept.CODE_TYPE  = 'DEPT' AND dept.CODE_VAL  = e.DEPT_CD
JOIN CODE_MST  role_m ON role_m.CODE_TYPE = 'ROLE' AND role_m.CODE_VAL = e.ROLE_CD
JOIN CODE_MST  cat    ON cat.CODE_TYPE   = 'CAT'  AND cat.CODE_VAL   = ea.CAT_CD
JOIN CODE_MST  stat   ON stat.CODE_TYPE  = 'STAT' AND stat.CODE_VAL  = ea.STAT_FLG;
```

### RAGへの活用

```sql
-- ビューから LISTAGG でテキスト化 → そのままコンテキストに使える
SELECT LISTAGG(
    社員名 || '（' || 部署 || '）: '
    || 費用区分 || ' ¥' || TO_CHAR(金額, '999,999')
    || ' [' || ステータス || '] ' || 備考,
    '\n'
)
FROM V_EXPENSE_READABLE
WHERE ステータス = '却下';
-- → 「佐藤 美咲（営業部）: 接待費 ¥52,000 [却下] 接待費上限超過のため」
```

### 向いているケース

- コードマスタが既にある（よくある構成）
- DBにビュー作成権限がある
- コードの種類が多い（CASE式が煩雑になる場合）

---

## パターン2: Cortex Analyst + セマンティックモデル

`sql/09_cortex_analyst_rag.sql` + `cortex_analyst/expense_semantic_model.yaml` のサンプル。

### 仕組み

```
自然言語の質問
    ↓ セマンティックモデル（YAML）を参照
Cortex Analyst REST API
    ↓ 物理名・コードへのマッピングを自動適用
SQL生成（コードマスタJOIN・デコード込み）
    ↓ Snowflake で実行
クエリ結果（ラベル表示済み）
    ↓ Cortex Search のドキュメントと合算
CORTEX.COMPLETE → 回答
```

### セマンティックモデル（YAMLの要点）

```yaml
# cortex_analyst/expense_semantic_model.yaml

tables:
  - name: EXPENSE_TBL
    dimensions:
      - name: 費用区分          # ← ビジネス名
        expr: CAT_CD            # ← 物理カラム名
        sample_values:
          - value: E
            label: 接待費       # ← コード値とラベルのマッピング
          - value: T
            label: 交通費

      - name: ステータス
        expr: STAT_FLG
        sample_values:
          - value: "01"
            label: 申請中
          - value: "03"
            label: 却下

relationships:
  - name: 経費申請_社員
    left_table: EXPENSE_TBL
    right_table: EMP_MST
    join_condition: EXPENSE_TBL.EMP_CD = EMP_MST.EMP_CD
```

YAMLに「物理名→ビジネス名」「コード値→ラベル」を定義しておくと、Cortex Analyst が自動でJOINを組み立てたSQLを生成します。

### セットアップ手順

```sql
-- 1. YAMLをステージにアップロード
PUT file://cortex_analyst/expense_semantic_model.yaml
    @RAG_DEMO_DB.RAG_SCHEMA.analyst_stage
    AUTO_COMPRESS=FALSE;

-- 2. Cortex Analyst でSQL生成のみ確認
CALL analyst_to_sql('却下された接待費の申請一覧を教えてください');
-- → {sql: "SELECT ... WHERE STAT_FLG='03' ...", explanation: "..."}

-- 3. ハイブリッドRAG実行
CALL analyst_hybrid_rag(
    '却下された経費申請の再申請アドバイスをください',
    '接待費 上限 承認 規定',
    '財務規定',
    'llama3.1-70b'
);
```

### 向いているケース

- 「どのテーブルのどのカラムを使うか」の判断を自動化したい
- 質問の種類が多様でSQLのパターンを事前定義できない
- ビジネスユーザーが自然言語でデータを問い合わせる UI を作りたい

---

## 2つのパターンの比較

| 観点 | パターン1（コードマスタ+VIEW） | パターン2（Cortex Analyst） |
|---|---|---|
| **設定コスト** | VIEWの作成のみ | セマンティックモデルYAMLの定義 |
| **クエリの柔軟性** | 固定SQL（VIEWで決まった形） | 自然言語から動的にSQL生成 |
| **コード値の扱い** | JOIN で明示的にデコード | YAMLの `sample_values` で定義 |
| **追加テーブル** | CODE_MST が必要 | YAMLに直接記述できる |
| **実行の予測可能性** | 高い（SQL固定） | 中（LLMが生成するため変わる場合あり） |
| **向いている用途** | 決まったレポート・集計 | 探索的な問い合わせ |

### 組み合わせパターン

```
定型レポート → パターン1（VIEW + LISTAGG）
自由形式の質問 → パターン2（Cortex Analyst）
                    ↓
              両方の結果を Cortex Search のドキュメントと合算
                    ↓
              CORTEX.COMPLETE で回答
```

---

## 参考リンク

- [Cortex Analyst 公式ドキュメント](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/cortex-analyst)
- [セマンティックモデルの記法](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/semantic-model-spec)
- [Cortex Search](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search/cortex-search-overview)
