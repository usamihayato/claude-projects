# 通信経路一覧 — SQL Server 2008 R2 → Azure SQL Database 移行

> **作成日**: 2026-08-06
> **対象構成**: SQL Server 2008 R2（オンプレ）→ Azure SQL Database（複数DB）/ ExpressRoute + Private Endpoint 接続
> **比較対象**: [03-communication-paths.md](./03-communication-paths.md)（SQL MI 版）
> **本番手順の前提**: [03-production-sqldb-multi-procedure.md](../06-migration-procedures/03-production-sqldb-multi-procedure.md)

---

## 大前提：SQL MI と SQL Database は配置モデルが根本的に違う

MI版の通信経路一覧（セクションD）を見ると分かる通り、SQL MI は「顧客のVNetにインジェクションされる」ため、MI 自身が行うバックアップ・診断ログ送信・監査ログ送信などのアウトバウンド通信が**顧客管理のNSG/ファイアウォールを経由**し、明示的な許可設定が必要だった。

Azure SQL Database（単一DB）は既定で `<server>.database.windows.net` という**パブリックエンドポイント**を持つ、Microsoft管理テナント内のマネージドサービスであり、顧客のVNetには存在しない。本番では Private Endpoint を使ってクライアント側からの接続を閉域化するが、これは**クライアント→SQL Databaseへのインバウンド経路**の話であり、SQL Database自身が行う管理系のアウトバウンド通信（バックアップ・監査ログ送信等）は Private Endpoint の有無に関わらず Microsoft のプラットフォーム内部で完結する。

**この違いにより、SQL MIの通信経路一覧のセクションD（SQL MI → Azure サービス、D-1〜D-6）に相当する「顧客がNSGで許可すべきアウトバウンド一覧」は、SQL Databaseには存在しない。**

---

## A. セットアップ時の通信（初回のみ）

MI版と同一（ツール自体は共通）。

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| A-1 | 管理 PC → Microsoft ダウンロードサーバー | SSMS インストーラー取得 | TCP 443 | TLS 1.2 | なし（匿名） |
| A-2 | 管理 PC → Azure Portal / Microsoft | SHIR インストーラー取得（方式D利用時） | TCP 443 | TLS 1.2 | Azure AD 認証 |
| A-3 | 管理 PC → Microsoft ダウンロードサーバー | SqlPackage / SSMA 取得 | TCP 443 | TLS 1.2 | なし（匿名） |

---

## B. 移行時の通信

移行方式によって経路が変わる。詳細は各手順書を参照。

### B-1. 方式C（SqlPackage）の場合

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| B-1 | 作業端末（SqlPackage実行）→ SQL Server | エクスポート（.bacpac 生成） | TCP 1433 | TLS | SQL 認証 |
| B-2 | 作業端末（SqlPackage実行）→ Azure SQL Database | インポート | TCP 1433 | TLS 1.2 | SQL 認証 |

> 中間ストレージ（Blob等）は不要。SqlPackageを実行する端末とターゲットDBの間で直接データが流れる。

### B-2. 方式D（DMS + SHIR）の場合

[03-production-sqldb-multi-procedure.md](../06-migration-procedures/03-production-sqldb-multi-procedure.md)の「事前確認事項 → ネットワーク構成」に詳細図あり。要点のみ抜粋。

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| B-3 | SHIR（オンプレサーバ）→ SQL Server 2008 R2 | データ読み取り | TCP 1433 | 同一ネットワーク内 | SQL 認証 |
| B-4 | SHIR → Azure DMS / Data Factory サービス | ハートビート・ジョブ制御 | TCP 443 | TLS 1.2 | 証明書認証（初回登録は認証キー） |
| B-5 | SHIR → Azure SQL Database（Private Endpoint 経由） | スキーマ・データの直接コピー | TCP 1433 | TLS 1.2 | SQL 認証 |

