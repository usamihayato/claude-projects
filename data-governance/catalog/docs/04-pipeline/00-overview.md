# データパイプライン設計：Stage → Bronze → Silver

- 作成日：2026-07-23
- 更新日：2026-07-26
- ステータス：ドラフト（レビュー前）
- 関連：[02-data-transformation/01-conversion-policy.md](../02-data-transformation/01-conversion-policy.md)、[03-schema-design/01-architecture.md](../03-schema-design/01-architecture.md)、[03-schema-design/02-table-definitions.md](../03-schema-design/02-table-definitions.md)

## 1. パイプライン全体像

```
[収集対象システム]
  ・コードマスタ(Excel)           ─┐
  ・設計書（Excel/CSV）            │
  ・画面定義（JSON抽出結果）       │
  ・ソースコード（JSON抽出結果）  ─┘
        │
        │  PUT（ファイルアップロード）
        ▼
┌─────────────────────────────────────────────────────────┐
│ Snowflake Internal Stage                                 │
│ @DG_CATALOG.BRONZE.STG_FILES                             │
│                                                           │
│   landing/<YYYYMMDD>/       ← 原本ファイル（xlsx）       │
│   parsed/<YYYYMMDD>/        ← UDF① でシートごとに CSV 化 │
│   structured/<YYYYMMDD>/    ← UDF② で Bronze 構造 CSV 化 │
│   extraction/<YYYYMMDD>/    ← AI 抽出結果（JSON）        │
│   archive/<YYYYMMDD>/       ← 処理済みファイルの退避先   │
└─────────────────────────────────────────────────────────┘
        │
        │  UDF①: xlsx → parsed CSV（Python / openpyxl）
        │    ・META.SOURCE_SHEET と突合して対象シートを決定
        │    ・シート単位で parsed/ へそのまま CSV 出力
        │
        │  UDF②: parsed CSV → structured CSV（Python）
        │    ・parsed CSV を読み取り Bronze 構造にマッピング
        │    ・structured/ へ構造化済み CSV 出力
        ▼
┌─────────────────────────────────────────────────────────┐
│ Bronze層                                                 │
│   RAW_COLUMN_DEFINITION     ← COPY INTO（CSV/JSON）     │
│   RAW_CODE_VALUE_DEFINITION ← COPY INTO（CSV/JSON）     │
│   （メタ情報付き生データ。追記のみ）                     │
└─────────────────────────────────────────────────────────┘
        │
        │  名寄せ・正規化・競合検知（02-bronze-to-silver.sql）
        ▼
┌─────────────────────────────────────────────────────────┐
│ Silver層                                                 │
│   STG_COLUMN_CANDIDATE      ← MERGE（差分更新）         │
│   STG_CODE_VALUE_CANDIDATE  ← MERGE（差分更新）         │
│   （名寄せ候補。優先度付きで統合）                       │
└─────────────────────────────────────────────────────────┘
```

### 1.1 取り込みパス

| パス | ソース | 経路 | 格納先ディレクトリ |
|---|---|---|---|
| Excel パス | コードマスタ(Excel) / 設計書 | PUT → UDF① → UDF② → SP | landing/ → parsed/ → structured/ |
| JSON パス | ソースコード / 画面定義（AI 抽出結果） | PUT → SP_LOAD_EXTRACTION_JSON | extraction/ |
| 直接取り込みパス | 構造化済み CSV（外部変換済み） | PUT → SP | structured/ |

## 2. 実行単位とバッチ管理

各パイプラインは `META.COLLECTION_BATCH` のバッチレコードと紐づく。

| ステップ | バッチ種別 | 実行頻度（想定） | 概要 |
|---|---|---|---|
| UDF① xlsx → parsed CSV | （UDF 内で管理） | 週次 | 原本 xlsx をシートごとに CSV 化（トレーサビリティ用） |
| UDF② parsed → structured CSV | （UDF 内で管理） | UDF① 完了後 | parsed CSV を Bronze テーブル構造にマッピング |
| structured CSV → Bronze | `収集` | UDF② 完了後 | COPY INTO で Bronze テーブルへ取り込み |
| AI 抽出 JSON → Bronze | `収集` | 任意 | JSON を FLATTEN して Bronze テーブルへ取り込み |
| Bronze → Silver | `名寄せ` | 収集バッチ完了後に自動起動 | Bronze レコードをグルーピング・名寄せして Silver へ MERGE |
| Silver → Gold | `昇格` | 名寄せバッチ完了後（自動昇格 + レビュー後確定） | 別ドキュメントで設計予定 |

## 3. シート管理（META.SOURCE_SHEET）

UDF① が xlsx を処理する際、`META.SOURCE_SHEET` テーブルと突合して処理対象のシートを決定する。

### 3.1 登録フロー

1. 目次シートを Python UDF で読み取り、シート一覧を取得
2. `META.SOURCE_SHEET` にシートごとのレコードを INSERT
3. `TABLE_PHYSICAL_NAME` / `COLUMN_PHYSICAL_NAME` が判明していれば登録、不明なら NULL
4. `IS_ACTIVE = TRUE` のシートのみ UDF① の処理対象

### 3.2 テーブル定義

