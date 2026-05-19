# 02. Identity and Access Management (IAM)

## 試験での重要度
- Policyの構文・評価ロジックは頻出
- Compartment設計・Dynamic Groupは実務設計問題で必出
- Federationは概念理解レベルで問われる

---

## Azure vs OCI 比較

### 概念対応表
| 概念 | Azure | OCI |
|---|---|---|
| クラウドアカウント最上位 | Azure AD Tenant | Tenancy |
| リソース論理グループ | Resource Group | Compartment |
| リソース階層 | 管理グループ → サブスクリプション → RG | Tenancy → Compartment（最大6階層） |
| ユーザー管理 | Azure AD User | IAM User |
| グループ管理 | Azure AD Group | Group |
| マシンID（サービスアカウント） | Managed Identity | Dynamic Group + Instance Principal |
| 権限付与単位 | ロール（RBAC） | Policy（文章形式） |
| 権限付与の仕組み | Role Assignment（ユーザー/グループ/MIに付与） | Allow文でGroupまたはDynamic Groupに付与 |
| 組み込みロール | Owner / Contributor / Reader 等 | verb（manage / use / read / inspect）で表現 |
| 外部IdP連携 | Azure AD B2B / 外部テナント連携 | Federation（SAML 2.0） |
| シークレット管理 | Azure Key Vault | OCI Vault |
| 条件付きアクセス | Conditional Access Policy | Policy の `where` 句による条件 |

### 主な設計の違い
| 観点 | Azure | OCI |
|---|---|---|
| 権限記述方式 | GUIまたはJSONで定義 | 自然言語に近い文章形式（`Allow group X to manage Y in Z`） |
| 暗黙的Deny | あり（Azure RBACも同様） | あり（Allow文のみ存在、Denyは書かない） |
| 権限スコープ | 管理グループ / サブスクリプション / RG / リソース | Tenancy / Compartment（階層的に継承） |
| グループへのロール付与 | サブスクリプション・RGスコープ | Compartmentスコープ（親から子へ継承） |
| 複数テナント管理 | マルチテナント構成・B2B | テナンシーは1つ（Compartmentで分離） |

---

## 1. IAMの全体構造

```
Tenancy（ルートコンパートメント）
├── Compartment A
│   ├── Compartment A-1
│   └── Compartment A-2
└── Compartment B

IAMリソース（ホームリージョンで管理・全リージョンに自動レプリケーション）
├── Users
├── Groups
├── Dynamic Groups
├── Policies
└── Identity Providers（Federation用）
```

---

## 2. Tenancy（テナンシー）

- OCIアカウントのルートレベル
- すべてのリソースはTenancy配下に存在する
- Tenancyそのものがルートコンパートメントを兼ねる
- Tenancy OCID は変更不可

---

## 3. Compartment（コンパートメント）

### 概要
- リソースを論理的にグループ化するための**名前空間**
- 最大**6階層**まで入れ子にできる
- 各リソースは必ず1つのCompartmentに属する
- Compartmentをまたいだリソース参照は可能（適切なPolicyがあれば）

### 特性
| 特性 | 内容 |
|---|---|
| 削除条件 | Compartment内にリソースが存在しないこと |
| リソース移動 | 一部のリソースはCompartment間で移動可能 |
| クォータ | Compartmentごとにリソースクォータを設定可能 |
| コスト追跡 | タグと組み合わせてCompartmentごとのコスト分析が可能 |

### 設計パターン

**環境分離型（推奨）**
```
Tenancy
├── Production/
├── Staging/
└── Development/
```
- 環境ごとにPolicyを明確に分離できる
- 本番への誤操作リスクを低減

**プロジェクト/チーム分離型**
```
Tenancy
├── ProjectA/
├── ProjectB/
└── Shared-Network/
```
- プロジェクト単位でコスト追跡しやすい
- 共有ネットワークをSandboxedにできる

---

## 4. Users（ユーザー）

### タイプ
| タイプ | 説明 |
|---|---|
| IAM User | OCIコンソール・CLI・APIを使う人間ユーザー |
| Service Account | プログラムアクセス用（APIキーを発行） |

### 認証方法
- **パスワード**：コンソールログイン用
- **APIキー（RSAキーペア）**：CLI・SDK・API用
- **Auth Token**：サードパーティツール（Object Storage S3互換 等）用
- **SMTP認証情報**：Email Delivery用
- **MFA（多要素認証）**：TOTP対応デバイスを利用

---

## 5. Groups（グループ）

- ユーザーをまとめる単位
- **Policyは個人ではなくGroupに対して付与する**
- 1ユーザーが複数Groupに所属可能
- 動的メンバーシップは不可（Static）

---

## 6. Dynamic Groups（ダイナミックグループ）

### 概要
- **OCI リソース（Compute Instance等）を "主体" として扱う**グループ
- リソースが一定の条件（ルール）を満たす場合に自動でグループに含まれる
- インスタンスがAPIを呼び出す際に使用（Instance Principal）

### マッチングルール例
```
# 特定コンパートメントのすべてのインスタンス
All {instance.compartment.id = 'ocid1.compartment.oc1..xxxxx'}

# 特定タグを持つインスタンス
All {tag.Department.Value = 'Finance', instance.type = 'compute'}
```

