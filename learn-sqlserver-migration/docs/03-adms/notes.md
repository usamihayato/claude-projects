# 03. Azure Database Migration Service（ADMS / DMS）調査

> **作成日**: 2026-04-15  
> **対象バージョン**: Azure Database Migration Service（DMS）最新版

---

## 1. ADMS（Azure Database Migration Service）とは

Microsoft が提供する**フルマネージドのデータベース移行サービス**。
オンプレミスや他クラウドの SQL Server を Azure 上のターゲットへ移行するためのツール群を提供する。

```
移行元（オンプレ SQL Server）
        │
        │  移行ジョブ（オフライン / オンライン）
        ▼
Azure Database Migration Service
        │
        ├─ Azure SQL Managed Instance
        ├─ Azure SQL Database
        └─ SQL Server on Azure VM
```

---

## 2. DMS の種類と選択

Microsoft の移行ツールは複数存在するため、用途に応じて使い分ける。

| ツール | 特徴 | 主な用途 |
|-------|------|---------|
| **Azure Database Migration Service** | フルマネージドサービス（Azure Portal から操作） | 本番移行（オフライン・オンライン） |
| **Azure Migrate: Database Assessment** | 移行前の互換性評価 | 事前調査・スコーピング |
| **Database Migration Assistant（DMA）** | ローカル実行の評価・移行ツール | 評価レポート・スキーマ移行 |
| **Database Experimentation Assistant（DEA）** | ワークロードのパフォーマンス比較 | 移行前のパフォーマンステスト |
| **SQL Server Migration Assistant（SSMA）** | 異種 DBMS からの移行（Oracle → SQL Server等） | 異種 DBMS 移行 |

> **本プロジェクト（SQL Server → SQL MI）では DMS + DMA の組み合わせが基本**。

---

## 3. 移行モードの比較

### 3-1. オフライン移行（推奨: ダウンタイム許容できる場合）

```
┌──────────────────────────────────────────┐
│  移行手順                                 │
│                                          │
│  1. DMA で評価レポートを生成               │
│  2. スキーマ移行（DMA）                   │
│  3. サービス停止（アプリ・SQL Server）      │
│  4. フルバックアップ → Azure Blob に転送   │
│  5. DMS でリストア → SQL MI              │
│  6. アプリの接続先を SQL MI に切り替え      │
│  7. 動作確認後にオンプレ廃止               │
└──────────────────────────────────────────┘
```

- ダウンタイム: フルバックアップ + リストア時間（DB サイズに依存）
- シンプルで確実な方法
- 小〜中規模 DB（数 GB〜数百 GB）に適している

---

### 3-2. オンライン移行（最小ダウンタイム移行）

```
┌──────────────────────────────────────────────────────┐
│  移行手順                                             │
│                                                      │
│  1. DMA で評価レポートを生成                           │
│  2. スキーマ移行（DMA）                               │
│  3. DMS でオンライン移行開始（CDC でログ同期）          │
│  4. フルバックアップ → リストア（アプリは稼働継続）      │
│  5. 差分・ログの継続同期                               │
│  6. カットオーバータイミング（業務停止 数分〜数十分）    │
│  7. アプリ接続先を切り替え                             │
└──────────────────────────────────────────────────────┘
```

- ダウンタイム: カットオーバー時の数分〜数十分のみ
- CDC（Change Data Capture）を使った継続ログ同期が必要
- 前提条件が多く、大規模 DB（数 TB）の移行で有効

---

## 4. 前提条件

### 移行元 SQL Server 側

| 要件 | 内容 |
|------|------|
| **SQL Server バージョン** | SQL Server 2005 以降（SQL MI へのオンライン移行は 2008 以降推奨） |
| **バックアップ形式** | FULL バックアップが有効であること |
| **ログ読み取り** | オンライン移行では SQL Server Agent + ログの読み取り権限が必要 |
| **ネットワーク** | DMS から移行元 SQL Server への TCP 1433 ポートが開いていること |
| **ファイアウォール** | SQL Server のファイアウォールで DMS の IP を許可する |

### Azure 側の準備

| 要件 | 内容 |
|------|------|
| **DMS インスタンス** | Premium SKU（オンライン移行は Premium のみ） |
| **Azure Blob Storage** | バックアップファイルの一時格納先（移行元 SQL Server からのアクセスが必要） |
| **SQL MI の専用サブネット** | `/27` 以上のアドレス空間 |
| **VNet / VPN または ExpressRoute** | DMS から SQL MI への通信経路 |
| **ターゲット DB の作成** | SQL MI にデータベースを事前に作成（スキーマはDMAで移行） |

---

## 5. 移行手順の詳細

### Step 1: Database Migration Assistant（DMA）で評価

```bash
# DMA は Windows GUI ツール
# 1. 移行元 SQL Server に接続
# 2. "Assessment" モードで評価レポートを生成
# 3. SQL MI への互換性問題を一覧で確認
# 4. "Migration" モードでスキーマのみ先行移行
```

