# 移行手順書 ファクトチェック結果

検証日：2026-06-22  
対象：`01-verification-procedure.md` / `02-production-dms-procedure.md`  
情報源：Microsoft Learn 公式ドキュメント

---

## チェック項目一覧

| # | 確認内容 | 結果 | 備考 |
|---|---|---|---|
| 1 | SSMS 18.x で SQL Server 2008 R2 に接続可能 | ✅ 正確 | SSMS 18.x は SQL Server 2008〜2019 をサポート |
| 2 | SSMS 19以降は SQL Server 2008 R2 接続に問題あり | ✅ 実態と一致（要補足） | 原因はTLS互換性問題。SSMS 20以降はワークアラウンド不可。SSMS 22の公式サポートはSQL Server 2014以降 |
| 3 | SqlPackage `/Action:Export` のパラメータ名 | ✅ 正確 | `/SourceServerName`, `/SourceDatabaseName`, `/TargetFile` は公式パラメータ |
| 4 | SqlPackage `/Action:Import` のパラメータ名 | ✅ 正確 | `/TargetServerName`, `/TargetDatabaseName`, `/SourceFile` は公式パラメータ |
| 5 | SqlPackage `/p:Storage=File` オプション | ✅ 正確 | エクスポート失敗時のトラブルシューティングとして有効 |
| 6 | SqlPackage `/version` コマンドでバージョン確認 | ✅ 正確 | 公式CLIリファレンスに記載あり |
| 7 | 互換性レベル 100 が Azure SQL DB の最小要件 | ✅ 正確 | Azure SQL Database がサポートする最低互換性レベルは 100 |
| 8 | SQL Server 2008 R2 で作成したDBの互換性レベルは通常 100 | ✅ 正確 | SQL Server 2008 R2 のデフォルト互換性レベルは 100 |
| 9 | SHIR バージョン 5.37 以上が必要 | ✅ 正確 | Microsoft 公式（2026-05-04付）で確認 |
| 10 | ファイアウォール TCP 1433（SQL Server）が必要 | ✅ 正確 | SQL Server への受信ポート |
| 11 | ファイアウォール TCP 443（SHIR→Azure通信）が必要 | ✅ 正確 | Azure へのアウトバウンド通信ポート |
| 12 | サーバーレスの最小仮想コア 0.5 | ✅ 正確 | General Purpose サーバーレス Gen5 で設定可能 |
| 13 | 自動一時停止の遅延「1時間」設定 | ✅ 有効な値 | 設定可能範囲は15分〜7日（または無効化）。1時間は有効な設定値 |
| 14 | Azure SQL DB の自動一時停止の最小値は1時間 | ℹ️ 補足 | 実際の最小値は15分。手順書の「1時間」は推奨設定値として記載されており問題なし |
| 15 | DMS Standard 価格レベルでオフライン移行が可能 | ✅ 正確 | Standard SKU はオフライン移行をサポート |

---

## 修正済み内容

### `01-verification-procedure.md` STEP 2

**変更前：**
```
⚠️ 注意：SSMS 19以降はSQL Server 2008 R2に接続できません
必ず SSMS 18.x を使用してください。
```

**変更後：**
```
⚠️ 注意：SSMS 19以降はSQL Server 2008 R2への接続に問題があります
- SSMS 19.x：TLS互換性の問題で接続困難（v19.3までワークアラウンドが存在）
- SSMS 20以降：上記ワークアラウンドが機能せず
- SSMS 22（最新）：公式サポートはSQL Server 2014以降のみ
SQL Server 2008 R2に接続するには必ず SSMS 18.x を使用してください。
```

---

## 参照先ドキュメント

- [SSMS サポートポリシー](https://learn.microsoft.com/en-us/ssms/support-policy)
- [SSMS システム要件](https://learn.microsoft.com/en-us/ssms/system-requirements)
- [SqlPackage Export](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-export)
- [SqlPackage Import](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-import)
- [Azure SQL Database サーバーレス概要](https://learn.microsoft.com/en-us/azure/azure-sql/database/serverless-tier-overview)
- [SQL Server to Azure SQL Database 移行チュートリアル（DMS）](https://learn.microsoft.com/en-us/data-migration/sql-server/database/database-migration-service)
- [ALTER DATABASE 互換性レベル](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level)
