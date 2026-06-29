# SQL Server 棚卸し結果 評価ステップガイド

> **前提**: `feature-check.sql` の実行結果が手元にある状態から開始する  
> **目的**: 社内 AI を活用しながら移行先を確定し、次アクションまで繋げる

---

## 全体フロー

```
STEP 1  SQL結果 → チェックリストへ転記（検知列）
   ↓
STEP 2  システムオブジェクト除外 → 判定列を記入
   ↓
STEP 3  SQL on VM 確定要件チェック（ノックアウト判定）
   ↓
STEP 4  移行先の確定（SQL MI / SQL DB / Synapse）
   ↓
STEP 5  ノックアウト要件の解消策確認
   ↓
STEP 6  コスト試算
   ↓
STEP 7  移行手順の選定
```

---

## STEP 1｜SQL 結果をチェックリストへ転記（検知列）

### タスク

`feature-check.sql` の Messages タブ出力を `feature-checklist.md` の**検知列**に転記する。

| 記録ルール | 例 |
|---|---|
| 0 件だった | `0件` と明記（空白にしない） |
| 件数のみ | `3件`（内容は STEP 2 で精査） |
| 名前が出た | `syspolicy_purge_history` など列挙 |
| スキップ | `※ 2016以降の機能` と明記 |

### 確認観点

- 空白のままにしない（未確認と区別するため）
- SECTION 3（DB ループ）は DB 名ごとに分けて記録する
- `0件` が正常な状態の項目もある（xp_cmdshell=0 は非使用で正常）

---

## STEP 2｜システムオブジェクト除外 → 判定列を記入

### タスク

検知列の結果を見て、**システム標準のものを除外**した上で判定列を埋める。

| 判定 | 記入内容 |
|---|---|
| ユーザーが作成・利用している | `☑ 要対応` |
| システム標準 or 未使用 | `- 不要` |

### AIプロンプト例（2-1 SQL Agent ジョブの精査）

```
以下は SQL Server Agent ジョブの一覧です。
SQL Server が自動生成するシステムジョブを除外し、
ユーザーが作成した業務ジョブのみを抽出してください。

システムジョブの例:
- syspolicy_purge_history（ポリシー管理）
- sp_delete_backuphistory（バックアップ履歴削除）
- sp_purge_jobhistory（ジョブ履歴削除）
- DatabaseBackup / IndexOptimize 等（Ola Hallengren スクリプト）

ジョブ一覧:
[SQL結果を貼り付け]

出力形式:
- 業務ジョブ: [名前] [enabled]
- システムジョブ（除外）: [名前]
```

### 確認観点

- **4-3（SP・UDF・ビュー）の件数が多くても、移行先選定には影響しない**（SQL DB でも問題なし）
- **1-1（xp_cmdshell）は value_in_use = 0 なら未使用**
- **1-2（FILESTREAM）は 0 なら未使用**
- **9-3（サイズ）は数字をそのまま記録**（1TB 超かどうかの判断は STEP 4 で）

---

## STEP 3｜SQL on VM 確定要件チェック

### タスク

以下のいずれかに `☑ 要対応` があれば **SQL on VM 確定**。以降の PaaS 検討は不要。

| チェック項目 | 確認方法 |
|---|---|
| 1-1〜1-4（OS コマンド・SSIS ローカル） | 判定列を確認 |
| 3-2（異種 DBMS Linked Server） | Oracle / DB2 等の product 名が出ているか |
| 4-2（CLR UNSAFE / EXTERNAL_ACCESS） | 件数 > 0 か |
| 5-2（マージ レプリケーション） | DB 名が出ているか |
| 6-2（Service Broker 外部アクティベーション） | 件数 > 0 か |

### AIプロンプト例

```
以下は SQL Server の機能棚卸し結果（判定列）です。
Azure SQL Managed Instance / SQL Database への PaaS 移行を阻む
「SQL on VM 確定要件」に該当する項目がないか確認してください。

判定結果:
[feature-checklist.md の判定列をコピペ]

確認してほしい観点:
1. xp_cmdshell / FILESTREAM / CmdExec / PowerShell / SSIS ステップの使用有無
2. 異種 DBMS（Oracle / DB2 等）への Linked Server の有無
3. CLR UNSAFE / EXTERNAL_ACCESS アセンブリの有無
4. マージ レプリケーションの有無
5. Service Broker 外部アクティベーションの有無

上記に該当するものがあれば、その理由と SQL on VM が必要な根拠も教えてください。
```

