# アーキテクチャ設計

## 1. 全体アーキテクチャ

```
ユーザー（Snowflake Intelligence UI ── エージェント選択して対話）
        │  自然言語の質問
        ▼
┌──────────────────────────────────────────────────────────┐
│             Cortex Agent（Intelligence上で構成）          │
│                                                          │
│  システムプロンプト:                                       │
│  「影響調査質問 → analyst_tool を使用せよ」               │
│  「ソースコード/障害分析質問 → search_tool を使用せよ」   │
│                                                          │
│   質問を解析  ───────┬──────────────────┐                │
│                      │                  │                │
│                      ▼                  ▼                │
│          ┌───────────────────┐  ┌───────────────────┐   │
│          │  Cortex Analyst   │  │  Cortex Search    │   │
│          │ (Text-to-SQL)     │  │ (Semantic Search) │   │
│          └─────────┬─────────┘  └─────────┬─────────┘   │
│                    │                       │             │
└────────────────────┼───────────────────────┼─────────────┘
                     │                       │
          ┌──────────▼──────────┐  ┌─────────▼──────────┐
          │   セマンティック    │  │    インデックス     │
          │   モデル（YAML）    │  │    用ビュー（SQL）  │
          └──────┬──────────────┘  └──────────┬──────────┘
                 │                             │
     ┌───────────┴──────────┐       ┌──────────▼──────────┐
     │  T_システム名_CRUD   │       │  T_システム名_SRC   │
     │  ・ジョブ名           │       │  ・ai_summary       │
     │  ・テーブル名         │       │  ・source_code      │
     │  ・CRUDフラグ         │       │  （非構造化テキスト）│
     │  ・ソースファイル名   │       └─────────────────────┘
     └──────────────────────┘
     　T_システム名_SRC（構造化部分）もAnalyst対象に追加
     　・file_name / module_name / function_name
     　・created_at / created_by（棚卸し・メタ集計用）
```

---

## 2. テーブル別ツールマッピング

| テーブル | カラム種別 | 適用ツール | 理由 |
|---|---|---|---|
| T_システム名_CRUD | 全カラム（構造化） | **Cortex Analyst** | CRUDフラグ・テーブル名・ジョブ名等。完全一致・フィルタ条件が必要な影響調査に最適 |
| T_システム名_SRC | 構造化カラム（file_name, module_name, function_name, ajs_name, created_at, created_by 等） | **Cortex Analyst** | ファイル棚卸し・作成者別集計・モジュール別件数など、メタデータ集計クエリに対応 |
| T_システム名_SRC | `source_code`（コード本文） | **Cortex Analyst**（LIKE検索） | 「〇〇関数を使っているファイルは何件？」のような特定キーワードの部分一致 + 集計クエリ |
| T_システム名_SRC | `ai_summary`（AI概要テキスト） | **Cortex Search** | 自然言語の意味的検索。処理内容説明・障害調査・概念的な問いに対応 |

> **source_code の分担ルール**:
> - 「〇〇関数を**使っているファイルは何件？どのファイル？**」→ Analyst（LIKE + COUNT/SELECT。集計・特定が目的）
> - 「〇〇を使っているプログラムは**どんな処理をしているか**？」→ Search（意味理解・説明が目的）
>
> ai_summaryはLIKE検索に不向き（要約時に関数名が省略される場合がある）。
> 技術キーワードの精密マッチには source_code が信頼性が高い。

---

## 3. 質問タイプ別ルーティング設計

### Cortex Analyst を使うべき質問（影響調査・棚卸し・コード内キーワード検索）

```
「〇〇テーブルを使用しているジョブを教えて」
「〇〇テーブルをUPDATEしているプログラムは？」
「〇〇ジョブネットに含まれるジョブの一覧は？」
「ファイル出力が発生する機能はどれ？」
「〇〇モジュールが参照しているテーブル一覧を出して」
「削除（DELETE）処理があるプログラムを教えて」
「〇〇関数を利用しているソースコードは何件ある？」        ← source_code LIKE検索
「〇〇ストアドプロシージャを呼び出しているファイル一覧」  ← source_code LIKE検索
「〇〇テーブルをSQLで直接参照しているプログラムは？」    ← source_code LIKE検索
```

