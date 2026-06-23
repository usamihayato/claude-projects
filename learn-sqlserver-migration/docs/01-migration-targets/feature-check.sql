/*
=============================================================================
 SQL Server 機能棚卸し 一括確認スクリプト
 対応チェックリスト: feature-checklist.md

 実行方法:
   1. SSMS 18.x で現行 SQL Server に接続する
   2. このファイルを開き F5 で全体実行する
   3. Messages タブの出力結果を feature-checklist.md の「検知」列に転記する

 実行順序:
   [SECTION 1] master DB  — サーバーレベルクエリ
   [SECTION 2] msdb DB    — SQL Agent・メールクエリ
   [SECTION 3] DB ループ  — 移行対象 DB ごとのクエリ
=============================================================================
*/

-- ============================================================
-- SECTION 1: master DB クエリ
-- ============================================================

USE master;
GO

PRINT '============================================================';
PRINT 'SECTION 1: master DB クエリ';
PRINT '============================================================';

PRINT '';
PRINT '[1-1] xp_cmdshell（OS コマンド実行）— value_in_use = 1 なら要対応';
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'xp_cmdshell';

PRINT '';
PRINT '[1-2] FILESTREAM / FileTable — 0 以外なら要対応';
SELECT SERVERPROPERTY('FilestreamEffectiveLevel') AS filestream_level;

PRINT '';
PRINT '[3-1] Linked Server（SQL Server 同士）';
SELECT name, product, provider
FROM sys.servers
WHERE is_linked = 1
  AND product = 'SQL Server';

PRINT '';
PRINT '[3-2] Linked Server（異種 DBMS）← SQL on VM 確定要件';
SELECT name, product, provider
FROM sys.servers
WHERE is_linked = 1
  AND product <> 'SQL Server';

PRINT '';
PRINT '[4-4] サーバーレベル DDL トリガー';
SELECT t.name, t.is_disabled, e.event_group_type_desc
FROM sys.server_triggers      t
LEFT JOIN sys.server_trigger_events e ON t.object_id = e.object_id;

PRINT '';
PRINT '[5-1] トランザクション レプリケーション（パブリッシャー）';
SELECT name
FROM sys.databases
WHERE is_published = 1;

PRINT '';
PRINT '[5-2] マージ レプリケーション ← SQL on VM 確定要件';
SELECT name
FROM sys.databases
WHERE is_merge_published = 1;

PRINT '';
PRINT '[5-3] スナップショット レプリケーション';
PRINT '   ※ スナップショットは is_published = 1 に含まれる（5-1 と同一フラグ）';
PRINT '   ※ distribution DB が存在する場合のみ以下でスナップショット個別確認可能';
IF DB_ID('distribution') IS NOT NULL
BEGIN
    SELECT name
    FROM distribution.dbo.MSPublications
    WHERE publication_type = 0;
END
ELSE
BEGIN
    PRINT '   distribution DB 未構成のため個別確認不可 — 5-1 の結果を参照';
END

PRINT '';
PRINT '[5-4] CDC（変更データキャプチャ）有効 DB';
SELECT name
FROM sys.databases
WHERE is_cdc_enabled = 1;

PRINT '';
PRINT '[5-5] 変更追跡（Change Tracking）有効 DB';
SELECT DB_NAME(database_id) AS db_name
FROM sys.change_tracking_databases;

PRINT '';
PRINT '[6-1] Service Broker 有効 DB';
SELECT name
FROM sys.databases
WHERE is_broker_enabled = 1;

PRINT '';
PRINT '[8-1] Windows 認証ログイン（AD ユーザー・グループ）';
SELECT name, type_desc
FROM sys.server_principals
WHERE type IN ('U','G')
  AND name NOT LIKE 'NT %';

PRINT '';
PRINT '[8-2] SQL 認証ログイン';
SELECT name
FROM sys.sql_logins
WHERE name NOT LIKE '##%';

PRINT '';
PRINT '[8-3] TDE（透過的データ暗号化）有効 DB';
SELECT name
FROM sys.databases
WHERE is_encrypted = 1;

PRINT '';
PRINT '[9-3] 全データベースの合計データサイズ（GB）';
SELECT SUM(size) * 8 / 1024 / 1024 AS total_GB
FROM sys.master_files
WHERE database_id > 4;
GO

-- ============================================================
-- SECTION 2: msdb DB クエリ
-- ============================================================

USE msdb;
GO

PRINT '';
PRINT '============================================================';
PRINT 'SECTION 2: msdb DB クエリ';
PRINT '============================================================';

