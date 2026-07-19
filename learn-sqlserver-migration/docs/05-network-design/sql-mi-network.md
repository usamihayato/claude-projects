# Azure SQL Managed Instance — ネットワーク構成（完全閉域）

> **作成日**: 2026-06-29  
> **要件**: パブリックからのインバウンドを完全に遮断する閉域構成

---

## 全体アーキテクチャ

```
オンプレミス環境
        ↕  VPN Gateway（S2S VPN）または ExpressRoute
        │
Azure VNet  例: 10.0.0.0/16
        │
        ├── GatewaySubnet（10.0.0.0/27） ← VPN GW / ER GW を配置
        │
        ├── app-subnet（10.0.1.0/24）    ← アプリ VM / App Service VNet 統合
        │
        └── snet-sqlmi（10.0.2.0/26）   ← SQL MI 専用サブネット
                委任: Microsoft.Sql/managedInstances
                NSG: service-aided が自動管理（管理ポート）
                       + 顧客ルールでデータポートを制御
                UDR: service-aided が自動管理
                        │
                        └── Azure SQL Managed Instance
                                ├── VNet ローカルエンドポイント（有効・推奨）
                                │     <mi名>.<dns_zone>.database.windows.net
                                │     port 1433（Proxy）/ port 11000-11999（Redirect）
                                ├── パブリックエンドポイント  ← ✅ 無効化
                                │     port 3342（無効化する）
                                └── プライベートエンドポイント（任意・別 VNet アクセス用）
                                      固定 IP / port 1433 のみ
```

---

## エンドポイントの種類と閉域化の方針

| エンドポイント種別 | 説明 | 完全閉域時の設定 |
|---|---|---|
| **VNet ローカルエンドポイント** | VNet 内部からのデフォルト接続先。DNS 名は `<mi>.database.windows.net` | **有効のまま使用**（同一 VNet / ピアリング先 / VPN 接続元から到達） |
| **パブリックエンドポイント** | インターネット経由の接続。ポート 3342 | **✅ 無効化する**（デフォルトは無効） |
| **プライベートエンドポイント** | 別 VNet からプライベートに接続するための固定 IP | 別 VNet のアプリから接続する場合に追加（任意） |

> **完全閉域の基本方針**:  
> パブリックエンドポイントを無効にし、VNet ローカルエンドポイントのみ使用する。  
> オンプレ → Azure は VPN Gateway または ExpressRoute 経由でのみ到達できる構成にする。

---

## 接続タイプ（Proxy vs Redirect）

2025年10月以降、**Redirect がデフォルト**になりました。接続タイプによって開放が必要なポートが変わります。

| 接続タイプ | 必要ポート | 特徴 |
|---|---|---|
| **Redirect**（2025年10月〜デフォルト） | 1433 + **11000〜11999** | レイテンシー・スループットが優れる。クライアントがゲートウェイをバイパスして直接ノードに接続 |
| **Proxy**（レガシー） | 1433 のみ | 古い TDS ドライバー（7.4 以前）との互換性のために残存。パフォーマンスは劣る |

> **オンプレ環境からの接続**: VPN / ExpressRoute 経由でのアクセスなので、ファイアウォールルールに  
> **1433 と 11000〜11999 の両方**を開放しておくことを推奨（Redirect 使用時）。

---

## サブネット要件

| 項目 | 要件 |
|---|---|
| **サブネット委任** | `Microsoft.Sql/managedInstances` への委任が必須 |
| **最小サブネットサイズ** | /27（32 アドレス）— 技術的最小値 |
| **推奨サブネットサイズ** | **/26（64 アドレス）** — 本番環境の標準。スケールアウト余裕のため /26 以上を推奨 |
| **専用サブネット** | 他のリソース（VM / App Service 等）との共用不可 |
| **NSG** | SQL MI 専用の NSG を割り当てる（他サブネットとの共用は不可） |
| **ルートテーブル（UDR）** | SQL MI 専用の UDR を割り当てる（他サブネットとの共用は不可） |

> ⚠️ 他のサブネットと NSG・UDR を共用すると、service-aided が自動追加するルールが干渉し、  
> 管理操作が失敗する場合があります。必ず専用リソースを作成してください。

---

## NSG ルール

SQL MI サブネットの NSG は **service-aided subnet configuration** によって管理ポート向けのルールが自動追加されます。  
顧客が手動で管理するのはデータポート（1433 / 11000〜11999）向けのインバウンドルールのみです。

### 顧客定義が必要なインバウンドルール

