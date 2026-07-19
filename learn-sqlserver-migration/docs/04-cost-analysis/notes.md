# 04. コスト分析・ライセンス最適化

> **作成日**: 2026-04-15  
> **対象**: Azure SQL Managed Instance（主）/ SQL Server on Azure VM（比較用）

---

## 1. コスト削減の主な手段

SQL Server を Azure に移行する際、以下の施策を組み合わせてコストを最適化する。

| 施策 | 削減効果の目安 | 概要 |
|------|:-----------:|------|
| Azure Hybrid Benefit（AHB） | 最大 **55%** 削減 | 既存 SQL Server / Windows ライセンスを Azure に適用 |
| Reserved Instances（予約） | 最大 **33%** 削減 | 1 年 or 3 年の事前予約で割引 |
| PaaS 化（SQL MI）による運用コスト削減 | 人件費削減 | OS・パッチ・バックアップ管理が不要になる |
| Windows Server EOL 対応コスト削減 | --- | EOL 延長サポート費用・OS 更新作業の消滅 |
| AHB + Reserved の組み合わせ | 最大 **80%** 削減 | 両方適用した場合の最大効果 |

---

## 2. Azure Hybrid Benefit（AHB）

### 概要

ソフトウェアアシュアランス（SA）付きの既存ライセンスを Azure に持ち込んで割引を受ける制度。

```
AHB 適用対象ライセンス

SQL Server Enterprise Edition（SA 付き）
  → SQL MI / SQL DB の Business Critical vCore を大幅割引

SQL Server Standard Edition（SA 付き）
  → SQL MI / SQL DB の General Purpose vCore を割引

Windows Server（SA 付き）
  → Azure VM の Windows OS ライセンス無償化
```

### SQL Managed Instance への AHB 適用効果（概算）

| SKU | AHB なし（PAYG） | AHB あり | 削減率 |
|-----|:--------------:|:-------:|:-----:|
| SQL MI GP 4 vCore | 約 ¥60,000/月 | 約 ¥27,000/月 | 約 55% |
| SQL MI GP 8 vCore | 約 ¥120,000/月 | 約 ¥54,000/月 | 約 55% |
| SQL MI BC 4 vCore | 約 ¥200,000/月 | 約 ¥90,000/月 | 約 55% |

> ※ 上記は東日本リージョンの概算。実際の金額は Azure 料金計算ツールで確認すること。

### AHB を適用できる条件

1. ライセンスに**ソフトウェアアシュアランス（SA）**が付いていること
2. SQL Server Enterprise / Standard Edition のライセンスを所有していること
3. ライセンスの **コア数** に応じた vCore 数に適用できる
   - SQL Server Enterprise 1 コアライセンス → SQL MI 4 vCore に適用可
   - SQL Server Standard 1 コアライセンス → SQL MI 1 vCore に適用可

---

## 3. Reserved Instances（予約割引）

### 概要

1 年または 3 年のコミットメントにより、従量課金より割引価格でリソースを利用できる。

| 予約期間 | 割引率（目安） |
|---------|:-----------:|
| 1 年予約 | 約 20〜25% 割引 |
| 3 年予約 | 約 30〜33% 割引 |

### 注意点

- 予約はキャンセル・変更に制限あり（払い戻し上限: 年間 ¥450,000 相当）
- vCore 数・SKU（GP / BC）の変更は可能だが一定条件あり
- 本番環境が安定稼働し始めたタイミングで予約に切り替えるのが安全

---

## 4. AHB + Reserved Instances の組み合わせ効果

```
PAYG 料金 → AHB 適用 → Reserved 適用（1年）
¥120,000/月 → ¥54,000/月 → 約 ¥43,000/月

削減率: 約 64%（AHB + 1年予約の場合）
```

---

## 5. PaaS 化（SQL MI）による運用コスト削減

### オンプレ SQL Server 運用コスト（従来）

| 項目 | 年間コスト試算（例） |
|------|:---------------:|
| Windows Server OS ライセンス（保守含む） | ¥500,000 |
| SQL Server ライセンス保守費（SA） | ¥600,000 |
| OSパッチ・セキュリティ対応（工数） | ¥400,000 |
| バックアップ管理・監視（工数） | ¥300,000 |
| ハードウェア更新・サーバ維持費 | ¥600,000 |
| Windows Server EOL 対応（OS 更新作業） | ¥500,000 |
| **合計** | **¥2,900,000/年** |

### Azure SQL MI 移行後（PaaS）