> **中間ストレージ（Blob等）は不要**。SQL MI 向け方式（ネイティブバックアップ経由）と異なり、DMS の SQL Database ターゲットは内部で Azure Data Factory パイプラインを使った**直接コピー**方式のため、バックアップファイルの中継地点が発生しない。
>
> B-4 の通信要件の詳細（SHIRが実際に到達すべきFQDN）は、公式ドキュメント（[セルフホステッド統合ランタイムのファイアウォール要件](https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime)）で確認した以下のエンドポイントに準拠：
>
> | ドメイン | ポート | 用途 |
> |---|---|---|
> | `*.servicebus.windows.net`（Azure Relay） | 443 | 対話的操作（テスト接続等） |
> | `{datafactory}.{region}.datafactory.azure.net` または `*.frontend.clouddatahub.net` | 443 | Data Factoryサービス本体への接続（DMS制御チャネル） |
> | `*.database.windows.net` | 1433 | Azure SQL Databaseへの直接コピー |
> | `download.microsoft.com` | 443 | SHIR自動更新用 |

---

## C. 移行後の通常通信

| # | 通信元 → 宛先 | 目的 | ポート | 暗号化 | 認証 |
|---|---|---|---|---|---|
| C-1 | オンプレアプリ → Azure SQL Database（Private Endpoint） | 業務クエリ | TCP 1433 | TLS 1.2 | SQL 認証 / AD 認証 |
| C-2 | SSMS（管理 PC）→ Azure SQL Database（Private Endpoint） | DB 管理・クエリ実行 | TCP 1433 | TLS 1.2 | SQL 認証 / AD 認証 |

> C-1・C-2 いずれも **ExpressRoute → Private Endpoint** 経由（[03-production-sqldb-multi-procedure.md](../06-migration-procedures/03-production-sqldb-multi-procedure.md) 2-3節）。
> SQL MI と異なり接続タイプ（Proxy/Redirect）の区別はなく、常に TCP 1433 のみで完結する。

---

## D. Azure SQL Database → Azure サービス（PaaS アウトバウンド）

**該当なし。** SQL Database自身が行うバックアップ・診断ログ送信・監査ログ送信等は、すべてMicrosoftのプラットフォーム内部（顧客のVNet境界の外側）で完結するため、顧客がNSG/Azure Firewallでアウトバウンドを許可する対象は存在しない。

MI版のD-1〜D-6（Blob / Azure AD / Azure Monitor / Event Hubs / Key Vault / NTP）に相当する行は、SQL Databaseでは**顧客が意識・設定する必要がない**。

### 唯一の例外：監査ログ送信先を閉域化する場合

監査ログの送信先（Storage アカウント）自体をパブリックアクセス無効の閉域構成にする場合のみ、設定が必要になる。ただし主導権が逆転する点に注意。

| | SQL MI | SQL Database |
|---|---|---|
| 設定する場所 | MI サブネットの **NSG**（アウトバウンド許可） | **Storage アカウント側**のファイアウォール設定 |
| 設定内容 | `Storage` サービスタグへの TCP 443 許可 | 「信頼された Microsoft サービスにこのストレージ アカウントへのアクセスを許可する」を有効化 |
| 認証 | CREDENTIAL オブジェクト（SAS トークン） | 論理サーバーのシステム割り当てマネージド ID に `Storage Blob Data Contributor` ロール付与 |
| 前提 | — | Storage アカウントが**汎用v2**であること |

詳細: [05-sql-db-audit-log-requirements.md](./05-sql-db-audit-log-requirements.md)

---

## E. Private Endpoint 経路の詳細

### DNS 解決

```
オンプレ DC の DNS サーバ
  → 条件付きフォワーダー（database.windows.net → Azure DNS）
  → Azure DNS Private Resolver（Hub VNet 内）
  → Private Endpoint のプライベートIP
```

MI版（[notes.md](./notes.md) セクション6）と同じ Azure DNS Private Resolver 構成をそのまま踏襲できる。SQL Database の FQDN も `database.windows.net` ゾーンに属するため、DNS フォワーダー設定を新規に作る必要はない（同じ条件付きフォワーダーで両方カバーされる）。