| 優先度 | 名前 | プロトコル | ポート | 送信元 | 宛先 | 動作 |
|---|---|---|---|---|---|---|
| 100 | allow-app-to-sql | TCP | 1433, 11000-11999 | アプリサブネット CIDR（例: 10.0.1.0/24） | SQL MI サブネット CIDR | 許可 |
| 110 | allow-onprem-to-sql | TCP | 1433, 11000-11999 | オンプレミス CIDR（例: 192.168.0.0/16） | SQL MI サブネット CIDR | 許可 |
| 4096 | deny-all-inbound | Any | Any | Any | Any | **拒否** |

> ポート 3342（パブリックエンドポイント）はパブリックエンドポイントを無効化すれば実質的に不要ですが、  
> NSG でも明示的に `Deny` するとより確実です。

### service-aided が自動管理するルール（変更禁止）

SQL MI のコントロールプレーン（管理トラフィック）向けのルールは service-aided が自動生成します。  
これらのルールを手動で変更・削除すると SQL MI の管理操作が失敗します。

---

## パブリックエンドポイントの無効化

デフォルトは無効ですが、明示的に設定することを推奨します。

### Azure Portal
`SQL Managed Instance` → `ネットワーク` → `パブリック エンドポイント` → **無効**

### PowerShell
```powershell
Set-AzSqlInstance `
  -ResourceGroupName "rg-sqlmi-production" `
  -Name "（SQL MI 名）" `
  -PublicDataEndpointEnabled $false `
  -Force
```

### Azure CLI
```bash
az sql mi update \
  --resource-group rg-sqlmi-production \
  --name （SQL MI 名） \
  --public-data-endpoint-enabled false
```

---

## オンプレミスからの接続経路

| 接続方式 | 特徴 | 推奨 |
|---|---|---|
| **ExpressRoute** | 専用回線経由。帯域保証・低遅延。コスト高 | 大規模・本番環境で推奨 |
| **VPN Gateway（S2S VPN）** | インターネット経由の暗号化トンネル。ExpressRoute より安価 | 中小規模・コスト重視の場合 |

接続後、オンプレミスのクライアントは VNet ローカルエンドポイントの DNS 名（`<mi>.database.windows.net`）で SQL MI に到達できます。

> DNS 解決には Azure 提供のプライベート DNS または独自 DNS サーバーが必要です。  
> オンプレ → Azure への DNS フォワーディング設定をお忘れなく。

---

## プライベートエンドポイント（別 VNet からアクセスする場合）

VNet ピアリングを使わずに別 VNet から SQL MI にアクセスしたい場合は**プライベートエンドポイント**を使用します。

| 項目 | 内容 |
|---|---|
| IP | 宛先 VNet のサブネットから固定 IP が払い出される（変更されない） |
| ポート | **1433 のみ**（Redirect 接続タイプは使用不可） |
| 方向 | クライアント → SQL MI への一方向のみ |
| 複数 VNet | 1 つの SQL MI に複数のプライベートエンドポイントを作成可能 |

> ⚠️ プライベートエンドポイント経由では Redirect 接続タイプが使えず、Proxy のみになります（port 1433）。  
> 同一 VNet 内のアクセスや VPN 経由のアクセスは VNet ローカルエンドポイントを使う方が Redirect の恩恵を受けられます。

---

## 設計チェックリスト（完全閉域）

- [ ] SQL MI 専用サブネットを /26 以上で作成した
- [ ] サブネット委任を `Microsoft.Sql/managedInstances` に設定した
- [ ] NSG・UDR は SQL MI 専用のリソースを作成した（他サブネットと共用しない）
- [ ] パブリックエンドポイントを無効化した
- [ ] NSG にアプリ・オンプレの送信元 CIDR を指定したインバウンドルールを追加した
- [ ] ポート 1433 + 11000〜11999（Redirect 使用時）を許可した
- [ ] VPN Gateway または ExpressRoute でオンプレと接続した
- [ ] オンプレ → Azure 方向の DNS フォワーディングを設定した
- [ ] service-aided の自動ルールを変更・削除していないことを確認した

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| 接続アーキテクチャ概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connectivity-architecture-overview |
| 接続の種類（Proxy / Redirect） | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connection-types-overview |
| プライベートエンドポイント概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/private-endpoint-overview |
| パブリックエンドポイントの構成 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/public-endpoint-configure |
| パブリックエンドポイントのセキュリティ | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/public-endpoint-overview |
| サブネットサイズの決定 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/vnet-subnet-determine-size |
| service-aided サブネット構成 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/subnet-service-aided-configuration-enable |
| 既存 VNet へのサブネット追加 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/vnet-existing-add-subnet |
| アプリケーションの接続方法 | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connect-application-instance |
| オンプレミス → Azure ハイブリッド接続 | https://learn.microsoft.com/ja-jp/azure/architecture/reference-architectures/hybrid-networking/ |
