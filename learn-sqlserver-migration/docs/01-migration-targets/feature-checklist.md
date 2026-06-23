# SQL Server 現行機能 棚卸しチェックリスト

> **目的**: 現行 SQL Server で使っている機能を把握し、移行可能なサービスを絞り込む  
> **記入方法**:
>
> | 列 | 記入内容 |
> |---|---|
> | **検知** | SQL の実行結果をそのまま記録（例: `3件` / `syspolicy_purge_history` / `0件`） |
> | **判定** | システムジョブ等を除外した上で最終判断。`☑ 要対応` または `- 不要` |
>
> → **検知と判定は別物**。SQLに引っかかっても、システム標準のものは判定で除外してよい  
> → **判定列の結果が、後続の移行先選定・ノックアウト要件確認の前提になる**

---

## 実行DBの凡例

| 表記 | 意味 | 接続方法 |
|---|---|---|
| `master` | サーバーレベルの情報。master DB で実行 | SSMS で接続後、DB を `master` に変更 |
| `msdb` | SQL Agent・メール等の管理情報。msdb DB で実行 | SSMS で接続後、DB を `msdb` に変更 |
| `各対象DB` | DB ごとに情報が異なる。移行対象 DB に切り替えて実行 | USE \[DB名\] を先頭に付けて実行 |

---

## 記入前に実行する一括確認クエリ（SSMS で実行）

以下を最初に実行しておくと、各セクションの確認が速くなる。

```sql
-- ① サーバー設定一覧（xp_cmdshell 有効化など）  ← master で実行
SELECT name, value_in_use FROM sys.configurations ORDER BY name;

-- ② データベース一覧と互換性レベル・サイズ  ← master で実行
SELECT
    name,
    compatibility_level,
    (SELECT SUM(size) * 8 / 1024 FROM sys.master_files WHERE database_id = d.database_id) AS size_MB
FROM sys.databases d
WHERE database_id > 4;

-- ③ リンクサーバー一覧  ← master で実行
SELECT name, product, provider FROM sys.servers WHERE is_linked = 1;

-- ④ CLR アセンブリ一覧  ← 各対象DB で実行
SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1;

-- ⑤ SQL Agent ジョブ一覧  ← msdb で実行
SELECT name, enabled FROM msdb.dbo.sysjobs ORDER BY name;

-- ⑥ レプリケーション（パブリッシャー確認）  ← master で実行
SELECT name FROM sys.databases WHERE is_published = 1 OR is_subscribed = 1;

-- ⑦ CDC（変更データキャプチャ）有効DB  ← master で実行
SELECT name FROM sys.databases WHERE is_cdc_enabled = 1;

-- ⑧ Service Broker 有効DB  ← master で実行
SELECT name FROM sys.databases WHERE is_broker_enabled = 1;

-- ⑨ FILESTREAM 設定  ← master で実行
SELECT SERVERPROPERTY('FilestreamEffectiveLevel') AS filestream_level;

-- ⑩ Full-Text Search カタログ  ← 各対象DB で実行
SELECT name FROM sys.fulltext_catalogs;

-- ⑪ 変更追跡（Change Tracking）有効DB  ← master で実行
SELECT DB_NAME(database_id) AS db_name FROM sys.change_tracking_databases;

-- ⑫ Windows ログイン一覧  ← master で実行
SELECT name, type_desc FROM sys.server_principals WHERE type IN ('U','G') AND name NOT LIKE 'NT %';

-- ⑬ SQL Agent ジョブの OS コマンド / SSIS ステップ一覧  ← msdb で実行
SELECT j.name AS job_name, s.step_name, s.subsystem
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.subsystem IN ('CmdExec','SSIS','ISAPACKAGE','PowerShell')
ORDER BY j.name;
```

---

## カテゴリ 1｜OS・サーバーレベルの依存

> **ここでチェックがあると SQL on VM 確定（PaaS 移行不可）**

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 1-1 | **xp_cmdshell**（OS コマンド実行） | master | `SELECT value_in_use FROM sys.configurations WHERE name = 'xp_cmdshell'`（1なら使用） | | - |
| 1-2 | **FILESTREAM / FileTable**（ファイルシステム連携） | master | `SELECT SERVERPROPERTY('FilestreamEffectiveLevel')`（0以外なら使用） | | - |
| 1-3 | **OS レベルの外部プロセス呼び出し**（PowerShell / バッチ / シェル実行） | msdb | `SELECT j.name, s.step_name, s.subsystem FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id WHERE s.subsystem IN ('CmdExec','PowerShell')` | | - |
| 1-4 | **カスタム ETL ツール（SSIS パッケージのローカル実行）** | msdb | `SELECT j.name, s.step_name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id WHERE s.subsystem IN ('SSIS','ISAPACKAGE')` | | - |

