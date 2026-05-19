# 05. ネットワーク設計・NW要件（Azure SQL 移行）

> **作成日**: 2026-04-15  
> **対象**: Azure SQL Managed Instance（主）への移行時のネットワーク設計

---

## 1. 現行 Azure ネットワーク構成

ユーザー提供情報をもとに整理した現在のネットワーク全体像。

```
オンプレミス DC
    │
    │ ExpressRoute（専用線）
    ▼
┌──────────────────────────────────────────┐
│  Hub VNet（東日本リージョン）              │
│                                          │
│  ┌──────────────┐  ┌──────────────────┐  │
│  │ ER Gateway   │  │  Azure Firewall  │  │
│  │ (ER 接続点)  │  │  (インターネット  │  │
│  └──────────────┘  │   出口)          │  │
│                    └──────────────────┘  │
└─────┬──────────────────────┬────────────┘
      │ VNet Peering          │ VNet Peering
      ▼                       ▼
┌──────────────┐       ┌──────────────┐
│ Spoke VNet A │  ...  │ Spoke VNet B │  ← 既存プロジェクト
│ (プロジェクトA)│       │ (プロジェクトB)│
└──────────────┘       └──────────────┘
```

### Peering 設定（現状）

| 設定項目 | Hub 側 | Spoke 側 |
|---------|:------:|:--------:|
| ゲートウェイ転送を許可 | **✓ 有効** | ー |
| リモートゲートウェイを使用 | ー | **✓ 有効** |
| 転送トラフィックを許可 | ✓ 有効 | ✓ 有効 |

> この設定により Spoke VNet からオンプレ DC への到達性が確立されている。

---

## 2. 移行時のネットワーク追加構成

### 2-1. 全体構成（移行後）

```
オンプレミス DC
    │
    │ ExpressRoute（既存）
    ▼
┌──────────────────────────────────────────────┐
│  Hub VNet（既存・変更なし）                    │
│  ER Gateway / Azure Firewall                  │
└─────┬────────────────────────────────────────┘
      │ VNet Peering（新規追加）
      ▼
┌──────────────────────────────────────────────────┐
│  Spoke VNet（SQL 移行用・新規作成）               │
│  例: 10.x.0.0/16（東日本リージョン）             │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  SQL MI 専用サブネット（/27 以上）          │   │
│  │  例: 10.x.1.0/27                          │   │
│  │  委任: Microsoft.Sql/managedInstances     │   │
│  │                                           │   │
│  │  ┌─────────────────────────────────┐     │   │
│  │  │  Azure SQL Managed Instance     │     │   │
│  │  │  Private IP: 10.x.1.4 など      │     │   │
│  │  └─────────────────────────────────┘     │   │
│  └──────────────────────────────────────────┘   │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  管理・アプリ用サブネット（任意）            │   │
│  └──────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘

接続経路（オンプレ → SQL MI）:
DC → ER → Hub ER GW → Hub VNet → Peering → SQL Spoke → SQL MI 専用サブネット
```

---

## 3. SQL Managed Instance の NW 要件

### 3-1. 専用サブネットの必須要件

SQL MI は VNet に **直接インジェクション**される（Private Endpoint とは異なる）。

| 要件 | 内容 |
|------|------|
| **専用サブネット** | SQL MI 専用。他のリソース（VM / App Service 等）と**共存不可** |
| **最小サイズ** | `/27`（アドレス数 32）以上。推奨は `/25` または `/24`（将来のスケールアップ分を確保） |
| **サブネット委任** | `Microsoft.Sql/managedInstances` を委任設定する |
| **サービスエンドポイント** | SQL MI サブネットには**サービスエンドポイントを設定しない** |
| **リソースロック** | サブネットへのリソースロックは不可（SQL MI の内部操作を阻害する） |

> **注意**: `/27` は最低 1 インスタンスのデプロイに必要。vCore 数を増やした際やインスタンスを追加する場合は IP が追加消費されるため、余裕を持ったサイズ（`/25` 推奨）を設計すること。

---

### 3-2. NSG（ネットワークセキュリティグループ）

SQL MI サブネットに適用する NSG。Microsoft はサービスタグを使ったルール設定を推奨。

#### 必須インバウンドルール

| 優先度 | 名前 | ソース | ソースポート | 宛先 | 宛先ポート | プロトコル | 操作 |
|-------|------|--------|------------|------|----------|----------|------|
| 100 | allow_management_inbound | `SqlManagement` | * | * | 9000, 9003, 1438, 1440, 1452 | TCP | 許可 |
| 110 | allow_misubnet_inbound | VNet | * | * | * | * | 許可 |
| 120 | allow_health_probe_inbound | `AzureLoadBalancer` | * | * | * | * | 許可 |
| 4096 | deny_all_inbound | * | * | * | * | * | 拒否 |

#### 必須アウトバウンドルール

