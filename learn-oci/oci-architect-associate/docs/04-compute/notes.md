# 04. Compute

## 試験での重要度
- Shape種別・Flex Shapeは頻出
- Instance Pool + Autoscalingの構成問題が多い
- Instance Principalと組み合わせた問題も出る

---

## Azure vs OCI 比較

### 概念対応表
| 概念 | Azure | OCI |
|---|---|---|
| 仮想マシン | Virtual Machine (VM) | Compute Instance (VM) |
| 物理サーバー専有 | Azure Dedicated Host | Bare Metal / Dedicated VM Host |
| VMのサイズ定義 | VM Size（例: Standard_D4s_v5） | Shape（例: VM.Standard.E4.Flex） |
| 柔軟なサイズ変更 | vCPU・メモリを固定Sizeから選択 | Flex ShapeでOCPU・メモリを独立指定 |
| OSイメージ | Azure Marketplace Image / Custom Image | Platform Image / Custom Image / Marketplace |
| 起動スクリプト | Custom Data（cloud-init） | User Data（cloud-init） |
| インスタンスメタデータ | Instance Metadata Service（169.254.169.254） | IMDS（169.254.169.254）※同じアドレス |
| VMスケールセット | VMSS (VM Scale Sets) | Instance Pool |
| 自動スケール | Autoscale（メトリクス/スケジュール） | Autoscaling Configuration（メトリクス/スケジュール） |
| スポットインスタンス | Azure Spot VMs | Preemptible Instances |
| 容量予約 | On-demand Capacity Reservation | Capacity Reservation |
| GPUインスタンス | NC/ND/NV Sizeシリーズ | GPU Shape（VM.GPU3.x / VM.GPU.A10.x） |
| ARM/高コスパ | Dpsv5（ARM Ampere Altra） | VM.Standard.A1.Flex（Ampere Altra） |

### 主な設計の違い
| 観点 | Azure | OCI |
|---|---|---|
| CPU単位 | vCPU（物理スレッド1本） | OCPU（物理コア1つ）= 2 vCPU |
| Flex型サイズ | サイズを選ぶ形式（細かい刻みあり） | OCPU数・メモリGBを自由に指定（真のFlex） |
| スケールアウト構成 | VMSS → Load Balancer バックエンドプール | Instance Pool → LB バックエンドセット（自動登録） |
| スポット削除の事前通知 | 最大30秒 | 約30秒 |
| ローカル一時ストレージ | 一部VMSizeに付属（temp disk） | DenseIO ShapeのLocal NVMe（高性能） |

---

## 1. Compute Instance の種別

### Virtual Machine (VM)
- ハイパーバイザー上で動作する仮想マシン
- 最も一般的な選択
- 起動時間：数分

### Bare Metal (BM)
- 物理サーバーを**専有**して使用
- ハイパーバイザーなし → ほぼ100%のリソース利用が可能
- 高パフォーマンスが必要なワークロード向け（HPC、DB等）
- 起動時間：10〜15分程度

### Dedicated VM Host（DVH）
- 物理サーバーを**専有**し、その上で**複数のVMを動かす**
- VMの**ライセンス持ち込み（BYOL）** や規制要件（GDPR等）でホスト専有が必要な場合に使用
- Bare Metalとの違い：VM形態で動かせる点

| 種別 | 共有 | 形態 | 主な用途 |
|---|---|---|---|
| VM | マルチテナント | 仮想マシン | 一般ワークロード |
| Bare Metal | シングルテナント | 物理 | HPC・高性能DB |
| Dedicated VM Host | シングルテナント（ホスト） | 仮想マシン | BYOL・規制対応 |

---

## 2. Shape（シェイプ）

OCIではインスタンスのCPU・メモリ・ネットワーク帯域を定義する「Shape」を選択する。

### Flexible Shape（推奨）
- OCPUとメモリを**独立して任意の値に設定できる**
- 代表的なFlex Shape：
  - `VM.Standard.E4.Flex`（AMD EPYC）
  - `VM.Standard.E5.Flex`（AMD EPYC 4th Gen）
  - `VM.Standard3.Flex`（Intel Xeon）
  - `VM.Standard.A1.Flex`（Ampere Altra ARM、コスト最安）