**→ 1-1〜1-4 のいずれかに ☑ がある場合: `SQL Server on Azure VM` 一択**

---

## カテゴリ 2｜SQL Server エージェント・スケジューリング

> **ここでチェックがあると SQL MI 以上が必要（SQL Database / Synapse は不可）**

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 2-1 | **SQL Server Agent ジョブ**（定期ジョブ全般） | msdb | `SELECT name, enabled FROM msdb.dbo.sysjobs ORDER BY name`（システムジョブ除外後の件数を判定に記録） | | - |
| 2-2 | **メンテナンスプラン**（バックアップ・統計更新・DBCC等の自動化） | msdb | `SELECT name FROM msdb.dbo.sysmaintplan_plans` | | - |
| 2-3 | **Database Mail**（ジョブ通知・アラートメール） | msdb | `SELECT name FROM msdb.dbo.sysmail_profile` | | - |
| 2-4 | **SQL Server Agent アラート**（エラー・パフォーマンス監視） | msdb | `SELECT name, message_id FROM msdb.dbo.sysalerts` | | - |

**→ 2-1〜2-4 のいずれかに ☑ がある場合: `SQL MI` または `SQL on VM`**

> **2-1 の判定メモ（システムジョブは除外してよい）**  
> 以下は SQL Server が自動生成する標準ジョブ。検知されても判定は `-`（移行不要）
> - `syspolicy_purge_history` — ポリシー管理履歴のパージ（SQL MI では不要）
> - `sp_delete_backuphistory` — バックアップ履歴の削除
> - `sp_purge_jobhistory` — ジョブ実行履歴の削除
> - `DatabaseIntegrityCheck`〜`IndexOptimize`（Ola Hallengren 標準スクリプト由来も同様に判断）

---

## カテゴリ 3｜外部接続・連携

> **異種 DBMS への接続は SQL on VM 確定。SQL Server 同士は SQL MI で可**

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 3-1 | **Linked Server（SQL Server → SQL Server）** | master | `SELECT name, product FROM sys.servers WHERE is_linked = 1` | | - |
| 3-2 | **Linked Server（SQL Server → Oracle / DB2 / その他）** | master | `SELECT name, product FROM sys.servers WHERE is_linked = 1 AND product <> 'SQL Server'` | | - |
| 3-3 | **MSDTC（分散トランザクション）** | 各対象DB | `SELECT OBJECT_NAME(object_id) FROM sys.sql_modules WHERE definition LIKE '%DISTRIBUTED TRANSACTION%'` | | - |
| 3-4 | **OpenRowSet / OpenDataSource（アドホック外部接続）** | 各対象DB | `SELECT OBJECT_NAME(object_id) FROM sys.sql_modules WHERE definition LIKE '%OPENROWSET%' OR definition LIKE '%OPENDATASOURCE%'` | | - |

**判定:**
- 3-2 に ☑ → `SQL on VM` 一択（SQL MI は異種 DBMS Linked Server 非対応）
- 3-1 / 3-3 / 3-4 に ☑ → `SQL MI` または `SQL on VM`

---

## カテゴリ 4｜プログラマビリティ

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 4-1 | **CLR 統合（SAFE アセンブリ）** | 各対象DB | `SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1` | | - |
| 4-2 | **CLR 統合（UNSAFE / EXTERNAL_ACCESS アセンブリ）** | 各対象DB | `SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1 AND permission_set_desc IN ('UNSAFE_ACCESS','EXTERNAL_ACCESS')` | | - |
| 4-3 | **ストアドプロシージャ・UDF・ビュー** | 各対象DB | `SELECT type_desc AS 種類, COUNT(*) AS 件数 FROM sys.objects WHERE type IN ('P','FN','V') AND is_ms_shipped = 0 GROUP BY type_desc` | | - |
| 4-4 | **サーバーレベル DDL トリガー** | master | `SELECT t.name, t.is_disabled, e.event_group_type_desc FROM sys.server_triggers t LEFT JOIN sys.server_trigger_events e ON t.object_id = e.object_id` | | - |
| 4-5 | **sp_configure（サーバー設定の変更）** | 各対象DB | `SELECT OBJECT_NAME(object_id) FROM sys.sql_modules WHERE definition LIKE '%sp_configure%'` | | - |
| 4-6 | **クロスDB参照・リモート実行**（Azure SQL DB 互換性警告） | 各対象DB | `SELECT OBJECT_NAME(object_id) AS object_name FROM sys.sql_modules WHERE definition LIKE '%].dbo.%' OR definition LIKE '% AT [%' ORDER BY OBJECT_NAME(object_id)` | | - |

