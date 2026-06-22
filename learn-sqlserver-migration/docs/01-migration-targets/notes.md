# 01. Azure SQL 移行先オプション比較

> **作成日**: 2026-04-15

---

## 試験での重要度 / 判断の重要度

移行先の選定は「ノックアウト要件が通るか」を軸に決める。
機能互換性が高い順に SQL on VM → SQL MI → SQL DB の順で制約が強まる。

---

## 1. 移行先の選択肢

Azure への SQL Server 移行には大きく 3 つの移行先がある。

```
オンプレ SQL Server
        │
        ├─ SQL Server on Azure VM   (IaaS) ← リフトアンドシフト
        ├─ Azure SQL Managed Instance (PaaS) ← 高互換 PaaS
        └─ Azure SQL Database         (PaaS) ← フルマネージド
```

---

## 2. 各オプションの概要

### 2-1. SQL Server on Azure VM（IaaS）

- オンプレの SQL Server をそのまま Azure の仮想マシン上に移行
- OS・SQL Server のバージョンを自由に選択可能
- Windows Server の EOL 管理は引き続き**自社責任**（EOL 脱却の観点では不完全）
- ライセンスは BYOL（Azure Hybrid Benefit 適用可）または従量課金

**向いているケース**:
- SQL Server の独自拡張（CLR, xp_cmdshell, Linked Server 等）を多用
- 既存の SQL Server バージョンのまま稼働させたい PoC・緊急移行
- アプリ改修コストを最小化したい場合

---

### 2-2. Azure SQL Managed Instance（PaaS）

- SQL Server と約 **99% の機能互換性** を持つフルマネージド PaaS
- OS・パッチ管理は Azure が担う（Windows Server EOL から完全に脱却可能）
- SQL Server Agent・Linked Server・CLR・Service Broker などをサポート
- VNet 内に展開され、Private Endpoint でオンプレと接続可能
- インスタンス単位での購入（vCore モデル）

**向いているケース**:
- SQL Server の主要機能をほぼそのまま使いたい
- Windows Server の運用から脱却したい（**本プロジェクトの主な移行先候補**）
- SQL Server Agent ジョブが多数ある

---

### 2-3. Azure SQL Database（PaaS）

- 単一データベース単位で管理するフルマネージド PaaS
- SQL Managed Instance より**機能制限が多い**（SQL Agent 不可、Linked Server 不可など）
- スケール・可用性・コストの最適化に最も優れる
- サーバーレス（自動一時停止・再開）オプションあり

**向いているケース**:
- 新規開発アプリや、機能依存が少ないシンプルなデータベース
- 利用率が低い DB でコストを最小化したい
- 開発・検証環境

---

### 2-4. Azure Synapse Analytics + Azure Data Lake Storage Gen2（アーカイブ・分析用途）

> ⚠️ **OLTP の直接移行先ではありません**
> 読み取り専用・蓄積系データのアーカイブや分析クエリを目的とした構成です。

```
オンプレ SQL Server 2008 R2（READ_ONLY 移行対象）
        │
        ↓ ADF / bcp でエクスポート → Parquet 変換
Azure Data Lake Storage Gen2（安価なオブジェクトストレージ）
        │
        ↓ T-SQL で参照
Azure Synapse Analytics Serverless SQL Pool（クエリのみ・コンピュートは使用時課金）
```

**主な特徴**:
- ストレージは ADLS（Blob ベース）のため、Azure SQL Database の 1/6 以下のコスト
- クエリ実行時のみ課金（Serverless SQL Pool: TB あたり課金）
- SSMS から Synapse エンドポイントへ T-SQL で接続可能
- INSERT / UPDATE / DELETE は不可（READ_ONLY 専用）

**向いているケース**:
- 本番移行後に READ_ONLY 化して参照だけ続ける蓄積系データ
- データ量が 1TB 以上でストレージコストを最小化したい
- BI ツール（Power BI 等）からの分析クエリが主な用途
- OLTP アプリとの接続を切り離せる

**向いていないケース**:
- トランザクション処理・INSERT/UPDATE が残る
- アプリ接続文字列を変更できない（エンドポイントが変わる）
- ストアドプロシージャ・SQL Agent ジョブを移行したい

---

## 3. 機能比較表

| 機能 | SQL on VM | SQL MI | SQL Database |
|------|:---------:|:------:|:------------:|
| SQL Server Agent | ✓ | ✓ | ✗ |
| Linked Server | ✓ | ✓（一部制限） | ✗ |
| CLR Integration | ✓ | ✓ | ✗ |
| Service Broker | ✓ | ✓ | ✗ |
| Database Mail | ✓ | ✓ | ✗ |
| xp_cmdshell | ✓ | ✗ | ✗ |
| Windows 認証（AD） | ✓ | ✓（Azure AD 連携） | ✓（Azure AD 連携） |
| MSDTC（分散トランザクション） | ✓ | ✓（プレビュー） | ✗ |
| Full-Text Search | ✓ | ✓ | ✓ |
| In-Memory OLTP | ✓ | ✓ | ✓（Premium以上） |
| 変更データキャプチャ（CDC） | ✓ | ✓ | ✓ |
| レプリケーション（パブリッシャ） | ✓ | ✓（トランザクション） | ✗ |
| カスタム照合順序（DB 単位） | ✓ | ✓（インスタンス単位） | ✓（DB 単位） |
| OS レベルのアクセス | ✓ | ✗ | ✗ |
| Windows Server EOL 脱却 | ✗ | **✓** | **✓** |
| パッチ管理自動化 | ✗（自社管理） | ✓ | ✓ |

