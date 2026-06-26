# SQL Server 2008 R2（本番2TB）→ Azure SQL Managed Instance 移行手順書（2026年版）

---

## ⚠️ 2026年のツール変更について（重要）

2026年2月28日以降、移行ツールの状況が大きく変わっています。

| ツール | 現在の状況 |
|---|---|
| Azure Data Studio (ADS) | **2026年2月28日に廃止済み** |
| Azure SQL Migration extension for ADS | **ADS廃止に伴い廃止済み** |
| DMA (Data Migration Assistant) | **廃止予定（移行推奨）** |
| Azure Arc SQL Migration（ポータル統合 UI） | ✅ 現在の最新推奨 — **ただし SQL Server 2012 以降のみ対応** |
| **ネイティブ BACKUP/RESTORE FROM URL** | ✅ **SQL Server 2008 R2 で確実に動作する公式サポート方式** |
| LRS（Log Replay Service）PowerShell 版 | ✅ オンライン移行の代替候補（後述） |

> **今回のケース（SQL Server 2008 R2）への影響**
> Azure Arc ポータル統合の移行 UI は SQL Server 2012 以降を必要とするため、2008 R2 では使用できません。
> Microsoft 公式移行ガイドでは、SQL Server 2012 SP1 CU2 より前のバージョンには
> 「.bak ファイルを直接 Azure Storage にアップロードして RESTORE FROM URL」を推奨しています。

---

## 移行方式の比較

| | **オフライン（推奨）** ネイティブ BACKUP / RESTORE FROM URL | **オンライン** LRS（PowerShell） |
|---|---|---|
| ダウンタイム | バックアップ＋アップロード＋リストア時間（数時間〜1日） | カットオーバー時のみ（数分〜数十分） |
| 必要ツール | SSMS・AzCopy | PowerShell（Az モジュール）・AzCopy |
| 手順の複雑さ | **低**（シンプル） | 中（ログバックアップの継続管理が必要） |
| SQL Server 2008 R2 対応 | ✅ 完全対応 | ✅ 対応（完全復旧モデルが必要） |
| Arc 必要性 | 不要 | 不要 |
| 推奨ケース | ダウンタイムを許容できる | ダウンタイムを最小限にしたい |

---

## 全体の流れ

```
【共通事前準備フェーズ】
STEP 1   事前確認（互換性レベル・復旧モデル・データサイズ）← SSMS でオンプレ実行
STEP 2   VNet・SQL MI 専用サブネットの作成               ← Azure ポータル
STEP 3   Azure SQL Managed Instance の作成               ← Azure ポータル（数時間）
STEP 4   Azure Blob Storage の作成・SAS トークン取得      ← Azure ポータル

【移行実行フェーズ（方式で分岐）】
────── オフライン（ネイティブ RESTORE） ────────────────────────
STEP 5A  フルバックアップ取得（WITH CHECKSUM）
STEP 6A  AzCopy で Blob Storage にアップロード
STEP 7A  SQL MI に接続 → SAS 認証情報の作成 → RESTORE DATABASE FROM URL
STEP 8A  リストア進捗の監視

────── オンライン（LRS：Log Replay Service） ──────────────────
STEP 5B  完全復旧モデルへの変更確認
STEP 6B  フルバックアップ + 差分バックアップの取得
STEP 7B  バックアップを Blob Storage にアップロード
STEP 8B  LRS を PowerShell で開始
STEP 9B  ログバックアップを定期取得・アップロード（移行中継続）
STEP 10B カットオーバー実行

【確認・切り替えフェーズ（共通）】
STEP 11  動作確認（件数突合・クエリ確認）
STEP 12  READ_ONLY 設定（参照専用運用のため）
STEP 13  後片付け（不要リソース削除）
```

---

## STEP 1｜事前確認（オンプレ SQL Server で実行）

SSMS でオンプレの SQL Server 2008 R2 に接続して実行します。

### ① 互換性レベルの確認

```sql
SELECT name, compatibility_level
FROM sys.databases
WHERE name = N'（移行対象のDB名）';
```

> **期待値**: `100`（SQL Server 2008 R2 のデフォルト）
> `80` や `90` の場合は変更を検討（事前に検証環境で動作確認を推奨）

