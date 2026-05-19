# MCP（Model Context Protocol）概要

## MCP とは

MCP（Model Context Protocol）は、**AI エージェントと外部ツール・データソースを接続するための標準規格**です。  
Anthropic が 2024 年 11 月に策定・公開しました。

> 「AI 界の USB-C」と表現されることが多い。  
> 接続する相手（DB・API・ファイルシステム）が変わっても、AI 側の接続方法は統一される。

---

## API との本質的な違い

### 従来の API 方式

```
エンジニアが書くコード
  │
  │  「売上データを取れ」と明示的に指定
  │  POST /api/v2/cortex/analyst/message
  │  { "messages": [...] }
  ▼
Snowflake Cortex Analyst
  │
  ▼
結果を返す → エンジニアがパースして使う
```

**エンジニアがすべてを決める**: いつ・何を・どう呼ぶかをコードで明示。

---

### MCP 方式

```
ユーザーの自然言語
  │
  ▼
AI エージェント（Claude など）
  │
  │  ① MCP Server に「何ができる？」と問い合わせ
  ▼
MCP Server（Snowflake）
  │  ② 利用可能なツール一覧を返す
  │     - execute_query（SQL 実行）
  │     - list_tables（テーブル一覧）
  │     - cortex_analyst（自然言語→SQL）
  │     - cortex_search（ドキュメント検索）
  ▼
AI エージェント
  │  ③ 質問に最適なツールを自律的に選んで実行
  │  ④ 必要なら複数ツールを組み合わせる
  ▼
自然言語で回答
```

**AI がすべてを決める**: エンジニアはツールを「用意する」だけ。いつ・どう使うかは AI が判断。

---

## 一言で言うと

| | API | MCP |
|---|---|---|
| 誰が判断するか | **エンジニア**（コード） | **AI エージェント**（自律） |
| 呼び出し方 | 明示的に HTTP リクエスト | AI がツールを発見して自動呼び出し |
| 組み合わせ | 自分でオーケストレーション | AI が自動で複数ツールを組み合わせ |
| 向いている場面 | アプリへの組み込み・自動化 | エージェントが自律的に動く場面 |

---

## MCP の構成要素

```
┌─────────────────────────────────────────────────────┐
│  MCP Host（AI エージェントが動く環境）               │
│                                                     │
│  例: Claude Desktop, Claude Code, Cursor, Windsurf  │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  MCP Client（Host に内蔵）                   │   │
│  │  ← MCP Server と通信するコンポーネント       │   │
│  └──────────────┬───────────────────────────────┘   │
└─────────────────┼───────────────────────────────────┘
                  │  MCP Protocol（JSON-RPC）
                  │
     ┌────────────┼──────────────┐
     ▼            ▼              ▼
MCP Server    MCP Server    MCP Server
（Snowflake）（GitHub）    （Slack）
```

MCP Server は**どこにでも置ける**: ローカルプロセス・クラウドサービス・社内サーバーなど。

---

## MCP が提供する 3 つの機能

### 1. Tools（ツール）
AI がアクションを実行するための関数。Snowflake MCP の場合:
- `execute_query` — SQL を実行して結果を返す
- `list_tables` — テーブル一覧を返す
- `describe_table` — テーブルのカラム定義を返す

### 2. Resources（リソース）
AI が参照できるデータ・ファイル。例: テーブルのスキーマ情報、ドキュメントなど。

### 3. Prompts（プロンプト）
よく使うプロンプトテンプレートを Server 側で定義して再利用する仕組み。

---

## Snowflake × MCP のユースケース

### ユースケース 1: Claude Code からデータ分析

```
エンジニアが Claude Code 上で:
「SALES_ORDERS テーブルの先月の売上上位5商品を調べて、
  Cortex Analyst を使って分析してみて」

Claude:
  → list_tables でテーブル構成を確認
  → describe_table で SALES_ORDERS のスキーマ把握
  → cortex_analyst に自然言語質問を投げて SQL 生成
  → execute_query で SQL 実行
  → 結果を解釈して回答
```

**エンジニアが書くコード: ゼロ**

---

### ユースケース 2: Claude Desktop からドキュメント検索

```
ビジネスユーザーが Claude Desktop 上で:
「経費精算の申請期限を教えて」

Claude:
  → cortex_search で社内規定ドキュメントを検索
  → 関連箇所を抽出して回答
```

---

### ユースケース 3: エージェントによる自律的なデータパイプライン監視

```
「毎朝 SALES_ORDERS の前日データを確認して
  異常があれば原因を調べてレポートして」

Claude:
  → execute_query で前日データを取得
  → 異常値を検知
  → describe_table で関連テーブルを確認
  → 追加の SQL で原因調査
  → レポートを生成
```

---

## Snowflake MCP Server が提供するツール一覧

| ツール名 | 説明 |
|---|---|
| `execute_query` | SQL を実行して結果を返す |
| `list_databases` | データベース一覧を取得 |
| `list_schemas` | スキーマ一覧を取得 |
| `list_tables` | テーブル・ビュー一覧を取得 |
| `describe_table` | テーブルのカラム定義・型を返す |
| `get_ddl` | テーブルの DDL（CREATE 文）を返す |

> Cortex Analyst・Cortex Search は `execute_query` 経由で SQL として呼び出す。  
> または Snowflake が提供する Cortex 専用ツール（拡張版 MCP Server）を使う。

---

## 次のステップ

- [02_snowflake_mcp_setup.md](02_snowflake_mcp_setup.md) — Snowflake MCP Server のセットアップ
- [03_cortex_via_mcp.md](03_cortex_via_mcp.md) — Cortex Analyst / Cortex Search を MCP 経由で使う