| 項目 | 内容 |
|------|------|
| OS パッチ管理 | Azure が自動管理 → **0 円** |
| バックアップ | 自動バックアップ（ポイントインタイムリストア）→ **0 円** |
| HA / フェイルオーバー | 組み込み済み → **0 円**（構築費用不要） |
| Windows Server EOL 対応 | SQL MI は OS 不要のため **発生しない** |
| 監視 | Azure Monitor / Defender for SQL で標準提供 |

---

## 6. Windows Server EOL 削減効果

### 現状の課題

```
オンプレ SQL Server 環境
┌─────────────────────────────────────┐
│  Windows Server 2019（EOL: 2029年）  │
│    └─ SQL Server 2019                │
│                                     │
│  Windows Server 2016（EOL: 2027年）  │
│    └─ SQL Server 2016                │
│                                     │
│  ※ EOL のたびに OS 更新作業が発生    │
└─────────────────────────────────────┘
```

### SQL MI 移行後

```
Azure SQL Managed Instance
┌─────────────────────────────────────────────────────┐
│  OS 管理不要（Microsoft が管理）                      │
│  SQL Server のパッチも自動適用                        │
│                                                     │
│  → Windows Server の EOL タスクが永続的に消滅        │
│  → OS 更新プロジェクトのコスト・工数がゼロになる       │
└─────────────────────────────────────────────────────┘
```

### EOL 対応コストの比較

| 対応方法 | コスト | EOL 繰り返し |
|---------|------|:-----------:|
| オンプレ OS 更新（毎回） | ¥500,000〜¥1,000,000/回 | あり（数年ごと） |
| Azure Hybrid Benefit で延長 | 追加費用 | 一時的な延長のみ |
| **SQL MI に移行（PaaS 化）** | **移行費のみ（一回限り）** | **なし** |

---

## 7. TCO（総保有コスト）比較モデル

### 5 年間の TCO 試算（例：小規模 SQL Server 1 台・DB 合計 500 GB）

```
【オンプレ継続の場合（5年間）】
  ハードウェア更新:       ¥1,000,000
  OSライセンス保守:       ¥500,000 × 5 = ¥2,500,000
  SQL Server SA:          ¥600,000 × 5 = ¥3,000,000
  運用工数（OS・バックアップ等）: ¥700,000 × 5 = ¥3,500,000
  EOL 対応（2027年・2029年）:  ¥1,500,000（2回分）
  ─────────────────────────────────────────
  合計: 約 ¥11,500,000

【SQL MI（AHB + 1年予約）に移行した場合（5年間）】
  移行費用（DMS・検証・アプリ改修）: ¥2,000,000
  SQL MI 利用料（AHB + RI）: ¥43,000 × 60 ヶ月 = ¥2,580,000
  監視・運用（Azure 管理のみ）: ¥200,000 × 5 = ¥1,000,000
  ─────────────────────────────────────────
  合計: 約 ¥5,580,000

削減額: 約 ¥5,920,000（約 51% 削減）
```

> ※ 上記は概算。実際は Azure 料金計算ツールおよび既存ライセンスの状況に応じて試算すること。

---

## 8. vCore サイジング指針

SQL MI の vCore 数の選定は現行サーバの CPU・メモリを参考にする。

| 現行サーバ | 推奨 SQL MI | 備考 |
|-----------|:----------:|------|
| 4 コア / 16 GB RAM | GP 4 vCore（20.4 GB） | 小規模 |
| 8 コア / 32 GB RAM | GP 8 vCore（40.8 GB） | 中規模 |
| 16 コア / 64 GB RAM | GP 16 vCore（81.6 GB） | 大規模 |
| 高 I/O 要件あり | BC 8〜16 vCore | ローカル SSD |

- **General Purpose（GP）**: 汎用。リモート Premium SSD ストレージ
- **Business Critical（BC）**: 高パフォーマンス。ローカル SSD + HA レプリカ内蔵

---

## 9. READ_ONLY・アーカイブ用途のコスト比較: Azure SQL Database vs Synapse + ADLS

> **対象シナリオ**: オンプレ 2TB の SQL Server を READ_ONLY で Azure に移行し、参照クエリのみ継続する場合

### 9-1. 構成別の料金内訳（東日本リージョン、2TB 想定）

#### 案A: Azure SQL Database Serverless（現行手順書の構成）