```sql
ALTER DATABASE （移行対象のDB名）
SET COMPATIBILITY_LEVEL = 100;
```

### ② 復旧モデルの確認（オンライン移行を検討する場合）

```sql
SELECT name, recovery_model_desc
FROM sys.databases
WHERE name = N'（移行対象のDB名）';
```

> - `FULL`：オンライン移行（LRS）が可能
> - `SIMPLE` または `BULK_LOGGED`：オフライン移行のみ、またはFULLに変更後にオンライン移行

### ③ データサイズの確認

```sql
USE （移行対象のDB名）;
GO
EXEC sp_spaceused;
GO

-- テーブル別サイズ上位 20 件
SELECT TOP 20
    t.name                              AS テーブル名,
    SUM(a.total_pages) * 8 / 1024      AS 合計MB,
    SUM(p.rows)                         AS 行数
FROM sys.tables t
INNER JOIN sys.indexes i     ON t.object_id = i.object_id
INNER JOIN sys.partitions p  ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0
GROUP BY t.name
ORDER BY 合計MB DESC;
```

> **バックアップサイズの目安（圧縮あり）**: データサイズの 40〜60%

---

## STEP 2｜VNet と SQL MI 専用サブネットの作成

SQL Managed Instance は VNet 内の**専用サブネット**に配置されます。
他のリソースとの共有は不可です。

### ① VNet の確認または作成

VPN/ExpressRoute と接続済みの既存 VNet があればそれを使用します。
新規作成する場合：

1. ポータル → 「仮想ネットワーク」→「作成」

| 項目 | 設定例 |
|---|---|
| リソースグループ | `rg-sqlmi-production` |
| 名前 | `vnet-sqlmi-prod` |
| リージョン | Japan East |
| アドレス空間 | `10.0.0.0/16`（例） |

### ② SQL MI 専用サブネットの追加

| 項目 | 設定値 |
|---|---|
| サブネット名 | `snet-sqlmi` |
| アドレス範囲 | `/27` 以上推奨（最小 `/28`）。例：`10.0.1.0/27` |
| サブネットの委任 | `Microsoft.Sql/managedInstances` |

> ⚠️ **NSG とルートテーブルについて**
> ポータルから SQL MI を作成すると、必要な NSG ルールと UDR が自動作成されます。

### ③ 接続構成の確認

```
オンプレ SQL Server 2008 R2
        ↕ VPN Gateway / ExpressRoute
VNet (vnet-sqlmi-prod)
        └── snet-sqlmi（専用サブネット）
              └── Azure SQL Managed Instance
```

---

## STEP 3｜Azure SQL Managed Instance の作成

> ⚠️ **作成には 4〜6 時間かかる場合があります。移行当日ではなく前日までに作成してください。**

1. ポータル → 「リソースの作成」→「Azure SQL」→「SQL マネージド インスタンス」→「作成」

### 基本設定

| 項目 | 設定値 |
|---|---|
| リソースグループ | `rg-sqlmi-production` |
| マネージド インスタンス名 | 任意（グローバルでユニーク） |
| リージョン | Japan East |

### コンピューティング設定（「Managed Instance の構成」内）

| 項目 | 設定値 |
|---|---|
| サービスレベル | General Purpose |
| ハードウェアの世代 | Standard-series（Gen5） |
| 仮想コア数 | **8 vCore**（移行中は高め、移行後に調整可） |
| ストレージ | データサイズの **1.5 倍以上**（例：2TB → 3〜4TB） |

### ネットワーク設定

| 項目 | 設定値 |
|---|---|
| 仮想ネットワーク / サブネット | STEP 2 で作成した `snet-sqlmi` |
| 接続の種類 | プロキシ（デフォルト） |
| パブリックエンドポイント | **無効**（VPN/ExpressRoute 経由のため不要） |

### 認証設定

| 項目 | 設定値 |
|---|---|
| 認証方法 | SQL 認証 |
| 管理者ログイン名 | 任意（`sa` は使用不可） |
| パスワード | 強力なパスワード |

「確認および作成」→「作成」をクリックします。
作成完了の通知を受けてから次の STEP に進みます。

---

## STEP 4｜Azure Blob Storage の作成と SAS トークンの取得

バックアップファイルの格納場所です。

