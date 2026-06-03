# アーキテクチャ設計

## 1. 全体アーキテクチャ

```
ユーザー（Streamlit チャット画面）
        │  自然言語の質問
        ▼
┌──────────────────────────────────────────────────────────┐
│                  Cortex Agent                            │
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
          │  T_システム名_CRUD  │  │  T_システム名_SRC  │
          │  (構造化メタデータ) │  │  (ソースコード)    │
          │  ・ジョブ名         │  │  ・ソースコード本文│
          │  ・テーブル名       │  │  ・ai_summary      │
          │  ・CRUDフラグ       │  │  ・モジュール名    │
          │  ・ソースファイル名 │  │  ・機能名          │
          └─────────────────────┘  └────────────────────┘
```

---

## 2. テーブル別ツールマッピング

| テーブル | 適用ツール | 理由 |
|---|---|---|
| T_システム名_CRUD | **Cortex Analyst** | フラグ・名称等の構造化データ。完全一致・フィルタ条件が必要な影響調査に最適 |
| T_システム名_SRC | **Cortex Search** | ソースコード・ai_summaryの非構造化テキスト。セマンティック類似検索が有効 |

---

## 3. 質問タイプ別ルーティング設計

### Cortex Analyst を使うべき質問（影響調査・棚卸し）

```
「〇〇テーブルを使用しているジョブを教えて」
「〇〇テーブルをUPDATEしているプログラムは？」
「〇〇ジョブネットに含まれるジョブの一覧は？」
「ファイル出力が発生する機能はどれ？」
「〇〇モジュールが参照しているテーブル一覧を出して」
「削除（DELETE）処理があるプログラムを教えて」
```

**特徴**: テーブル名・ジョブ名・フラグ値など、**完全一致で特定できる構造的な検索**

### Cortex Search を使うべき質問（解説・障害調査）

```
「〇〇.sqlはどんな処理をしているプログラム？」
「〇〇モジュールの処理フローを説明して」
「このエラーメッセージが出た場合の原因は？」
「〇〇機能の処理内容を新人向けに解説して」
「〇〇バッチが異常終了した場合の調査ポイントは？」
```

**特徴**: 処理内容・意図・文脈を把握するための**意味的な検索**

---

## 4. Cortex Analyst セマンティックモデル設計

### 対象テーブル: T_システム名_CRUD

```yaml
# 設計ポイント
# ・論理名（日本語）と物理カラム名の対応を明示
# ・CRUDフラグはフィルタ条件として使われるため
#   ビジネス用語（「使用している」「更新している」）とのマッピングが重要
# ・verified_queries で頻出パターンを事前登録し精度を安定化
```

**主要エンティティ**:

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

### 対象テーブル: T_システム名_SRC

| 設計項目 | 設定値 | 理由 |
|---|---|---|
| 主検索カラム | `ai_summary` | 事前生成の概要文、長すぎず精度高い |
| 補助カラム | `module_name`, `function_name`, `file_name` | フィルタとしてメタデータを活用 |
| ソースコード | `source_code`（属性として保持） | 検索対象ではなく回答生成に利用 |
| チャンク戦略 | ai_summaryは1レコード1チャンク | すでに要約済みのため分割不要 |
| 更新戦略 | `TARGET_LAG = '1 day'` | 日次バッチ後に再インデックス |

### セマンティックビュー設計

Cortex Searchのインデックス対象として最適化したViewを作成:

```sql
CREATE OR REPLACE VIEW V_SRC_SEARCH AS
SELECT
    source_id,
    file_name,
    module_name,
    function_name,
    ajs_name,
    net_name,
    system_name,
    -- 検索精度向上のため概要+モジュール名+機能名を結合
    ai_summary
        || ' モジュール: ' || COALESCE(module_name, '')
        || ' 機能: ' || COALESCE(function_name, '')
        || ' ファイル: ' || file_name AS search_content,
    source_code,
    created_at
FROM T_システム名_SRC
WHERE ai_summary IS NOT NULL;
```

---

## 6. エージェント設計

### ツール登録

```
Tool 1: impact_analysis_tool (cortex_analyst_text_to_sql)
  - セマンティックモデル: @<stage>/semantic_model.yaml
  - 用途: 影響調査・CRUD棚卸し

Tool 2: source_code_search_tool (cortex_search_service)
  - サービス名: SRC_SEARCH_SERVICE
  - 用途: ソースコード解説・障害調査
```

### モデル選択

| 用途 | 推奨モデル | 理由 |
|---|---|---|
| エージェント基盤 | `claude-3-5-sonnet` または `mistral-large2` | ツール選択の精度と多言語（日本語）対応 |
| Cortex Analyst内部 | 自動選択（Snowflake管理） | Analyst API内部で最適化済み |

---

## 7. Semantic View 設計（Cortex Search 用）

Cortex Search Serviceを作成する際のビュー定義:

```
目的: T_システム名_SRCのai_summaryを中心にした検索最適化ビュー

フィルタに使えるカラム:
- module_name: モジュール絞り込み
- function_name: 機能絞り込み
- ajs_name: ジョブ名絞り込み
- system_name: システム絞り込み（マルチシステム対応時）

検索対象テキスト:
- search_content (ai_summary + module_name + function_name の結合)

応答生成に使う追加カラム:
- source_code: 実際のソースコード（引用表示用）
- file_name: ソースファイル名
```
