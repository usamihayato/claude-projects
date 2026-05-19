# Collibra DQ ランニングコスト比較（Standalone / AKS / ARO）

> **作成日**: 2026-04-16  
> **対象バージョン**: Collibra DQ 2026.02  
> **リージョン**: Japan East  
> **通貨**: 日本円（JPY）  
> **価格種別**: 従量課金（Pay-as-you-go）  
> **為替レート**: 1 USD = 150 JPY（Azure 公式 JPY 価格を使用）

> ⚠️ **注意**: 本ドキュメントの価格は 2025年8月時点の Azure 公式価格（Japan East・JPY・従量課金）を参照。  
> 最新価格の確認は [Azure 料金計算ツール](https://azure.microsoft.com/ja-jp/pricing/calculator/) または  
> [Azure Retail Prices API](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&$filter=armRegionName%20eq%20'japaneast'%20and%20currencyCode%20eq%20'JPY') で行うこと。

---

## スコープ

| コンポーネント | スコープ | 備考 |
|---|---|---|
| DQ Agent | **対象** | 本試算に含む |
| Spark | **対象** | 本試算に含む |
| DQ Web | 対象 | 本試算に含む（次フェーズで除外予定） |
| Metastore（PostgreSQL） | **対象外** | グループ会社の既存環境を利用 |

---

## 目次

1. [前提条件・構成の定義](#1-前提条件構成の定義)
2. [単価リスト（途中式の根拠）](#2-単価リスト途中式の根拠)
3. [Standalone（Azure VM）コスト試算](#3-standaloneazure-vmコスト試算)
4. [AKS コスト試算](#4-aksコスト試算)
5. [ARO コスト試算](#5-aroコスト試算)
6. [三構成 比較サマリー](#6-三構成-比較サマリー)
7. [コスト削減オプション](#7-コスト削減オプション)

---

## 1. 前提条件・構成の定義

### 1.1 Collibra DQ 最小要件

| 規模 | CPU | RAM | 備考 |
|---|---|---|---|
| **最小（本試算）** | **16 コア** | **128 GB** | 週1回・1 TB スキャン |
| 標準 | 32 コア | 256 GB | 並行ジョブ数 ~9 |
| 大規模 | 64 コア | 512 GB | 並行ジョブ数 ~18 |

### 1.2 スキャン条件の仮置き

| 条件 | 値 |
|---|---|
| スキャン頻度 | 週 1 回 |
| スキャンサイズ | 1 TB / 回 |
| 月間スキャン回数 | 約 4.3 回 |
| ジョブ実行時間の目安 | 2〜4 時間 / 回 |
| DQ プロセスの稼働形態 | **24時間365日常時稼働**（VM/Pod は常時起動） |

> Spark は週1回のジョブ時のみ高負荷になるが、VM/Pod の起動コストは常時発生する。  
> スポット/プリエンプティブルの活用は [7章](#7-コスト削減オプション) を参照。

### 1.3 各構成の最小インフラ定義

#### Standalone（Azure VM）

| コンポーネント | リソース | 台数 | 役割 |
|---|---|---|---|
| DQ VM | Standard_E16s_v5（16 vCPU / 128 GB） | 1 | DQ Web + DQ Agent + Spark |
| ~~Metastore~~ | ~~PostgreSQL Flexible Server~~ | ~~1~~ | **対象外**（グループ会社環境） |
| OS Disk | Premium SSD P10（128 GB） | 1 | OS 領域 |
| Data Disk | Premium SSD P20（512 GB） | 1 | ログ・Spark 一時領域 |
| ネットワーク | NSG のみ（ILB なし） | — | — |

#### AKS

| コンポーネント | リソース | 台数 | 役割 |
|---|---|---|---|
| Control Plane | AKS Free Tier | 1 cluster | Kubernetes 制御面 |
| System Node Pool | Standard_D2s_v5（2 vCPU / 8 GB） | 1 | kube-system Pod |
| DQ Node Pool | Standard_E16s_v5（16 vCPU / 128 GB） | 1 | DQ Web + Agent + Spark |
| ~~Metastore~~ | ~~PostgreSQL Flexible Server~~ | ~~1~~ | **対象外**（グループ会社環境） |
| OS Disk（System） | Premium SSD P10（128 GB） | 1 | — |
| OS Disk（DQ） | Premium SSD P10（128 GB） | 1 | — |
| PVC（DQ data） | Premium SSD P10（128 GB） | 1 | DQ 永続データ |
| ACR | Basic Tier | 1 | コンテナイメージ |
| Load Balancer | Standard Tier | 1 | DQ Web 公開 |

#### ARO（Azure Red Hat OpenShift）

| コンポーネント | リソース | 台数 | 役割 |
|---|---|---|---|
| OpenShift クラスター料金 | ARO fee（per cluster） | 1 | OpenShift ライセンス |
| Master Node | Standard_D8s_v3（8 vCPU / 32 GB） | 3 | 制御面（変更不可） |
| Worker Node | Standard_E16s_v5（16 vCPU / 128 GB） | 2 | DQ Web + Agent + Spark |
| ~~Metastore~~ | ~~PostgreSQL Flexible Server~~ | ~~1~~ | **対象外**（グループ会社環境） |
| OS Disk（各ノード） | Premium SSD P10（128 GB） | 5 | — |
| Load Balancer | Standard Tier（ARO 付属） | 1 | DQ Web 公開 |

---

## 2. 単価リスト（途中式の根拠）

> 価格は Azure 公式 Japan East・JPY・従量課金（Pay-as-you-go）。  
> 月額換算 = 時間単価 × 730 時間（= 365日 × 24時間 / 12ヶ月）。

### 2.1 Virtual Machines（Linux、Japan East、従量課金）

| SKU | vCPU | RAM | 時間単価（JPY） | 月額（JPY） | 参照 |
|---|---|---|---|---|---|
| Standard_D2s_v5 | 2 | 8 GB | ¥15.07 | ¥11,001 | [VM 料金](https://azure.microsoft.com/ja-jp/pricing/details/virtual-machines/linux/) |
| Standard_D4s_v5 | 4 | 16 GB | ¥30.14 | ¥22,002 | 同上 |
| Standard_D8s_v3 | 8 | 32 GB | ¥65.86 | ¥48,078 | 同上 |
| **Standard_E16s_v5** | **16** | **128 GB** | **¥179.96** | **¥131,371** | 同上 |
| Standard_E32s_v5 | 32 | 256 GB | ¥359.92 | ¥262,742 | 同上 |

**途中式（Standard_E16s_v5 月額）:**
```
¥179.96/hr × 730 hr/月 = ¥131,371/月
```

### 2.2 Azure DB for PostgreSQL Flexible Server（参考・本試算対象外）

> Metastore はグループ会社環境を利用するため、本試算には含まない。  
> 将来的に自社構築する場合の参考として価格を記載する。

| SKU | vCPU | RAM | 月額 コンピュート（JPY） | 備考 |
|---|---|---|---|---|
| Burstable B2ms | 2 | 8 GB | ¥14,053 | 開発・PoC 向け |
| GP_D4ds_v5 | 4 | 16 GB | ¥45,713 | 本番向け最小 |
| GP_D8ds_v5 | 8 | 32 GB | ¥91,425 | 本番向け標準 |

### 2.3 Managed Disk（Premium SSD、Japan East）

| Disk | サイズ | 月額（JPY） |
|---|---|---|
| P10 | 128 GB | ¥2,529 |
| P15 | 256 GB | ¥4,120 |
| P20 | 512 GB | ¥7,546 |
| P30 | 1 TB | ¥13,946 |

### 2.4 AKS 関連

| リソース | 月額（JPY） | 備考 |
|---|---|---|
| AKS Control Plane（Free Tier） | **¥0** | SLA なし（99.9% SLA は Standard Tier ¥7,737/月） |
| AKS Control Plane（Standard Tier） | ¥7,737 | ¥10.60/hr × 730h |
| ACR Basic | ¥1,097 | 基本料金 + ストレージ（10 GB） |

**途中式（ACR Basic 月額）:**
```
基本料金: $0.167/日 × 150 JPY × 30日 = ¥752
ストレージ（10 GB）: $0.023/GB × 10 GB × 150 JPY = ¥345
合計: ¥752 + ¥345 = ¥1,097/月
```

### 2.5 Load Balancer（Standard、Japan East）

| 項目 | 単価 | 月額（JPY） |
|---|---|---|
| LB 基本料金 | ¥2.75/hr | ¥2,008 |
| ルール料金（最初の5ルール） | ¥0.275/ルール/hr | ¥201/ルール |
| データ処理（最初の5 GB） | ¥2.20/GB | — |

**途中式（LB 月額・1ルール想定）:**
```
基本料金: ¥2.75/hr × 730h = ¥2,008
ルール料金（1ルール）: ¥0.275/hr × 730h = ¥201
合計: ¥2,008 + ¥201 = ¥2,209/月
```

### 2.6 ARO クラスター料金（Japan East）

| 項目 | 時間単価（JPY） | 月額（JPY） |
|---|---|---|
| ARO クラスター fee | ¥54.0/hr | ¥39,420 |

**途中式（ARO クラスター月額）:**
```
$0.36/hr × 150 JPY/USD × 730 hr/月 = ¥39,420/月
```

> ARO クラスター料金には OpenShift ライセンス・サポートが含まれる。  
> 参照: [ARO 料金](https://azure.microsoft.com/ja-jp/pricing/details/openshift/)

---

## 3. Standalone（Azure VM）コスト試算

### 3.1 月額の途中式

| # | コンポーネント | リソース | 計算式 | 月額（JPY） |
|---|---|---|---|---|
| 1 | DQ VM | Standard_E16s_v5 × 1 | ¥179.96 × 730h | ¥131,371 |
| ~~2~~ | ~~Metastore~~ | ~~PostgreSQL~~ | — | **対象外** |
| 2 | OS Disk | Premium SSD P10（128 GB）× 1 | 固定 | ¥2,529 |
| 3 | Data Disk | Premium SSD P20（512 GB）× 1 | 固定 | ¥7,546 |
| 4 | ネットワーク送受信 | アウトバウンド 10 GB/月 想定 | ¥16.5/GB × 10 GB | ¥165 |
| **合計** | | | | **¥141,611/月** |

### 3.2 年額・5年総額

```
月額: ¥141,611
年額（×12）: ¥141,611 × 12 = ¥1,699,332
5年総額（×60）: ¥141,611 × 60 = ¥8,496,660
```

| 期間 | 金額（JPY） |
|---|---|
| 月額 | ¥141,611 |
| **年額** | **¥1,699,332** |
| **5年総額** | **¥8,496,660** |

---

## 4. AKS コスト試算

### 4.1 月額の途中式

| # | コンポーネント | リソース | 計算式 | 月額（JPY） |
|---|---|---|---|---|
| 1 | AKS Control Plane | Free Tier | — | ¥0 |
| 2 | System Node Pool VM | Standard_D2s_v5 × 1 | ¥15.07 × 730h | ¥11,001 |
| 3 | DQ Node Pool VM | Standard_E16s_v5 × 1 | ¥179.96 × 730h | ¥131,371 |
| ~~4~~ | ~~Metastore~~ | ~~PostgreSQL~~ | — | **対象外** |
| 4 | OS Disk（System Pool） | Premium SSD P10 × 1 | 固定 | ¥2,529 |
| 5 | OS Disk（DQ Pool） | Premium SSD P10 × 1 | 固定 | ¥2,529 |
| 6 | PVC（DQ data） | Premium SSD P10 × 1 | 固定 | ¥2,529 |
| 7 | ACR | Basic Tier + 10 GB | 基本 + ストレージ | ¥1,097 |
| 8 | Load Balancer | Standard × 1（1ルール） | ¥2.75 × 730h + ¥0.275 × 730h | ¥2,209 |
| 9 | ネットワーク送受信 | アウトバウンド 10 GB/月 想定 | ¥16.5/GB × 10 GB | ¥165 |
| **合計** | | | | **¥153,430/月** |

### 4.2 年額・5年総額

```
月額: ¥153,430
年額（×12）: ¥153,430 × 12 = ¥1,841,160
5年総額（×60）: ¥153,430 × 60 = ¥9,205,800
```

| 期間 | 金額（JPY） |
|---|---|
| 月額 | ¥153,430 |
| **年額** | **¥1,841,160** |
| **5年総額** | **¥9,205,800** |

---

## 5. ARO コスト試算

### 5.1 月額の途中式

| # | コンポーネント | リソース | 計算式 | 月額（JPY） |
|---|---|---|---|---|
| 1 | ARO クラスター料金 | OpenShift ライセンス込み | $0.36 × 150 × 730h | ¥39,420 |
| 2 | Master Node VM | Standard_D8s_v3 × 3 | ¥65.86 × 730h × 3台 | ¥144,235 |
| 3 | Worker Node VM | Standard_E16s_v5 × 2 | ¥179.96 × 730h × 2台 | ¥262,742 |
| ~~4~~ | ~~Metastore~~ | ~~PostgreSQL~~ | — | **対象外** |
| 4 | OS Disk（全ノード） | Premium SSD P10 × 5 | ¥2,529 × 5台 | ¥12,645 |
| 5 | Load Balancer | Standard × 1（ARO 付属分） | ¥2.75 × 730h + ¥0.275 × 730h | ¥2,209 |
| 6 | ネットワーク送受信 | アウトバウンド 10 GB/月 想定 | ¥16.5/GB × 10 GB | ¥165 |
| **合計** | | | | **¥461,416/月** |

> **Master Node について**: ARO では Master Node（制御面）3台は必須かつサイズ変更不可。  
> Master Node の VM コスト（Standard_D8s_v3 × 3）はユーザー側の Azure サブスクリプションに課金される。

> **Worker Node について**: ARO の最小 Worker 数は 2台。ただし本番では 3台推奨（単一障害点を排除）。  
> 本試算は最小の 2台で計算。

### 5.2 年額・5年総額

```
月額: ¥461,416
年額（×12）: ¥461,416 × 12 = ¥5,536,992
5年総額（×60）: ¥461,416 × 60 = ¥27,684,960
```

| 期間 | 金額（JPY） |
|---|---|
| 月額 | ¥461,416 |
| **年額** | **¥5,536,992** |
| **5年総額** | **¥27,684,960** |

---

## 6. 三構成 比較サマリー

### 6.1 コスト比較表

| 構成 | 月額（JPY） | 年額（JPY） | 5年総額（JPY） | Standalone 比 |
|---|---|---|---|---|
| **Standalone（Azure VM）** | **¥141,611** | **¥1,699,332** | **¥8,496,660** | 1.00× |
| AKS | ¥153,430 | ¥1,841,160 | ¥9,205,800 | 1.08× |
| ARO | ¥461,416 | ¥5,536,992 | ¥27,684,960 | 3.26× |

### 6.2 コスト構成の内訳（月額）

```
【Standalone】月額 ¥141,611
  VM (E16s_v5)    ¥131,371  ████████████████████████████████  92.8%
  ディスク          ¥10,075  ███                                7.1%
  ネットワーク          ¥165  ▏                                  0.1%

【AKS】月額 ¥153,430
  VM (E16s_v5 DQ) ¥131,371  ████████████████████████████████  85.6%
  VM (D2s_v5 Sys)  ¥11,001  ███                                7.2%
  ディスク            ¥7,587  ██                                 4.9%
  ACR/LB/NW         ¥3,471  █                                  2.3%

【ARO】月額 ¥461,416
  Worker VM ×2    ¥262,742  ████████████████████████████████  56.9%
  Master VM ×3    ¥144,235  █████████████████                  31.3%
  ARO クラスター料金 ¥39,420  █████                               8.5%
  ディスク/NW        ¥15,019  ██                                 3.3%
```

### 6.3 構成別の特徴比較

| 比較項目 | Standalone | AKS | ARO |
|---|---|---|---|
| **月額コスト** | ¥141,611 ★ | ¥153,430 | ¥461,416 |
| **5年総額** | ¥8,496,660 ★ | ¥9,205,800 | ¥27,684,960 |
| **AKS とのコスト差（月）** | −¥11,819 | 基準 | +¥307,986 |
| **構築難易度** | 低（Linux 操作のみ） ★ | 中（Kubernetes 知識必要） | 高（OpenShift 知識必要） |
| **冗長化** | 手動（ILB + 2台） | Deployment replicaCount | Deployment replicaCount |
| **スケールアウト** | 手動 | HPA / Cluster Autoscaler | HPA / MachineSet |
| **RHEL サポート** | なし（RHEL は別途） | なし | **含む（Red Hat）** ★ |
| **Kubernetes** | 不要 ★ | 必要 | 必要 |
| **OpenShift 機能** | なし | なし | あり（Route / SCC 等） |
| **SLA**（コントロールプレーン） | — | 99.9%（Standard Tier） | 99.95% |

### 6.4 結論

| 観点 | 推奨構成 | 理由 |
|---|---|---|
| **コスト最小** | **Standalone** | 月額 ¥141,611 で最安。AKS 比 −¥11,819/月、ARO 比 −¥319,805/月 |
| **5年 TCO** | **Standalone** | ARO 比で約 ¥19,188,300（約1,919万円）安い |
| **運用負荷最小** | **Standalone** | Kubernetes 知識不要。systemd + テキストファイル操作のみ |
| **Kubernetes 活用** | **AKS** | Standalone とほぼ同コストで Kubernetes エコシステムを活用可能 |
| **企業標準が OpenShift** | **ARO** | Red Hat サポート・OpenShift 統合が必要な場合のみ選択 |

---

## 7. コスト削減オプション

### 7.1 Reserved Instances（予約インスタンス）

VM を 1年・3年の予約購入にすることで割引を受けられる。

| リソース | 割引率（1年） | 割引率（3年） |
|---|---|---|
| VM（E16s_v5） | 約 36% | 約 58% |

**Standalone での Reserved Instance 適用時の月額試算（1年予約）:**

```
VM (E16s_v5): ¥131,371 × (1 - 0.36) = ¥84,077
OS Disk:       ¥2,529（変化なし）
Data Disk:     ¥7,546（変化なし）
ネットワーク:      ¥165（変化なし）
合計: ¥84,077 + ¥2,529 + ¥7,546 + ¥165 = ¥94,317/月
```

| 期間 | 従量課金 | 1年予約 | 削減額 |
|---|---|---|---|
| 月額 | ¥141,611 | ¥94,317 | −¥47,294（−33%） |
| 年額 | ¥1,699,332 | ¥1,131,804 | −¥567,528 |
| 5年総額 | ¥8,496,660 | ¥5,659,020 | −¥2,837,640 |

### 7.2 Spot VM / スポットノード（AKS のみ）

スキャンが週1回・夜間実行であれば、DQ Node Pool をスポット VM で実行することで最大 60〜80% 削減できる。ただし中断リスクあり。

```
DQ Node Pool をスポットに変更した場合（AKS）:
Standard_E16s_v5 スポット割引: 最大 60〜80% 割引
¥131,371 × 0.3（スポット目安） = ¥39,411
→ 月額削減: −¥91,960（−60%）
```

### 7.3 Dev/Test 価格

開発・検証環境では Azure Dev/Test サブスクリプションを使用すると、一部 VM で最大 55% 割引を受けられる。

### 7.4 三構成の Reserved Instance（1年）適用後の5年総額

| 構成 | 5年総額（従量課金） | 5年総額（1年予約） | 5年削減額 |
|---|---|---|---|
| Standalone | ¥8,496,660 | ¥5,659,020 | −¥2,837,640 |
| AKS | ¥9,205,800 | ¥6,130,560 | −¥3,075,240 |
| ARO | ¥27,684,960 | ¥18,894,240 | −¥8,790,720 |

> ARO クラスター料金（¥39,420/月）は予約割引の対象外のため、VM のみに適用。

---

## 付録: 価格検証コマンド

以下の Azure Retail Prices API クエリで最新価格を確認できる。

```bash
# Standard_E16s_v5 (Linux, Japan East, JPY)
curl -s "https://prices.azure.com/api/retail/prices?\
api-version=2023-01-01-preview&\
\$filter=armRegionName eq 'japaneast' \
and currencyCode eq 'JPY' \
and priceType eq 'Consumption' \
and contains(skuName,'E16s v5') \
and serviceName eq 'Virtual Machines'" \
| python3 -c "
import json,sys
data=json.load(sys.stdin)
for i in data['Items']:
    if 'Windows' not in i.get('productName',''):
        print(i['skuName'], i['retailPrice'], i['unitOfMeasure'])
"

# ARO クラスター料金 (Japan East, JPY)
curl -s "https://prices.azure.com/api/retail/prices?\
api-version=2023-01-01-preview&\
\$filter=armRegionName eq 'japaneast' \
and currencyCode eq 'JPY' \
and priceType eq 'Consumption' \
and serviceName eq 'Azure Red Hat OpenShift'" \
| python3 -c "
import json,sys
data=json.load(sys.stdin)
for i in data['Items']:
    print(i['meterName'], i['retailPrice'], i['unitOfMeasure'])
"
```
