# Collibra DQ 制約事項一覧（要件定義向け）

> **作成日**: 2026-04-16
> **対象バージョン**: Collibra DQ 2026.02
> **自社スコープ**: DQ Agent + Spark のみ（DQ Web・Metastore はグループ会社管理）
> **比較対象**: Standalone（Azure VM） vs AKS（Kubernetes）

---

## 目次

1. [制約事項一覧 ― Standalone（Azure VM）](#1-制約事項一覧--standaloneazure-vm)
   - 1.1 リソース・ジョブ実行数
   - 1.2 運用・メンテナンス
   - 1.3 コスト・調達
   - 1.4 その他
2. [制約事項一覧 ― AKS（Kubernetes）](#2-制約事項一覧--akskubernetes)
   - 2.1 リソース・ジョブ実行数
   - 2.2 運用・メンテナンス
   - 2.3 コスト・調達
   - 2.4 その他
3. [サマリー比較表](#3-サマリー比較表)

---

## 1. 制約事項一覧 ― Standalone（Azure VM）

### 1.1 リソース・ジョブ実行数

#### 同時ジョブ上限（ULIMIT ベース）

- DQ サービス起動時に **約 428 スレッド** を消費する
- ジョブを1件実行するたびに **追加で約 400 スレッド** を消費する
- ULIMIT のデフォルト値（1024）では、ジョブを1件も実行できない状態になるため、**`/etc/security/limits.conf` に 4096 以上を設定することが必須**
- ULIMIT = 4096 の場合の同時ジョブ上限:
  ```
  (4096 - 428) / 400 ≒ 9 ジョブ
  ```

#### 同時ジョブ上限（RAM ベース）

RAM ベースの目安式: `(RAM_GB / 28) - 1`

| VM SKU | CPU | RAM | 同時ジョブ目安 |
|---|---|---|---|
| Standard_E16s_v5 | 16コア | 128 GB | **約 4 ジョブ** |
| Standard_E32s_v5 | 32コア | 256 GB | **約 9 ジョブ** |
| Standard_E64s_v5 | 64コア | 512 GB | **約 18 ジョブ** |

> ULIMIT の上限と RAM の上限のうち、**小さい方**が実際の同時ジョブ数の制約になる。  
> 例: E16s_v5 + ULIMIT 4096 の場合、ULIMIT 上限（9）より RAM 上限（4）が小さいため、実質 **約 4 ジョブ** が上限。

#### データサイズ制約

- 1ジョブで処理できるデータサイズの上限は **2 TB**（Collibra 公式制約）
- 2 TB を超えるデータセットを対象にしたい場合は、スキャン対象を分割・削減する処理が別途必要

#### スケール方法の制約

- **垂直スケール（VM サイズアップ）のみ**
  - VM のサイズを変更するには **停止（Deallocate）→ サイズ変更 → 起動** の手順が必要
  - この間 DQ Agent・Spark は停止するため、**ダウンタイムが発生する**
  - `az vm resize` コマンドまたは Azure Portal から実施
- Spark の水平スケールアウト（Worker を別 VM に追加）は、設定上は Spark Standalone クラスタとして組める構成もあるが、Collibra DQ の Agent は単一 Spark Master を前提とした設計のため、**実質的に単一 VM 上での垂直スケールが現実的**

---

### 1.2 運用・メンテナンス

#### アップグレード

- アップグレードは **JAR ファイルの差し替え** + `owlmanage.sh restart` により実施する
- 作業中 DQ Agent・Spark が停止するため、**必ずダウンタイムが発生する**
- ローリングアップデート（無停止更新）は**不可能**
- 推奨手順:
  1. アップグレード前に **Disk Snapshot** を取得（障害時の切り戻し用）
  2. `owlmanage.sh stop` でサービス停止
  3. 旧 JAR を `bin.backup` にリネームして退避
  4. 新 JAR を展開・配置
  5. `owlmanage.sh start` で起動・ログ確認
- ロールバック: `bin.backup` から旧 JAR を復元し起動

#### OS パッチ管理

- `dnf update` を**手動で実施**する必要がある
- カーネルアップデートが含まれる場合は**VM の再起動が必要**（=ダウンタイム発生）
- AKS のような「自動ノード OS アップグレード」機能はない
- Azure Automation で定期的な `dnf update` を自動化することは可能だが、再起動制御まで含めると設定が複雑になる

#### Java バージョン管理

- Java 17 のマイナーバージョン更新は **手動で `dnf update java-17-openjdk-devel` を実施**
- `JAVA_HOME` の変更が必要になるケースがあるため、更新後に動作確認が必要

#### オンデマンド起動（スキャン時のみ起動）

- DQ Agent は DQ Web に直接通信しない（Metastore を JDBC でポーリングするだけ）ため、**スキャン実行時以外は VM を停止（Deallocate）しておくことが可能**
- ユーザーがジョブ設定を行う際（DQ Web UI 操作）も Agent の起動は不要
- 起動リードタイム:
  - VM コールド起動: 約 2〜5 分
  - DQ Agent プロセス起動: さらに 1〜2 分
  - 合計: **スキャン開始まで約 3〜7 分**
- 自動化: **Azure Automation Runbook**（PowerShell）で VM 起動 → スキャン待機 → VM 停止 を自動化可能
- コスト削減効果:
  - 週 1 回・4 時間スキャンの場合: **¥131,371/月（常時稼働）→ ¥14,034/月（オンデマンド）**
  - 削減率: **約 90%削減**

#### 監視・自動復旧

- systemd の `Restart=always` を設定することで、プロセス異常終了時の**自動再起動は可能**
- ただし Kubernetes の Liveness / Readiness Probe のような「組み込みの死活監視・自動切り離し」は存在しない
- Azure Monitor + Log Analytics でのカスタムアラート（ログエラー検知・プロセス監視）を別途設定する必要がある

#### バックアップ

- **Azure Backup**（Recovery Services Vault）: VM ディスク全体を定期的にスナップショット保存。自動スケジュール設定が可能
- **Disk Snapshot**（手動）: アップグレード前など任意のタイミングで即時取得可能
- Metastore（PostgreSQL）のバックアップは**グループ会社が管理**するため、自社の対応範囲外

---

### 1.3 コスト・調達

#### 月額コスト（常時稼働・Pay-as-you-go）

| VM SKU | vCPU | RAM | 月額（Pay-as-you-go） | 同時ジョブ目安 |
|---|---|---|---|---|
| Standard_E16s_v5 | 16 | 128 GB | **¥131,371/月** | ~4 ジョブ |
| Standard_E32s_v5 | 32 | 256 GB | **¥262,741/月** | ~9 ジョブ |

> 価格は 2025年8月時点の Azure Japan East・JPY・従量課金。最新価格は [Azure 料金計算ツール](https://azure.microsoft.com/ja-jp/pricing/calculator/) で確認すること。

#### オンデマンド起動時の月額コスト

週 1 回・スキャン 4 時間の場合（E16s_v5 ベース）:

```
179.96 円/時 × 4 時間 × 4.3 回/月 ≒ ¥3,095/月（VM 起動分）
+ ディスク費用 ¥10,939/月（常時発生）
= 合計 ¥14,034/月
```

- **RI（Reserved Instance）とオンデマンド起動の組み合わせは原則不可**
  - RI は VM が停止（Deallocate）していても課金が継続する
  - オンデマンド起動で運用する場合は **Pay-as-you-go を維持すること**

#### Reserved Instance（RI）割引（常時稼働の場合のみ有効）

| RI 期間 | 割引率 | E16s_v5 月額 |
|---|---|---|
| 1年 RI | 約 36% 割引 | **¥94,317/月** |
| 3年 RI | 約 57% 割引 | **¥56,490/月** |

#### コンテナ・レジストリ費用

- **ACR（Azure Container Registry）費用: なし**
- Standalone はコンテナを使用しない。JAR ファイルのみで動作するため、ACR は不要

#### 調達フロー

1. Collibra からライセンスメールを受領（ライセンスキー・ライセンス名が記載）
2. [Collibra Product Resource Center](https://productresources.collibra.com/) からインストールパッケージ（`.tar.gz`）をダウンロード
3. VM に転送（`scp` または Azure Blob Storage 経由）して展開・インストール
- コンテナイメージの取得・レジストリ転送などの作業は**不要**

---

### 1.4 その他の制約

#### OS 制約

- **対応 OS: RHEL 8.x / 9.x のみ**
- Ubuntu・Debian・CentOS は非サポート
- Azure Marketplace の RHEL イメージ（`RedHat:RHEL:9-lvm-gen2`）を使用する

#### ソフトウェアバージョン固定

| ソフトウェア | 要件 | 備考 |
|---|---|---|
| Java | **17 のみ**（2026.02 以降） | 11 / 21 は非サポート |
| Spark | **4.1.0**（2026.02 に同梱） | パッケージに含まれるため個別インストール不要 |
| PostgreSQL（Metastore） | 13 以上 | グループ会社管理のため自社では制御不可 |

#### 必要スキル

- Linux（RHEL）の基本操作・ファイル編集・プロセス管理
- systemd によるサービス管理
- Java / JVM のヒープ・スレッド設定の基礎知識
- Spark Standalone モードの概念理解
- **Kubernetes・Helm・Docker の知識は不要**

#### 設定管理

- 設定はすべてテキストファイルで管理する
  - `owl-env.sh`: JVM オプション・SSL 設定・ライセンスキー
  - `owl.properties`: Metastore JDBC 接続設定
  - `agent.properties`: Spark Master 接続・実行モード
- Git による設定ファイルのバージョン管理は推奨するが、Terraform 等の IaC ツールとの**直接統合は難しい**
- シークレット（パスワード）は `owlmanage.sh encrypt` で暗号化して `owl.properties` に記載するか、Azure Key Vault + Managed Identity で起動時に取得する

#### 冗長化の制約

- **Agent Only 構成では、同一 Datasource を複数の Agent が担当することはできない**
  - 複数の Agent が同一 Datasource をポーリングすると、**重複実行が発生**する
- 現実的な冗長化オプション:
  - **Option A（推奨）**: Datasource を Agent ごとに分散（複数 VM に Agent をインストールし、担当 Datasource を分割）
  - **Option B**: Availability Zone 指定の単一 VM（ゾーン障害からの保護のみ。冗長化ではない）
- VM Scale Sets・Active-Standby + Internal Load Balancer は DQ Agent には適用不可（Agent は HTTP フロントエンドを持たないため）

#### ネットワーク制御の粒度

- NSG（Network Security Group）による **VM 単位の制御**のみ
- Kubernetes NetworkPolicy のような「Pod 単位・ラベル単位の通信制御」は不可

#### Collibra 公式サポート

- **完全サポート対象**（制約なし）

---

## 2. 制約事項一覧 ― AKS（Kubernetes）

### 2.1 リソース・ジョブ実行数

#### ULIMIT 制約（AKS 固有の注意点）

- DQ Agent Pod の `ulimits` は **`values.yaml` で明示的に設定する必要がある**
- 未設定のままデプロイすると、コンテナのデフォルト ULIMIT（1024）が適用され、**ジョブ実行がブロックされるリスクがある**
- 設定例（`values.yaml`）:
  ```yaml
  owl-agent:
    podSecurityContext:
      sysctls: []
    containerSecurityContext:
      ulimits:
        - name: nofile
          soft: 4096
          hard: 4096
  ```

#### 同時ジョブ上限

- 単一ノードに縛られず、**ノードプール全体の CPU / RAM が実質の上限**となる
- Spark Executor Pod はジョブ実行時に動的生成されるため、**ノードの空きリソースが不足するとジョブが `Pending` 状態で止まる**
- Pod の `resources.requests` / `limits` の設計がジョブ実行可否を左右する
- Cluster Autoscaler を有効化することで、Pending Pod を検知してノードを自動追加可能

#### データサイズ制約

- Standalone と同様に **1ジョブあたり 2 TB が上限**（Collibra 製品共通の制約）

#### スケール方法

- **水平スケール対応**（Cluster Autoscaler によるノード自動追加）
  - スケールアウト中もサービス停止なし
  - ただし新規ノードの準備完了まで数分かかるため、急激な負荷増には即応できない場合がある
- ノードプール最小構成の制約:
  - **System Node Pool**: kube-system 用に最低 1 台必要（DQ とは別に追加コストが発生）
  - **DQ Node Pool**: DQ Agent + Spark Executor 全 Pod が収まる台数が必要
    - 最低 2 台推奨（1 台障害時の継続稼働のため）

---

### 2.2 運用・メンテナンス

#### アップグレード

- `helm upgrade` によるローリングアップデートが可能
- **サービス停止なし**（古い Pod を1つずつ新しい Pod に切り替える）
- ロールバック: `helm rollback <release> <revision>` 1 コマンドで即時切り戻し可能
- ただし毎回アップグレード前に**コンテナイメージを ACR へ事前転送する作業が必要**
  - `docker pull`（Collibra レジストリ）→ `docker tag` → `docker push`（ACR）
  - この転送作業は `helm upgrade` とは別工程であり、**抜け漏れするとデプロイが失敗する**

#### OS パッチ管理

- AKS ノードは **自動 OS アップグレード機能あり**
  - `--auto-upgrade-channel node-image` で自動適用可能
  - **メンテナンスウィンドウ**（`az aks maintenanceconfiguration`）を設定することで、更新を業務時間外に限定できる
- Standalone のように手動で `dnf update` を実施する必要はない

#### Kubernetes バージョン管理（重要な制約）

- Collibra DQ 2026.02 がサポートする Kubernetes バージョンは **1.29〜1.34 のみ**
- AKS の自動アップグレード（`--auto-upgrade-channel stable`）を有効化した場合、**Collibra 非サポートバージョン（1.35 以降）に自動更新されるリスクがある**
- → **自動アップグレードのチャンネル設定を慎重に管理すること**
  - 推奨: `--auto-upgrade-channel node-image`（OS パッチのみ自動。K8s バージョンは手動管理）
  - または自動アップグレードを無効化し、Collibra のリリースノートで対応バージョンを確認してから手動更新する

#### オンデマンド起動（スキャン時のみ起動）

- `az aks stop` / `az aks start` でクラスター全体の起動・停止が可能
- **起動リードタイム**:
  - クラスター起動: 約 10〜15 分
  - Pod 起動まで含めると: **約 15〜20 分**
  - → Standalone（3〜7 分）より **リードタイムが長い**
- ノードプールだけを 0 スケール（`az vmss scale --new-capacity 0`）する方法もあるが、PVC のマウント解除・再マウントの制御が複雑になる
- **スキャン終了を検知して自動停止する仕組み**は、Standalone の Automation Runbook と比べて実装が複雑

#### 管理作業上の制約

- **AKS Private Cluster** の場合、`kubectl` / `helm` の操作は**専用の管理 VM 経由でのみ可能**
  - ローカル端末から直接 AKS API Server への接続不可（Private Link による制限）
  - 管理 VM を常時起動しておくか、作業時のみ起動する運用が必要
  - 管理 VM 分のコスト（D2s_v5 等: 約 ¥22,000/月）が追加で発生

#### 監視・自動復旧

- Kubernetes の **Liveness Probe / Readiness Probe** により、Pod 異常時の自動再起動・トラフィック切り離しが組み込みで動作する
- **Cluster Autoscaler** でノード障害時の Pod 自動再スケジュールが可能
- Azure Monitor for Containers（Container Insights）による Pod・ノードのメトリクス収集が可能
- Standalone と比較して**監視・自動復旧の仕組みが充実している**

#### バックアップ

- Standalone と同様、Metastore のバックアップはグループ会社管理
- PVC（Persistent Volume）のバックアップ: Azure Backup（Kubernetes 向け拡張機能）または Velero を使用可能

---

### 2.3 コスト・調達

#### 月額コスト（常時稼働・Pay-as-you-go）

| コンポーネント | 仕様 | 費用/月 |
|---|---|---|
| AKS コントロールプレーン（Free Tier） | SLA なし | **無料** |
| AKS コントロールプレーン（Standard Tier） | SLA 99.9% | **約 ¥7,000** |
| System Node Pool | Standard_D2s_v5 × 1 | **約 ¥22,000** |
| DQ Node Pool | Standard_E16s_v5 × 2 | **約 ¥262,741** |
| ACR（Basic Tier） | コンテナイメージ保存用 | **約 ¥3,000** |
| **合計（最小構成・Free Tier）** | | **約 ¥153,430/月** |
| **合計（最小構成・Standard Tier）** | | **約 ¥160,430/月** |

> 価格は 2025年8月時点の Azure Japan East・JPY・従量課金。最新価格は [Azure 料金計算ツール](https://azure.microsoft.com/ja-jp/pricing/calculator/) で確認すること。

#### AKS Free Tier の制約

- コントロールプレーンの SLA が**保証されない**
- API Server の可用性が低下した場合、`kubectl` / `helm` 操作が一時的に不能になる可能性がある
- **本番環境では Standard Tier（¥7,000/月）への移行を推奨**

#### Reserved Instance（RI）割引

- DQ ノードプールの VM には RI を適用可能
- **AKS コントロールプレーン費用は RI 対象外**（常に従量課金）
- RI 適用時のコスト削減例（DQ Node Pool E16s_v5 × 2 の場合）:
  - 1年 RI: 約 36% 割引 → ¥262,741 → **約 ¥168,154/月**
  - 3年 RI: 約 57% 割引 → **約 ¥112,979/月**

#### 調達フロー（Standalone より手順が多い）

1. Collibra からライセンスメール・**コンテナレジストリ認証情報**・**Helm チャート ZIP ダウンロード URL** を受領
2. Collibra のプライベートレジストリからコンテナイメージを取得:
   ```bash
   docker login <collibra-registry> -u <USER> -p <PASS>
   docker pull <collibra-registry>/owl-web:<VERSION>
   docker pull <collibra-registry>/owl-agent:<VERSION>
   # ... 他のイメージも同様に取得
   ```
3. 取得したイメージを ACR へ転送:
   ```bash
   docker tag <collibra-registry>/owl-agent:<VERSION> <ACR>.azurecr.io/owl-agent:<VERSION>
   docker push <ACR>.azurecr.io/owl-agent:<VERSION>
   ```
4. Helm チャート ZIP を展開:
   ```bash
   unzip collibra-dq-helm-<VERSION>.zip
   # helm repo add は不可。ZIP 展開後にローカルパスで指定する
   ```
5. `helm upgrade --install` でデプロイ
- **アップグレードのたびに手順 2〜3 の ACR 転送が必要**（抜け漏れに注意）

---

### 2.4 その他の制約

#### 必要スキル

- Kubernetes の基本概念（Pod / Deployment / Service / PVC / Namespace）の理解
- `kubectl` コマンドの操作
- Helm の操作（`helm upgrade` / `helm rollback` / `helm values`）
- YAML による `values.yaml` の編集
- ACR（Azure Container Registry）へのイメージ転送
- AKS クラスターの管理（ノードプール・アップグレード）
- **Standalone と比較して学習コスト・初期構築難易度が高い**
- 構築に慣れていない場合、初期セットアップに数日〜1 週間かかる可能性がある

#### Helm チャートの取得方法と制約

- Collibra DQ の Helm チャートは **`helm repo add` による標準リポジトリ経由での取得が不可能**
- **ZIP ファイルとして Collibra から直接受領**し、ローカルに展開してパスを指定する方式のみ
- Helm チャートの内容はバージョンアップごとに変わるため、**新バージョンの ZIP を受領するたびに展開・差し替えが必要**

#### Helm カスタマイズの制限

- `values.yaml` のカスタマイズについて、Collibra の公式ドキュメントに以下の注記がある:
  > *"The Helm deployment is unique for each customer and Collibra Support may be limited."*
- 標準パラメータの範囲内での設定変更はサポートされるが、**独自の Helm テンプレート改造はサポート対象外**

#### Kubernetes バージョン対応範囲

- **サポート対象: 1.29〜1.34**（Collibra DQ 2026.02 時点）
- **k3s はサポート対象外**（Collibra 公式ドキュメントに記載なし）
- サポート対象の Kubernetes プロバイダー: AKS / EKS / GKE / OpenShift / Rancher

#### 設定管理

- `values.yaml` + Kubernetes Secret による設定管理が可能
- **GitOps（ArgoCD / Flux）との統合が可能**（Standalone より IaC 親和性が高い）
- Kubernetes Secret によるシークレット管理、または **Azure Key Vault + External Secrets Operator** による連携が可能

#### 冗長化

- `replicaCount: 2` を `values.yaml` に設定するだけで Agent の冗長化が可能
- Kubernetes が Pod の死活を監視し、障害時に自動で再スケジュール
- **Standalone より冗長化が容易**

#### ネットワーク制御

- **Kubernetes NetworkPolicy** により、Pod 単位・ラベル単位での通信制御が可能
- Standalone の NSG（VM 単位）と比較してより細かいセキュリティ制御が実現できる

#### Collibra 公式サポート

- **完全サポート対象**
- ただし Helm チャートのカスタマイズ部分については**サポートが限定的**（前述の公式注記あり）

---

## 3. サマリー比較表

Standalone と AKS の主要制約を対比した早見表。

| 制約カテゴリ | Standalone（Azure VM） | AKS |
|---|---|---|
| **同時ジョブ上限**（E16s_v5/128GB） | **約 4 ジョブ** | ノードプール拡張で増加可 |
| **データサイズ上限 / ジョブ** | **2 TB**（共通制約） | **2 TB**（共通制約） |
| **スケール方法** | 垂直のみ（**停止が必要**） | 水平（**無停止・自動化可**） |
| **アップグレードダウンタイム** | **あり**（JAR 差し替え） | **なし**（ローリング更新） |
| **OS パッチ管理** | **手動**（`dnf update`） | **自動化可能** |
| **オンデマンド起動リードタイム** | **3〜7 分** | **15〜20 分** |
| **月額コスト（常時稼働・最小構成）** | **¥131,371/月** | **¥153,430/月** |
| **RI 割引（1年）** | 適用可（約 36%） | ノード VM のみ適用可 |
| **RI とオンデマンド起動の併用** | **不可**（RI は常時課金） | **不可**（同様） |
| **コンテナイメージ調達** | **不要** | ACR への手動転送が必要 |
| **Helm チャート取得** | 該当なし | **ZIP 配布のみ**（repo add 不可） |
| **K8s バージョン管理** | 該当なし | 1.29〜1.34 のみ・**自動更新リスクあり** |
| **必要スキル** | Linux / systemd / Java | **+ Kubernetes / Helm / ACR** |
| **冗長化難易度** | **高い**（Datasource 分散のみ） | **低い**（`replicaCount` で容易） |
| **設定管理（IaC 親和性）** | 低い（テキストファイル） | **高い**（values.yaml / GitOps） |
| **監視・自動復旧** | systemd のみ（限定的） | **Liveness Probe・自動再スケジュール** |
| **Collibra 公式サポート** | 完全サポート | 完全サポート（Helm カスタムは限定的） |