### 確認観点

- SQL on VM 確定 → STEP 5 以降は SQL on VM 前提で再確認
- SQL on VM 確定でない → STEP 4 に進む

---

## STEP 4｜移行先の確定（SQL MI / SQL DB / Synapse）

### タスク

判定サマリの Step 2・Step 3 を実施し、移行先を 1 つに絞る。

```
SQL on VM 確定でない場合:

Q. 以下のいずれかに ☑ がある？
  → カテゴリ 2（SQL Agent）
  → 3-1（SQL Server 間 Linked Server）
  → 3-3（MSDTC）
  → 4-1（CLR SAFE）
  → 5-1（トランザクション レプリケーション）
  → 6-1（Service Broker 内部のみ）

  Yes → SQL MI 以上
  No  → 9-1（OLTP 継続）に ☑？
           Yes → SQL DB Serverless
           No（参照専用）→ 9-3/9-4 に ☑？
                Yes → Synapse + ADLS
                No  → SQL DB Serverless
```

### AIプロンプト例

```
以下は SQL Server 機能棚卸しの判定結果です。
Azure 移行先（SQL MI / SQL DB / Synapse + ADLS）を推奨し、
その根拠を判定サマリのルールに沿って説明してください。

判定結果（☑ 要対応 の項目のみ抜粋）:
[☑ の項目一覧を貼り付け]

ワークロード情報:
- 移行後も INSERT/UPDATE/DELETE が発生するか: [はい/いいえ]
- データ総サイズ: [XX GB]
- 参照頻度: [高頻度 / 月数回程度]

移行先の判定ルール:
- SQL Agent / Linked Server（SQL間）/ CLR SAFE / トランザクションレプリ 等 → SQL MI
- 上記なし かつ OLTP 継続 → SQL DB Serverless
- 上記なし かつ 参照専用 かつ 1TB以上または低頻度 → Synapse + ADLS
```

### 確認観点

- SQL Agent ジョブがシステムジョブのみだった場合は SQL DB も候補に入る
- ビュー・SP・UDF の件数は移行先選定に影響しない（SQL DB で対応可）
- データ量が 16 TB 超の場合、SQL MI（GP）は上限オーバー → Hyperscale または SQL on VM

---

## STEP 5｜ノックアウト要件の解消策確認

### タスク

確定した移行先に対し、`☑ 要対応` となった各機能の解消策を `02-knockout-requirements/notes.md` で確認する。

### AIプロンプト例

```
Azure SQL Managed Instance への移行を検討しています。
以下の機能が現行 SQL Server で使用されています。
各機能について、SQL MI への移行における制限と解消策を教えてください。

使用機能:
- [例: SQL Agent ジョブ 15 本（CmdExec ステップなし）]
- [例: Linked Server（社内の別 SQL Server への接続）]
- [例: Database Mail（ジョブ完了通知）]

確認したい点:
1. SQL MI でそのまま移行できるか
2. 移行できない場合の代替手段
3. 対応工数の概算（大 / 中 / 小）
```

### 確認観点

| 機能 | SQL MI での扱い | 要チェック点 |
|---|---|---|
| SQL Agent ジョブ | サポート（CmdExec / xp_cmdshell は不可） | ステップの subsystem を再確認 |
| Linked Server | SQL Server 同士はサポート | 接続先が Oracle 等でないか |
| CLR（SAFE） | サポート | UNSAFE が混在していないか |
| Service Broker | 内部のみサポート | 外部アクティベーション有無を再確認 |
| Database Mail | サポート（SMTP 設定要） | SMTP サーバーの準備 |
| MSDTC | プレビュー段階 | 業務クリティカルでないか確認 |
| TDE | デフォルト有効（無効化不可） | オンプレが TDE なしでも自動適用される |
| 照合順序 | インスタンス作成時に固定 | Japanese_CI_AS など日本語照合順序を指定する |

---

## STEP 6｜コスト試算

### タスク

`04-cost-analysis/notes.md` を参照し、DB サイズ・vCore・リザーブド/HB 適用の有無で概算コストを算出する。

