# 通信経路一覧 — SQL Server 2008 R2 → Azure SQL MI 移行

> **作成日**: 2026-07-07  
> **対象構成**: SQL Server 2008 R2（オンプレ）→ Azure SQL MI / ExpressRoute 接続 / 完全閉域

---

## A. セットアップ時の通信（初回のみ）

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| A-1 | 管理 PC → Microsoft ダウンロードサーバー | SSMS インストーラー取得 | TCP 443 | TLS 1.2 | なし（匿名） |
| A-2 | 管理 PC → Azure Portal / Microsoft | SHIR インストーラー取得 | TCP 443 | TLS 1.2 | Azure AD 認証 |
| A-3 | SHIR VM → Microsoft Update | .NET Framework 等の依存関係更新 | TCP 443 | TLS 1.2 | なし（匿名） |

**ダウンロード URL（参考）**

| ツール | URL |
|---|---|
| SSMS | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| SHIR | Azure Portal → Azure Database Migration Service → 統合ランタイム → インストーラーをダウンロード |

---

## B. 移行時の通信

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| B-1 | SHIR → SQL Server 2008 R2 | バックアップ取得（`BACKUP DATABASE` 実行） | TCP 1433 | TLS 1.0〜（※注1） | SQL 認証（dmsuser） |
| B-2 | SHIR → Blob Storage | .bak ファイルのアップロード | TCP 443 | TLS 1.2 | SAS トークン |
| B-3 | SHIR → Azure DMS | ハートビート・ジョブポーリング・ステータス報告 | TCP 443 | TLS 1.2 | 証明書認証（初回登録は認証キー） |
| B-4 | DMS / SHIR → SQL MI | `RESTORE FROM URL` コマンドの発行 | TCP 1433 | TLS 1.2 | SQL 認証（管理者） |
| B-5 | SQL MI → Blob Storage | .bak ファイルの取得（RESTORE FROM URL） | TCP 443 | TLS 1.2 | CREDENTIAL オブジェクト（SAS トークン） |

> **注1**: SQL Server 2008 R2 RTM（10.50.1600.1）は TLS 1.0 のみ対応。  
> TLS 1.2 対応には SP4 + KB3135244 後継パッチ + Windows Schannel 設定が必要。  
> SHIR は旧バージョンの TLS を許容する設定が可能（DMS 公式サポート済み）。

**B-3 SHIR → DMS 通信の詳細**

| 通信種別 | 内容 |
|---|---|
| ハートビート | 定期的な生存確認を DMS に送信 |
| ジョブポーリング | 実行すべきタスクの有無を DMS に問い合わせ |
| ジョブ実行指示受信 | バックアップ取得・アップロード等の指示を引き取り |
| 進捗・ステータス報告 | 実行中・完了・エラーを DMS に送信 |
| 認証情報の取得 | 接続文字列・SAS トークン等（暗号化済み）を受信 |

> SHIR からのアウトバウンドのみ。DMS から SHIR へのインバウンドは発生しない。

---

## C. 移行後の通常通信

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| C-1 | Power BI Report Server → SQL MI | レポート用参照クエリ | TCP 1433（Proxy）/ 11000〜11999（Redirect） | TLS 1.2 | SQL 認証 / AD 認証 |
| C-2 | SSMS（管理 PC）→ SQL MI | DB 管理・クエリ実行 | TCP 1433（Proxy）/ 11000〜11999（Redirect） | TLS 1.2 | SQL 認証 / AD 認証 |

> C-1・C-2 はいずれも **ExpressRoute 経由**（オンプレ → VNet → SQL MI）

**接続タイプによるポートの違い**

| 接続タイプ | 必要ポート | 備考 |
|---|---|---|
| Proxy | TCP 1433 のみ | SQL MI 側で `ProxyOverride = Proxy` に設定が必要（デフォルトは Redirect） |
| Redirect（デフォルト） | TCP 1433 + 11000〜11999 | オンプレ FW・NSG 両方で追加開放が必要 |

---

## D. SQL MI → Azure サービス（PaaS アウトバウンド）

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | PE 対応 | 経路 |
|---|---|---|---|---|---|---|
| D-1 | SQL MI → Blob Storage | 自動バックアップ（定期） | TCP 443 | TLS 1.2 | ✅ 可能 | PE 経由（VNet 内）または Azure バックボーン |
| D-2 | SQL MI → Azure AD | 認証 | TCP 443 | TLS 1.2 | ❌ 不可 | Azure バックボーン / インターネット |
| D-3 | SQL MI → Azure Monitor | 監視・診断ログ | TCP 443 | TLS 1.2 | ✅ 可能（AMPLS） | PE 経由または Azure バックボーン |
| D-4 | SQL MI → Event Hubs | 監査ログ | TCP 443 | TLS 1.2 | ✅ 可能 | PE 経由または Azure バックボーン |
| D-5 | SQL MI → Key Vault | TDE 顧客管理キー（CMK 使用時のみ） | TCP 443 | TLS 1.2 | ✅ 可能 | PE 経由または Azure バックボーン |
| D-6 | SQL MI → time.windows.com | 時刻同期（NTP） | UDP 123 | なし | ❌ 不可 | インターネット |