PRINT '';
PRINT '[1-3] OS レベルの外部プロセス呼び出し（CmdExec / PowerShell ステップ）';
SELECT j.name AS job_name, s.step_name, s.subsystem
FROM msdb.dbo.sysjobs     j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.subsystem IN ('CmdExec','PowerShell')
ORDER BY j.name;

PRINT '';
PRINT '[1-4] SSIS パッケージ実行ステップ';
SELECT j.name AS job_name, s.step_name, s.subsystem
FROM msdb.dbo.sysjobs     j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.subsystem IN ('SSIS','ISAPACKAGE')
ORDER BY j.name;

PRINT '';
PRINT '[2-1] SQL Server Agent ジョブ（システムジョブ除外後）';
PRINT '   ※ 除外: syspolicy_purge_history / sp_delete_backuphistory / sp_purge_jobhistory';
SELECT name, enabled
FROM msdb.dbo.sysjobs
WHERE name NOT IN (
    'syspolicy_purge_history',
    'sp_delete_backuphistory',
    'sp_purge_jobhistory'
)
ORDER BY name;

PRINT '';
PRINT '[2-2] メンテナンスプラン';
SELECT name
FROM msdb.dbo.sysmaintplan_plans;

PRINT '';
PRINT '[2-3] Database Mail プロファイル';
SELECT name
FROM msdb.dbo.sysmail_profile;

PRINT '';
PRINT '[2-4] SQL Server Agent アラート';
SELECT name, message_id
FROM msdb.dbo.sysalerts;

GO

-- ============================================================
-- SECTION 3: 各対象 DB ループ
-- 対象: 3-3 / 3-4 / 4-1〜4-3 / 4-5 / 6-2 / 7-1〜7-5 / 8-4 / 8-5
-- ============================================================

USE master;
GO

PRINT '';
PRINT '============================================================';
PRINT 'SECTION 3: 各対象 DB ループ（database_id > 4 かつ ONLINE の全 DB）';
PRINT '============================================================';
GO

DECLARE @dbname NVARCHAR(128);
DECLARE @sql    NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state_desc  = 'ONLINE'
    ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '';
    PRINT '----------------------------------------------';
    PRINT 'DB: ' + @dbname;
    PRINT '----------------------------------------------';

    -- [3-3] MSDTC（分散トランザクション）
    PRINT '[3-3] MSDTC 使用オブジェクト';
    SET @sql = N'USE [' + @dbname + N'];
SELECT OBJECT_NAME(object_id) AS object_name
FROM sys.sql_modules
WHERE definition LIKE ''%DISTRIBUTED TRANSACTION%'';';
    EXEC(@sql);

    -- [3-4] OpenRowSet / OpenDataSource
    PRINT '[3-4] OPENROWSET / OPENDATASOURCE 使用オブジェクト';
    SET @sql = N'USE [' + @dbname + N'];
SELECT OBJECT_NAME(object_id) AS object_name
FROM sys.sql_modules
WHERE definition LIKE ''%OPENROWSET%''
   OR definition LIKE ''%OPENDATASOURCE%'';';
    EXEC(@sql);

    -- [4-1] CLR SAFE アセンブリ
    PRINT '[4-1] CLR アセンブリ（SAFE）';
    SET @sql = N'USE [' + @dbname + N'];
SELECT name, permission_set_desc
FROM sys.assemblies
WHERE is_user_defined    = 1
  AND permission_set_desc = ''SAFE_ACCESS'';';
    EXEC(@sql);

    -- [4-2] CLR UNSAFE / EXTERNAL_ACCESS ← SQL on VM 確定要件
    PRINT '[4-2] CLR アセンブリ（UNSAFE / EXTERNAL_ACCESS）← SQL on VM 確定要件';
    SET @sql = N'USE [' + @dbname + N'];
SELECT name, permission_set_desc
FROM sys.assemblies
WHERE is_user_defined    = 1
  AND permission_set_desc IN (''UNSAFE_ACCESS'',''EXTERNAL_ACCESS'');';
    EXEC(@sql);

    -- [4-3] ストアドプロシージャ・UDF・ビュー（ユーザー定義のみ）
    PRINT '[4-3] ストアドプロシージャ・UDF・ビュー（ユーザー定義件数）';
    SET @sql = N'USE [' + @dbname + N'];
SELECT type_desc AS 種類, COUNT(*) AS 件数
FROM sys.objects
WHERE type IN (''P'',''FN'',''V'')
  AND is_ms_shipped = 0
