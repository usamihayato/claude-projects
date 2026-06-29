# 移行手順選定サマリー

> **移行元**: SQL Server 2008 R2（オンプレミス）  
> **作成日**: 2026-06-29

---

## ⚠️ 2026年のツール変更（重要）

2026年2月28日以降、Microsoft の移行ツール体系が大きく変わっています。
手順を検索する際は情報の鮮度に注意してください。

| ツール | 現在の状況 |
|---|---|
| Azure Data Studio (ADS) | **2026年2月28日に廃止済み** |
| Azure SQL Migration extension for ADS | **ADS 廃止に伴い廃止済み** |
| Database Migration Assistant (DMA) | **廃止予定**（後継: Azure Migrate 統合） |
| Azure Arc SQL Migration（ポータル統合 UI） | ✅ 現在の推奨 UI — **ただし SQL Server 2012 以降のみ対応** |
| ネイティブ BACKUP / RESTORE FROM URL | ✅ **SQL Server 2008 R2 で確実に動作する公式サポート方式** |
| Azure DMS（Database Migration Service） | ✅ SQL Server 2008 以降のソースをサポート |
| SqlPackage（BACPAC エクスポート/インポート） | ✅ SQL DB への移行で引き続き有効 |

> **SQL Server 2008 R2 への影響**  
> Azure Arc ポータル統合の移行 UI は SQL Server 2012 以降が必要なため **2008 R2 では使用不可**。  
> Microsoft 公式ガイドでは、2012 SP1 CU2 より前のバージョンには  
> 「.bak をローカルに取得 → Blob にアップロード → RESTORE FROM URL」を推奨しています。

---

## 移行先と移行方式の全体マップ

```
SQL Server 2008 R2（オンプレミス）
        │
        ├─ Azure SQL Managed Instance（PaaS・高互換）
        │       ├─ 方式A: ネイティブバックアップ + RESTORE FROM URL
        │       └─ 方式B: Azure DMS オフライン + SHIR
        │
        └─ Azure SQL Database（PaaS・フルマネージド）
                ├─ 方式C: SqlPackage（BACPAC）
                └─ 方式D: Azure DMS オフライン + SHIR
```

---

## SHIR（セルフホステッド統合ランタイム）の設置場所について

SHIR は**ソース SQL Server に TCP 1433 で到達でき、かつ Azure に TCP 443 で通信できる**  
Windows マシンであればどこでも動作します。オンプレ限定ではありません。

| 設置場所 | 条件 | 特徴 |
|---|---|---|
| **オンプレ Windows サーバー** | SQL Server と同一ネットワーク内 | 追加 VM コスト不要。SQL Server への通信はローカル完結 |
| **Azure VNet 内の Windows VM** | VPN Gateway または ExpressRoute でオンプレと接続済み | VM コストが発生。Blob へのアップロードは Azure 内で完結するため高速 |

> 大容量 DB の場合、SHIR を Azure 側に置くと Blob アップロードが Azure 内通信になるため  
> ExpressRoute/VPN の帯域節約になる。ただしオンプレ → SHIR 間の転送は同じ回線を通る。

---

## SQL MI 向け移行方式の比較

### 方式 A — ネイティブバックアップ + RESTORE FROM URL

**概要**: オンプレでフルバックアップを取得し、AzCopy で Blob Storage にアップロード後、SQL MI で RESTORE FROM URL を実行する。

| 項目 | 内容 |
|---|---|
| ダウンタイム | バックアップ取得〜リストア完了まで（数時間〜） |
| 必要ツール | SSMS 18.x、AzCopy v10 |
| 向いている規模 | 単一 DB・中規模（〜数百 GB） |
| ADS 不要 | ✅ |
| SQL 2008 R2 対応 | ✅ |

**メリット**
- 手順がシンプルで理解しやすい
- 追加サービス（DMS）のコストが不要
- ツールが少なく障害点が少ない

**デメリット**
- ローカルへのバックアップファイル保存領域が必要（DB サイズ相当）
- 複数 DB の場合は手動繰り返しが必要
- 進捗確認は SQL クエリのみ（GUI 管理画面なし）

**コスト**
| リソース | 概算 |
|---|---|
| AzCopy | 無料 |
| Blob Storage（一時） | 〜数千円（移行期間のみ） |
| SQL MI | vCore 数による（例: 8 vCore General Purpose ≒ 5〜6 万円/月） |