**特徴①（メタデータ）**: テーブル名・ジョブ名・フラグ値など、完全一致で特定できる構造的な検索
**特徴②（コード内検索）**: 特定の関数名・テーブル名・キーワードをコード本文からLIKE部分一致で集計・特定する検索。**「何件あるか」「どのファイルか」が知りたい場合はAnalyst**

### Cortex Search を使うべき質問（解説・概念的な問い・障害調査）

```
「〇〇.sqlはどんな処理をしているプログラム？」
「〇〇モジュールの処理フローを説明して」
「このエラーメッセージが出た場合の原因は？」
「〇〇機能の処理内容を新人向けに解説して」
「〇〇バッチが異常終了した場合の調査ポイントは？」
「〇〇関数を使っているプログラムはどんな処理をしているか？」  ← 件数でなく内容が目的
```

**特徴**: 処理内容・意図・文脈を把握するための意味的な検索。「なぜ」「どのように」という問いに対応。

---

## 4. Cortex Analyst セマンティックモデル設計

> **セマンティックモデル（YAML）はCortex Analyst専用の定義ファイル**です。
> Cortex Searchとは無関係です（Searchは後述の「インデックス用ビュー」を使います）。

### 対象テーブル: T_システム名_CRUD ＋ T_システム名_SRC（構造化部分）

```yaml
# 設計ポイント
# ・2テーブルをセマンティックモデルに登録し、JOIN CLUEを定義する
# ・CRUDフラグはフィルタ条件として使われるため
#   ビジネス用語（「使用している」「更新している」）とのマッピングが重要
# ・verified_queries で頻出パターンを事前登録し精度を安定化
```

### T_システム名_CRUD の主要エンティティ

| ビジネス概念 | 物理カラム | 補足 |
|---|---|---|
| ジョブ | `ajs_name` | バッチスケジューラのジョブ名 |
| ジョブネット | `net_name` | 複数ジョブを束ねる親グループ |
| プログラム / ソースファイル | `src_name` | 実行するSQLやバッチファイル名 |
| テーブル（日本語） | `table_name_jp` | 検索のキーになる主カラム |
| テーブル/ファイル名 | `file_table_name` | file_table_flg=1でファイル、0でテーブル |
| 機能 | `function_name` | 業務機能名（日本語） |
| モジュール | `module_name` | システムモジュール名（日本語） |
| CREATE操作 | `crud_c_flag` | 1=あり |
| READ操作 | `crud_r_flag` | 1=あり |
| UPDATE操作 | `crud_u_flag` | 1=あり |
| DELETE操作 | `crud_d_flag` | 1=あり |
| ファイル取り込み | `file_i_flg` | 1=インポートあり |
| ファイル出力 | `file_o_flg` | 1=ファイル出力あり |

### T_システム名_SRC の構造化カラム（Analyst対象）

| ビジネス概念 | 物理カラム | 補足 |
|---|---|---|
| ソースファイル名 | `file_name` | 実ファイル名（CRUD側のsrc_nameと対応） |
| モジュール | `module_name` | CRUD側と共通 |
| 機能 | `function_name` | CRUD側と共通 |
| ジョブ | `ajs_name` | 結合キー（CRUD側と共通） |
| 作成日 | `created_at` | 棚卸し・最新追加プログラム検索 |
| 作成者 | `created_by` | 担当者別集計 |

> `source_code` / `ai_summary` はCortex Searchが担当するため、Analystのモデルには含めない。

### テーブル間の結合定義（relationships）

```yaml
relationships:
  - name: crud_to_src
    left_table: T_<システム名>_CRUD
    right_table: T_<システム名>_SRC
    relationship_columns:
      - left_column: ajs_name
        right_column: ajs_name
    join_type: left_outer
    relationship_type: many_to_many
```

これにより「〇〇テーブルを更新しているジョブのソースファイル名は？」のような
**両テーブルをまたぐ複合クエリ**が1回のAnalystコールで解決できる。

**重要な言語マッピング（synonyms定義）**:

