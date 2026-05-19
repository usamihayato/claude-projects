# AKS 設計書（Collibra DQ 導入用）

> **作成日**: 2026-04-14  
> **対象環境**: Azure（Spoke VNET）/ Collibra DQ 2026.02

---

## 目次

1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [ネットワーク設計](#2-ネットワーク設計)
3. [AKS クラスター設計](#3-aks-クラスター設計)
4. [管理用 Linux VM 設計](#4-管理用-linux-vm-設計)
5. [コンテナレジストリ（ACR）設計](#5-コンテナレジストリacr設計)
6. [Private Endpoint 設計（metastore 接続）](#6-private-endpoint-設計metastore-接続)
7. [セキュリティ設計](#7-セキュリティ設計)
8. [運用・更新設計](#8-運用更新設計)
9. [監視設計](#9-監視設計)

---

## 1. アーキテクチャ概要

### Hub-Spoke 構成図

```
オンプレミス社内ネットワーク
        │
        │ ExpressRoute
        ▼
┌──────────────────────────────────────┐
│           Hub VNET（既存）            │
│                                      │
│  ┌──────────────┐  ┌──────────────┐  │
│  │ ER Gateway   │  │ Azure FW     │  │
│  └──────────────┘  └──────────────┘  │
│          UDR による強制ルーティング        │
└──────────────────────────────────────┘
        │ VNET Peering
        ▼
┌──────────────────────────────────────────────────────┐
│                  Spoke VNET（新規）                    │
│                                                      │
│  ┌─────────────────────┐  ┌──────────────────────┐   │
│  │   AKS ノードサブネット  │  │   管理 VM サブネット    │   │
│  │  (snet-aks-node)    │  │  (snet-mgmt)         │   │
│  │                     │  │  ┌────────────────┐  │   │
│  │  ┌────┐ ┌────┐ ┌────┐│  │  │ Linux VM       │  │   │
│  │  │Node│ │Node│ │Node││  │  │ (管理・helm操作) │  │   │
│  │  └────┘ └────┘ └────┘│  │  └────────────────┘  │   │
│  │  ※Podは Overlay CIDR │  └──────────────────────┘   │
│  └─────────────────────┘                              │
│                                                      │
│  ┌─────────────────────────────────────────────┐     │
│  │   Private Endpoint サブネット (snet-pe)       │     │
│  │   ・ACR Private Endpoint                    │     │
│  │   ・metastore (PostgreSQL / 別テナント US)   │     │
│  └─────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────┘
        │ Private Endpoint（クロステナント）
        ▼
┌──────────────────────────────┐
│  別テナント（Azure US リージョン）  │
│  Azure Database for PostgreSQL │
│  （Collibra DQ metastore）     │
└──────────────────────────────┘
```

### インターネット通信の制御方針

すべての外部通信は **Azure Firewall 経由**とし、AKS ノード・Pod から直接インターネットに出ることを禁止する。

| 通信 | 経路 | 許可要否 |
|------|------|---------|
| AKS ノード → インターネット | Spoke UDR → Hub FW → インターネット | 必要最小限のみ許可 |
| AKS Pod → 社内システム（DQ スキャン先） | Spoke UDR → Hub FW → ER → オンプレミス | 許可 |
| 管理 VM → AKS API Server | Private Endpoint 経由（Spoke 内） | 許可 |
| AKS → metastore (PostgreSQL) | Private Endpoint 経由（Spoke 内） | 許可 |
| AKS → ACR | Private Endpoint 経由（Spoke 内） | 許可 |

---

## 2. ネットワーク設計

### VNET・サブネット設計

| リソース | アドレス空間 / CIDR | 用途 |
|---------|------------------|------|
| **Spoke VNET** | `10.1.0.0/22` | Collibra DQ 専用 VNET |
| `snet-aks-node` | `10.1.0.0/24` | AKS ノード IP（Azure CNI Overlay） |
| `snet-mgmt` | `10.1.1.0/28` | 管理用 Linux VM |
| `snet-pe` | `10.1.2.0/27` | Private Endpoint 専用 |
| （Hub VNET） | （既存） | Azure FW / ER Gateway |

> **Azure CNI Overlay について**  
> ノードは `snet-aks-node` のアドレスを使用する。Pod は VNET アドレス空間とは独立したオーバーレイ CIDR（例: `192.168.0.0/16`）からアドレスを取得するため、Pod 数が増えても VNET アドレスを消費しない。

### Pod CIDR（Overlay）

| 項目 | 値 |
|------|-----|
| Pod CIDR | `192.168.0.0/16` |
| Service CIDR | `172.16.0.0/16` |
| DNS Service IP | `172.16.0.10` |

> Pod CIDR・Service CIDR はオンプレミスや Hub VNET のアドレス空間と重複しないこと。

### VNET Peering 設計

| 設定項目 | 値 |
|---------|-----|
| Peering 名（Spoke → Hub） | `peer-spoke-to-hub` |
| Peering 名（Hub → Spoke） | `peer-hub-to-spoke` |
| ゲートウェイ転送を許可（Hub 側） | **有効**（ER Gateway を Spoke に転送） |
| リモートゲートウェイを使用（Spoke 側） | **有効** |
| 転送されたトラフィックを許可 | 有効 |

### UDR（ユーザー定義ルート）設計

Spoke VNET 全サブネットに適用し、デフォルトルートを Azure Firewall に向ける。

| ルートテーブル名 | 割当サブネット |
|---------------|-------------|
| `rt-aks-node` | `snet-aks-node` |
| `rt-mgmt` | `snet-mgmt` |

**`rt-aks-node` のルート定義**:

| ルート名 | アドレスプレフィックス | ネクストホップ |
|---------|-------------------|-------------|
| `route-default-to-fw` | `0.0.0.0/0` | 仮想アプライアンス（Azure FW の IP） |
| `route-onprem` | `10.0.0.0/8`（社内アドレス帯） | 仮想アプライアンス（Azure FW の IP） |

> **注意**: AKS の `snet-aks-node` に UDR を適用する場合、`nextHopType: VirtualAppliance` を使用する。AKS が必要とする Azure コントロールプレーン向け通信（`AzureCloud` サービスタグ等）は Azure Firewall のネットワークルールで許可する。

### Azure Firewall ルール設計

Azure Firewall は Hub VNET に既存のものを使用。以下のルールを追加する。

**ネットワークルール（AKS 必須）**:

| 名前 | 送信元 | 宛先 | プロトコル/ポート | 説明 |
|------|--------|------|---------------|------|
| `allow-aks-apiserver` | `snet-aks-node` | AKS API Server IP | TCP/443 | AKS コントロールプレーン通信 |
| `allow-aks-ntp` | `snet-aks-node` | `ntp.ubuntu.com` | UDP/123 | NTP |
| `allow-aks-azurecloud` | `snet-aks-node` | サービスタグ `AzureCloud` | TCP/443 | Azure モニタリング・管理 |
| `allow-onprem-scan` | `snet-aks-node` | 社内 DB サブネット帯 | TCP/1433,5432等 | DQ スキャン（ER 経由） |

**アプリケーションルール（FQDN 許可）**:

| 名前 | 送信元 | FQDN / タグ | 説明 |
|------|--------|-----------|------|
| `allow-aks-fqdn` | `snet-aks-node` | `AzureKubernetesService`（FQDNタグ） | AKS 必須 FQDN 一括許可 |
| `allow-ubuntu-updates` | `snet-mgmt`, `snet-aks-node` | `*.ubuntu.com`, `security.ubuntu.com` | Ubuntu セキュリティパッチ |

### NSG 設計

| NSG 名 | 割当サブネット | 主な許可ルール |
|--------|-------------|-------------|
| `nsg-aks-node` | `snet-aks-node` | AKS LoadBalancer ヘルスプローブ（TCP/10250）、Pod 間通信 |
| `nsg-mgmt` | `snet-mgmt` | SSH（TCP/22）を社内 IP からのみ許可、その他拒否 |
| `nsg-pe` | `snet-pe` | Private Endpoint への通信のみ許可 |

---

## 3. AKS クラスター設計

### クラスター基本設定

| 項目 | 設定値 | 備考 |
|------|--------|------|
| **クラスター名** | `aks-collibra-dq` | |
| **リージョン** | Japan East | |
| **Kubernetes バージョン** | 1.32.x（最新安定版） | 定期アップグレード対象 |
| **プライベートクラスター** | **有効** | API Server を Private Endpoint 経由のみに制限 |
| **ネットワークプラグイン** | `azure`（Azure CNI） | |
| **ネットワークモード** | `overlay`（Azure CNI Overlay） | |
| **ネットワークポリシー** | `azure` または `calico` | Pod 間通信の制御 |
| **DNS プレフィックス** | `aks-collibra-dq` | |

### ノードプール設計

| プール名 | 用途 | VM サイズ | ノード数 | OS |
|---------|------|---------|--------|-----|
| `system` | システム Pod（CoreDNS等） | `Standard_D4s_v5` | 3（固定） | Ubuntu |
| `dqpool` | DQ Web / Agent / Spark | `Standard_D16s_v5`（16コア/64GB） | 3〜6（オートスケール） | Ubuntu |

> **VM サイズ選定根拠**: Collibra DQ 中規模要件（32コア/256GB）を3ノードで分散する場合、1ノードあたり約 10コア/85GB が必要。`Standard_D16s_v5`（16vCPU/64GB）で余裕を持たせた構成とする。

### プライベートクラスター設定

| 項目 | 設定 |
|------|------|
| プライベートクラスター | 有効 |
| API Server Private Endpoint | `snet-aks-node` に作成 |
| プライベート DNS ゾーン | `privatelink.japaneast.azmk8s.io` |
| 公開 FQDN | 無効 |

管理用 Linux VM のみが API Server にアクセスできる。

### Managed Identity 設計

| Identity | 種類 | 用途 |
|----------|------|------|
| AKS クラスター Identity | System-assigned | AKS コントロールプレーンのリソース操作 |
| Kubelet Identity | User-assigned | ノードからの ACR Pull、Key Vault アクセス |

### オートスケール設定

| 設定 | 値 |
|------|-----|
| Cluster Autoscaler | 有効 |
| `dqpool` 最小ノード数 | 3 |
| `dqpool` 最大ノード数 | 6 |
| スケールダウン遅延 | 10分 |

---

## 4. 管理用 Linux VM 設計

AKS がプライベートクラスターのため、`kubectl` / `helm` 操作用に専用 VM を Spoke VNET 内に配置する。

| 項目 | 設定値 |
|------|--------|
| **VM 名** | `vm-aks-mgmt` |
| **OS** | Ubuntu 24.04 LTS |
| **VM サイズ** | `Standard_B2s`（2vCPU/4GB） |
| **サブネット** | `snet-mgmt`（`10.1.1.0/28`） |
| **パブリック IP** | **なし** |
| **認証** | SSH 公開鍵認証のみ（パスワード認証無効） |
| **ディスク** | Premium SSD 64GB |

### アクセス方法

社内から SSH するには **ExpressRoute → Hub VNET → Spoke VNET（Peering）** の経路を使用する。  
Azure Bastion を Hub VNET に設置している場合はそちらも利用可能。

### インストールするツール

| ツール | 用途 |
|--------|------|
| `kubectl` | AKS 操作 |
| `helm` | Chart デプロイ |
| `az` CLI | Azure リソース管理 |
| `psql` | metastore 接続確認 |

---

## 5. コンテナレジストリ（ACR）設計

Collibra のコンテナイメージを自社 ACR にミラーリングして使用する（Collibra レジストリへの直接 Pull を避ける）。

| 項目 | 設定値 |
|------|--------|
| **ACR 名** | `acrcollibradq` |
| **SKU** | Premium（Private Endpoint サポート） |
| **リージョン** | Japan East |
| **Public Network Access** | **無効** |
| **Private Endpoint** | `snet-pe` に作成 |
| **プライベート DNS ゾーン** | `privatelink.azurecr.io` |

### AKS との統合

```
AKS Kubelet Identity
  → ACR の「AcrPull」ロールを付与
  → Private Endpoint 経由でイメージ Pull
```

---

## 6. Private Endpoint 設計（metastore 接続）

metastore（PostgreSQL）は **別テナント・Azure US リージョン**に設置済みのため、クロステナント Private Endpoint を使用する。

| 項目 | 設定値 |
|------|--------|
| **Private Endpoint 名** | `pe-metastore-postgres` |
| **配置サブネット** | `snet-pe` |
| **接続先** | 別テナントの Azure Database for PostgreSQL（フレキシブルサーバー） |
| **接続方式** | **手動承認**（クロステナントのため自動承認不可） |
| **プライベート DNS ゾーン** | `privatelink.postgres.database.azure.com` |
| **DNS ゾーンのリンク先** | Spoke VNET |

### クロステナント接続フロー

```
1. 本テナントで Private Endpoint を作成
   → 接続先リソース ID を指定（別テナントの PostgreSQL）
   → 状態: 「保留中」

2. 別テナント管理者が承認
   → Azure Portal または az CLI で承認操作
   → 状態: 「承認済み」

3. Private DNS ゾーン（privatelink.postgres.database.azure.com）に
   A レコードを手動追加
   → FQDN: <server-name>.privatelink.postgres.database.azure.com → Private IP
```

> **注意**: クロステナントの場合、別テナントの管理者による明示的な承認が必要。また、別テナント側でも Private Endpoint 接続を有効にしておく必要がある。

---

## 7. セキュリティ設計

### Microsoft Defender for Cloud

| 対象 | プラン | 設定 |
|------|--------|------|
| **Defender for Containers** | 有効化 | AKS クラスター保護、コンテナイメージスキャン |
| **Defender for Servers** | 有効化 | 管理 VM の脅威検知 |
| **Defender CSPM** | 有効化（推奨） | セキュリティスコア・推奨事項の管理 |

Defender for Containers により以下が自動で実施される：
- AKS ノードおよび実行中コンテナの脅威検知
- ACR に Push されたイメージの脆弱性スキャン
- Kubernetes API サーバーへの不審アクセス検知

### Azure Policy（AKS）

以下のポリシーを AKS クラスターに適用する。

| ポリシー | 目的 |
|---------|------|
| 特権コンテナの禁止 | `privileged: true` の Pod を拒否 |
| ホストネットワーク使用の制限 | `hostNetwork: true` の Pod を拒否 |
| 読み取り専用ルートファイルシステムの強制 | コンテナ内 OS 領域への書き込みを制限 |
| 承認済みイメージレジストリの強制 | 自社 ACR 以外からの Pull を拒否 |

### AKS RBAC

| ロール | 付与先 | 用途 |
|--------|--------|------|
| `Azure Kubernetes Service Cluster Admin Role` | 管理 VM の Managed Identity | 管理操作全般 |
| `Azure Kubernetes Service Cluster User Role` | 運用担当者 | 通常操作 |

---

## 8. 運用・更新設計

### AKS クラスターアップグレード

| 項目 | 設定 |
|------|------|
| **自動アップグレードチャネル** | `patch`（マイナーバージョン固定でパッチのみ自動） |
| **メンテナンスウィンドウ** | 毎週土曜 2:00〜5:00（JST） |
| **ノードイメージ自動アップグレード** | `NodeImage`（毎週最新ノード OS イメージに更新） |
| **アップグレード方式** | ローリングアップグレード（`maxSurge: 1`） |

> **Kubernetes バージョンのライフサイクル**:  
> AKS は通常 N-2 バージョンをサポート。メジャー・マイナーアップグレードは手動で計画的に実施する。

### Linux VM（管理用）パッチ適用

| 項目 | 設定 |
|------|------|
| **パッチ管理** | Azure Update Manager（旧 Automation Update Management の後継） |
| **評価スケジュール** | 毎日 |
| **自動パッチ適用** | セキュリティパッチのみ自動（毎週土曜 2:00〜） |
| **パッケージ取得経路** | Azure FW 経由 → `*.ubuntu.com` を FQDN ルールで許可 |
| **再起動設定** | 必要な場合のみ自動再起動（メンテナンスウィンドウ内） |

### AKS ノード OS パッチ（kured）

AKS ノードの OS パッチ適用後に再起動が必要な場合は **kured**（Kubernetes Reboot Daemon）で自動再起動する。

| 設定 | 値 |
|------|-----|
| 再起動実施時間帯 | 03:00〜05:00（メンテナンスウィンドウに合わせる） |
| 1度に再起動するノード数 | 1（ローリング再起動） |

---

## 9. 監視設計

| 監視対象 | ツール | 収集内容 |
|---------|--------|---------|
| AKS クラスター | **Container Insights**（Azure Monitor） | Pod・ノードのメトリクス、ログ |
| AKS コントロールプレーン | Diagnostic Settings | API Server、Scheduler、Controller Manager ログ |
| 管理 VM | Azure Monitor Agent | CPU/メモリ/ディスク、syslog |
| Azure Firewall | Diagnostic Settings | フローログ、ルールヒット数 |
| Private Endpoint | NSG フローログ | 接続元 IP・ポートの記録 |

### Log Analytics ワークスペース

| 項目 | 値 |
|------|-----|
| ワークスペース名 | `law-collibra-dq` |
| リージョン | Japan East |
| 保持期間 | 90日（デフォルト）、セキュリティログは 180日 |