評価レポートの確認ポイント:
- 互換性の問題（Breaking Changes / Behavior Changes / Deprecated Features）
- SQL MI でサポートされていない機能の一覧
- 修正が必要なオブジェクト数

---

### Step 2: Azure Blob Storage にバックアップを格納

```powershell
# オフライン移行の場合: バックアップを Azure Blob に転送
# オプション① AzCopy を使ったバックアップ転送
azcopy copy "C:\Backup\mydb.bak" "https://<storage>.blob.core.windows.net/<container>/mydb.bak" --recursive

# オプション② SQL Server から直接 Blob バックアップ
BACKUP DATABASE [mydb]
TO URL = 'https://<storage>.blob.core.windows.net/<container>/mydb.bak'
WITH CREDENTIAL = 'AzureBlobStorageCredential', STATS = 5;
```

---

### Step 3: DMS で移行ジョブを作成・実行

```
Azure Portal → Azure Database Migration Service
  → 新しい移行プロジェクト
    → ソース: SQL Server
    → ターゲット: Azure SQL Managed Instance
    → 移行モード: オフライン or オンライン
    → バックアップ場所: Azure Blob Storage
    → 移行対象 DB を選択
    → 移行を開始
```

---

### Step 4: カットオーバー（オンライン移行の場合）

```
1. アプリのトランザクションが落ち着くタイミングを選ぶ
2. DMS の "Start Cutover" をクリック
3. 残差分ログを最終同期
4. アプリの接続文字列を SQL MI のエンドポイントに変更
5. 動作確認 → オンプレの SQL Server を停止
```

---

## 6. DMS の制限事項・注意点

| 項目 | 詳細 |
|------|------|
| **サポートするバックアップ圧縮** | 圧縮バックアップ対応（`WITH COMPRESSION`） |
| **バックアップの分割（ストライプ）** | 複数バックアップファイルへの分割（ストライプ）は対応。ただし同じ Blob コンテナに格納する必要あり |
| **TDE 対応** | TDE で暗号化された DB の移行は証明書のインポートが先に必要 |
| **移行中の DDL 変更** | オンライン移行中に移行元でスキーマ変更（DDL）を行うと同期が中断される場合あり |
| **最大バックアップサイズ** | 単一ファイルは 5 TB まで（Blob の制限） |
| **Premium SKU の必要性** | オンライン移行（CDC）には Premium SKU が必須 |
| **DMS のリージョン** | ターゲット SQL MI と同じリージョンに DMS を作成すること |

---

## 7. 推奨移行フロー（本プロジェクト向け）

```
フェーズ 1: 評価（Assessment）
├─ DMA で評価レポートを生成
├─ ノックアウト要件（02-knockout-requirements）との照合
└─ 修正が必要な SQL オブジェクトの確認

フェーズ 2: 環境準備
├─ Azure 環境構築（VNet / SQL MI / Blob Storage / DMS）
├─ DMA でスキーマ移行（DDL のみ）
└─ 移行元 SQL Server のバックアップ取得・動作確認

フェーズ 3: 移行（Migration）
├─ オフライン移行: バックアップ → Blob → DMS でリストア
│   または
├─ オンライン移行: CDC でログ同期 → カットオーバー
└─ 動作確認・接続文字列の切り替え

フェーズ 4: 検証・最適化
├─ クエリパフォーマンスの確認（Query Store 活用）
├─ SQL Agent ジョブの再作成・動作確認
└─ 監視・アラート設定（Azure Monitor / Defender for SQL）
```

---

## 8. チェックリスト

- [ ] DMA を使って評価レポートを生成した
- [ ] 互換性問題（Breaking Changes）をすべて確認した
- [ ] 移行元 SQL Server のバージョンを確認した（2008 以上推奨）
- [ ] Azure Blob Storage を準備し、バックアップ転送を確認した
- [ ] DMS インスタンスを SQL MI と同リージョンに作成した
- [ ] オンライン移行の場合は Premium SKU を選択した
- [ ] TDE 証明書のエクスポート・インポート手順を確認した
- [ ] カットオーバー手順・ロールバック手順を文書化した

---

## 9. よく出る問題パターン

**Q. TDE で暗号化されたデータベースを DMS で移行できるか？**
→ A. 可能だが事前に TDE 証明書を SQL MI にインポートする必要がある。手順: `BACKUP CERTIFICATE` → `CREATE CERTIFICATE ... FROM FILE` で SQL MI に登録。

**Q. 移行中にアプリを止めたくないが、DB サイズが 2 TB ある。どうする？**
→ A. DMS のオンライン移行（CDC）を使い、フルバックアップ後はログ差分を継続同期する。カットオーバーは業務時間外の短時間停止のみで済む。

**Q. 複数の DB（30 本）を一括で移行できるか？**
→ A. DMS の 1 プロジェクトで複数 DB を並列移行可能。ただし大規模 DB が混在する場合は移行ジョブを分割してリスクを下げることを推奨。