| ユーザーの表現 | 解釈すべきSQLフィルタ |
|---|---|
| 「使用している」「参照している」 | `crud_r_flag=1 OR crud_c_flag=1 OR crud_u_flag=1 OR crud_d_flag=1` |
| 「更新している」「修正している」 | `crud_u_flag = 1` |
| 「削除している」 | `crud_d_flag = 1` |
| 「作成している」「INSERTしている」 | `crud_c_flag = 1` |
| 「読んでいる」「SELECTしている」 | `crud_r_flag = 1` |
| 「ファイルを出している」 | `file_o_flg = 1` |
| 「ファイルを取り込んでいる」 | `file_i_flg = 1` |

---

## 5. Cortex Search サービス設計

### 対象テーブル: T_システム名_SRC（非構造化カラムのみ）

| 設計項目 | 設定値 | 理由 |
|---|---|---|
| 主検索カラム | `ai_summary` | 事前生成の概要文、長すぎず精度高い |
| フィルタ属性 | `module_name`, `function_name`, `file_name` | 絞り込み条件として活用（検索対象ではない） |
| ソースコード | `source_code`（応答生成用に保持） | 検索インデックスには使わず、引用表示に利用 |
| チャンク戦略 | ai_summaryは1レコード1チャンク | すでに要約済みのため分割不要 |
| 更新戦略 | `TARGET_LAG = '1 day'` | 日次バッチ後に再インデックス |

### インデックス用ビュー定義（Cortex Search用）

> **注意**: これはCortex Searchのインデックス対象を定義する通常のSQLビューです。
> Cortex Analystの「セマンティックモデル（YAML）」とは別物です。

```sql
-- Cortex Search Service の CREATE 文で直接使用するSELECTクエリ
-- （別途Viewを作る場合はこの内容をVIEWとして定義する）
SELECT
    source_id,
    file_name,
    module_name,
    function_name,
    ajs_name,
    net_name,
    system_name,
    -- 検索精度向上のためai_summaryにメタ情報を付加
    ai_summary
        || ' モジュール名: ' || COALESCE(module_name, '')
        || ' 機能名: ' || COALESCE(function_name, '')
        || ' ファイル名: ' || COALESCE(file_name, '')
        AS search_content,  -- ← Cortex Searchがインデックスするカラム
    source_code,
    created_at
FROM T_<システム名>_SRC
WHERE ai_summary IS NOT NULL
```

---

## 6. エージェント設計（Snowflake Intelligence）

> **本プロジェクトでは Snowflake Intelligence を使用します。**
> エージェントを登録するだけでチャットUIが自動的に提供されるため、カスタムUIの実装は不要です。

### Intelligence エージェント構成

```
エージェント名: 社内システム保守支援Bot

ツール登録:
  Tool 1: impact_analysis_tool (cortex_analyst_text_to_sql)
    - セマンティックモデル: @<stage>/semantic_model.yaml
    - 対象テーブル: T_CRUD（全体） + T_SRC（構造化カラム）
    - 用途: 影響調査・CRUD棚卸し・ファイル棚卸し

  Tool 2: source_code_search_tool (cortex_search_service)
    - サービス名: SRC_SEARCH_SERVICE
    - 対象: T_SRC の ai_summary（インデックス済み）
    - 用途: ソースコード解説・障害調査

システムプロンプト: 03_orchestration_design.md 参照
```

### モデル選択

| 用途 | 推奨モデル | 理由 |
|---|---|---|
| エージェント基盤 | `claude-3-5-sonnet` | ツール選択の精度と日本語対応 |
| Cortex Analyst内部 | 自動選択（Snowflake管理） | Analyst API内部で最適化済み |

### Intelligence セットアップの流れ

```
1. Snowsight の「Intelligence」タブを開く
2. 「+ New Agent」でエージェントを作成する
3. ツールとして「Cortex Analyst」と「Cortex Search」を追加する
4. セマンティックモデルのYAMLとSearchサービス名を指定する
5. システムプロンプトを設定する
6. エージェントを「公開」するとチームメンバーが利用可能になる
```

詳細は `sql/05_intelligence_agent_config.md` を参照。