GROUP BY type_desc;';
    EXEC(@sql);

    -- [4-5] sp_configure 使用オブジェクト
    PRINT '[4-5] sp_configure 使用オブジェクト';
    SET @sql = N'USE [' + @dbname + N'];
SELECT OBJECT_NAME(object_id) AS object_name
FROM sys.sql_modules
WHERE definition LIKE ''%sp_configure%'';';
    EXEC(@sql);

    -- [4-6] クロスDB参照・リモート実行（Azure SQL DB 互換性警告）
    PRINT '[4-6] クロスDB参照・リモート実行（Azure SQL DB 移行後に要動作確認）';
    SET @sql = N'USE [' + @dbname + N'];
SELECT OBJECT_NAME(object_id) AS object_name
FROM sys.sql_modules
WHERE definition LIKE ''%].dbo.%''
   OR definition LIKE ''% AT [%''
ORDER BY OBJECT_NAME(object_id);';
    EXEC(@sql);

    -- [6-2] Service Broker 外部アクティベーション ← SQL on VM 確定要件
    PRINT '[6-2] Service Broker 外部アクティベーション ← SQL on VM 確定要件';
    SET @sql = N'USE [' + @dbname + N'];
SELECT name, activation_procedure
FROM sys.service_queues
WHERE activation_procedure IS NOT NULL;';
    EXEC(@sql);

    -- [7-1] Full-Text Search カタログ
    PRINT '[7-1] Full-Text Search カタログ';
    SET @sql = N'USE [' + @dbname + N'];
SELECT name FROM sys.fulltext_catalogs;';
    EXEC(@sql);

    -- [7-2] In-Memory OLTP（メモリ最適化ファイルグループ）
    PRINT '[7-2] In-Memory OLTP（メモリ最適化ファイルグループ）';
    SET @sql = N'USE [' + @dbname + N'];
SELECT name FROM sys.filegroups WHERE type = ''FX'';';
    EXEC(@sql);

    -- [7-3] テンポラル テーブル（SQL Server 2016 以降の機能）
    PRINT '[7-3] テンポラル テーブル（SQL Server 2016 以降の機能）';
    BEGIN TRY
        SET @sql = N'USE [' + @dbname + N'];
SELECT name FROM sys.tables WHERE temporal_type = 2;';
        EXEC(@sql);
    END TRY
    BEGIN CATCH
        PRINT '   ※ SQL Server 2016 以降の機能（このバージョンでは対象外）';
    END CATCH;

    -- [7-4] パーティション関数件数
    PRINT '[7-4] パーティション関数件数';
    SET @sql = N'USE [' + @dbname + N'];
SELECT COUNT(*) AS 件数 FROM sys.partition_functions;';
    EXEC(@sql);

    -- [7-5] データ圧縮（圧縮設定パーティション件数）
    PRINT '[7-5] データ圧縮（圧縮設定パーティション件数）';
    SET @sql = N'USE [' + @dbname + N'];
SELECT COUNT(*) AS 件数 FROM sys.partitions WHERE data_compression > 0;';
    EXEC(@sql);

    -- [8-4] Always Encrypted（SQL Server 2016 以降の機能）
    PRINT '[8-4] Always Encrypted 列暗号化キー（SQL Server 2016 以降の機能）';
    BEGIN TRY
        SET @sql = N'USE [' + @dbname + N'];
SELECT name FROM sys.column_encryption_keys;';
        EXEC(@sql);
    END TRY
    BEGIN CATCH
        PRINT '   ※ SQL Server 2016 以降の機能（このバージョンでは対象外）';
    END CATCH;

    -- [8-5] 行レベル セキュリティ（SQL Server 2016 以降の機能）
    PRINT '[8-5] 行レベル セキュリティ ポリシー（SQL Server 2016 以降の機能）';
    BEGIN TRY
        SET @sql = N'USE [' + @dbname + N'];
SELECT name, is_enabled FROM sys.security_policies;';
        EXEC(@sql);
    END TRY
    BEGIN CATCH
        PRINT '   ※ SQL Server 2016 以降の機能（このバージョンでは対象外）';
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @dbname;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
GO

-- ============================================================
-- 完了
-- ============================================================

PRINT '';
PRINT '============================================================';
PRINT 'スクリプト実行完了';
PRINT '次のアクション:';
PRINT '  1. Messages タブの結果を feature-checklist.md の「検知」列に記録する';
PRINT '  2. システムジョブ等を除外し「判定」列を記入する';
PRINT '  3. 判定サマリで移行先を確定する';
PRINT '============================================================';
GO
