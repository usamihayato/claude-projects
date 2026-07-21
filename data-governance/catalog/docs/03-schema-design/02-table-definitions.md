# テーブル・スキーマ・DB構成の設計（2）：テーブル定義

- 作成日：2026-07-21
- ステータス：ドラフト（レビュー前）
- 関連：[01-architecture.md](01-architecture.md)、DDL: [ddl/01_bronze.sql](ddl/01_bronze.sql) / [ddl/02_silver.sql](ddl/02_silver.sql) / [ddl/03_gold.sql](ddl/03_gold.sql)

対象DB：`DG_CATALOG`（Snowflake）

## 1. META スキーマ（運用メタデータ）

### 1.1 `META.SOURCE_SYSTEM`（収集対象システム管理）

| 列名 | 型 | 説明 |
|---|---|---|
| SOURCE_SYSTEM_ID | NUMBER | PK |
| SOURCE_SYSTEM_NAME | VARCHAR | 収集対象システム名（画面あり業務システム） |
| REPOSITORY_URL | VARCHAR | ソースコードリポジトリの参照先 |
| DOCUMENT_REPOSITORY_PATH | VARCHAR | 設計書の格納場所 |
| OWNER | VARCHAR | システム所管部署・担当者 |
| REMARKS | VARCHAR | 備考 |
| CREATED_AT | TIMESTAMP_NTZ | 登録日時 |

### 1.2 `META.COLLECTION_BATCH`（収集・変換バッチ管理）

| 列名 | 型 | 説明 |
|---|---|---|
| BATCH_ID | NUMBER | PK |
| BATCH_TYPE | VARCHAR | `収集` / `名寄せ` / `昇格` のいずれか |
| SOURCE_SYSTEM_ID | NUMBER | FK: `META.SOURCE_SYSTEM` |
| STARTED_AT | TIMESTAMP_NTZ | 実行開始日時 |
| COMPLETED_AT | TIMESTAMP_NTZ | 実行完了日時 |
| STATUS | VARCHAR | `実行中` / `成功` / `失敗` |
| REMARKS | VARCHAR | 備考（失敗時のエラー内容等） |

## 2. BRONZE スキーマ（メタ情報付き生データ）

### 2.1 `BRONZE.RAW_COLUMN_DEFINITION`（列名定義の抽出結果）

| 列名 | 型 | 説明 |
|---|---|---|
| RAW_ID | NUMBER | PK |
| BATCH_ID | NUMBER | FK: `META.COLLECTION_BATCH` |
| SOURCE_TYPE | VARCHAR | `設計書` / `ソースコード` / `画面定義` |
| SOURCE_IDENTIFIER | VARCHAR | ファイルパス／リポジトリ名／ドキュメント名 |
| SOURCE_LOCATION | VARCHAR | シート名／行番号／クラス名など詳細位置 |
| SOURCE_VERSION | VARCHAR | ドキュメントバージョン／コミットハッシュ |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名 |
| COLUMN_LOGICAL_NAME_RAW | VARCHAR | 抽出された論理名候補（正規化前） |
| RAW_CONTENT | VARIANT | 抽出元の生データ（原文をそのまま保持） |
| EXTRACTED_AT | TIMESTAMP_NTZ | 抽出日時 |
| CREATED_AT | TIMESTAMP_NTZ | Bronze層への格納日時 |

### 2.2 `BRONZE.RAW_CODE_VALUE_DEFINITION`（区分値定義の抽出結果）

| 列名 | 型 | 説明 |
|---|---|---|
| RAW_ID | NUMBER | PK |
| BATCH_ID | NUMBER | FK: `META.COLLECTION_BATCH` |
| SOURCE_TYPE | VARCHAR | `設計書` / `ソースコード` / `画面定義` |
| SOURCE_IDENTIFIER | VARCHAR | ファイルパス／リポジトリ名／ドキュメント名 |
| SOURCE_LOCATION | VARCHAR | シート名／行番号／クラス名など詳細位置 |
| SOURCE_VERSION | VARCHAR | ドキュメントバージョン／コミットハッシュ |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名（区分値が格納される列） |
| CONTEXT_COLUMN_NAME_RAW | VARCHAR | 区分値の意味を左右する判別列の物理名（同一テーブル内の別列。商品種別コード・国コード等）。コンテキストがない場合は `NULL` |
| CONTEXT_VALUE_RAW | VARCHAR | 判別列の値（正規化前）。コンテキストがない場合は `NULL` |
| CODE_VALUE | VARCHAR | 区分値（コード値。型が混在しうるため文字列で保持） |
| CODE_LABEL_RAW | VARCHAR | 抽出された表示ラベル候補（正規化前） |
| CODE_DESCRIPTION_RAW | VARCHAR | 補足説明（あれば） |
| RAW_CONTENT | VARIANT | 抽出元の生データ |
| EXTRACTED_AT | TIMESTAMP_NTZ | 抽出日時 |
| CREATED_AT | TIMESTAMP_NTZ | Bronze層への格納日時 |

