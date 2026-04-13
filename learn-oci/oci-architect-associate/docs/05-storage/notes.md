# 05. Storage

## 試験での重要度
- Object Storage（Tier・機能・アクセス制御）は毎回出題レベル
- Block Volume（パフォーマンス・バックアップ）も頻出
- ストレージ種別の使い分け判断問題が多い

---

## Azure vs OCI 比較

### 概念対応表
| 概念 | Azure | OCI |
|---|---|---|
| オブジェクトストレージ | Azure Blob Storage | Object Storage |
| Blobコンテナ | Container | Bucket |
| ストレージアクセス層 | Hot / Cool / Cold / Archive | Standard / Infrequent Access / Archive |
| 一時共有URL | SAS Token（Shared Access Signature） | Pre-Authenticated Request (PAR) |
| S3互換API | Azure Blob Storage（独自API） | Object Storage S3互換API |
| ライフサイクル管理 | Lifecycle Management Policy | Object Lifecycle Policy |
| オブジェクトバージョニング | Blob Versioning | Object Versioning |
| クロスリージョンレプリケーション | GRS / GZRS / Object Replication | Cross-Region Replication |
| ブロックストレージ | Azure Managed Disk | Block Volume |
| OSディスク | OS Disk | Boot Volume |
| データディスク | Data Disk | Block Volume（Data） |
| ディスクパフォーマンスTier | Standard HDD / Standard SSD / Premium SSD / Ultra Disk | Lower Cost / Balanced / Higher Perf / Ultra High Perf（VPU値で指定） |
| ディスクスナップショット | Snapshot | Manual Backup / Backup Policy |
| 共有ファイルストレージ | Azure Files | File Storage |
| ファイル共有プロトコル | SMB / NFS | NFS v3 |
| 高速ローカルストレージ | Temp Disk / NVMe（Lsシリーズ） | Local NVMe（DenseIO Shape） |
| キー管理 | Azure Key Vault（CMK） | OCI Vault（Customer Managed Key） |

### 主な設計の違い
| 観点 | Azure | OCI |
|---|---|---|
| ストレージアカウント | すべてのストレージはストレージアカウント配下 | サービスごとに独立（Object Storage / Block Volume / File Storage） |
| Archiveからの復元時間 | Standard: 即時、Archive: 最大15時間（Rehydration） | Archive: 最大1時間（Restore操作が必要） |
| ブロックストレージのパフォーマンス指定 | SKU（Standard HDD等）を選択 | VPU/GB値を数値で指定（柔軟） |
| ファイルストレージのプロトコル | SMB/NFS両対応 | NFS v3のみ（v4.1は未サポート） |
| Blob公開設定 | コンテナレベルのアクセスポリシー | バケットのVisibility（Public/Private）+ PAR |

---

## 1. ストレージ種別の概要

| 種別 | プロトコル | 永続性 | 共有 | 主な用途 |
|---|---|---|---|---|
| **Object Storage** | HTTP(S) / S3互換 | 永続 | 複数クライアント | 静的コンテンツ・バックアップ・ログ |
| **Block Volume** | iSCSI / Paravirtualized | 永続 | 単一インスタンス（通常） | OS、DB、アプリデータ |
| **File Storage** | NFS v3 | 永続 | 複数インスタンス | 共有ファイル・コンテンツ管理 |
| **Local NVMe** | 直接接続 | 非永続 | 単一インスタンス | 超高速一時ストレージ・キャッシュ |

---

## 2. Object Storage（オブジェクトストレージ）

### 概要
- キーバリュー型のストレージ（オブジェクト＝データ＋メタデータ）
- **バケット（Bucket）** という名前空間にオブジェクトを格納
- オブジェクトサイズ上限：10TiB（マルチパートアップロード使用時）
- リージョンスコープのサービス

### ストレージTier（アクセス頻度に応じて選択）

| Tier | アクセス頻度 | 最低保存期間 | 取り出しコスト | 用途 |
|---|---|---|---|---|
| **Standard** | 頻繁 | なし | なし | アクティブデータ・Webコンテンツ |
| **Infrequent Access** | 月1回程度 | 31日 | あり | バックアップ・ログ |
| **Archive** | ほぼアクセスしない | 90日 | あり（復元に時間） | 長期アーカイブ・コンプライアンス |

> **Archiveからのデータ復元には最大1時間かかる（Restore操作が必要）**

### バケットのアクセス制御
| 方法 | 説明 |
|---|---|
| **IAM Policy** | OCIユーザー・グループへのアクセス制御（基本） |
| **Pre-Authenticated Request (PAR)** | 認証不要の一時的なアクセスURL（有効期限付き） |
| **Bucket Visibility** | Public（匿名アクセス可）or Private（認証必須） |