> **注**: `service-aided サブネット構成` が管理トラフィック向けの UDR・NSG ルールを自動管理する。  
> D-1〜D-6 は顧客管理トラフィックであり、Azure Firewall 使用時は顧客側でのポリシー設定が必要。

---

## E. Windows VM アクティベーション通信（SHIR VM が Azure 上の場合）

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 備考 |
|---|---|---|---|---|---|
| E-1 | SHIR VM → kms.core.windows.net（168.63.129.16） | Windows ライセンス認証（KMS） | TCP 1688 | なし | Azure 内部ネットワーク経由。インターネット不要 |

> Azure VM の KMS 通信は Azure プラットフォームの内部 IP（`168.63.129.16`）に到達するため、  
> インターネットアクセスなしで動作する。  
> UDR で `0.0.0.0/0 → Azure Firewall` にしている場合は `168.63.129.16` への TCP 1688 を  
> Firewall で許可するか、専用の `/32` ルートで Firewall をバイパスする。

---

## F. ネットワーク構成上の分類（FW / NSG 設定早見表）

| 通信 # | 通信 | 経路 | FW / NSG 設定 |
|---|---|---|---|
| A-1〜A-3 | セットアップ時ダウンロード | インターネット | 管理 PC からの HTTPS アウトバウンド許可 |
| B-1 | SHIR → SQL Server | オンプレ内 / ER 経由 | NSG: TCP 1433 許可（送信元: SHIR サブネット） |
| B-2 | SHIR → Blob | PE 経由（推奨）/ インターネット | FW: TCP 443（`Storage` サービスタグ） |
| B-3 | SHIR → DMS | インターネット（Azure バックボーン） | FW: TCP 443（`DataFactory` サービスタグ） |
| B-4 | DMS/SHIR → SQL MI | VNet 内 | NSG: TCP 1433 許可（送信元: DMS/SHIR サブネット） |
| B-5 | SQL MI → Blob | PE 経由（推奨） | FW: TCP 443（`Storage` サービスタグ） |
| C-1・C-2 | オンプレ → SQL MI | ExpressRoute → VNet | オンプレ FW + NSG: TCP 1433（+ 11000〜11999） |
| D-1 | SQL MI → Blob（自動バックアップ） | VNet 内（PE）または Azure バックボーン | FW: TCP 443（`Storage` サービスタグ） |
| D-2 | SQL MI → Azure AD | Azure バックボーン / インターネット | FW: TCP 443（`AzureActiveDirectory` サービスタグ） |
| D-3 | SQL MI → Azure Monitor | VNet 内（AMPLS）または Azure バックボーン | FW: TCP 443（`AzureMonitor` サービスタグ） |
| D-4 | SQL MI → Event Hubs | VNet 内（PE）または Azure バックボーン | FW: TCP 443（`EventHub` サービスタグ） |
| D-5 | SQL MI → Key Vault | VNet 内（PE）または Azure バックボーン | FW: TCP 443（`AzureKeyVault` サービスタグ） |
| D-6 | SQL MI → NTP | インターネット | FW: UDP 123（`time.windows.com`） |
| E-1 | SHIR VM → KMS | Azure 内部 | FW or UDR: TCP 1688 → 168.63.129.16 を許可 / バイパス |

---

## G. Private Endpoint 対応状況まとめ

完全閉域構成で自社管理リソースを PE に閉じる場合の対応可否。

| サービス | PE 対応 | PE 利用時の効果 |
|---|---|---|
| **Blob Storage** | ✅ | パブリックアクセス無効化可。VNet 内完結 |
| **Key Vault** | ✅ | パブリックアクセス無効化可。VNet 内完結 |
| **Event Hubs** | ✅ | パブリックアクセス無効化可。VNet 内完結 |
| **Azure Monitor** | ✅（AMPLS） | 設定が複雑。Log Analytics / Application Insights を一括で PE 化 |
| **Azure AD** | ❌ | PE 不可。Azure バックボーン経由は必須 |
| **NTP（time.windows.com）** | ❌ | PE 不可。インターネット経由は必須 |

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| SSMS ダウンロード | https://learn.microsoft.com/ja-jp/sql/ssms/download-sql-server-management-studio-ssms |
| SHIR（DMS 向け） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/self-hosted-integration-runtime |
| SHIR（ADF 向け） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| DMS セキュリティベストプラクティス | https://learn.microsoft.com/ja-jp/azure/dms/dms-security-best-practices |
| SQL Server TLS 1.2 対応（KB3135244） | https://support.microsoft.com/en-us/topic/kb3135244-tls-1-2-support-for-microsoft-sql-server-e4472ef8-90a9-13c1-e4d8-44aad198cdbe |
| SQL MI 接続アーキテクチャ | https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/connectivity-architecture-overview |
| Azure Monitor Private Link（AMPLS） | https://learn.microsoft.com/ja-jp/azure/azure-monitor/logs/private-link-security |
| Azure Blob Storage プライベートエンドポイント | https://learn.microsoft.com/ja-jp/azure/storage/common/storage-private-endpoints |
| Azure Key Vault プライベートエンドポイント | https://learn.microsoft.com/ja-jp/azure/key-vault/general/private-link-service |
| Azure VM KMS アクティベーション | https://learn.microsoft.com/ja-jp/azure/virtual-machines/windows/kms-activation-support |