### AIプロンプト例

```
以下の条件で Azure [SQL MI / SQL DB Serverless / Synapse + ADLS] の
月額コスト概算と 5 年 TCO を試算してください。

環境情報:
- データ総サイズ: [XX GB]
- 現行 SQL Server のコア数: [XX コア]
- SQL Server ライセンス: [SA あり / なし]（Azure Hybrid Benefit 適用可否）
- 可用性要件: [General Purpose / Business Critical]
- アクセス頻度: [常時稼働 / 夜間停止可 / 月数回程度]

試算してほしい項目:
1. コンピュート費用（vCore モデル）
2. ストレージ費用
3. Azure Hybrid Benefit 適用後の割引額
4. リザーブドインスタンス（1年/3年）の比較
5. オンプレ継続との差額（TCO）
```

### 確認観点

- **SQL MI は vCore 単位で購入**（最小 4 vCore）
- **SQL DB Serverless は自動一時停止**で非稼働時コストがほぼゼロ
- **Synapse + ADLS はストレージが SQL DB の約 1/6**（Cool 層: ¥1.5/GB vs ¥17.3/GB）
- Azure Hybrid Benefit は **SQL Server Enterprise SA あり** で最大 55% 割引

---

## STEP 7｜移行手順の選定

### タスク

DB サイズとダウンタイム許容時間をもとに、移行方式を決定する。

| 条件 | 推奨方式 |
|---|---|
| DB サイズ < 200 GB かつ ダウンタイム許容あり | BACPAC（SqlPackage）|
| DB サイズ ≥ 200 GB または ダウンタイム最小化 | Azure DMS + SHIR（オフライン移行）|
| READ_ONLY データのアーカイブ | ADF / bcp → Parquet → ADLS |

### AIプロンプト例

```
以下の条件で SQL Server から Azure SQL Database / SQL MI への
移行方式（BACPAC または Azure DMS）を選定してください。

環境情報:
- DB サイズ: [XX GB]
- 許容ダウンタイム: [XX 時間]
- 移行元 SQL Server バージョン: [2008 R2 / 2016 / etc.]
- ネットワーク帯域（オンプレ ↔ Azure）: [おおよその Mbps]
- SHIR（セルフホステッド統合ランタイム）の設置可否: [可 / 不可]

確認したい点:
1. BACPAC と DMS それぞれの所要時間概算
2. 各方式のリスクと注意点
3. 移行前に確認すべき互換性レベルの扱い
```

### 確認観点

- **BACPAC は互換性レベル 100 以上が必要**（SQL Server 2008 R2 はデフォルト 100 で OK）
- **DMS は SHIR バージョン 5.37 以上が必要**
- **SSMS は 18.x を使用**（19 以降は SQL Server 2008 R2 との TLS 互換問題あり）
- 本番移行前に**検証環境で BACPAC → Azure SQL DB への動作確認**を推奨

---

## 参照ドキュメント早見表

| STEP | 参照先 |
|---|---|
| 1〜4 | `docs/01-migration-targets/feature-checklist.md` |
| 5 | `docs/02-knockout-requirements/notes.md` |
| 6 | `docs/04-cost-analysis/notes.md` |
| 7 | `docs/06-migration-procedures/01-verification-procedure.md`（検証）|
| 7 | `docs/06-migration-procedures/02-production-dms-procedure.md`（本番）|

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SQL Server 移行ガイド（全体） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/ |
| SQL MI と SQL Server の T-SQL 相違点 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/transact-sql-tsql-differences-sql-server |
| Azure SQL 機能比較（MI / DB / VM） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/features-comparison |
| Azure AD Connect（オンプレ AD 同期） | https://learn.microsoft.com/ja-jp/entra/identity/hybrid/connect/whatis-azure-ad-connect |
| Azure AD 認証（Azure SQL） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/authentication-aad-overview |
| Database Experimentation Assistant（DEA） | https://learn.microsoft.com/ja-jp/sql/dea/database-experimentation-assistant-overview |
| SqlPackage Export | https://learn.microsoft.com/ja-jp/sql/tools/sqlpackage/sqlpackage-export |
| Azure Database Migration Service | https://learn.microsoft.com/ja-jp/azure/dms/dms-overview |

---

*作成日：2026-06-23*