### Standard Shape
- OCPU・メモリが固定された従来のShape
- `VM.Standard2.1`（1 OCPU、15GB）のような命名

### DenseIO Shape
- **NVMe SSD（ローカルストレージ）を搭載**
- 超高速I/Oが必要なDBや分析ワークロード向け
- ローカルストレージはインスタンス終了で消える（永続化不可）
- 例: `VM.DenseIO2.8`（8 OCPU + NVMe 6.4TB）

### GPU Shape
- NVIDIA GPU搭載
- AI/ML学習・推論・グラフィックレンダリング
- 例: `VM.GPU3.1`（NVIDIA V100 × 1）、`VM.GPU.A10.1`（NVIDIA A10）

### HPC Shape（High Performance Computing）
- 低レイテンシRDMAネットワーク対応
- クラスタネットワーキングを使った並列計算向け
- 例: `BM.HPC2.36`（36コア + RDMA）

### Shape選択フロー
```
汎用ワークロード → VM Flex（E4/E5/Standard3）
コスト最優先 → VM.Standard.A1.Flex（ARM）
超高速ローカルI/O → DenseIO
AI/ML → GPU Shape
HPC並列計算 → HPC Shape + Cluster Networking
物理専有 → Bare Metal
```

---

## 3. OCPU と vCPU の違い

| 単位 | 説明 |
|---|---|
| **OCPU** | Oracle CPU。物理コアの**1スレッド**に相当 |
| **vCPU** | 一般的な仮想CPU。OCPUの2倍（1 OCPU = 2 vCPU） |

- Flex Shapeでは「OCPU数」を指定（1〜最大値の範囲）
- メモリはOCPUあたり1GB〜最大値（Shapeによる）の範囲で指定

---

## 4. Image（イメージ）

### Platform Image（プラットフォームイメージ）
- Oracleが提供・管理する公式イメージ
- OS：Oracle Linux、CentOS、Ubuntu、Windows Server等
- 定期的にパッチ適用済みイメージが更新される

### Custom Image（カスタムイメージ）
- 既存インスタンスから作成したイメージ
- インスタンスの設定・ソフトウェアを含んだ「ゴールデンイメージ」
- 別のCompartmentや別リージョンにコピー可能

### Marketplace Image
- Oracle Cloud Marketplace上のサードパーティイメージ
- 商用ソフトウェア（F5, Palo Alto等）や事前構築済みスタック

### BYOI（Bring Your Own Image）
- オンプレや他のクラウドのイメージをOCIにインポート
- サポートフォーマット：VMDK, QCOW2, OVA 等

---

## 5. 起動設定（Cloud-init / User Data）

### Cloud-init
- インスタンス初回起動時に自動実行されるスクリプト
- コンソールまたはCLI/APIで`--user-data`として渡す
- 用途：
  - パッケージのインストール
  - 設定ファイルの配置
  - アプリケーションの起動設定

```yaml
# cloud-init例
#cloud-config
packages:
  - nginx
runcmd:
  - systemctl start nginx
  - systemctl enable nginx
```

### Instance Metadata Service（IMDS）
- インスタンス内部からメタデータを取得するHTTPエンドポイント
- URL: `http://169.254.169.254/opc/v2/instance/`
- 取得できる情報：インスタンスOCID、Shape、AD、リージョン等
- **IMDSv2**（推奨）：認証トークンによるセキュアなアクセス

---

## 6. Instance Pool（インスタンスプール）

### 概要
- 同一設定の複数インスタンスを**グループとして管理**する仕組み
- **Instance Configuration（インスタンス構成）** をテンプレートとして使用
- Instance Configurationには：Shape・Image・VCN/Subnet・SSH Key等を定義

### Instance Configuration vs Custom Image
| 要素 | Instance Configuration | Custom Image |
|---|---|---|
| 内容 | 起動設定のテンプレート | ディスクイメージ（OS含む） |
| 用途 | Instance Pool/Autoscalingの定義 | OSの状態を複製 |

### Instance Poolの動作
- 指定した**サイズ（インスタンス数）** を維持
- 障害が発生したインスタンスは自動で置き換え
- **Load Balancerバックエンドセットと統合**：プールにインスタンスが追加/削除されると自動でLBに登録/解除

