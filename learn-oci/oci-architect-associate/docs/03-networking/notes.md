# 03. Networking

## 試験での重要度
- VCN・Subnet・ゲートウェイの構成は毎回出題レベル
- Security List vs NSGの違いは頻出
- FastConnect/VPN・DRGの接続パターンも重要

---

## Azure vs OCI 比較

### 概念対応表
| 概念 | Azure | OCI |
|---|---|---|
| 仮想ネットワーク | VNet | VCN (Virtual Cloud Network) |
| サブネット | Subnet | Subnet（Regionalまたは AD固有） |
| インターネット接続 | Internet Gateway（VNet組み込み） | Internet Gateway（明示的に作成） |
| アウトバウンドNAT | NAT Gateway | NAT Gateway |
| Azureサービスへのプライベート接続 | Service Endpoint / Private Link | Service Gateway（OSN経由） |
| VNet間接続（同一リージョン） | VNet Peering | Local Peering Gateway (LPG) |
| VNet間接続（別リージョン） | Global VNet Peering | DRG + Remote Peering Connection |
| オンプレ専用線接続 | ExpressRoute | FastConnect |
| オンプレVPN接続 | VPN Gateway | VPN Connect（CPE + DRG） |
| ネットワーク仮想ハブ | Virtual WAN Hub | DRG v2 |
| サブネットレベルFW | Network Security Group（Azure NSG） | Security List |
| リソースレベルFW | Azure NSG（NICに付与） | Network Security Group（OCI NSG） |
| ロードバランサー（L7） | Azure Application Gateway | Load Balancer |
| ロードバランサー（L4） | Azure Load Balancer | Network Load Balancer |
| DNS管理 | Azure DNS | OCI DNS |
| プライベートDNS | Azure Private DNS Zone | OCI Private DNS Zone |
| 踏み台アクセス | Azure Bastion | OCI Bastion Service |

### 主な設計の違い
| 観点 | Azure | OCI |
|---|---|---|
| ゲートウェイの作成 | 多くはVNetに組み込み | 明示的に個別作成が必要（IGW, NAT GW等） |
| ルートテーブルの適用 | サブネットに関連付け | サブネットに関連付け（同様） |
| FWルール名称 | NSG（サブネット・NIC両方に同じ名称） | Security List（サブネット）とNSG（リソース）で名称が異なる |
| VNet Peering | Transitiveルーティング不可 | Transitiveルーティング不可（同様） |
| 専用線品質 | ExpressRoute（キャリア経由） | FastConnect（Co-location/キャリア経由） |

---

## 1. VCN（Virtual Cloud Network）

### 概要
- OCIのプライベートネットワーク空間
- 1リージョンに複数のVCNを作成可能
- VCNはリージョンスコープ（AD全体にまたがる）

### 設計上の推奨値
| 項目 | 推奨 |
|---|---|
| VCN CIDR | /16 〜 /30（RFC1918 プライベートアドレス推奨） |
| Subnet CIDR | VCN CIDRのサブネット |
| 最小Subnet | /30（利用可能IP: 1個） |

### VCN内のDNS
- VCNのDNSラベルを設定するとデフォルトドメイン名が付与される
- 形式: `<hostname>.<subnet-dns-label>.<vcn-dns-label>.oraclevcn.com`

---

## 2. Subnet（サブネット）

| 種別 | 説明 |
|---|---|
| **Regionalサブネット**（推奨） | VCN内の全ADにまたがる。リソースを任意のADに配置可能 |
| **AD固有サブネット** | 特定の1つのADにのみ存在。旧来の設計。現在は非推奨 |

| アクセス種別 | 説明 |
|---|---|
| **パブリックサブネット** | インターネット向けルートあり・パブリックIPの割り当て可能 |
| **プライベートサブネット** | インターネットからの直接アクセス不可 |

### 予約済みIPアドレス
各Subnetで先頭3つと最後の1つ（計4つ）はOCIが予約する。

---

## 3. ゲートウェイ一覧

### Internet Gateway（IGW）
- VCNからインターネットへの双方向通信を提供
- パブリックサブネットのリソースにパブリックIPが必要
- 1 VCNに1つのみ作成可能

### NAT Gateway
- プライベートサブネットのリソースが**インターネットへのアウトバウンド通信**を行うためのゲートウェイ
- **インバウンド（インターネット→VCN）は不可**
- パブリックIPが自動付与される（予約済みIPも指定可能）
- ブロック設定で一時的に無効化できる

### Service Gateway
- VCNからOCIのパブリックサービス（Object Storage等）へ**インターネットを経由せずに**アクセス
- Oracle Services Network (OSN) に接続する
- 対象サービス：
  - **Object Storage**（OCI Object Storage - All Regions）
  - **OCI各種サービス**（All <region> Services In Oracle Services Network）