1. ポータル → 「ストレージ アカウント」→「作成」

| 項目 | 設定値 |
|---|---|
| リソースグループ | `rg-sqlmi-production` |
| ストレージ アカウント名 | 任意（英小文字と数字のみ、グローバルでユニーク） |
| リージョン | **Japan East**（SQL MI と同じリージョン） |
| パフォーマンス | Standard |
| 冗長性 | LRS（移行用途のため最低限で可） |

2. 作成後、コンテナーを作成：「コンテナー」→「＋コンテナー」

| 項目 | 設定値 |
|---|---|
| コンテナー名 | `sqlmi-migration` |
| パブリックアクセス | プライベート（デフォルト） |

### SAS トークンの生成

1. 「ストレージ アカウント」→「セキュリティとネットワーク」→「Shared access signature」
2. 以下の権限を付与：

| 項目 | 設定値 |
|---|---|
| 許可されるサービス | Blob |
| 許可されるリソースの種類 | コンテナー・オブジェクト |
| 許可されるアクセス許可 | 読み取り・書き込み・リスト・削除 |
| 有効期限 | 移行完了予定日より数日後 |

3. 「SAS と接続文字列を生成する」→ **「BLOB サービス SAS URL」をコピーして保管**

---

## オフライン移行（STEP 5A〜8A）：ネイティブ BACKUP / RESTORE FROM URL（推奨）

## STEP 5A｜フルバックアップの取得

SSMS または sqlcmd でオンプレ SQL Server に接続して実行します。

```sql
BACKUP DATABASE [（移行対象のDB名）]
TO DISK = N'D:\backup\（DB名）_full.bak'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10;
GO
```

> ⚠️ **`WITH CHECKSUM` は後の RESTORE でバックアップの整合性検証に使用されます。必ず付けてください。**

> **2TB バックアップの所要時間目安**
> ディスク I/O 性能により、圧縮込みで 2〜6 時間程度を想定してください。

---

## STEP 6A｜AzCopy で Blob Storage にアップロード

### AzCopy のインストール

```
https://learn.microsoft.com/ja-jp/azure/storage/common/storage-use-azcopy-v10
```

### アップロード実行

```cmd
azcopy copy "D:\backup\（DB名）_full.bak" ^
  "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）_full.bak?（SASトークン）"
```

> **アップロード時間の目安（1Gbps 帯域）**
> 圧縮後ファイルが 1TB 程度の場合、2〜3 時間程度。バックグラウンドで実行し完了を確認してから次へ進みます。

---

## STEP 7A｜SQL MI で RESTORE DATABASE FROM URL を実行

SSMS から SQL MI に接続します。

**接続先**: `（SQL MI名）.（ユニークID）.database.windows.net`（ポータルの「概要」で確認）

### ① SAS 認証情報の作成（SQL MI 上で実行）

```sql
-- SQL MI の master に接続して実行
CREATE CREDENTIAL [https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '（SASトークン の先頭 ? を除いた部分）';
GO
```

> `SECRET` には SAS トークンの先頭の `?` を取り除いた文字列を指定します。
> 例：`sv=2023-01-03&ss=b&srt=co&sp=rwdlacuptfx&...`

### ② リストアの実行

```sql
RESTORE DATABASE [（DB名）]
FROM URL = N'https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）_full.bak'
WITH STATS = 10;
GO
```

> **リストアは非同期で実行されます。**
> コマンドを実行したあとに接続が切れたりタイムアウトになっても、SQL MI はバックグラウンドでリストアを継続します。
> 次の STEP 8A で進捗を確認してください。

---

## STEP 8A｜リストア進捗の監視

SQL MI に接続し、以下のクエリで進捗を確認します。

```sql
-- リストアの進捗確認
SELECT
    r.session_id,
    r.command,
    r.percent_complete,
    r.estimated_completion_time / 1000 AS 残り秒数,
    r.start_time
FROM sys.dm_exec_requests r
WHERE r.command = 'RESTORE DATABASE';
```

```sql
-- 操作ステータスの確認（完了・エラーの確認用）
SELECT *
FROM sys.dm_operation_status
WHERE resource_type_desc = 'Database'
ORDER BY start_time DESC;
```

> `state_desc` が `SUCCEEDED` になればリストア完了です。