**判定:**
- 4-2 に ☑ → `SQL on VM` 一択（CLR UNSAFE は SQL MI 非対応）
- 4-1 に ☑ → `SQL MI` 以上（SQL DB は CLR 非対応）
- 4-5 に ☑ → `SQL MI` 以上（SQL DB は sp_configure 非対応）
- 4-3 のみ ☑（ビュー・SP・UDF の件数が多い）→ **SQL DB でも問題なし**（BACPAC / DMS でスキーマごと移行されるため件数は移行先選定に影響しない）
- 4-4 に ☑ → `SQL MI` 以上（SQL DB はサーバーレベル DDL トリガー非対応）
- 4-6 に ☑（クロスDB参照あり）→ **SQL DB は原則不可**（DB 間クエリ非対応のためビュー・SP がエラーになる）。`SQL MI` を推奨（同一インスタンス内なら追加設定なしでそのまま動作）

---

## カテゴリ 5｜レプリケーション・変更管理

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 5-1 | **トランザクション レプリケーション（パブリッシャー）** | master | `SELECT name FROM sys.databases WHERE is_published = 1` | | - |
| 5-2 | **マージ レプリケーション** | master | `SELECT name FROM sys.databases WHERE is_merge_published = 1` | | - |
| 5-3 | **スナップショット レプリケーション** | master | `SELECT name FROM sys.databases WHERE is_published = 1`（5-1 と同一フラグ。区別は distribution DB の `MSPublications.publication_type = 0` で確認） | | - |
| 5-4 | **変更データキャプチャ（CDC）** | master | `SELECT name FROM sys.databases WHERE is_cdc_enabled = 1` | | - |
| 5-5 | **変更追跡（Change Tracking）** | master | `SELECT DB_NAME(database_id) AS db_name FROM sys.change_tracking_databases` | | - |

**判定:**
- 5-2 に ☑ → `SQL on VM` 一択（マージレプリは SQL MI 非対応）
- 5-1 / 5-3 に ☑ → `SQL MI` または `SQL on VM`
- 5-4 / 5-5 に ☑ → `SQL MI` / `SQL DB` / `SQL on VM` すべて対応

---

## カテゴリ 6｜非同期・メッセージング

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 6-1 | **Service Broker（DB 内部メッセージングのみ）** | master | `SELECT name FROM sys.databases WHERE is_broker_enabled = 1 AND database_id > 4` | | - |
| 6-2 | **Service Broker（外部アクティベーション：SQL 外のプロセス呼び出し）** | 各対象DB | `SELECT name, activation_procedure FROM sys.service_queues WHERE activation_procedure IS NOT NULL` | | - |

**判定:**
- 6-2 に ☑ → `SQL on VM` 一択（外部アクティベーションは SQL MI 非対応）
- 6-1 のみ ☑ → `SQL MI` または `SQL on VM`

---

## カテゴリ 7｜全文検索・高度データ機能

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 7-1 | **Full-Text Search（全文検索）** | 各対象DB | `SELECT name FROM sys.fulltext_catalogs` | | - |
| 7-2 | **In-Memory OLTP（メモリ最適化テーブル）** | 各対象DB | `SELECT name FROM sys.filegroups WHERE type = 'FX'` | | - |
| 7-3 | **テンポラル テーブル（履歴テーブル）** | 各対象DB | `SELECT name FROM sys.tables WHERE temporal_type = 2` | | - |
| 7-4 | **パーティション テーブル / パーティション関数** | 各対象DB | `SELECT COUNT(*) FROM sys.partition_functions` | | - |
| 7-5 | **データ圧縮（行・ページ圧縮）** | 各対象DB | `SELECT COUNT(*) FROM sys.partitions WHERE data_compression > 0` | | - |

**判定:**
- 7-1〜7-5 いずれも `SQL DB` / `SQL MI` / `SQL on VM` で対応可
- ただし 7-2（In-Memory OLTP）は SQL DB では Premium 以上が必要

---

## カテゴリ 8｜セキュリティ・暗号化