### Dynamic Routing Gateway（DRG）v2
- VCNと外部ネットワーク（オンプレ・他VCN・他リージョン）を接続するハブ
- **1つのDRGに複数のVCNをアタッチ可能**（v2の主な強化点）
- アタッチメント種別：
  | 種別 | 説明 |
  |---|---|
  | VCN Attachment | VCNをDRGに接続 |
  | IPSec Tunnel Attachment | VPN Connectのトンネルを終端 |
  | FastConnect Virtual Circuit Attachment | FastConnectを終端 |
  | Remote Peering Connection Attachment | 他リージョンとのRemote Peering |

### ゲートウェイ比較まとめ
| ゲートウェイ | 方向 | 宛先 |
|---|---|---|
| Internet Gateway | 双方向 | インターネット |
| NAT Gateway | アウトバウンドのみ | インターネット |
| Service Gateway | アウトバウンドのみ | OCI Services（OSN） |
| DRG | 双方向 | オンプレ・他VCN・他リージョン |

---

## 4. VCN Peering（ピアリング）

### Local Peering Gateway (LPG)
- **同一リージョン内の異なるVCN同士**を接続
- 各VCNにLPGを1つ作成し、ピアリング接続を確立
- CIDRが重複していると接続不可
- **Transitiveルーティング不可**（A-B-C接続でAからCへは通信できない）

### Remote Peering（DRG経由）
- **異なるリージョン間のVCN接続**
- DRGのRemote Peering Connection (RPC)機能を使用
- 同一Tenancyまたは異なるTenancyのVCNと接続可能
- Remote Peering接続はDRG v2の機能

---

## 5. セキュリティ制御

### Security List
- **Subnetレベル**のファイアウォール
- Subnetに関連付け、Subnet内の全リソースに適用
- **Stateless / Stateful** を選択可能（デフォルトはStateful）
- Ingressルール・Egressルールを個別に設定

### Network Security Group（NSG）
- **リソース（NIC）レベル**のファイアウォール
- 個々のComputeインスタンスのVNICに関連付け
- ルール内でソース/宛先として**別のNSGのOCIDを指定可能**（アプリケーション層間の制御に便利）
- よりきめ細かな制御が可能

### Security List vs NSG 比較
| 項目 | Security List | NSG |
|---|---|---|
| 適用単位 | Subnet全体 | 個別VNIC（リソース） |
| ルール数上限 | Subnetあたり200 | NSGあたり120 |
| ソース/宛先指定 | CIDR・ICMPタイプのみ | CIDR・他のNSG・サービス |
| 推奨用途 | 基本的なSubnetレベル制御 | アプリケーション層の細かい制御 |

> **試験ポイント：Security ListとNSGは同時に使用可能。両方の許可ルールを満たした場合のみ通信が許可される。**

---

## 6. Route Table（ルートテーブル）

- **Subnetに1つ**のルートテーブルを関連付け
- ルーティングルールは「宛先CIDR → ゲートウェイ」の形式
- **最長一致（Longest Prefix Match）**で評価
- デフォルトルート（0.0.0.0/0）も設定可能

### ルートテーブルの例
```
宛先CIDR               ターゲット
0.0.0.0/0             Internet Gateway（パブリックサブネット用）
0.0.0.0/0             NAT Gateway（プライベートサブネットのアウトバウンド用）
10.0.0.0/8            DRG（オンプレ向け）
192.168.0.0/16        LPG（他VCN向け）
all-<region>-services-in-oracle-services-network  Service Gateway
```

---

## 7. Load Balancer

### Load Balancer（LB）
- Layer 7（HTTP/HTTPS）対応のアプリケーションロードバランサー
- **パブリックLB**：インターネット向け（パブリックIP付与）
- **プライベートLB**：VCN内部向け（プライベートIPのみ）
- バックエンドセット + ヘルスチェック + リスナーで構成

#### 主な機能
| 機能 | 説明 |
|---|---|
| SSL終端 | LBでSSL処理（バックエンドへはHTTPで転送可能） |
| SSL Pass-through | バックエンドまでSSLを通す |
| セッション永続化 | クッキーベースのセッション固定 |
| URLリダイレクト | HTTP → HTTPSリダイレクト |
| コンテンツベースルーティング | URLパス・ホスト名に基づいてバックエンドを振り分け |

#### Shape（帯域幅）
- Flexible Shape：10Mbps〜8Gbpsの範囲で自動スケール（推奨）
- Dynamic Shape：100Mbps / 400Mbps / 8Gbps から選択

### Network Load Balancer（NLB）
- Layer 4（TCP/UDP）対応
- 超低レイテンシ・高スループット向け
- ソースIPアドレスの保持が可能
- ヘルスチェックあり