## 3. SILVER スキーマ（名寄せ中の中間テーブル）

### 3.1 `SILVER.STG_COLUMN_CANDIDATE`（列名対応の名寄せ候補）

| 列名 | 型 | 説明 |
|---|---|---|
| STG_ID | NUMBER | PK |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名 |
| COLUMN_LOGICAL_NAME_CANDIDATE | VARCHAR | 名寄せ後の論理名候補（優先順位に基づく暫定採用値） |
| CONFLICT_FLAG | BOOLEAN | ソース間で内容が一致しない場合に `TRUE` |
| NEEDS_REVIEW_FLAG | BOOLEAN | 該当ソースが1件のみ等、要確認の場合に `TRUE` |
| CANDIDATE_VALUES | VARIANT | 各ソースでの値・優先度・出典の一覧（競合内容の詳細） |
| SOURCE_RAW_IDS | ARRAY | 集約元となった `BRONZE.RAW_COLUMN_DEFINITION.RAW_ID` の一覧 |
| MATCHING_BATCH_ID | NUMBER | FK: `META.COLLECTION_BATCH`（名寄せ実行バッチ） |
| UPDATED_AT | TIMESTAMP_NTZ | 更新日時 |

### 3.2 `SILVER.STG_CODE_VALUE_CANDIDATE`（区分値対応の名寄せ候補）

| 列名 | 型 | 説明 |
|---|---|---|
| STG_ID | NUMBER | PK |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名 |
| CONTEXT_COLUMN_NAME | VARCHAR | 判別列の物理名（正規化後）。コンテキストがない場合は `NULL`（共通） |
| CONTEXT_VALUE | VARCHAR | 判別列の値（正規化後）。コンテキストがない場合は `NULL`（共通） |
| CODE_VALUE | VARCHAR | 区分値（コード値） |
| CODE_LABEL_CANDIDATE | VARCHAR | 名寄せ後の表示ラベル候補 |
| CODE_DESCRIPTION_CANDIDATE | VARCHAR | 名寄せ後の補足説明候補 |
| CONFLICT_FLAG | BOOLEAN | ソース間で内容が一致しない場合に `TRUE` |
| NEEDS_REVIEW_FLAG | BOOLEAN | 要確認の場合に `TRUE`（判別列の後発見時も強制的に `TRUE`） |
| CANDIDATE_VALUES | VARIANT | 各ソースでの値・優先度・出典の一覧 |
| SOURCE_RAW_IDS | ARRAY | 集約元となった `BRONZE.RAW_CODE_VALUE_DEFINITION.RAW_ID` の一覧 |
| MATCHING_BATCH_ID | NUMBER | FK: `META.COLLECTION_BATCH` |
| UPDATED_AT | TIMESTAMP_NTZ | 更新日時 |

## 4. GOLD スキーマ（確定済みマスタ）

いずれも SCD Type2 相当の版管理（`VALID_FROM` / `VALID_TO` / `IS_CURRENT`）を持つ。

### 4.1 `GOLD.DIM_COLUMN_MASTER`（列定義マスタ）

| 列名 | 型 | 説明 |
|---|---|---|
| COLUMN_MASTER_ID | NUMBER | PK |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名 |
| COLUMN_LOGICAL_NAME | VARCHAR | 確定した論理名（業務名） |
| COLUMN_DESCRIPTION | VARCHAR | 列の説明 |
| VALID_FROM | DATE | 有効開始日 |
| VALID_TO | DATE | 有効終了日（現在有効な場合は `NULL`） |
| IS_CURRENT | BOOLEAN | 現在有効なレコードかどうか |
| SOURCE_STG_ID | NUMBER | FK: `SILVER.STG_COLUMN_CANDIDATE`（確定根拠） |
| REVIEWED_BY | VARCHAR | レビュー・確定した担当者（自動昇格の場合は `SYSTEM`） |
| REVIEWED_AT | TIMESTAMP_NTZ | レビュー・確定日時 |
| CREATED_AT | TIMESTAMP_NTZ | Gold層への格納日時 |