| カラム | 用途 |
|---|---|
| `SOURCE_SYSTEM_ID` | 収集対象システムへの FK |
| `FILE_NAME` | 元の Excel ファイル名 |
| `SHEET_NAME` | シート名（目次シートに記載された名称） |
| `TABLE_PHYSICAL_NAME` | 対応するテーブル物理名（判明している場合） |
| `COLUMN_PHYSICAL_NAME` | 対応するカラム物理名（判明している場合） |
| `SHEET_TYPE` | シートの種別（区分値一覧 / 列定義 / その他） |
| `IS_ACTIVE` | 処理対象かどうか（FALSE で除外可能） |

## 4. ファイル命名規約

Stage にアップロードするファイルは以下の命名規約に従う。

### 4.1 命名フォーマット

構造化済み CSV（UDF② 出力 / 直接取り込み）：
```
<ソース種別プレフィックス>_<テーブル物理名>_<YYYYMMDD>.<拡張子>
```

parsed CSV（UDF① 出力）：
```
<シート名>.csv
```

AI 抽出結果 JSON：
```
<ソース種別プレフィックス>_<テーブル物理名>_<YYYYMMDD>.json
```

### 4.2 ソース種別プレフィックス

| プレフィックス | ソース種別 | 拡張子 |
|---|---|---|
| `excel` | コードマスタ(Excel) | `.csv` |
| `design` | 設計書 | `.csv` |
| `src` | ソースコード（AI抽出結果） | `.json` |
| `screen` | 画面定義（AI抽出結果） | `.json` |

### 4.3 命名例

| ファイル名 | 内容 | 格納先 |
|---|---|---|
| `code_master_v2.xlsx` | 原本 Excel | `landing/20260726/` |
| `請求ステータス.csv` | UDF① が出力したシート CSV | `parsed/20260726/` |
| `excel_T_CLAIM_20260726.csv` | UDF② が出力した構造化 CSV | `structured/20260726/` |
| `src_T_CLAIM_20260726.json` | ソースコードからの AI 抽出結果 | `extraction/20260726/` |

### 4.4 COPY INTO 時のパターン指定

プレフィックスと日付ディレクトリを使って、取り込み対象を絞り込める。

```sql
-- 特定日付の structured CSV を取り込む
CALL DG_CATALOG.BRONZE.SP_LOAD_CODE_VALUE_FROM_STRUCTURED(1, '20260726');

-- 特定日付の AI 抽出 JSON を取り込む
CALL DG_CATALOG.BRONZE.SP_LOAD_EXTRACTION_JSON(1, '20260726');
```

## 5. ファイル仕様

### 5.1 列名定義 CSV（設計書・コードマスタ由来）

structured/ に格納する CSV のヘッダ列順：

```
SOURCE_TYPE,SOURCE_IDENTIFIER,SOURCE_LOCATION,SOURCE_VERSION,TABLE_PHYSICAL_NAME,COLUMN_PHYSICAL_NAME,COLUMN_LOGICAL_NAME_RAW,RAW_CONTENT
設計書,/docs/table-spec/claims.xlsx,Sheet1:Row5,v2.1,T_CLAIM,clm_stat_cd,請求ステータスコード,"{""original_text"":""請求ステータスコード""}"
```

### 5.2 区分値定義 CSV（設計書・コードマスタ由来）

```
SOURCE_TYPE,SOURCE_IDENTIFIER,SOURCE_LOCATION,SOURCE_VERSION,TABLE_PHYSICAL_NAME,COLUMN_PHYSICAL_NAME,CONTEXT_NAME_RAW,CONTEXT_VALUE_RAW,CODE_VALUE,CODE_LABEL_RAW,CODE_DESCRIPTION_RAW,RAW_CONTENT
設計書,/docs/code-list/claims-codes.xlsx,Sheet1:Row10,v2.1,T_CLAIM,clm_stat_cd,,,01,申請中,,"{""original_text"":""01: 申請中""}"
```

### 5.3 AI 抽出結果 JSON（ソースコード・画面定義由来）

extraction/ に格納する JSON：

```json
{
  "source_type": "ソースコード",
  "source_identifier": "src/main/java/com/example/ClaimStatus.java",
  "source_version": "abc1234",
  "extractions": [
    {
      "extraction_type": "code_value",
      "table_physical_name": "T_CLAIM",
      "column_physical_name": "clm_stat_cd",
      "code_value": "01",
      "code_label_raw": "申請中",
      "source_location": "Line 15-20, enum ClaimStatus"
    }
  ]
}
```

## 6. ファイル一覧

| ファイル | 内容 |
|---|---|
| [01-stage-to-bronze.sql](01-stage-to-bronze.sql) | structured CSV / JSON → Bronze 取り込みプロシージャ |
| [02-bronze-to-silver.sql](02-bronze-to-silver.sql) | 名寄せ・正規化・競合検知のストアドプロシージャ |
| [03-silver-description-generation-sample.sql](03-silver-description-generation-sample.sql) | Bronze原文（主根拠）＋Cortex Search社内ガイドRAG（参考情報）による列説明文候補（`COLUMN_DESCRIPTION_CANDIDATE`）生成のお試し実装サンプル（1テーブル分） |