### LB vs NLB 比較
| 項目 | Load Balancer | Network Load Balancer |
|---|---|---|
| レイヤー | L7（HTTP/HTTPS） | L4（TCP/UDP） |
| SSL終端 | 対応 | 非対応（Pass-through） |
| ソースIP保持 | 非対応（デフォルト） | 対応 |
| レイテンシ | 通常 | 超低レイテンシ |
| 用途 | Webアプリ | ゲーム・IoT・DB等 |

---

## 8. オンプレミス接続

### VPN Connect（IPSec VPN）
- インターネット経由の暗号化トンネル
- **複数トンネルで冗長化推奨**（1 CPE あたり最大2トンネル）
- Customer Premises Equipment (CPE)：オンプレ側のVPNデバイス
- DRGとCPE間でIPSec IKEv1/IKEv2をサポート
- BGPまたはスタティックルーティング

### FastConnect
- 専用線による**低レイテンシ・高帯域・安定した接続**
- インターネットを経由しないためセキュリティが高い
- 帯域幅オプション：1Gbps / 10Gbps / 100Gbps
- 接続方式：
  | 種別 | 説明 |
  |---|---|
  | **Co-location** | Oracle DCと同じデータセンターに直接接続 |
  | **Exchange Provider** | IXを経由して接続 |
  | **Network Provider** | 通信キャリア経由で接続 |
- **Virtual Circuit**：FastConnect上の論理接続単位
- BGPによるルーティング（プライベートピアリング）

### VPN Connect vs FastConnect
| 項目 | VPN Connect | FastConnect |
|---|---|---|
| 経路 | インターネット（暗号化） | 専用線 |
| 帯域 | 可変（インターネット依存） | 1/10/100Gbps |
| 冗長性 | 複数トンネル | 複数Virtual Circuit |
| 費用 | 安価 | 高価 |
| 用途 | 開発・低帯域・コスト優先 | 本番・高帯域・安定性優先 |

---

## 9. DNS

### パブリックDNS
- OCI DNS Serviceで外部公開ドメインを管理
- レコードタイプ：A, AAAA, CNAME, MX, TXT, NS 等
- **トラフィックマネジメント**：地理分散・フェイルオーバー・ロードバランシングポリシーを設定可能

### プライベートDNS
- VCN内のリソースに対するDNS解決
- VCNのデフォルトドメイン: `<hostname>.<subnet>.<vcn>.oraclevcn.com`
- **プライベートビュー**：VCN内専用のDNSゾーンを作成可能

### カスタムリゾルバ
- **DNS Resolver**：VCNごとに設定
- オンプレDNSとOCI DNSの相互解決が可能
- **フォワーディングルール**：特定ドメインの問い合わせをオンプレDNSサーバーに転送
- **リスニングエンドポイント**：オンプレからOCIのDNSに問い合わせを受け付ける

---

## 10. Bastion Service

- プライベートサブネット内のインスタンスへの**セキュアなSSH/RDPアクセス**を提供
- パブリックIPやVPNなしに踏み台サーバーなしでアクセス可能
- セッションタイプ：
  | タイプ | 用途 |
  |---|---|
  | Managed SSH Session | インスタンスへのSSH |
  | SSH Port Forwarding Session | TCPトンネリング（DB接続等） |
- 接続時間制限・IPアドレス制限が設定可能
- 接続ログは自動記録

---

## 11. 試験対策チェックリスト

- [ ] IGW/NAT GW/Service GW/DRGの使い分けを説明できる
- [ ] Security ListとNSGの違いと使いどころを説明できる
- [ ] Local PeeringとRemote Peeringの違いを説明できる
- [ ] LBとNLBの使い分けを説明できる
- [ ] VPN ConnectとFastConnectの使い分けを説明できる
- [ ] Route Tableの評価ロジック（最長一致）を理解している
- [ ] プライベートDNSとカスタムリゾルバのユースケースを説明できる

---

## 12. よく出る問題パターン

**Q. プライベートサブネットのインスタンスがOCIのObject Storageにインターネット経由せずアクセスするには？**
→ A. Service Gatewayを作成し、RouteTableにService Gatewayへのルートを追加する

**Q. 2つのVCN（同一リージョン）を接続するには？**
→ A. 各VCNにLocal Peering Gateway (LPG)を作成してピアリング接続を確立する

**Q. オンプレのDBサーバーとOCIインスタンスを低レイテンシで接続するには？**
→ A. FastConnectを使用する（VPN ConnectはインターネットのためレイテンシはFastConnectより高い）

**Q. プライベートサブネットのインスタンスにSSH接続するには（VPNなし）？**
→ A. Bastion Serviceを使用してManaged SSH Sessionを作成する