### 4.2 `GOLD.DIM_CODE_VALUE_MASTER`（区分値マスタ）

| 列名 | 型 | 説明 |
|---|---|---|
| CODE_VALUE_MASTER_ID | NUMBER | PK |
| TABLE_PHYSICAL_NAME | VARCHAR | 対象テーブル物理名 |
| COLUMN_PHYSICAL_NAME | VARCHAR | 対象列物理名 |
| CONTEXT_COLUMN_NAME | VARCHAR | 判別列の物理名。コンテキストがない場合は `NULL`（共通） |
| CONTEXT_VALUE | VARCHAR | 判別列の値。コンテキストがない場合は `NULL`（共通） |
| CODE_VALUE | VARCHAR | 区分値（コード値） |
| CODE_LABEL | VARCHAR | 確定した表示ラベル |
| CODE_DESCRIPTION | VARCHAR | 補足説明 |
| VALID_FROM | DATE | 有効開始日 |
| VALID_TO | DATE | 有効終了日（現在有効な場合は `NULL`。判別列の後発見時は発見日を設定して無効化） |
| IS_CURRENT | BOOLEAN | 現在有効なレコードかどうか |
| SOURCE_STG_ID | NUMBER | FK: `SILVER.STG_CODE_VALUE_CANDIDATE`（確定根拠） |
| REVIEWED_BY | VARCHAR | レビュー・確定した担当者（自動昇格の場合は `SYSTEM`） |
| REVIEWED_AT | TIMESTAMP_NTZ | レビュー・確定日時 |
| CREATED_AT | TIMESTAMP_NTZ | Gold層への格納日時 |

## 5. 利用イメージ（Gold層参照クエリ例）

対象DBの物理名データを、カタログを使って人が理解できる形に変換して参照するイメージ。

```sql
-- 対象DBの生データ（物理名・区分値のまま）に対して
-- Gold層のマスタをJOINし、論理名・表示ラベルを付与する例
-- （clm_stat_cd はテーブル内の product_type_cd の値によって意味が変わる想定。
--   コンテキストなしの共通レコード（CONTEXT_VALUE IS NULL）はフォールバックとして
--   優先度を下げてCOALESCEする）
SELECT
    src.clm_stat_cd                                AS raw_code_value,
    COALESCE(code_m_ctx.CODE_LABEL, code_m_common.CODE_LABEL) AS status_label,
    col_m.COLUMN_LOGICAL_NAME                       AS column_logical_name
FROM  対象db.対象スキーマ.対象テーブル       AS src
LEFT JOIN DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER  AS code_m_ctx
       ON code_m_ctx.TABLE_PHYSICAL_NAME  = '対象テーブル'
      AND code_m_ctx.COLUMN_PHYSICAL_NAME = 'clm_stat_cd'
      AND code_m_ctx.CODE_VALUE           = src.clm_stat_cd
      AND code_m_ctx.CONTEXT_COLUMN_NAME  = 'product_type_cd'
      AND code_m_ctx.CONTEXT_VALUE        = src.product_type_cd
      AND code_m_ctx.IS_CURRENT           = TRUE
LEFT JOIN DG_CATALOG.GOLD.DIM_CODE_VALUE_MASTER  AS code_m_common
       ON code_m_common.TABLE_PHYSICAL_NAME  = '対象テーブル'
      AND code_m_common.COLUMN_PHYSICAL_NAME = 'clm_stat_cd'
      AND code_m_common.CODE_VALUE           = src.clm_stat_cd
      AND code_m_common.CONTEXT_VALUE        IS NULL
      AND code_m_common.IS_CURRENT           = TRUE
LEFT JOIN DG_CATALOG.GOLD.DIM_COLUMN_MASTER      AS col_m
       ON col_m.TABLE_PHYSICAL_NAME   = '対象テーブル'
      AND col_m.COLUMN_PHYSICAL_NAME  = 'clm_stat_cd'
      AND col_m.IS_CURRENT            = TRUE;
```