> **2TB リストアの所要時間目安**
> SQL MI の vCore 数によりますが、8 vCore で 4〜12 時間程度を見込んでください。

---

## オンライン移行（STEP 5B〜10B）：LRS（Log Replay Service）PowerShell 版

> **LRS とは**
> Blob Storage に置いたバックアップファイルを SQL MI が継続的に読み取り・適用するサービスです。
> ログバックアップを追加し続けることでオンプレの変更を追従し、準備できたらカットオーバーします。
>
> ⚠️ **前提**: 完全復旧モデル（FULL）が必要です。

## STEP 5B｜完全復旧モデルへの変更確認

STEP 1 で `SIMPLE` と確認された場合は変更します。すでに `FULL` の場合はスキップ。

```sql
-- 完全復旧モデルに変更
ALTER DATABASE [（移行対象のDB名）] SET RECOVERY FULL;
GO

-- 変更直後に必ずフルバックアップを取得（ログ連鎖の確立のため）
BACKUP DATABASE [（移行対象のDB名）]
TO DISK = N'D:\backup\（DB名）_full_initial.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;
GO
```

---

## STEP 6B｜フルバックアップ + 差分バックアップの取得

```sql
-- フルバックアップ
BACKUP DATABASE [（移行対象のDB名）]
TO DISK = N'D:\backup\（DB名）_full.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;
GO

-- 差分バックアップ（フルバックアップ後のデータを補完・任意だが推奨）
BACKUP DATABASE [（移行対象のDB名）]
TO DISK = N'D:\backup\（DB名）_diff.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;
GO
```

---

## STEP 7B｜バックアップを Blob Storage にアップロード

LRS はフォルダー構造で DB 単位に管理します。
コンテナー内に **DB 名と同じサブフォルダー** を作成してアップロードします。

```cmd
:: フルバックアップ
azcopy copy "D:\backup\（DB名）_full.bak" ^
  "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）/（DB名）_full.bak?（SASトークン）"

:: 差分バックアップ
azcopy copy "D:\backup\（DB名）_diff.bak" ^
  "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）/（DB名）_diff.bak?（SASトークン）"
```

---

## STEP 8B｜LRS を PowerShell で開始

PowerShell で Az モジュールをインストール済みであることを前提とします。

```powershell
# Azure へのサインイン（未サインインの場合）
Connect-AzAccount

# LRS を開始（continuous モード = オンライン移行）
$params = @{
    ResourceGroupName    = "rg-sqlmi-production"
    InstanceName         = "（SQL MI 名）"
    Name                 = "（DB名）"
    StorageContainerUri  = "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）"
    StorageContainerSasToken = "?（SASトークン の ? 以降）"
    AutoComplete         = $false   # $false = continuous モード（オンライン）
}
Start-AzSqlInstanceDatabaseLogReplay @params
```

> `AutoComplete = $true` にすると最後のバックアップファイルを指定してオフラインと同等の動作になります（カットオーバー不要）。

---

## STEP 9B｜ログバックアップを定期取得・アップロード（カットオーバーまで継続）

LRS が動作している間、ログバックアップを定期的に取得して Blob Storage にアップロードします。

```sql
-- ログバックアップ（連番付きファイル名で管理）
DECLARE @logFile NVARCHAR(256)
SET @logFile = N'D:\backup\（DB名）_log_'
    + CONVERT(NVARCHAR(8), GETDATE(), 112)
    + N'_'
    + REPLACE(CONVERT(NVARCHAR(8), GETDATE(), 108), N':', N'')
    + N'.bak'

BACKUP LOG [（移行対象のDB名）]
TO DISK = @logFile
WITH COMPRESSION, CHECKSUM, STATS = 10;
```

```cmd
:: ログバックアップをアップロード（新ファイルが生成されるたびに実行）
azcopy copy "D:\backup\（DB名）_log_*.bak" ^
  "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）/?（SASトークン）"
```

```powershell
# LRS の進捗確認
Get-AzSqlInstanceDatabaseLogReplay `
  -ResourceGroupName "rg-sqlmi-production" `
  -InstanceName "（SQL MI 名）" `
  -Name "（DB名）"