| 優先度 | 名前 | ソース | 宛先 | 宛先ポート | プロトコル | 操作 |
|-------|------|--------|------|----------|----------|------|
| 100 | allow_management_outbound | * | `SqlManagement` | 443 | TCP | 許可 |
| 110 | allow_misubnet_outbound | * | VNet | * | * | 許可 |
| 120 | allow_storage_outbound | * | `Storage.JapanEast` | 443 | TCP | 許可 |
| 130 | allow_aad_outbound | * | `AzureActiveDirectory` | 443 | TCP | 許可 |
| 140 | allow_afw_outbound | * | `AzureMonitor` | 443 | TCP | 許可 |
| 4096 | deny_all_outbound | * | * | * | * | 拒否 |

> `SqlManagement` サービスタグは SQL MI の管理プレーン通信に必要。これがないと SQL MI のデプロイ・管理操作が失敗する。

---

### 3-3. ルートテーブル（UDR）

SQL MI サブネットへのルートテーブル設定。

#### 現行構成（Azure Firewall 経由でインターネット接続）における考慮点

```
パターン① SQL MI 管理トラフィックを Azure Firewall に通す場合

  SQL MI → 0.0.0.0/0 → Next Hop: Azure Firewall の IP
  → Azure FW でアウトバウンド FQDN ルール（許可）が必要

パターン② SQL MI 管理トラフィックを直接インターネットに通す場合

  SQL MI 管理用 IP レンジに対して Next Hop: Internet を設定
  → SQL MI の内部管理トラフィックは Microsoft のマネージドエンドポイントへ
```

**推奨**: パターン①（Azure FW 経由）で統一し、FW ルールで許可する。

#### UDR の設定例（SQL MI サブネット向け）

| アドレスプレフィックス | ネクストホップの種類 | 備考 |
|---------------------|:----------------:|------|
| `0.0.0.0/0` | 仮想アプライアンス（Azure FW IP） | インターネット向けは FW 経由 |
| `10.0.0.0/8`（オンプレ・VNet 全体） | VNet ゲートウェイ | オンプレへはゲートウェイ経由（※） |

> ※ Hub-Spoke + ER 構成では通常オンプレ向けルートは BGP で自動伝搬されるため、UDR の明示設定は不要な場合が多い。Azure FW への強制転送（0.0.0.0/0）を設定した場合は、オンプレ向けの具体的なプレフィックスを VNet ゲートウェイ向けに UDR で明示設定する必要がある。

---

## 4. VNet Peering 設定（Hub ↔ SQL 移行 Spoke）

既存の Spoke VNet と同じ設定を踏襲する。

| 設定項目 | Hub 側 | SQL Spoke 側 |
|---------|:------:|:-----------:|
| ゲートウェイ転送を許可 | **✓ 有効** | ー |
| リモートゲートウェイを使用 | ー | **✓ 有効** |
| 転送トラフィックを許可 | ✓ 有効 | ✓ 有効 |
| 転送されたトラフィックを許可 | ✓ 有効 | ✓ 有効 |

> **「リモートゲートウェイを使用」を有効にすることで、SQL Spoke からオンプレ DC への到達性が確立される（既存 Spoke と同様の挙動）。**

---

## 5. Azure Firewall ルール追加

Hub VNet の Azure Firewall に以下のルールを追加する。

### 5-1. SQL MI 管理トラフィック用（アウトバウンド）

SQL MI の管理プレーン通信を許可するアプリケーションルール。

| ルール名 | ソース | プロトコル/ポート | ターゲット FQDN |
|---------|-------|:---------------:|---------------|
| allow-sqlmi-management | SQL MI サブネット CIDR | HTTPS:443 | `*.blob.core.windows.net` |
| allow-sqlmi-management | SQL MI サブネット CIDR | HTTPS:443 | `*.database.windows.net` |
| allow-sqlmi-management | SQL MI サブネット CIDR | HTTPS:443 | `login.microsoftonline.com` |
| allow-sqlmi-management | SQL MI サブネット CIDR | HTTPS:443 | `management.azure.com` |

### 5-2. アプリ・オンプレ DC からの SQL 接続用（インバウンド方向）

オンプレアプリ → ER → Hub FW → SQL Spoke → SQL MI のルートを通る場合。

| ルール名 | ソース | プロトコル/ポート | 宛先 |
|---------|-------|:---------------:|------|
| allow-onprem-to-sqlmi | オンプレ DC の CIDR | TCP:1433 | SQL MI の Private IP |
| allow-onprem-to-sqlmi | オンプレ DC の CIDR | TCP:11000-11999 | SQL MI の Private IP（リダイレクトモード用） |

> **接続ポリシーに注意**:
> - **プロキシモード** (Proxy): TCP 1433 のみ
> - **リダイレクトモード** (Redirect): TCP 1433 + TCP 11000-11999 が必要
> - SQL MI のデフォルトは VNet 内からは**リダイレクトモード**

---

## 6. DNS 設計

### SQL MI のエンドポイントと DNS

SQL MI はデプロイすると以下の形式のエンドポイントが発行される:

```
<インスタンス名>.<dns-zone>.database.windows.net
例: sqlmi-prod.xxxxxxxx.database.windows.net
```

この FQDN は **VNet 内の DNS（Azure DNS: 168.63.129.16）** で自動的にプライベート IP に解決される。