| # | 機能 | 実行DB | 確認SQL | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 8-1 | **Windows 認証（Active Directory）** | master | `SELECT name, type_desc FROM sys.server_principals WHERE type IN ('U','G') AND name NOT LIKE 'NT %'` | | - |
| 8-2 | **SQL 認証（ユーザー名・パスワード）** | master | `SELECT name FROM sys.sql_logins WHERE name NOT LIKE '##%'` | | - |
| 8-3 | **TDE（透過的データ暗号化）** | master | `SELECT name FROM sys.databases WHERE is_encrypted = 1` | | - |
| 8-4 | **Always Encrypted（列レベル暗号化）** | 各対象DB | `SELECT name FROM sys.column_encryption_keys` | | - |
| 8-5 | **行レベル セキュリティ（RLS）** | 各対象DB | `SELECT name, is_enabled FROM sys.security_policies` | | - |

**判定:**
- 8-1〜8-5 いずれも `SQL DB` / `SQL MI` / `SQL on VM` で対応可
- SQL MI へ移行する場合、TDE は**デフォルト有効**（オンプレ側が TDE なしでも自動で有効になる点に注意）

---

## カテゴリ 9｜ワークロードの性質

> **ここは移行先の大分類（OLTP vs アーカイブ）を決める**

| # | 質問 | 実行DB | 確認SQL / 確認方法 | 検知 | 判定 |
|---|---|:---:|---|---|:---:|
| 9-1 | 移行後も **INSERT / UPDATE / DELETE** が発生するか | — | 業務担当者へヒアリング | | - |
| 9-2 | 移行後は **SELECT（参照のみ）** になるか | — | 業務担当者へヒアリング | | - |
| 9-3 | **データ量は 1TB 以上** か | master | `SELECT SUM(size) * 8 / 1024 / 1024 AS total_GB FROM sys.master_files WHERE database_id > 4` | | - |
| 9-4 | **参照頻度が低い**（月数回程度）か | — | 業務担当者へヒアリング | | - |
| 9-5 | **Power BI / 分析ツール** からのクエリが主な用途か | — | 業務担当者へヒアリング | | - |

**判定:**
- 9-1 に ☑ → Synapse + ADLS は候補から外れる（READ_ONLY 専用のため）
- 9-2 かつ 9-3 / 9-4 に ☑ → **Synapse + ADLS が最安候補**
- 9-2 かつ 9-3 / 9-4 が `-` → **Azure SQL Database Serverless** が候補

---

## 判定サマリ

> チェックが終わったら以下の表を埋めて移行先を決定する

### Step 1｜移行先の絞り込み

| チェック結果 | 確定内容 |
|---|---|
| カテゴリ 1（1-1〜1-4）に ☑ がある | **→ SQL on VM 確定**（以降の判定不要） |
| 3-2（異種 DBMS Linked Server）に ☑ がある | **→ SQL on VM 確定** |
| 4-2（CLR UNSAFE）に ☑ がある | **→ SQL on VM 確定** |
| 5-2（マージレプリケーション）に ☑ がある | **→ SQL on VM 確定** |
| 6-2（Service Broker 外部アクティベーション）に ☑ がある | **→ SQL on VM 確定** |

### Step 2｜SQL on VM が確定していない場合

| チェック結果 | 確定内容 |
|---|---|
| カテゴリ 2 または 3-1 / 3-3 / 4-1 / 4-4 / 4-6 / 5-1 / 6-1 に ☑ がある | **→ SQL MI 以上**（SQL DB / Synapse は除外） |
| 上記が全て `-` | **→ SQL DB または Synapse + ADLS が候補** |

### Step 3｜SQL DB か Synapse かを決める

| チェック結果 | 確定内容 |
|---|---|
| カテゴリ 9-1（OLTP 継続）に ☑ がある | **→ SQL DB Serverless**（Synapse は除外） |
| 9-2 かつ（9-3 または 9-4）に ☑ がある | **→ Synapse + ADLS が最安候補** |
| 9-2 で 9-3 / 9-4 が `-`（小容量・高頻度） | **→ SQL DB Serverless**（接続変更なしで完結） |

---

### 判定結果記入欄

```
確定した移行先: [                                    ]

根拠となった機能:
  ・
  ・
  ・

次のアクション:
  □ 02-knockout-requirements/notes.md で解消策を確認する
  □ 04-cost-analysis/notes.md で TCO 試算を実施する
  □ 移行手順書（06-migration-procedures/）に進む
```

---

*作成日：2026-06-23*
