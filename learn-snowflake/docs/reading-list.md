# SnowPro Core (COF-C03) 公式ドキュメント読み込みリスト

本リストは、SnowPro Core認定資格（COF-C03）の出題分野に沿って、公式ドキュメント（docs.snowflake.com/ja）の中から基礎固めに読むべきページを整理したものです。分野・サブトピックの構成は公式試験学習ガイド（`../snowflake-docs/SnowProCoreStudyGuideC03_JPN.pdf`、2026-02-20最終更新）の目次に準拠しています。掲載URLはすべて実在確認済みです。

---

## 0. 試験概要・分野別配点

| 分野 | 配点 |
|---|---|
| 1.0 Snowflake AIデータクラウドの機能とアーキテクチャ | 31% |
| 2.0 アカウント管理およびデータガバナンス | 20% |
| 3.0 データのロード、アンロード、および接続 | 18% |
| 4.0 パフォーマンス最適化、クエリ、および変換 | 21% |
| 5.0 データコラボレーション | 10% |

**読み込み方針**: 配点の高い分野1・4から着手し、各ページを読んだあとに `notes.md`（別途作成予定）へ要点をまとめる。Udemyの模擬試験で誤答した論点があれば、対応する分野のページへ立ち戻って復習する。

---

## 1. Snowflake AIデータクラウドの機能とアーキテクチャ（31%）

### 1.1 Snowflakeアーキテクチャの説明と使用

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/intro-key-concepts | 重要な概念およびアーキテクチャ | 3層アーキテクチャ（クラウドサービス層/コンピュート層/ストレージ層） |
| https://docs.snowflake.com/ja/user-guide/intro-editions | Snowflakeエディション | エディション比較 |

### 1.2 Snowflakeのインターフェースおよびツールの使用

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/ui-snowsight | Snowsight: Snowflakeウェブインターフェイス | Snowsight |
| https://docs.snowflake.com/ja/developer-guide/snowflake-cli/index | Snowflake CLI | Snowflake CLI |
| https://docs.snowflake.com/ja/user-guide/vscode-ext | Visual Studio Code SQL 拡張機能 | IDE連携（VS Code） |

### 1.3 Snowflakeオブジェクト階層およびタイプの区別

参照: 1.1の `intro-key-concepts`（組織/アカウント/データベースオブジェクトの階層を含む）

### 1.4 仮想ウェアハウスの構成

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/warehouses-overview | ウェアハウスの概要 | ウェアハウスサイズ、自動一時停止/再開 |
| https://docs.snowflake.com/ja/user-guide/warehouses-considerations | ウェアハウスに関する考慮事項 | ユースケース別構成、ベストプラクティス |
| https://docs.snowflake.com/ja/user-guide/warehouses-multicluster | マルチクラスターウェアハウス | スケーリングポリシー、スケールイン/アウト |

### 1.5 Snowflakeストレージ概念の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/tables-clustering-micropartitions | マイクロパーティションとデータクラスタリング | マイクロパーティション、データクラスタリング |
| https://docs.snowflake.com/ja/user-guide/tables-temp-transient | 仮テーブルと一時テーブルの使用 | Temporary/Transientテーブル |
| https://docs.snowflake.com/ja/user-guide/views-introduction | ビューの概要 | 標準ビュー/マテリアライズドビュー/セキュアビュー |

### 1.6 AI/MLおよびアプリケーション開発機能の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/snowflake-cortex/overview | Snowflake AI と ML | Snowflake Cortex（AI SQL関数、Cortex Search、Cortex Analyst） |
| https://docs.snowflake.com/ja/developer-guide/snowpark/index | Snowpark API | Snowpark |
| https://docs.snowflake.com/ja/developer-guide/streamlit/about-streamlit | Streamlit in Snowflake について | Streamlit in Snowflake |
| https://docs.snowflake.com/ja/user-guide/ui-snowsight/notebooks-in-workspaces/notebooks-in-workspaces-overview | ワークスペースのSnowflake Notebooks | Snowflake Notebook |

---

## 2. アカウント管理およびデータガバナンス（20%）

### 2.1 Snowflakeのセキュリティモデルと原則の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/security-access-control-overview | アクセス制御の概要 | RBAC、DAC、セキュア化可能オブジェクトの階層、ロール種別 |
| https://docs.snowflake.com/ja/user-guide/admin-account-identifier | アカウント識別子 | アカウント識別子 |
| https://docs.snowflake.com/ja/user-guide/security-mfa | 多要素認証（MFA） | 認証（MFA） |

### 2.2 データガバナンス機能とその使用方法の定義

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/security-column-intro | 列レベルのセキュリティについて | 列レベルのデータマスキング |
| https://docs.snowflake.com/ja/user-guide/security-row-intro | 行アクセスポリシーについて | 行レベルのセキュリティ |
| https://docs.snowflake.com/ja/user-guide/object-tagging | オブジェクトタグの紹介 | オブジェクトのタグ付け |
| https://docs.snowflake.com/ja/user-guide/trust-center/overview | トラストセンター | Trust Center |
| https://docs.snowflake.com/ja/user-guide/account-replication-intro | 複数のアカウント間にわたる複製とフェールオーバーの概要 | データレプリケーションとフェールオーバー |