**難易度**: ★★☆☆☆（低〜中）  
**おすすめ**: 単一 DB・ダウンタイムを許容できる・DMS のセットアップを省きたい場合 → **第一候補**

> 詳細手順: [03-sql-mi-native-backup.md](./03-sql-mi-native-backup.md)

---

### 方式 B — Azure DMS オフライン + SHIR（SQL MI 向け）

**概要**: SHIR をソース SQL Server に到達できる Windows マシン（オンプレまたは Azure VNet 内 VM）にインストールし、Azure DMS がバックアップ取得〜Blob アップロード〜RESTORE を自動実行する。

| 項目 | 内容 |
|---|---|
| ダウンタイム | DMS 移行実行中（数時間〜） |
| 必要ツール | SSMS 18.x、SHIR v5.37+、Azure DMS |
| 向いている規模 | 複数 DB・大規模 |
| ADS 不要 | ✅ |
| SQL 2008 R2 対応 | ✅ |

**メリット**
- 複数 DB を一括で移行可能
- Azure Portal で進捗をテーブル単位で可視化できる
- バックアップ〜リストアの自動化（ローカルに .bak 不要）

**デメリット**
- SHIR のインストール・設定が必要（セットアップ工数あり）
- DMS インスタンスのコストが追加で発生
- 設定項目が多い（ソース/ターゲット/バックアップ設定）

**コスト**
| リソース | 概算 |
|---|---|
| SHIR | 無料（インストール先 VM のコストは別途） |
| DMS（Standard SKU） | 〜1〜2 万円/月（移行期間のみ） |
| Blob Storage（一時） | 〜数千円 |
| SQL MI | vCore 数による |

**難易度**: ★★★☆☆（中）  
**おすすめ**: 移行対象 DB が複数ある・進捗を GUI で確認したい場合 → **複数 DB 移行の第一候補**

> 詳細手順: [04-sql-mi-dms-offline.md](./04-sql-mi-dms-offline.md)

---

## SQL DB 向け移行方式の比較

### 方式 C — SqlPackage（BACPAC エクスポート/インポート）

**概要**: SqlPackage CLI でオンプレ DB を .bacpac ファイルにエクスポートし、Azure SQL Database にインポートする。

| 項目 | 内容 |
|---|---|
| ダウンタイム | エクスポート開始〜インポート完了まで |
| 必要ツール | SSMS 18.x、SqlPackage（最新版） |
| 向いている規模 | 単一 DB・中小規模（〜数百 GB） |
| ADS 不要 | ✅ |
| SQL 2008 R2 対応 | ✅ |

**メリット**
- 手順が最もシンプル（CLI 2 コマンド）
- 追加サービス不要（SHIR・DMS 不要）
- スキーマ＋データを 1 ファイルに同梱

**デメリット**
- ローカルに .bacpac ファイルの保存領域が必要
- 大規模 DB ではインポートに長時間かかる
- SQL DB の機能制限（SQL Agent・Linked Server 不可）の影響を別途確認が必要

**コスト**
| リソース | 概算 |
|---|---|
| SqlPackage | 無料 |
| Azure SQL Database（サーバーレス） | 〜数百円/月〜（使用量次第） |

**難易度**: ★☆☆☆☆（低）  
**おすすめ**: 機能依存が少ないシンプルな DB・コストを最小化したい場合 → **最も手軽な選択肢**

> 詳細手順: [01-sql-db-sqlpackage.md](./01-sql-db-sqlpackage.md)

---

### 方式 D — Azure DMS オフライン + SHIR（SQL DB 向け）

**概要**: 方式 B と同じ仕組みで、ターゲットを Azure SQL Database にする。DMS がバックアップ取得〜インポートを自動実行。SHIR はオンプレまたは Azure VNet 内 VM に設置可能。

| 項目 | 内容 |
|---|---|
| ダウンタイム | DMS 移行実行中 |
| 必要ツール | SSMS 18.x、SHIR v5.37+、Azure DMS |
| 向いている規模 | 複数 DB・大規模 |
| ADS 不要 | ✅ |
| SQL 2008 R2 対応 | ✅ |

> ⚠️ SQL DB では DMS の内部動作がネイティブバックアップではなく一括コピー（Bulk Copy）になる点に注意。