### 主な機能

#### バージョニング（Versioning）
- オブジェクトの更新・削除前バージョンを保持
- 誤削除・誤上書きからのリカバリに使用
- バケット単位で有効化
- 古いバージョンはライフサイクルポリシーで自動削除可能

#### ライフサイクルポリシー
- ルールベースでオブジェクトを自動的に処理
- 操作：
  - `ARCHIVE`：Standard → Archiveに移動
  - `INFREQUENT_ACCESS`：Standard → Infrequent Accessに移動
  - `DELETE`：オブジェクトの削除
- 対象：オブジェクト名のプレフィックス・タグでフィルタリング可能

```
例：30日以上更新のないオブジェクトをInfrequent Accessに移動
例：90日以上のオブジェクトをArchiveに移動
例：365日以上のオブジェクトを削除
```

#### クロスリージョンレプリケーション
- 異なるリージョンのバケットにオブジェクトを非同期レプリケーション
- 災害対策・データ近接配置に使用
- レプリケーション先はRead-Onlyバケット

#### Object Storage暗号化
- デフォルトで**Oracle管理キー**で暗号化（透過的）
- **Customer管理キー（Vault）** の使用も可能

### S3互換API
- Amazon S3と互換性のあるAPIエンドポイントを提供
- S3を使用するツール・アプリケーションをそのまま利用可能
- 認証にAuth Token（Swift）またはS3互換の署名付きリクエストを使用

---

## 3. Block Volume（ブロックボリューム）

### 概要
- Compute Instanceにアタッチして使用するネットワーク接続ストレージ
- **永続的**（インスタンス削除後もボリュームは残る）
- 最小50GiB、最大32TiB
- 1インスタンスに最大32ボリュームをアタッチ可能

### ボリュームの種別
| 種別 | 説明 |
|---|---|
| **Boot Volume** | インスタンスのOSが格納されたシステムディスク |
| **Block Volume** | データ用の追加ディスク（Data Volume） |

### パフォーマンスレベル（VPUs/GB）

| レベル | VPU | IOPS（1TB時） | スループット | 用途 |
|---|---|---|---|---|
| **Lower Cost** | 0 | 2,000 | 480MB/s | バックアップ・アーカイブ |
| **Balanced** | 10（デフォルト） | 25,000 | 480MB/s | 一般ワークロード |
| **Higher Performance** | 20 | 50,000 | 680MB/s | OLTP・高速DB |
| **Ultra High Performance** | 30〜120 | 最大225,000 | 2,680MB/s | 超高性能DB・大規模OLTP |

> VPU = Volume Performance Units / GB。値が高いほど高性能・高コスト

### アタッチ方式
| 方式 | 説明 |
|---|---|
| **Paravirtualized** | 仮想化ドライバー経由（VM推奨・低オーバーヘッド） |
| **iSCSI** | ネットワークブロックデバイス（BM推奨・フル制御） |

### マルチアタッチ（共有ブロックボリューム）
- **複数インスタンス**に同一ブロックボリュームをアタッチ可能
- デフォルトはRead-Onlyアタッチ
- Read-Writeには**クラスタ対応ファイルシステム（Oracle ACFS等）** が必要

### バックアップ

#### 手動バックアップ
- 任意のタイミングでスナップショットをObject Storageに保存
- バックアップからボリュームを復元可能
- 別リージョンにコピー可能（リージョン間バックアップ）

#### ポリシーベースバックアップ（Backup Policy）
| ポリシー | バックアップ頻度 | 保持期間 |
|---|---|---|
| **Bronze** | 月次バックアップ | 12ヶ月 |
| **Silver** | 週次＋月次 | 4週間＋12ヶ月 |
| **Gold** | 日次＋週次＋月次 | 7日＋4週間＋12ヶ月 |
| **Custom** | 任意に設定 | 任意に設定 |

### Block Volume Replication（クロスリージョンレプリケーション）
- Block Volumeを別リージョンに非同期レプリケーション
- DR（ディザスタリカバリ）用途

---

## 4. File Storage（ファイルストレージ）

### 概要
- **NFSv3ベース**の共有ファイルシステム
- **複数のComputeインスタンスから同時マウント**可能
- ADスコープのサービス

### 構成要素
| 要素 | 説明 |
|---|---|
| **File System** | 実際のファイルデータを格納するストレージ |
| **Mount Target** | NFSクライアントがマウントするIPエンドポイント |
| **Export** | Mount Targetに対してFile Systemを公開する設定 |