### 2.3 監視およびコスト管理の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/resource-monitors | リソースモニターの操作 | リソースモニター、クレジット使用状況 |
| https://docs.snowflake.com/ja/sql-reference/account-usage | Account Usage | ACCOUNT_USAGEスキーマ |
| https://docs.snowflake.com/ja/user-guide/budgets | Budgetsを使用したクレジット使用状況のモニター | 予算（Budgets） |

---

## 3. データのロード、アンロード、および接続（18%）

### 3.1 データのロードおよびアンロードの実行

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/data-load-overview | データのロードの概要 | ロード方法全般、ステージ、一括/連続ロード |
| https://docs.snowflake.com/ja/user-guide/data-load-local-file-system-create-stage | ローカルファイルに対する内部ステージの選択 | 内部ステージ |
| https://docs.snowflake.com/ja/sql-reference/sql/copy-into-table | COPY INTO &lt;テーブル&gt; | COPY INTOコマンド、エラー処理オプション |

### 3.2 自動データ取り込みの実行

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/data-load-snowpipe-intro | Snowpipe | Snowpipe |
| https://docs.snowflake.com/ja/user-guide/data-load-snowpipe-streaming-overview | Snowpipe Streaming | Snowpipe Streaming |
| https://docs.snowflake.com/ja/user-guide/streams-intro | ストリームの紹介 | ストリーム |
| https://docs.snowflake.com/ja/user-guide/tasks-intro | タスクの紹介 | タスク |
| https://docs.snowflake.com/ja/user-guide/dynamic-tables-about | 動的テーブル | ダイナミックテーブル |

### 3.3 各種Snowflakeコネクタおよび統合の識別

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/developer-guide/drivers | ドライバー | Snowflakeドライバー・コネクタ |
| https://docs.snowflake.com/ja/user-guide/data-load-s3-config | Amazon S3へのセキュアアクセスの構成 | ストレージ統合 |
| https://docs.snowflake.com/ja/sql-reference/sql/create-api-integration | CREATE API INTEGRATION | API統合 |

---

## 4. パフォーマンス最適化、クエリ、および変換（21%）

### 4.1 クエリパフォーマンスの評価

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/ui-query-profile | クエリ履歴でクエリのアクティビティをモニターする | クエリプロファイル/クエリインサイト |
| https://docs.snowflake.com/ja/sql-reference/account-usage/query_history | QUERY_HISTORY ビュー | ACCOUNT_USAGEビュー（クエリ属性・履歴） |

### 4.2 クエリパフォーマンスの最適化

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/query-acceleration-service | Query Acceleration Serviceの使用（QAS） | クエリアクセラレーションサービス |
| https://docs.snowflake.com/ja/user-guide/search-optimization-service | 検索最適化サービス | 検索最適化サービス |
| https://docs.snowflake.com/ja/user-guide/tables-clustering-keys | クラスタリングキーとクラスタ化されたテーブル | クラスタリングキー |
| https://docs.snowflake.com/ja/user-guide/views-materialized | マテリアライズドビューの使用 | マテリアライズドビュー |

### 4.3 Snowflakeキャッシュの使用

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/querying-persisted-results | 保存済みのクエリ結果の使用 | クエリ結果キャッシュ |

### 4.4 データ変換手法の実行

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/querying-semistructured | 半構造化データのクエリ | 半構造化データの使用 |
| https://docs.snowflake.com/ja/sql-reference/functions-aggregation | 集計関数 | 集計関数 |
| https://docs.snowflake.com/ja/sql-reference/functions-window | ウィンドウ関数 | ウィンドウ関数 |

---

## 5. データコラボレーション（10%）

### 5.1 データコラボレーションと保護の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/data-sharing-intro | Secure Data Sharingについて | Secure Data Sharing機能 |
| https://docs.snowflake.com/ja/sql-reference/sql/create-clone | CREATE &lt;オブジェクト&gt; ... CLONE | クローニング |
| https://docs.snowflake.com/ja/user-guide/data-time-travel | Time Travelの理解と使用 | Time Travel |
| https://docs.snowflake.com/ja/user-guide/data-failsafe | Fail-safeの理解と表示 | Fail-Safe |

### 5.2 Snowflakeのデータシェアリング機能の説明

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/data-sharing-reader-create | リーダーアカウントを管理する | リーダーアカウント |
| https://docs.snowflake.com/ja/user-guide/cleanrooms/introduction | Snowflake Data Clean Rooms について | データクリーンルーム |

### 5.3 Snowflakeマーケットプレイスおよびリスティングを使用したデータ共有

| URL | タイトル | 対応トピック |
|---|---|---|
| https://docs.snowflake.com/ja/user-guide/data-marketplace-intro | Snowflake Marketplace について | Snowflakeマーケットプレイス、リスティング |
| https://docs.snowflake.com/ja/developer-guide/native-apps/native-apps-about | Snowflake Native App Framework について | ネイティブアプリ |