```

> **ログバックアップの間隔の目安**
> - 通常時：15〜30 分ごと
> - カットオーバー直前：5〜10 分ごと（ラグを最小化するため）

---

## STEP 10B｜カットオーバーの実行

### ① アプリケーションの接続を停止

オンプレ SQL Server への参照クエリを停止します。

### ② 最終ログバックアップを取得・アップロード

```sql
BACKUP LOG [（移行対象のDB名）]
TO DISK = N'D:\backup\（DB名）_log_final.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;
```

```cmd
azcopy copy "D:\backup\（DB名）_log_final.bak" ^
  "https://（ストレージアカウント名）.blob.core.windows.net/sqlmi-migration/（DB名）/（DB名）_log_final.bak?（SASトークン）"
```

### ③ LRS のカットオーバーを実行

```powershell
Complete-AzSqlInstanceDatabaseLogReplay `
  -ResourceGroupName "rg-sqlmi-production" `
  -InstanceName "（SQL MI 名）" `
  -Name "（DB名）" `
  -LastBackupName "（DB名）_log_final.bak"
```

> `LastBackupName` には Blob Storage のフォルダー内でのファイル名（パスなし）を指定します。
> 完了後、SQL MI 上の DB がオンライン状態になります。

---

## STEP 11｜動作確認（共通）

SSMS から SQL MI に接続して確認します。

**接続先**: `（SQL MI名）.（ユニークID）.database.windows.net`

```sql
-- テーブル一覧と行数を確認
SELECT
    t.name       AS テーブル名,
    p.rows       AS 行数
FROM sys.tables t
INNER JOIN sys.partitions p
    ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
ORDER BY p.rows DESC;
```

```sql
-- オンプレ側と件数を突合（オンプレ・SQL MI 両方で実行して比較）
SELECT COUNT(*) AS 件数 FROM （主要テーブル名）;
```

```sql
-- 代表クエリの動作確認
SELECT TOP 100 * FROM （主要テーブル名）;
```

```sql
-- ビュー・ストアドプロシージャの存在確認
SELECT name, type_desc
FROM sys.objects
WHERE type IN ('P', 'V', 'FN', 'TF')
ORDER BY type_desc, name;
```

> 件数が一致し、代表クエリが正常に動作すれば移行成功です。

---

## STEP 12｜READ_ONLY 設定（参照専用運用のため）

```sql
ALTER DATABASE [（DB名）]
SET READ_ONLY
WITH NO_WAIT;
GO

