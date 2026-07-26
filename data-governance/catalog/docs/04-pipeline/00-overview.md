# データパイプライン設計：Stage → Bronze → Silver

- 作成日：2026-07-23
- ステータス：ドラフト（レビュー前）
- 関連：[02-data-transformation/01-conversion-policy.md](../02-data-transformation/01-conversion-policy.md)、[03-schema-design/01-architecture.md](../03-schema-design/01-architecture.md)、[03-schema-design/02-table-definitions.md](../03-schema-design/02-table-definitions.md)

## 1. パイプライン全体像

```
[収集対象システム]
  ・設計書（Excel/CSV）
  ・ソースコード（JSON抽出結果）
  ・画面定義（JSON抽出結果）
  ・コードマスタ(Excel → CSV変換)
        │
        │  ファイルアップロード（PUT / 外部ステージ連携）
        ▼
┌──────────────────────────────────────────────────┐
│ Snowflake Internal Stage                          │
│   @DG_CATALOG.BRONZE.STG_COLUMN_DEF_FILES         │
│   @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES     │
│                                                    │
│   ファイルフォーマット:                            │
│     FF_COLUMN_DEF_CSV  … 列名定義（CSV）           │
│     FF_CODE_VALUE_CSV  … 区分値定義（CSV）          │
│     FF_EXTRACTION_JSON … AI抽出結果（JSON）         │
└──────────────────────────────────────────────────┘
        │
        │  COPY INTO（01-stage-to-bronze.sql）
        ▼
┌──────────────────────────────────────────────────┐
│ Bronze層                                          │
│   RAW_COLUMN_DEFINITION                           │
│   RAW_CODE_VALUE_DEFINITION                       │
│   （メタ情報付き生データ。追記のみ）              │
└──────────────────────────────────────────────────┘
        │
        │  名寄せ・正規化・競合検知（02-bronze-to-silver.sql）
        ▼
┌──────────────────────────────────────────────────┐
│ Silver層                                          │
│   STG_COLUMN_CANDIDATE                            │
│   STG_CODE_VALUE_CANDIDATE                        │
│   （名寄せ候補。MERGE で差分更新）                │
└──────────────────────────────────────────────────┘
```

## 2. 実行単位とバッチ管理

各パイプラインは `META.COLLECTION_BATCH` のバッチレコードと紐づく。

| ステップ | バッチ種別 | 実行頻度（想定） | 概要 |
|---|---|---|---|
| Stage → Bronze | `収集` | 週次 | ステージ上のファイルを Bronze テーブルへ COPY INTO |
| Bronze → Silver | `名寄せ` | 収集バッチ完了後に自動起動 | Bronze レコードをグルーピング・名寄せして Silver へ MERGE |
| Silver → Gold | `昇格` | 名寄せバッチ完了後（自動昇格 + レビュー後確定） | 別ドキュメントで設計予定 |

## 3. ファイル命名規約

Stage にアップロードするファイルは以下の命名規約に従う。

### 3.1 命名フォーマット

```
<ソース種別プレフィックス>_<テーブル物理名>_<YYYYMMDD>.<拡張子>
```

### 3.2 ソース種別プレフィックス

| プレフィックス | ソース種別 | 拡張子 | 格納先ステージ |
|---|---|---|---|
| `excel` | コードマスタ(Excel) | `.csv` | `STG_CODE_VALUE_DEF_FILES` または `STG_COLUMN_DEF_FILES` |
| `design` | 設計書 | `.csv` | `STG_COLUMN_DEF_FILES` または `STG_CODE_VALUE_DEF_FILES` |
| `src` | ソースコード（AI抽出結果） | `.json` | `STG_EXTRACTION_JSON_FILES` |
| `screen` | 画面定義（AI抽出結果） | `.json` | `STG_EXTRACTION_JSON_FILES` |

### 3.3 命名例

| ファイル名 | 内容 |
|---|---|
| `excel_T_CLAIM_20260726.csv` | コードマスタ(Excel) から出力した区分値定義 |
| `design_T_CLAIM_20260726.csv` | 設計書から出力した列名定義 |
| `src_T_CLAIM_20260726.json` | ソースコードからの AI 抽出結果 |
| `screen_T_CLAIM_20260726.json` | 画面定義からの AI 抽出結果 |

### 3.4 COPY INTO 時のパターン指定

プレフィックスを使って、ソース種別ごとに取り込み対象を絞り込める。

```sql
-- Excel 由来のファイルだけ取り込む
COPY INTO ...
FROM @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES
PATTERN = 'excel_.*\.csv'
...;

-- 特定テーブルのファイルだけ取り込む
COPY INTO ...
FROM @DG_CATALOG.BRONZE.STG_CODE_VALUE_DEF_FILES
PATTERN = '.*_T_CLAIM_.*\.csv'
...;
```

## 4. ファイル仕様

### 4.1 列名定義 CSV（設計書・コードマスタ由来）

```
SOURCE_TYPE,SOURCE_IDENTIFIER,SOURCE_LOCATION,SOURCE_VERSION,TABLE_PHYSICAL_NAME,COLUMN_PHYSICAL_NAME,COLUMN_LOGICAL_NAME_RAW,RAW_CONTENT
設計書,/docs/table-spec/claims.xlsx,Sheet1:Row5,v2.1,T_CLAIM,clm_stat_cd,請求ステータスコード,"{""original_text"":""請求ステータスコード""}"
```

### 4.2 区分値定義 CSV（設計書・コードマスタ由来）

```
SOURCE_TYPE,SOURCE_IDENTIFIER,SOURCE_LOCATION,SOURCE_VERSION,TABLE_PHYSICAL_NAME,COLUMN_PHYSICAL_NAME,CONTEXT_COLUMN_NAME_RAW,CONTEXT_VALUE_RAW,CODE_VALUE,CODE_LABEL_RAW,CODE_DESCRIPTION_RAW,RAW_CONTENT
設計書,/docs/code-list/claims-codes.xlsx,Sheet1:Row10,v2.1,T_CLAIM,clm_stat_cd,,,01,申請中,,"{""original_text"":""01: 申請中""}"
```

### 4.3 AI 抽出結果 JSON（ソースコード・画面定義由来）

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

## 5. ファイル一覧

| ファイル | 内容 |
|---|---|
| [01-stage-to-bronze.sql](01-stage-to-bronze.sql) | ステージ定義・ファイルフォーマット定義・COPY INTO ストアドプロシージャ |
| [02-bronze-to-silver.sql](02-bronze-to-silver.sql) | 名寄せ・正規化・競合検知のストアドプロシージャ |
