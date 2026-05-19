# Snowflake MCP Server セットアップ

## 前提条件

| 項目 | 必要なもの |
|---|---|
| Snowflake アカウント | アカウント識別子・ユーザー・パスワード or キーペア |
| Python 環境 | Python 3.10 以上 + `uv`（推奨）または `pip` |
| MCP Host | Claude Desktop または Claude Code（どちらか一方で OK） |

---

## Snowflake MCP Server とは

Snowflake が公式提供する MCP Server。  
GitHub: `https://github.com/Snowflake-Labs/mcp`

このサーバーを起動することで、Claude などの AI エージェントが Snowflake に直接接続できるようになる。

---

## Step 1: uv のインストール（推奨）

`uv` は Python の高速パッケージマネージャー。MCP Server の実行に最適。

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Windows（PowerShell）
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"

# インストール確認
uv --version
```

`pip` を使う場合は Step 2 で `uvx` の代わりに `python -m snowflake_mcp` を使う。

---

## Step 2: Snowflake MCP Server のインストール確認

`uvx` は `uv` がインストール済みであれば追加インストール不要で使える。

```bash
# 動作確認（ヘルプが表示されれば OK）
uvx snowflake-mcp --help
```

---

## Step 3: Snowflake の接続情報を確認する

MCP Server に渡す接続情報を手元に用意する。

```
アカウント識別子: <orgname>-<accountname>
  例: myorg-myaccount
  または: xy12345.ap-northeast-1.aws

ユーザー名: <your_username>
ロール: ANALYST_USER（または ACCOUNTADMIN）
ウェアハウス: ANALYST_WH
データベース: ANALYST_DEMO_DB
スキーマ: ANALYST_SCHEMA
```

アカウント識別子の確認方法（Snowflake SQL）:
```sql
SELECT CURRENT_ACCOUNT_NAME(), CURRENT_ORGANIZATION_NAME();
-- 結果: MYACCOUNT, MYORG → アカウント識別子は myorg-myaccount
```

---

## Step 4-A: Claude Desktop に設定する

### 設定ファイルの場所

| OS | パス |
|---|---|
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |

### 設定内容

```json
{
  "mcpServers": {
    "snowflake": {
      "command": "uvx",
      "args": ["snowflake-mcp"],
      "env": {
        "SNOWFLAKE_ACCOUNT":   "myorg-myaccount",
        "SNOWFLAKE_USER":      "your_username",
        "SNOWFLAKE_PASSWORD":  "your_password",
        "SNOWFLAKE_WAREHOUSE": "ANALYST_WH",
        "SNOWFLAKE_DATABASE":  "ANALYST_DEMO_DB",
        "SNOWFLAKE_SCHEMA":    "ANALYST_SCHEMA",
        "SNOWFLAKE_ROLE":      "ANALYST_USER"
      }
    }
  }
}
```

設定後、**Claude Desktop を再起動**する。

### 接続確認

Claude Desktop を開き、チャット画面でハンマーアイコン（🔨）を確認する。  
クリックして `snowflake` の各ツールが表示されれば接続成功。

```
利用可能なツール:
  ✓ execute_query
  ✓ list_databases
  ✓ list_schemas
  ✓ list_tables
  ✓ describe_table
  ✓ get_ddl
```

---

## Step 4-B: Claude Code に設定する

### プロジェクトレベルの設定（このリポジトリ専用）

プロジェクトルートに `.mcp.json` を作成する:

```json
{
  "mcpServers": {
    "snowflake": {
      "command": "uvx",
      "args": ["snowflake-mcp"],
      "env": {
        "SNOWFLAKE_ACCOUNT":   "myorg-myaccount",
        "SNOWFLAKE_USER":      "your_username",
        "SNOWFLAKE_PASSWORD":  "your_password",
        "SNOWFLAKE_WAREHOUSE": "ANALYST_WH",
        "SNOWFLAKE_DATABASE":  "ANALYST_DEMO_DB",
        "SNOWFLAKE_SCHEMA":    "ANALYST_SCHEMA",
        "SNOWFLAKE_ROLE":      "ANALYST_USER"
      }
    }
  }
}
```

### グローバル設定（どのプロジェクトでも使う場合）

```bash
claude mcp add snowflake \
  --command uvx \
  --args snowflake-mcp \
  --env SNOWFLAKE_ACCOUNT=myorg-myaccount \
  --env SNOWFLAKE_USER=your_username \
  --env SNOWFLAKE_PASSWORD=your_password \
  --env SNOWFLAKE_WAREHOUSE=ANALYST_WH \
  --env SNOWFLAKE_DATABASE=ANALYST_DEMO_DB \
  --env SNOWFLAKE_SCHEMA=ANALYST_SCHEMA \
  --env SNOWFLAKE_ROLE=ANALYST_USER
```

### 接続確認

```bash
# MCP Server の状態確認
claude mcp list

# 出力例
snowflake  uvx snowflake-mcp  ✓ connected
```

---

## セキュリティ: パスワードを設定ファイルに書かない方法

パスワードをファイルに平文で書くのは避けたい場合、**キーペア認証**を使う。

### キーペアの生成

```bash
# 秘密鍵の生成
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt

# 公開鍵の生成
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```

### Snowflake に公開鍵を登録

```sql
ALTER USER your_username SET RSA_PUBLIC_KEY='<rsa_key.pub の中身（ヘッダー除く）>';
```

### MCP 設定をキーペアに変更

```json
{
  "mcpServers": {
    "snowflake": {
      "command": "uvx",
      "args": ["snowflake-mcp"],
      "env": {
        "SNOWFLAKE_ACCOUNT":          "myorg-myaccount",
        "SNOWFLAKE_USER":             "your_username",
        "SNOWFLAKE_PRIVATE_KEY_PATH": "/path/to/rsa_key.p8",
        "SNOWFLAKE_WAREHOUSE":        "ANALYST_WH",
        "SNOWFLAKE_DATABASE":         "ANALYST_DEMO_DB",
        "SNOWFLAKE_SCHEMA":           "ANALYST_SCHEMA",
        "SNOWFLAKE_ROLE":             "ANALYST_USER"
      }
    }
  }
}
```

---

## トラブルシューティング

### 「snowflake-mcp が見つからない」

```bash
# uv のキャッシュをクリアして再試行
uv cache clean
uvx snowflake-mcp --help
```

### 「Authentication failed」

```bash
# 接続情報を環境変数にセットして単体テスト
export SNOWFLAKE_ACCOUNT=myorg-myaccount
export SNOWFLAKE_USER=your_username
export SNOWFLAKE_PASSWORD=your_password
uvx snowflake-mcp
```

### 「Warehouse not found」

```sql
-- ウェアハウス名の大文字小文字を確認
SHOW WAREHOUSES;
```

### Claude Desktop がツールを認識しない

1. `claude_desktop_config.json` の JSON 構文を確認（末尾カンマは NG）
2. Claude Desktop を完全に再起動（タスクトレイから終了）
3. ログを確認: macOS の場合 `~/Library/Logs/Claude/`

---

## 設定ファイルのサンプル

`../config/mcp_config_example.json` に Claude Desktop・Claude Code 両対応のサンプルがあります。

---

## 次のステップ

- [03_cortex_via_mcp.md](03_cortex_via_mcp.md) — MCP 経由で Cortex Analyst / Cortex Search を使う