-- 確認（1 であれば READ_ONLY）
SELECT name, is_read_only
FROM sys.databases
WHERE name = N'（DB名）';
```

```sql
-- 書き込みができないことをテスト（エラーになれば OK）
INSERT INTO （テーブル名） VALUES (...);
-- エラー: The database '...' is read-only.
```

---

## STEP 13｜後片付け（不要リソース削除）

| リソース | 対応 |
|---|---|
| Blob Storage のバックアップファイル | ✅ 確認後に削除（ストレージ課金対象） |
| Blob Storage アカウント | ✅ 不要になったら削除 |
| SHIR（今回は不使用のため該当なし） | — |
| バックアップファイル（オンプレ側） | ✅ 確認後に削除 |
| Azure SQL Managed Instance | 🔒 **残す**（本番運用リソース） |
| VNet / サブネット | 🔒 **残す** |
| リソースグループ | 🔒 **残す** |

---

## チェックリスト（オフライン：ネイティブ RESTORE 版）

| 項目 | 確認 |
|---|---|
| 互換性レベルが 100 であること | ☐ |
| VNet・SQL MI 専用サブネット（/27以上・委任設定）が作成された | ☐ |
| SQL Managed Instance が作成された（数時間待機） | ☐ |
| SQL MI への接続確認ができた（VPN/ExpressRoute 経由） | ☐ |
| Blob Storage・コンテナーが作成された | ☐ |
| SAS トークンが取得された | ☐ |
| フルバックアップが WITH CHECKSUM で取得された | ☐ |
| AzCopy でバックアップが Blob Storage にアップロードされた | ☐ |
| SQL MI 上で SAS 認証情報（CREDENTIAL）が作成された | ☐ |
| RESTORE DATABASE FROM URL が実行された | ☐ |
| リストアが正常完了した（sys.dm_operation_status で確認） | ☐ |
| 全主要テーブルの件数がオンプレと一致した | ☐ |
| 代表クエリが正常に動作した | ☐ |
| READ_ONLY が設定された | ☐ |
| 不要な Blob ファイルを削除した | ☐ |

---

## チェックリスト（オンライン：LRS 版）

| 項目 | 確認 |
|---|---|
| 互換性レベルが 100 であること | ☐ |
| 復旧モデルが FULL に設定された | ☐ |
| VNet・SQL MI 専用サブネット・SQL MI が作成された | ☐ |
| Blob Storage・コンテナー・SAS トークンが準備された | ☐ |
| Az PowerShell モジュールがインストールされた | ☐ |
| フルバックアップ・差分バックアップが WITH CHECKSUM で取得された | ☐ |
| バックアップが Blob Storage の DB 別フォルダーにアップロードされた | ☐ |
| LRS が PowerShell で開始された | ☐ |
| ログバックアップの定期取得・アップロードが実施された | ☐ |
| 最終ログバックアップが適用された | ☐ |
| LRS カットオーバー（Complete-AzSqlInstanceDatabaseLogReplay）が完了した | ☐ |
| 全主要テーブルの件数がオンプレと一致した | ☐ |
| 代表クエリが正常に動作した | ☐ |
| READ_ONLY が設定された | ☐ |
| 不要な Blob ファイルを削除した | ☐ |

---

## トラブルシューティング

### RESTORE FROM URL が「認証情報が見つからない」エラーになる

```
確認項目：
① CREDENTIAL の名前が Blob コンテナーの URL と完全一致しているか
② SECRET に SAS トークンの先頭 ? が含まれていないか（? 以降のみ指定する）
③ SAS トークンの有効期限が切れていないか
④ SAS トークンに「読み取り」「オブジェクト」権限が付与されているか
```

### リストアが完了せず、RESTORE の STATE が変化しない

```sql
-- バックグラウンドリストアの確認
SELECT * FROM sys.dm_operation_status
WHERE resource_type_desc = 'Database'
ORDER BY start_time DESC;
```

`state_desc` が `IN_PROGRESS` のまま変化しない場合は、ストレージへのアクセス状況や
SQL MI の vCore 数（リストア速度に影響）を確認してください。

### LRS でログバックアップが「適用されない」

```
確認項目：
① Blob Storage のフォルダーパスが正しいか（DB名と一致するフォルダー内か）
② バックアップファイル名のソート順が正しい連番になっているか
   （LRS はファイル名の辞書順で適用するため、ゼロ埋め連番を推奨）
③ Get-AzSqlInstanceDatabaseLogReplay でエラーメッセージを確認する
```

### SQL MI 作成後に VPN 経由で接続できない

```
確認項目：
① SQL MI のプライベート IP アドレスを確認（ポータルの「概要」）
② VPN Gateway のルーティングが SQL MI のサブネット宛に設定されているか
③ サブネットの NSG / UDR が Azure が自動作成したものを変更していないか
④ ポート 1433（SQL）・11000〜11999（リダイレクト接続時）が開放されているか
```

---

## 付録：ADS 廃止後の移行ツール対応表

| 方式 | SQL Server 2008 R2 対応 | ツール | ADS 不要 |
| --- | --- | --- | --- |
| ネイティブ BACKUP / RESTORE FROM URL | ✅ | SSMS + AzCopy | ✅ |
| LRS（Log Replay Service） | ✅ | PowerShell / Azure portal | ✅ |
| Azure Arc SQL Migration（ポータル UI） | ❌（2012 以降のみ） | Azure portal | ✅ |
| MI Link（Distributed AG） | ❌（2016 以降のみ） | SSMS + Azure portal | ✅ |

---

*作成日：2026-06-26*
*参照：[SQL Server → SQL MI 移行ガイド](https://learn.microsoft.com/ja-jp/data-migration/sql-server/managed-instance/guide)*
*参照：[ADS 廃止後の代替ツール](https://techcommunity.microsoft.com/blog/microsoftdatamigration/alternatives-after-the-deprecation-of-the-azure-sql-migration-extension-in-azure/4491749)*
*参照：[LRS による SQL MI 移行](https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/log-replay-service-migrate)*