---

### OLTP 3択との機能比較（アーカイブ用途の観点）

| 観点 | SQL on VM | SQL MI | SQL Database | **Synapse + ADLS** |
|------|:---------:|:------:|:------------:|:------------------:|
| OLTP（INSERT/UPDATE） | ✓ | ✓ | ✓ | **✗** |
| READ クエリ（T-SQL） | ✓ | ✓ | ✓ | **✓**（一部制限あり） |
| SQL Server Agent | ✓ | ✓ | ✗ | **✗** |
| ストアドプロシージャ | ✓ | ✓ | ✓ | **△**（Serverless は制限あり） |
| SSMS から接続 | ✓ | ✓ | ✓ | **✓**（別エンドポイント） |
| Windows Server EOL 脱却 | ✗ | ✓ | ✓ | **✓** |
| 大容量ストレージコスト | 高 | 高 | 高 | **非常に安い** |
| 非クエリ時のコスト | 高 | 高 | 低（自動停止） | **ほぼゼロ** |
| Power BI 連携 | ✓ | ✓ | ✓ | **◎（ネイティブ統合）** |

---

## 4. 管理責任の比較（責任共有モデル）

```
                オンプレ   SQL on VM   SQL MI    SQL DB
アプリケーション   自社       自社        自社       自社
データ            自社       自社        自社       自社
OS・パッチ        自社       自社        Azure      Azure
SQL Server        自社       自社        Azure      Azure
ストレージ         自社       Azure       Azure      Azure
ネットワーク       自社       Azure       Azure      Azure
```

---

## 5. 選定フロー

```
Q1: xp_cmdshell / OS コマンド実行が必要か？
│
├─ Yes → SQL Server on Azure VM（IaaS）
│         ※ Windows Server EOL 管理は残る
│
└─ No
      │
      Q2: 移行後も INSERT / UPDATE が発生するか？
      │
      ├─ Yes（OLTP 継続）
      │     │
      │     Q3: SQL Agent / Linked Server / CLR / Service Broker が必要か？
      │     │
      │     ├─ Yes → Azure SQL Managed Instance ★推奨
      │     │
      │     └─ No（シンプルな CRUD のみ）
      │           └─ Azure SQL Database（最もコスト最適）
      │
      └─ No（READ_ONLY・参照専用・アーカイブ）
            │
            Q4: データ量が 1TB 以上、または参照頻度が低いか？
            │
            ├─ Yes → Azure Synapse + ADLS ★コスト最安
            │         ※ アプリ接続変更・T-SQL 一部制限あり
            │
            └─ No（小容量・既存接続文字列を変えたくない）
                  └─ Azure SQL Database Serverless（自動一時停止）
```

---

## 6. Azure SQL Managed Instance を推奨する理由（本プロジェクト）

| 観点 | 内容 |
|------|------|
| **Windows Server EOL 脱却** | OS 管理は Azure 側が担うため、EOL タスクが消滅 |
| **SQL Server 高互換** | 既存の SQL Agent ジョブ・Linked Server をほぼそのまま移行可能 |
| **セキュリティ** | VNet 統合・Private Endpoint・Microsoft Defender 標準対応 |
| **運用自動化** | パッチ適用・バックアップ・HA が自動化される |
| **コスト最適化** | Azure Hybrid Benefit 適用で既存ライセンスを活用可能 |

---

## 7. チェックリスト

- [ ] 現行 SQL Server バージョン・エディションを確認する
- [ ] 利用機能（SQL Agent ジョブ数・Linked Server 先・CLR アセンブリ等）をリストアップする
- [ ] xp_cmdshell など OS レベルの依存があるか確認する
- [ ] データベースサイズ・IOPS 要件を測定する
- [ ] Windows 認証（AD）の利用有無と Azure AD 連携の要件を確認する

---

## 8. よく出る判断パターン

**Q. SQL Agent ジョブが 50 本以上あるが、PaaS に移行できるか？**
→ A. SQL Managed Instance であれば SQL Agent をサポートするため移行可能。ジョブ定義のスクリプト化と動作確認が必要。

**Q. オンプレの Oracle に Linked Server 接続しているが、SQL MI に移行できるか？**
→ A. SQL MI の Linked Server は SQL Server 同士が主な対象。Oracle への Linked Server は制限があるため要検証。代替手段（SSIS / Data Factory）の検討が必要。

**Q. Windows Server のライセンスを SQL MI に移行後も活用したいが？**
→ A. Azure Hybrid Benefit（AHB）により既存の SQL Server ライセンスを SQL MI に適用可能。Windows Server ライセンスは AHB で Azure VM に流用可能（SQL MI 自体は OS 管理不要のため適用先は VM）。