| 費用項目 | 計算根拠 | 月額（概算） |
|---------|---------|:----------:|
| ストレージ（2TB） | 2,000 GB × ¥17.3/GB | **¥34,500** |
| コンピュート（GP Serverless, 0.5 vCore 最小・自動停止1h） | 参照時のみ課金（月10〜30時間稼働想定） | **¥1,500〜5,000** |
| バックアップストレージ（7日保持） | 自動バックアップ込み | **¥0（含む）** |
| **合計** | | **約 ¥36,000〜40,000/月** |

> ⚠️ Azure SQL Database はストレージが GB 単価で高いため、大容量データでは高コストになる

#### 案B: Azure Synapse Analytics Serverless SQL Pool + ADLS Gen2

| 費用項目 | 計算根拠 | 月額（概算） |
|---------|---------|:----------:|
| ADLS Gen2 ストレージ（Cool 階層, 2TB） | 2,000 GB × ¥1.5/GB | **¥3,000** |
| Synapse Serverless SQL Pool（クエリ実行分） | ¥750/TB スキャン × 想定 1TB/月 | **¥750** |
| Synapse ワークスペース（停止時） | 非クエリ時は課金なし | **¥0** |
| ADF パイプライン（移行時のみ・一時費用） | 初回移行: ¥5,000〜20,000（一回限り） | — |
| **合計（移行後ランニング）** | | **約 ¥3,000〜5,000/月** |

### 9-2. 月額コスト比較サマリ

```
                   案A: Azure SQL DB Serverless   案B: Synapse + ADLS
                   ────────────────────────────   ──────────────────────
ストレージ (2TB)   ¥34,500/月                     ¥3,000/月 (Cool 階層)
コンピュート       ¥1,500〜5,000/月               ¥0（非クエリ時）
クエリ課金        なし（コンピュートに含む）         ¥750/TB スキャン
─────────────────────────────────────────────────────────────────────
合計              約 ¥36,000〜40,000/月           約 ¥3,000〜5,000/月
                                                  ↑ 約 88% コスト削減
```

### 9-3. 5 年間 TCO 比較（2TB READ-ONLY 移行シナリオ）

```
【案A: Azure SQL Database Serverless（5年間）】
  移行費用（BACPAC・検証）:          ¥300,000
  月額ランニング: ¥38,000 × 60 ヶ月: ¥2,280,000
  ─────────────────────────────────────────────
  合計: 約 ¥2,580,000

【案B: Synapse + ADLS（5年間）】
  移行費用（ADF パイプライン構築・Parquet 変換）: ¥500,000
  月額ランニング: ¥4,000 × 60 ヶ月:              ¥240,000
  ─────────────────────────────────────────────
  合計: 約 ¥740,000

5年間の削減額: 約 ¥1,840,000（約 71% 削減）
```

> ※ 案B は移行費用が高い（ADF パイプライン構築・データ変換）が、ランニングコストで逆転する

### 9-4. クエリ料金の目安（Synapse Serverless SQL Pool）

Synapse Serverless は**スキャンしたデータ量**に対して課金される（$5/TB ≒ ¥750/TB）。

| 月のクエリ量 | スキャン量 | 月額クエリ料金 |
|------------|---------|:-----------:|
| 軽い参照のみ（集計・件数確認程度） | 〜100GB | 約 ¥75 |
| 通常利用（数十クエリ/月） | 〜1TB | 約 ¥750 |
| 頻繁な分析クエリ（BI ダッシュボード含む） | 〜5TB | 約 ¥3,750 |

> **Parquet 形式 + カラムナー圧縮** を使うと、スキャン量を大幅に削減できる（CSV の 1/5〜1/10）

### 9-5. 案B の T-SQL 制限事項（Synapse Serverless SQL Pool）

移行前に以下の制限を確認すること。

| 機能 | 可否 | 代替案 |
|------|:---:|------|
| SELECT（通常の参照クエリ） | ✓ | — |
| JOIN、GROUP BY、ORDER BY | ✓ | — |
| CREATE EXTERNAL TABLE（ADLS ファイルをテーブルとして定義） | ✓ | — |
| ストアドプロシージャ | ✗ | ビュー / Synapse Pipeline で代替 |
| INSERT / UPDATE / DELETE | ✗ | READ_ONLY なら問題なし |
| 一時テーブル（#temp） | ✓（制限あり） | CTE / 外部テーブルで代替 |
| IDENTITY / SEQUENCE | ✗ | 参照用途では影響なし |
| @@SERVERNAME などシステム関数 | △ | 一部のみ対応 |

### 9-6. 選定判断基準