---

## 7. Autoscaling（オートスケーリング）

### 種別
| 種別 | トリガー | 用途 |
|---|---|---|
| **Metric-based（メトリクスベース）** | CPU使用率等のモニタリング指標 | トラフィック変動に応じた自動スケール |
| **Schedule-based（スケジュールベース）** | 指定した日時・スケジュール | 予測可能な負荷変動（営業時間中のみ拡張等） |

### Metric-based Autoscaling の設定項目
- **最小インスタンス数**
- **最大インスタンス数**
- **初期インスタンス数**
- **スケールアウトルール**：条件（例：CPU > 70%が5分継続）→ 追加インスタンス数
- **スケールインルール**：条件（例：CPU < 30%が15分継続）→ 削減インスタンス数
- **クールダウン期間**：スケール実行後の次のスケールまでの待機時間（デフォルト300秒）

### Autoscalingの前提
1. Instance Configurationを作成
2. Instance Poolを作成（Instance Configurationを指定）
3. Autoscaling Configurationを作成（Instance Poolに関連付け）

---

## 8. スケーリング方式

### 水平スケール（Scale Out / In）
- インスタンス**数を増減**
- Instance Pool + Autoscalingで実現
- ステートレスアプリケーションに適合

### 垂直スケール（Scale Up / Down）
- インスタンスの**サイズ（Shape）を変更**
- **インスタンスを一時停止して**Shapeを変更する（ダウンタイムが発生）
- Flex ShapeはOCPUとメモリを変更するだけ
- ステートフルアプリケーション（DBサーバー等）に適合

---

## 9. Preemptible Instance（プリエンプティブルインスタンス）

- 通常VMの**最大50%割引**で使用できる低コストインスタンス
- **Oracleが容量不足時に削除することがある**（事前通知 約30秒）
- ユースケース：バッチ処理・CI/CD・テスト環境・機械学習の学習ジョブ
- 削除される際に`preemptionAction`で動作を指定（TERMINATE or STOP）

---

## 10. Capacity Reservation（容量予約）

- 将来の使用に備えて特定のCompartment・AD・Shape・数量のキャパシティを**事前予約**
- 予約したキャパシティは確保されるが、インスタンスを起動するまで課金なし（予約自体は無料）
- ユースケース：障害復旧計画・大規模スケールアウト時の容量保証

---

## 11. その他の重要機能

### Boot Volume（ブートボリューム）
- インスタンスのOSが格納されたブロックボリューム
- インスタンス削除時にボリュームを保持するか選択可能
- カスタムイメージの元にもなる
- デフォルト50GB（変更可能）

### Secondary VNIC
- インスタンスに追加のネットワークインターフェースを付与
- 異なるVCN・Subnetへの接続が可能
- ネットワークアプライアンス（ファイアウォール等）の実装に使用

### Live Migration
- OracleがメンテナンスでインスタンスをFD間で**無停止移行**する
- ほとんどのVMインスタンスで自動的に行われる

---

## 12. 試験対策チェックリスト

- [ ] VM / BM / DVHの違いと用途を説明できる
- [ ] Flex Shapeの概念とOCPU・vCPUの違いを説明できる
- [ ] 4種のイメージ（Platform/Custom/Marketplace/BYOI）を説明できる
- [ ] Instance Pool + Autoscalingの構成手順を説明できる
- [ ] Metric-basedとSchedule-basedの違いを説明できる
- [ ] 水平スケールと垂直スケールの違いを説明できる
- [ ] Preemptible Instanceの用途と注意点を説明できる

---

## 13. よく出る問題パターン

**Q. 夜間バッチ処理コストを最小化したい。途中で削除されても再実行できる設計の場合、最適なインスタンスは？**
→ A. Preemptible Instanceを使用する

**Q. トラフィック増加時に自動でインスタンスを追加し、LBに自動登録する構成は？**
→ A. Instance Configuration → Instance Pool（LBバックエンドセット統合）→ Autoscaling（Metric-based）

**Q. ライセンスをBYOLで持ち込み、物理ホストを専有しながらVMとして動かすには？**
→ A. Dedicated VM Hostを使用する

**Q. OCPUとvCPUの換算は？**
→ A. 1 OCPU = 2 vCPU