### オンプレ DC からの名前解決

```
オンプレ DC の DNS サーバ
  → 条件付きフォワーダー（database.windows.net → Azure DNS）
  → Azure DNS (168.63.129.16) ※ Azure VNet 内から解決される
  → SQL MI のプライベート IP

【注意】168.63.129.16 はオンプレから直接到達できないため、
       Hub VNet 内に Azure DNS リゾルバー（DNS Resolver）または
       DNS フォワーダー VM を置いてオンプレの DNS を中継させる構成が必要。
```

#### 推奨構成: Azure DNS Private Resolver の利用

```
オンプレ DC の DNS
    │ 条件付きフォワーダー（database.windows.net）
    ▼
Azure DNS Private Resolver（Hub VNet 内）
    │
    ▼
Azure DNS（168.63.129.16）
    │
    ▼
SQL MI Private IP
```

---

## 7. 接続経路まとめ

### オンプレアプリ → SQL MI

```
オンプレ アプリサーバ
    │ TCP:1433（または 11000-11999）
    ▼
オンプレ DC ルータ
    │ ExpressRoute
    ▼
Hub VNet（ER Gateway）
    │ VNet Peering（Hub → SQL Spoke）
    ▼
SQL Spoke VNet
    │ NSG（許可ルール確認）
    ▼
SQL MI 専用サブネット
    │
    ▼
Azure SQL Managed Instance（Private IP）
```

### Azure 上のアプリ（別 Spoke）→ SQL MI

```
Spoke VNet（アプリ）
    │ VNet Peering（Spoke → Hub）
    ▼
Hub VNet
    │ Azure Firewall（必要に応じてルール設定）
    │ VNet Peering（Hub → SQL Spoke）
    ▼
SQL Spoke VNet → SQL MI
```

> Spoke 間の通信は必ず Hub を経由する（Hub-Spoke アーキテクチャの原則）。Azure FW でスポーク間のトラフィックを許可するルールが必要。

---

## 8. NW 要件チェックリスト

### Spoke VNet・サブネット設計

- [ ] SQL 移行用 Spoke VNet のアドレス空間を決定した（既存 VNet と重複なし）
- [ ] SQL MI 専用サブネットを `/27` 以上（推奨 `/25`）で設計した
- [ ] サブネット委任 `Microsoft.Sql/managedInstances` の設定を確認した
- [ ] サービスエンドポイントを SQL MI サブネットに設定しないことを確認した

### Peering

- [ ] Hub ↔ SQL Spoke の Peering を設定した（ゲートウェイ転送 / リモートゲートウェイ）
- [ ] オンプレ DC からの疎通確認（ping / telnet:1433）を実施した

### NSG

- [ ] `SqlManagement` サービスタグを使ったインバウンドルールを設定した
- [ ] アウトバウンドの `Storage.JapanEast`・`AzureActiveDirectory` 許可を設定した

### UDR

- [ ] SQL MI サブネットのデフォルトルート（0.0.0.0/0）の次ホップを Azure FW に設定した
- [ ] オンプレ向けプレフィックスを VNet ゲートウェイへの UDR で明示した（FW 強制転送と共存する場合）

### Azure Firewall

- [ ] SQL MI 管理用アウトバウンド FQDN ルールを追加した
- [ ] オンプレ→SQL MI の TCP:1433 / 11000-11999 許可ルールを追加した

### DNS

- [ ] `database.windows.net` の条件付きフォワーダーをオンプレ DNS に設定した
- [ ] Azure DNS Private Resolver（または DNS フォワーダー）を Hub VNet に配置した
- [ ] オンプレから SQL MI FQDN の名前解決ができることを確認した

---

## 9. よく出る問題パターン

**Q. SQL MI のデプロイが失敗する。原因は？**
→ A. NSG の `SqlManagement` インバウンドルール漏れ、または サブネットへのサービスエンドポイント設定が原因のことが多い。また、サブネット委任が未設定の場合もエラーになる。

**Q. オンプレから TCP:1433 で接続できない。疎通は取れているが SQL 接続が失敗する。**
→ A. リダイレクトモードの場合、TCP:11000-11999 のポートも Azure FW / オンプレ FW で開放する必要がある。まず Azure Portal で接続ポリシーを「プロキシ」に変更して TCP:1433 のみで接続テストを行い、切り分けする。

**Q. UDR で 0.0.0.0/0 を Azure FW に向けたら、オンプレへの通信が切れた。**
→ A. デフォルトルートを FW に向けると ER からの BGP 広報ルートよりも UDR が優先されるため、オンプレ向けのプレフィックス（例: `10.0.0.0/8`）を VNet ゲートウェイ向けに UDR で明示設定する必要がある。

**Q. 別 Spoke VNet のアプリから SQL MI に接続できない。**
→ A. Hub-Spoke 構成では Spoke 間は Hub 経由になる。Azure Firewall でアプリ Spoke → SQL Spoke の TCP:1433 を許可するネットワークルールが必要。また、Hub VNet の Peering 設定で「転送されたトラフィックを許可」が有効になっているか確認する。