| 判断基準 | Azure SQL Database Serverless | Synapse + ADLS |
|--------|:---:|:---:|
| データ量 2TB 以上 | △（コスト高） | ✓ |
| 参照頻度が低い（月数回） | ✓ | ✓（最安） |
| 既存の接続文字列・ドライバをそのまま使いたい | ✓ | ✗（要変更） |
| Power BI / 分析ツールとの連携 | ✓ | ◎ |
| 移行の簡便さ（BACPAC で完結） | ◎ | △（ADF 構築が必要） |
| 5年間のコスト最小化 | △ | ◎ |

---

## 10. チェックリスト

- [ ] 現行 SQL Server ライセンスの SA 有効期限を確認した
- [ ] AHB 適用可能なコア数を確認した
- [ ] 現行サーバの CPU / メモリ使用率を計測し、vCore 数を試算した
- [ ] Azure 料金計算ツールで SQL MI の月額費用を試算した
- [ ] 5 年間の TCO 比較（オンプレ継続 vs Azure 移行）を作成した
- [ ] Reserved Instances の適用タイミング（本番安定後）を計画した
- [ ] Windows Server EOL 対応コスト削減効果を定量化した
- [ ] READ_ONLY データの移行先として Synapse + ADLS のコスト比較を行った
- [ ] Synapse Serverless の T-SQL 制限が現行クエリに影響しないか確認した

---

## 11. よく出る判断パターン

**Q. 現行 SQL Server のライセンスが SA 切れの場合、AHB は使えるか？**
→ A. AHB には SA が必要。SA が切れている場合は従量課金（PAYG）か、SA を再契約してから AHB を適用する。一方、Azure へ移行することで今後の SA 更新費用自体が不要になるケースもある（PaaS のためライセンス不要）。

**Q. vCore 数は後から変更できるか？**
→ A. SQL MI の vCore 数・ストレージはオンラインで変更可能（数分〜数十分のダウンタイムあり）。最初は少ない vCore から始めてスケールアップする戦略も有効。

**Q. Reserved Instances を購入した後に SQL MI を削除した場合はどうなるか？**
→ A. 予約は自動的に同じリージョン・SKU の別 SQL MI に適用される。該当するリソースがなければ無駄になるため、本番移行が確定してから購入すること。

**Q. 2TB の READ_ONLY データを Synapse + ADLS に移行する場合、移行ツールは何を使うか？**
→ A. 主に Azure Data Factory（ADF）を使う。ADF の「SQL Server → ADLS Gen2（Parquet 形式）」パイプラインで並列エクスポートが可能。bcp コマンドで CSV エクスポート → ADF で Parquet 変換という段階的な方法もある。

**Q. Synapse Serverless SQL Pool で既存の SELECT クエリはそのまま動くか？**
→ A. 基本的な SELECT / JOIN / GROUP BY / ORDER BY は動作する。ただし OPENROWSET 構文または EXTERNAL TABLE 経由でのアクセスになるため、既存クエリのテーブル参照部分は変更が必要。ビュー（CREATE VIEW）で既存クエリと同名のオブジェクトを作れば影響を最小化できる。

**Q. Synapse + ADLS で Cool 階層と Hot 階層はどう使い分けるか？**
→ A. 参照頻度が月 1〜2 回以下なら Cool 階層（¥1.5/GB/月）が安い。ただし Cool 階層はデータ読み出し時に追加料金（¥0.015/GB）が発生するため、頻繁にクエリを実行する場合は Hot 階層（¥2.7/GB/月）が有利になる分岐点を計算すること。

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| Azure SQL Managed Instance 料金 | https://azure.microsoft.com/ja-jp/pricing/details/azure-sql-managed-instance/single/ |
| Azure SQL Database 料金 | https://azure.microsoft.com/ja-jp/pricing/details/azure-sql-database/single/ |
| Azure SQL Database Serverless 概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/serverless-tier-overview |
| Azure Hybrid Benefit（ライセンス節約） | https://azure.microsoft.com/ja-jp/pricing/hybrid-benefit/ |
| Azure Reserved Instances（予約割引） | https://learn.microsoft.com/ja-jp/azure/cost-management-billing/reservations/save-compute-costs-reservations |
| Azure Data Lake Storage Gen2 料金 | https://azure.microsoft.com/ja-jp/pricing/details/storage/data-lake/ |
| Azure Synapse Analytics 料金 | https://azure.microsoft.com/ja-jp/pricing/details/synapse-analytics/ |
| Azure 料金計算ツール | https://azure.microsoft.com/ja-jp/pricing/calculator/ |
