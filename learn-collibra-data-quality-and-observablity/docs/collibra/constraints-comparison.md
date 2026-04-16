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