### NSG（Private Endpoint が置かれるサブネット向け）

| 優先度 | 名前 | ソース | 宛先ポート | 動作 |
|---|---|---|---|---|
| 100 | allow-app-to-sqldb-pe | アプリ/オンプレ CIDR | TCP 1433 | 許可 |
| 4096 | deny-all-inbound | Any | Any | 拒否 |

MI版のような`SqlManagement`サービスタグを使った管理系インバウンドルールは**不要**（Private Endpoint はデータプレーンの単方向接続のみで、MIのようなサブネット委任・service-aided管理は発生しないため）。

---

## F. ネットワーク構成上の分類（FW / NSG 設定早見表）

| 通信 # | 通信 | 経路 | FW / NSG 設定 |
|---|---|---|---|
| A-1〜A-3 | セットアップ時ダウンロード | インターネット | 管理 PC からの HTTPS アウトバウンド許可 |
| B-1・B-2 | SqlPackage（方式C） | 作業端末 → 直接 | 作業端末からのTCP 1433アウトバウンド許可（オンプレ側）／インバウンド許可（SQL DB側、Private Endpoint利用時はPE経由） |
| B-3 | SHIR → SQL Server | オンプレ内 | NSG不要（同一ネットワーク） |
| B-4 | SHIR → DMS/Data Factory | インターネット（Azure バックボーン） | FW: TCP 443（`DataFactory`相当のFQDN許可） |
| B-5 | SHIR → SQL Database | ExpressRoute → Private Endpoint | NSG: TCP 1433 許可（PEサブネット向け） |
| C-1・C-2 | オンプレ → SQL Database | ExpressRoute → Private Endpoint | オンプレ FW + NSG: TCP 1433 |
| D | SQL Database → Azure サービス | **該当なし** | **顧客側の設定不要** |
| （監査のみ）| SQL Database → Storage（閉域時） | Microsoft プラットフォーム内部 | **Storage側**で信頼されたサービス例外を設定（顧客NSGではない） |

---

## G. Private Endpoint 対応状況まとめ（SQL Database 版）

| サービス | PE 対応 | 備考 |
|---|---|---|
| **Azure SQL Database（データプレーン接続）** | ✅ | 本番で採用済み（[03-production-sqldb-multi-procedure.md](../06-migration-procedures/03-production-sqldb-multi-procedure.md)） |
| **Blob Storage（監査ログ送信先）** | ✅ | ただし設定は Storage 側の「信頼されたサービス」例外＋マネージドID。PEを使わなくても閉域化できる |
| **Log Analytics（監査ログ送信先）** | ✅（AMPLS） | MI版と同様、設定はやや複雑 |

---

## MI版との差分まとめ（設計者向けチェックリスト）

- [ ] SQL Database は顧客VNetにインジェクションされないことを前提に設計する（専用サブネット・サブネット委任は不要）
- [ ] SQL Database自身のアウトバウンド通信（バックアップ・診断・監査送信）に対するNSG許可ルールは**作成しない**（対象が存在しないため）
- [ ] クライアント接続の閉域化は Private Endpoint（本番採用済み）で行う。MIのようなVNetローカルエンドポイントの概念はない
- [ ] 監査ログ送信先ストレージを閉域化する場合は、Storage側の「信頼されたMicrosoftサービス」例外設定を行う（顧客NSGではない）
- [ ] DNS解決はMI版のAzure DNS Private Resolver構成をそのまま流用できる（`database.windows.net`ゾーン共通）

---

## 参考リンク

| ドキュメント | URL |
|---|---|
| ネットワークアクセス制御（SQL Database） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/network-access-controls-overview?view=azuresql |
| Private Link 概要（SQL Database） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/private-endpoint-overview?view=azuresql |
| SQL Server → SQL DB（DMSオフライン移行） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/database/database-migration-service |
| セルフホステッド統合ランタイム（ファイアウォール要件） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| （比較対象）SQL MI 通信経路一覧 | [03-communication-paths.md](./03-communication-paths.md) |