### 用途
- Compute InstanceからObject Storageに書き込む（APIキー不要）
- FunctionがVaultのシークレットを取得する
- Autonomous DatabaseがObject Storageにエクスポートする

---

## 7. Policies（ポリシー）

### 基本構文
```
Allow <subject> to <verb> <resource-type> in <location> [where <condition>]
```

| 要素 | 内容 | 例 |
|---|---|---|
| subject | 誰に | `group Admins` / `dynamic-group MyDG` / `any-user` |
| verb | 何ができるか | `inspect` / `read` / `use` / `manage` |
| resource-type | 何に対して | `instances` / `object-family` / `all-resources` |
| location | どこで | `tenancy` / `compartment Production` |
| condition | 条件（任意） | `where request.operation = 'GetObject'` |

### 動詞（verb）の権限レベル
| verb | 権限 | 主な操作 |
|---|---|---|
| `inspect` | 最低権限 | リソースのリスト・基本情報の取得 |
| `read` | inspect + | リソースの詳細情報取得 |
| `use` | read + | リソースの使用（作成・削除は不可） |
| `manage` | 全権限 | 作成・更新・削除を含む全操作 |

### resource-type ファミリー
| ファミリー | 含まれるリソース |
|---|---|
| `compute-family` | instances, instance-images, volume-attachments 等 |
| `virtual-network-family` | vcns, subnets, route-tables, security-lists 等 |
| `object-family` | buckets, objects |
| `database-family` | db-systems, db-homes, databases 等 |
| `all-resources` | すべてのリソース |

### Policy評価ロジック
- **暗黙的Deny（Deny by Default）**：明示的に許可されていなければ拒否
- 明示的Denyは存在しない（OCIのPolicyは Allow のみ記述する）
- 複数のPolicyが存在する場合は**最も許可範囲の広いものが優先**（最大権限が適用）
- 上位Compartmentのポリシーは下位Compartmentにも適用される

### Policy配置場所
- `tenancy`を対象とするポリシー → Tenancy（ルート）に配置
- 特定Compartmentを対象とするポリシー → そのCompartmentまたは親に配置

### よく使うポリシー例
```
# グループにCompartment内の全インスタンスの管理権限
Allow group NetworkAdmins to manage virtual-network-family in compartment Production

# Dynamic GroupにObject Storageの書き込み権限
Allow dynamic-group AppServers to manage objects in compartment Production where target.bucket.name = 'app-logs'

# テナンシー全体の管理者
Allow group Administrators to manage all-resources in tenancy
```

---

## 8. Federation（フェデレーション）

### 概要
- 外部のIdP（Identity Provider）と連携してSSOを実現
- OCIはSAML 2.0をサポート

### 対応IdP
- Microsoft Active Directory Federation Services (ADFS)
- Azure Active Directory
- Okta
- その他SAML 2.0対応IdP

### 仕組み
1. IdPでユーザーが認証される
2. SAMLアサーションがOCIに送信される
3. OCIがIdPグループをOCI Groupにマッピング
4. マッピングされたGroupのPolicyが適用される

### ポイント
- フェデレーションユーザーはOCIに個別ユーザーを作成不要
- グループマッピングでPolicyを管理
- マルチクラウド環境での統合認証に有効

---

## 9. Instance Principal / Resource Principal

### Instance Principal
- Compute Instanceがキーを使わずにOCI APIを呼び出す仕組み
- Dynamic Groupに対してPolicyを付与することで実現
- 設定手順：
  1. Dynamic Groupを作成（条件でインスタンスを指定）
  2. PolicyでDynamic Groupに必要な権限を付与
  3. インスタンス上のコードでInstance Principal認証を使用

### Resource Principal
- FunctionsやData Flowなどのサーバーレスサービス向け
- Instance Principalと同様の概念だがリソース種別が異なる

---

## 10. Vault（シークレット管理）

- APIキー・パスワードなどのシークレットを安全に保管
- **Master Encryption Key (MEK)** でシークレットを暗号化
- キーの種類：
  - **Customer-managed key**：ユーザーが管理（HSM or Software）
  - **Oracle-managed key**：Oracleが管理（デフォルト）
- シークレットのローテーション機能あり

---

## 11. 試験対策チェックリスト

- [ ] Policy構文を暗記して書ける（Allow group X to verb Y in compartment Z）
- [ ] 動詞4段階（inspect/read/use/manage）の違いを説明できる
- [ ] Dynamic GroupとInstance Principalのユースケースを説明できる
- [ ] Compartment階層とポリシー継承の動作を理解している
- [ ] Federationの目的と仕組みを説明できる
- [ ] 暗黙的Denyの概念を理解している

---

## 12. よく出る問題パターン

**Q. インスタンスがAPIキーなしでObject Storageにアクセスするには？**
→ A. Dynamic GroupにインスタンスをマッチさせてPolicyを付与し、Instance Principalを使用する

**Q. 開発チームが本番Compartmentのリソースを参照（読み取りのみ）できるようにするには？**
→ A. `Allow group Developers to read all-resources in compartment Production`

**Q. ポリシーAでuseが許可、ポリシーBでmanageが許可の場合、有効な権限は？**
→ A. manage（複数ポリシーは最大権限が適用される）