**メリット**
- 複数 DB を一括移行可能
- Portal で進捗を可視化
- ローカルに .bacpac 保存不要

**デメリット**
- SHIR セットアップが必要
- DMS のコストが追加発生
- SQL DB の機能制限の影響を別途確認が必要

**コスト**
| リソース | 概算 |
|---|---|
| SHIR | 無料（インストール先 VM のコストは別途） |
| DMS（Standard SKU） | 〜1〜2 万円/月（移行期間のみ） |
| Azure SQL Database | 利用量次第 |

**難易度**: ★★★☆☆（中）  
**おすすめ**: 複数の SQL DB を一括で移行する場合

> 詳細手順: [02-sql-db-dms-offline.md](./02-sql-db-dms-offline.md)

---

## 4方式の総合比較

| | A: ネイティブ RESTORE | B: DMS オフライン (MI) | C: SqlPackage | D: DMS オフライン (DB) |
|---|:---:|:---:|:---:|:---:|
| 移行先 | SQL MI | SQL MI | SQL DB | SQL DB |
| ダウンタイム | 中（数時間〜） | 中（数時間〜） | 中（数時間〜） | 中（数時間〜） |
| 複数 DB 一括 | ✗ | **✓** | ✗ | **✓** |
| セットアップ工数 | **低** | 中 | **最低** | 中 |
| 進捗の可視化 | SQL クエリ | **Portal** | CLI ログ | **Portal** |
| 追加コスト | なし | DMS 課金 | なし | DMS 課金 |
| SHIR 必要 | ✗ | ✓ | ✗ | ✓ |
| 難易度 | ★★☆ | ★★★☆ | **★☆** | ★★★☆ |
| 2008 R2 対応 | ✅ | ✅ | ✅ | ✅ |

---

## 方式選定フロー

```
Q1: 移行先は SQL MI か SQL DB か？
│
├─ SQL Database（機能依存が少ない・コスト重視）
│       │
│       Q2: DB 数が複数（3 本以上）あるか？
│       ├─ No  → 【方式 C】SqlPackage（最もシンプル）
│       └─ Yes → 【方式 D】DMS オフライン
│
└─ SQL Managed Instance（SQL Agent・Linked Server・CLR 等が必要）
        │
        Q3: DB 数が複数（3 本以上）あるか？
        ├─ No  → 【方式 A】ネイティブ RESTORE（最もシンプル）
        └─ Yes → 【方式 B】DMS オフライン（一括移行）
```

---

## ADS 廃止後のツール対応表（SQL Server 2008 R2 向け）

| 移行方式 | SQL 2008 R2 対応 | 主要ツール | ADS 不要 |
|---|:---:|---|:---:|
| ネイティブ BACKUP / RESTORE FROM URL（方式 A） | ✅ | SSMS 18.x + AzCopy | ✅ |
| Azure DMS オフライン + SHIR（方式 B / D） | ✅ | SSMS 18.x + SHIR + Azure Portal | ✅ |
| SqlPackage（方式 C） | ✅ | SqlPackage CLI + SSMS 18.x | ✅ |
| Azure Arc SQL Migration（ポータル統合 UI） | ❌（2012 以降のみ） | — | ✅ |
| MI Link（Distributed AG） | ❌（2016 以降のみ） | — | ✅ |
| DMA スキーマ移行 | ⚠️ 廃止予定 | — | ✅ |

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL Server → SQL MI 移行ガイド | https://learn.microsoft.com/ja-jp/data-migration/sql-server/managed-instance/guide |
| SQL Server → SQL DB 移行ガイド | https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/guide |
| Azure DMS 概要 | https://learn.microsoft.com/ja-jp/azure/dms/dms-overview |
| DMS でサポートされるシナリオ | https://learn.microsoft.com/ja-jp/azure/dms/resource-scenario-status |
| セルフホステッド統合ランタイム（SHIR） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| ADS 廃止後の代替ツール（英語） | https://techcommunity.microsoft.com/blog/microsoftdatamigration/alternatives-after-the-deprecation-of-the-azure-sql-migration-extension-in-azure/4491749 |
| SqlPackage ダウンロード | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-download |
| SSMS 18.x ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| AzCopy v10 | https://learn.microsoft.com/ja-jp/azure/storage/common/storage-use-azcopy-v10 |