```
接続の流れ：
Compute Instance
└── NFS Mount (Mount Target IPアドレス:/export-path)
    └── Mount Target
        └── Export
            └── File System
```

### スケーリング
- 容量は**自動拡張**（事前プロビジョニング不要）
- 最大8 Exabytes
- スループットはデータ量に比例して自動スケール

### セキュリティ
- **Export Options**：クライアントIPアドレスによるアクセス制御
- **Security List / NSG** で通信を制御（ポート: 111/TCP,UDP, 2048-2050/TCP,UDP）

### スナップショット
- File Systemの時点コピーを作成
- スナップショットは`.snapshot`ディレクトリからアクセス可能
- スケジュールスナップショットポリシーで自動化可能

### レプリケーション
- 別のFile Systemや別のリージョンのFile Systemへの非同期レプリケーション

---

## 5. Local NVMe（ローカルNVMe）

### 概要
- DenseIO Shapeに**物理的に搭載**されたNVMe SSD
- 最高のI/Oパフォーマンス（低レイテンシ・高IOPS）

### 重要な制約
- **インスタンスを削除するとデータも消える**（非永続）
- Block Volumeのようにスナップショット不可
- ボリューム拡張不可（Shapeに固定）

### ユースケース
- 高速一時キャッシュ（DBのバッファキャッシュ等）
- 分散ストレージの一部（Cassandra・HDFS等）
- テンポラリデータ処理

---

## 6. ストレージ選択の判断基準

```
複数インスタンスから共有アクセスが必要
├── ファイルシステム（NFS）→ File Storage
└── オブジェクト（HTTP）→ Object Storage

単一インスタンスのブロックデバイスが必要
└── Block Volume

超高速ローカルI/Oが必要（非永続でもよい）
└── Local NVMe（DenseIO Shape）

データをHTTP/APIで保存・取得・公開したい
└── Object Storage

長期アーカイブ・コスト最小化
└── Object Storage Archive Tier
```

### シナリオ別まとめ
| シナリオ | 推奨ストレージ |
|---|---|
| WebサーバーのOS・アプリ | Block Volume（Boot Volume） |
| Webサイトの静的コンテンツ配信 | Object Storage（Publicバケット） |
| DBデータファイル | Block Volume（Higher Performance以上） |
| 複数サーバーからの共有コンテンツ | File Storage |
| バックアップ・ログの長期保管 | Object Storage（Infrequent Access / Archive） |
| 分散処理の高速一時ストレージ | Local NVMe |
| 他クラウドからのデータ移行先 | Object Storage（S3互換API活用） |

---

## 7. データ転送サービス

### Data Transfer Disk
- 物理ディスクをOracleに郵送してデータをインポート/エクスポート
- 超大量データ（100TB以上）でインターネット転送が現実的でない場合

### Data Transfer Appliance
- Oracleが提供するオンプレ設置型のアプライアンスでデータ収集

---

## 8. 試験対策チェックリスト

- [ ] Object Storage 3つのTierの違いと最低保存期間を説明できる
- [ ] Pre-Authenticated Request (PAR)の用途を説明できる
- [ ] ライフサイクルポリシーで自動Tier移動・削除ができる仕組みを理解している
- [ ] Block VolumeのパフォーマンスレベルとVPUの意味を説明できる
- [ ] バックアップポリシー（Bronze/Silver/Gold）の違いを説明できる
- [ ] File StorageのMount Target / Export / File Systemの関係を説明できる
- [ ] Local NVMeが非永続であることを理解している
- [ ] シナリオに応じて適切なストレージ種別を選択できる

---

## 9. よく出る問題パターン

**Q. 複数のWebサーバーがHTMLテンプレートファイルを共有したい。最適なストレージは？**
→ A. File Storage（NFS共有）

**Q. 3ヶ月以上アクセスのないオブジェクトを自動的に最も低コストのTierに移動するには？**
→ A. ライフサイクルポリシーで90日以上経過したオブジェクトをArchive Tierに移動するルールを設定する

**Q. 外部パートナーにObject Storageのファイルを一時的にダウンロードさせるには？**
→ A. Pre-Authenticated Request (PAR)を有効期限付きで作成して共有する

**Q. DBサーバーが最高パフォーマンスのI/Oを必要とする。選択すべきBlock Volumeのパフォーマンスレベルは？**
→ A. Ultra High Performance（VPU 30〜120）

**Q. Archiveから標準アクセスでデータを取り出すにはどうするか？**
→ A. まずRestore操作を実行し（最大1時間かかる）、その後ダウンロードする
