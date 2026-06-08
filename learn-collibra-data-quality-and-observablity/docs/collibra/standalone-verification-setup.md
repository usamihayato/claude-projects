# Collibra DQ フルスタンドアロン 検証環境 セットアップ手順書

> **目的**: 検証用 Linux VM 上に Collibra DQ をフルコンポーネントで構築し、製品の動作確認・ライセンス検証を行う  
> **対象バージョン**: Collibra DQ 2026.02  
> **対象 OS**: RHEL 9.x  
> **公式ドキュメント**: [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm)

---

## 本ドキュメントと azure-vm-setup.md の違い

| 項目 | azure-vm-setup.md（本番想定） | 本ドキュメント（検証用） |
|---|---|---|
| **構成パターン** | Agent Only（DQ Web はグループ会社共用） | **フルスタンドアロン（DQ Web + Agent + Spark + 内部 PostgreSQL）** |
| **Metastore** | Azure DB for PostgreSQL（外部・Private Endpoint） | **Collibra 同梱の内部 PostgreSQL（localhost）** |
| **クラウド依存** | Azure（NSG / Key Vault / Azure Monitor / Runbook） | **なし（汎用 Linux のみ）** |
| **SSL/HTTPS** | 推奨 | **省略（HTTP のみ）** |
| **想定用途** | 本番・ステージング | **動作確認・ライセンス検証・機能評価** |

---

## 構成図

```
検証用 Linux VM（単一台）
┌─────────────────────────────────────────────┐
│                                             │
│  DQ Web（:9000）                            │
│  └─ Spring Boot / REST API / Web UI         │
│                                             │
│  DQ Agent                                   │
│  └─ Metastore をポーリング → Spark ジョブ投入 │
│                                             │
│  Spark Standalone                           │
│  ├─ Master（:7077）                         │
│  └─ Worker                                  │
│                                             │
│  内部 PostgreSQL（:5432）                    │
│  └─ Collibra 同梱の内部 DB（owlmetastore）   │
│                                             │
└─────────────────────────────────────────────┘
```

---

## 目次

1. [事前準備](#1-事前準備)
2. [Java 17 のインストール](#2-java-17-のインストール)
3. [Collibra DQ パッケージの準備](#3-collibra-dq-パッケージの準備)
4. [インストール（setup.sh の実行）](#4-インストールsetupsh-の実行)
5. [ライセンス・起動設定（owl-env.sh）](#5-ライセンス起動設定owl-envsh)
6. [メタストア接続設定（owl.properties）](#6-メタストア接続設定owlproperties)
7. [サービスの起動](#7-サービスの起動)
8. [動作確認](#8-動作確認)
9. [DQ Agent の登録](#9-dq-agent-の登録)
10. [トラブルシューティング](#10-トラブルシューティング)
11. [参考リンク](#11-参考リンク)

---

## 1. 事前準備

### 1.1 前提条件チェックリスト

| 項目 | 確認方法 |
|---|---|
| Linux VM が起動して SSH 接続可能 | `ssh <user>@<VM_IP>` |
| OS ディスクに 100 GB 以上の空き容量 | `df -h /` |
| ライセンスキー（`LICENSE_KEY`）を取得済み | Collibra ライセンスメール |
| ライセンス名（`LICENSE_NAME`）を取得済み | Collibra ライセンスメール |
| インストールパッケージを取得済み | Collibra Product Resource Center |

### 1.2 変数定義

本手順全体で使用する環境変数をまとめて定義する。SSH ログイン後、作業セッション開始時に毎回実行すること。

```bash
# ---- Collibra DQ アプリケーション ----
OWL_BASE="/opt/owl"
DQ_VERSION="2026.02"
DQ_WEB_PORT="9000"

# ---- ライセンス情報（Collibra 社提供） ----
DQ_LICENSE_KEY="<Collibraから提供されたライセンスキー>"
DQ_LICENSE_NAME="<Collibraから提供されたライセンス名>"

# ---- 内部 Metastore（同梱 PostgreSQL） ----
METASTORE_HOST="localhost"
METASTORE_PORT="5432"
METASTORE_DB="owlmetastore"
METASTORE_USER="owluser"
METASTORE_PASS="<任意のパスワード>"   # 後で owlmanage.sh encrypt で暗号化する
```

### 1.3 OS 初期設定

#### ULIMIT 設定

```bash
# 現在値を確認
ulimit -n
# 4096 未満の場合は以下を実行

sudo tee -a /etc/security/limits.conf <<'EOF'
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF

# 設定反映のためシェルを再起動
exec bash -l

# 確認（65536 であること）
ulimit -n
```

#### firewalld ポート開放（firewalld が有効な場合のみ）

```bash
sudo systemctl status firewalld

# DQ Web ポート
sudo firewall-cmd --permanent --add-port="${DQ_WEB_PORT}/tcp"

# Spark Cluster UI ポート
sudo firewall-cmd --permanent --add-port=8080/tcp

sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

#### SELinux の確認

```bash
getenforce
# Enforcing の場合、インストール後に以下を実行
# sudo restorecon -Rv "${OWL_BASE}"

# 検証環境では Permissive でも可
# sudo setenforce 0
```

---

## 2. Java 17 のインストール

Collibra DQ 2026.02 は **Java 17 が必須**。

```bash
# Java 17 インストール
sudo dnf install -y java-17-openjdk-devel

# バージョン確認
java -version
# 期待値: openjdk version "17.x.x" ...

# JAVA_HOME を設定
JAVA_PATH=$(dirname $(dirname $(readlink -f $(which java))))
sudo tee /etc/profile.d/java.sh <<EOF
export JAVA_HOME=${JAVA_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

source /etc/profile.d/java.sh
echo $JAVA_HOME
```

> 複数バージョンが混在する場合は `sudo alternatives --config java` で Java 17 をデフォルトに設定すること。

---

## 3. Collibra DQ パッケージの準備

### 3.1 VM へのファイル転送

ローカル端末からパッケージを VM に転送する。

```bash
# ローカル端末から実行
scp dq-full-package-${DQ_VERSION}.tar.gz <user>@<VM_IP>:/tmp/
```

### 3.2 パッケージの展開

```bash
cd /tmp

# 展開
tar -xvf dq-full-package-${DQ_VERSION}.tar.gz
cd dq

# 展開後の構造確認
ls -la
```

**展開後のディレクトリ構造:**

```
dq/
├── setup.sh           # セットアップスクリプト
├── owlmanage.sh       # 起動・停止・暗号化スクリプト
├── owlcheck           # 動作確認バイナリ
├── bin/               # JAR ファイル
├── config/            # 設定ファイルテンプレート
├── spark/             # Spark バイナリ（同梱版）
└── lib/               # 依存ライブラリ
```

### 3.3 実行権限付与

```bash
chmod +x setup.sh owlmanage.sh owlcheck
```

---

## 4. インストール（setup.sh の実行）

### 4.1 フルスタンドアロン インストールコマンド

`-options` に `postgres` を追加することで Collibra 同梱の内部 PostgreSQL をインストールする。

```bash
cd /tmp/dq

./setup.sh \
  -owlbase="${OWL_BASE}" \
  -options=spark,owlweb,owlagent,postgres \
  -pguser="${METASTORE_USER}" \
  -pgpassword="${METASTORE_PASS}" \
  -pgserver="${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}"
```

**`-options=` の各コンポーネントの役割:**

| 値 | コンポーネント | 役割 |
|---|---|---|
| `spark` | Spark Standalone | データ品質処理の分散実行基盤 |
| `owlweb` | DQ Web | Web UI / REST API サーバー（ポート 9000） |
| `owlagent` | DQ Agent | Metastore をポーリングしてジョブを実行 |
| `postgres` | 内部 PostgreSQL | Collibra 同梱の Metastore 用 DB |

### 4.2 インストール完了の確認

```bash
# インストール先の構造確認
ls -la "${OWL_BASE}/"
```

**期待されるディレクトリ構造:**

```
/opt/owl/
├── bin/
│   ├── owlmanage.sh
│   ├── owlcheck
│   └── owl-core-*-jar-with-dependencies.jar
├── config/
│   ├── owl-env.sh         # 環境変数・起動設定（5章で編集）
│   ├── owl.properties     # Metastore 接続設定（6章で確認）
│   └── log4j*.properties
├── drivers/               # JDBC ドライバー追加用
├── log/
├── pids/
├── spark/
│   └── work/              # Spark 一時ファイル（自動削除されない）
└── owl-postgres/          # 内部 PostgreSQL データディレクトリ
```

```bash
# 主要ファイルの存在確認
ls -la "${OWL_BASE}/bin/owlmanage.sh" \
       "${OWL_BASE}/bin/owlcheck" \
       "${OWL_BASE}/config/owl-env.sh" \
       "${OWL_BASE}/config/owl.properties"

# 内部 PostgreSQL ディレクトリの確認
ls -la "${OWL_BASE}/owl-postgres/"

# Spark バージョン確認
"${OWL_BASE}/spark/bin/spark-submit" --version
# 期待値: version 4.1.0
```

---

## 5. ライセンス・起動設定（owl-env.sh）

### 5.1 owl-env.sh の編集

```bash
sudo vi "${OWL_BASE}/config/owl-env.sh"
```

以下の内容を設定する（既存行を上書き、なければ追記）:

```bash
# ===== ライセンス =====
export LICENSE_KEY="<Collibraから提供されたライセンスキー>"
export LICENSE_NAME="<Collibraから提供されたライセンス名>"

# ===== パス =====
export OWL_BASE=/opt/owl
export SPARK_HOME="${OWL_BASE}/spark"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk   # 2章で確認したパスを設定

# ===== Java 17 対応オプション（2025.02 以降必須） =====
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"

# ===== DQ Web ポート =====
export SERVER_PORT=9000

# ===== メモリ（VM のスペックに応じて調整） =====
export HEAP_MIN_SIZE=2g
export HEAP_MAX_SIZE=8g

# ===== ログ =====
export LOG_DIR="${OWL_BASE}/log"
export LOG_LEVEL=INFO
```

> **JAVA_HOME のパス確認**: `echo $JAVA_HOME` で正しいパスが表示されることを確認してから設定すること。

### 5.2 ライセンスキーの事前確認（任意）

起動前にライセンスキーが有効かどうかを確認できる。

```bash
cd "${OWL_BASE}"
./bin/owlmanage.sh setlic="${DQ_LICENSE_KEY}"
# 期待値: "License Accepted" + 有効期限日
```

### 5.3 パスワードの暗号化

`setup.sh` の `-pgpassword` で指定したパスワードは `owl.properties` に平文で書き込まれている。暗号化して上書きする。

```bash
cd "${OWL_BASE}"

# パスワードを暗号化
./bin/owlmanage.sh encrypt="${METASTORE_PASS}"
# 出力例: ENC(XXXXXXXXXXXXXXXXXXXXXXXXX)

# 出力された ENC(...) をコピーしておく（次章で使用）
```

---

## 6. メタストア接続設定（owl.properties）

`setup.sh` 実行後に生成された `owl.properties` を確認・修正する。

```bash
sudo vi "${OWL_BASE}/config/owl.properties"
```

**フルスタンドアロン構成の設定:**

```properties
# ライセンス名（owl-env.sh の LICENSE_NAME と同じ値）
owldomain=<ライセンス名>

# DQ Web のメタストア接続（内部 PostgreSQL）
spring.datasource.url=jdbc:postgresql://localhost:5432/owlmetastore?currentSchema=public
spring.datasource.username=owluser
spring.datasource.password=ENC(<5章で暗号化したパスワード>)
spring.datasource.driver-class-name=org.postgresql.Driver

# DQ Agent のメタストア接続（同じ内部 PostgreSQL）
spring.agent.datasource.url=jdbc:postgresql://localhost:5432/owlmetastore?currentSchema=public
spring.agent.datasource.username=owluser
spring.agent.datasource.password=ENC(<5章で暗号化したパスワード>)
spring.agent.datasource.driver-class-name=org.postgresql.Driver
```

> **注意**: 外部 PostgreSQL とは異なり、内部 PostgreSQL への接続は `sslmode` を指定しない（または `sslmode=disable`）。

```bash
# 確認（パスワードが ENC(...) 形式になっていること）
grep -E "datasource\.(url|username|password)" "${OWL_BASE}/config/owl.properties"
```

---

## 7. サービスの起動

### 7.1 起動順序

内部 PostgreSQL → DQ Web → DQ Agent の順に起動する。`owlmanage.sh start` は一括起動コマンドだが、内部 PostgreSQL が先に立ち上がるよう設計されている。

```bash
cd "${OWL_BASE}"

# 全コンポーネントを一括起動
./bin/owlmanage.sh start
```

**起動ログの確認:**

```bash
# DQ Web の起動ログをリアルタイムで確認
tail -f "${OWL_BASE}/log/owl-web.log"
```

**起動完了のサイン:**

```
Started OwlApplication in XX.XXX seconds (JVM running for XX.XXX)
```

> 初回起動時はメタストアのスキーマ初期化（テーブル作成など）が実行されるため、通常より時間がかかる（2〜5分程度）。

### 7.2 個別コンポーネントの操作

```bash
# 内部 PostgreSQL のみ起動・停止
./bin/owlmanage.sh start=postgres
./bin/owlmanage.sh stop=postgres

# DQ Web のみ起動・停止
./bin/owlmanage.sh start=owlweb
./bin/owlmanage.sh stop=owlweb

# DQ Agent のみ起動・停止
./bin/owlmanage.sh start=owlagent
./bin/owlmanage.sh stop=owlagent

# 全コンポーネント停止
./bin/owlmanage.sh stop

# 全コンポーネント再起動
./bin/owlmanage.sh restart
```

### 7.3 systemd への登録（VM 再起動後に自動起動させる場合）

```bash
sudo tee /etc/systemd/system/collibra-dq.service <<EOF
[Unit]
Description=Collibra DQ Service
After=network.target

[Service]
Type=forking
User=$(whoami)
WorkingDirectory=${OWL_BASE}
ExecStart=${OWL_BASE}/bin/owlmanage.sh start
ExecStop=${OWL_BASE}/bin/owlmanage.sh stop
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable collibra-dq
sudo systemctl start collibra-dq
sudo systemctl status collibra-dq
```

---

## 8. 動作確認

### 8.1 プロセス確認

```bash
# DQ 関連プロセスが起動していること
ps -ef | grep -E "owl|spark" | grep -v grep

# Java プロセス一覧（DQ Web・Spark が含まれること）
jps -l
```

**期待される出力例:**

```
XXXX org.springframework.boot.loader.JarLauncher   # DQ Web
XXXX org.apache.spark.deploy.master.Master         # Spark Master
XXXX org.apache.spark.deploy.worker.Worker         # Spark Worker
```

### 8.2 ポートの確認

```bash
# LISTEN ポートの確認
ss -tlnp | grep -E "9000|8080|7077|5432"
```

**期待される出力:**

```
LISTEN  0  ...  0.0.0.0:9000   ...   # DQ Web
LISTEN  0  ...  0.0.0.0:8080   ...   # Spark Cluster UI
LISTEN  0  ...  0.0.0.0:7077   ...   # Spark Master
LISTEN  0  ...  127.0.0.1:5432 ...   # 内部 PostgreSQL
```

### 8.3 DQ Web UI へのアクセス確認

ブラウザで以下の URL にアクセスし、ログイン画面が表示されることを確認する。

```
http://<VMのIPアドレス>:9000
```

> 検証用 VM に直接 SSH できる環境ならば、VM 上でも確認可能:
> ```bash
> curl -s http://localhost:${DQ_WEB_PORT}/dq/api/v1/health
> # 期待値: {"status":"UP"} または 200 OK
> ```

**初回ログイン情報（デフォルト）:**

| 項目 | 値 |
|---|---|
| ユーザー名 | `admin` |
| パスワード | `password`（初回ログイン時に変更を求められる） |

**管理者パスワード要件（初回変更時）:**

> **出典**: [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm)

- 8〜72 文字
- 大文字 1 文字以上
- 数字 1 文字以上
- 特殊文字（`!`, `%`, `&`, `@`, `#`, `$`, `^`, `?`, `_`, `~`）1 文字以上

### 8.4 Spark Cluster UI の確認

ブラウザで `http://<VMのIPアドレス>:8080` にアクセスし、以下を確認する。

| 確認項目 | 期待値 |
|---|---|
| Workers | 1 以上が `ALIVE` 状態 |
| Status | `ALIVE` |

### 8.5 ライセンス確認

DQ Web UI ログイン後、右上の **?** → **About** でライセンス情報・バージョンを確認する。

---

## 9. DQ Agent の登録

DQ Web が起動した後、Admin Console から DQ Agent を登録する。

**操作手順（DQ Web UI）:**

1. ブラウザで `http://<VMのIPアドレス>:9000` にログイン
2. 右上の歯車アイコン → **Settings**
3. 左メニュー → **Admin Console** → **Agent Configuration**
4. **Add Agent** をクリックし、以下を入力

| 設定項目 | 入力値 | 説明 |
|---|---|---|
| Agent Display Name | `agent-standalone-01` | 任意の表示名 |
| Base Path | `/opt/owl` | `OWL_BASE` の値 |
| Spark Deployment Mode | `Client` | スタンドアロン構成では `Client` を選択 |
| Number of Executors | `2` | 検証環境では 2〜4 程度で十分 |
| Executor Memory (GB) | `4` | VM の RAM に応じて調整 |
| Driver Memory (GB) | `2` | 検証用途なら 2 GB で十分 |
| Executor Cores | `2` | 検証用途なら 2 コアで十分 |

5. **Save** → Agent Status が **Online** になることを確認

> **Executor メモリの目安**: `numExecutors × executorMemory + driverMemory ≤ VM RAM − HEAP_MAX_SIZE − OS 予約`  
> 例: RAM 32 GB VM の場合: `2 × 4 + 2 = 10 GB`（DQ Web の 8 GB Heap + Agent 用で合計約 18 GB 使用）

### 9.2 agent.properties の確認

Agent 登録後に `agent.properties` が生成（または更新）される。

```bash
cat "${OWL_BASE}/config/agent.properties"
```

**主要設定の確認ポイント:**

```properties
sparksubmitmode=native
sparkhome=/opt/owl/spark
sparkmaster=spark://localhost:7077
numExecutors=2
executorMemory=4g
executorCores=2
driverMemory=2g
```

`sparkmaster` が `spark://localhost:7077` になっていること（フルスタンドアロンではローカルの Spark Master を使用）。

---

## 10. トラブルシューティング

### 10.1 症状別対処表

| 症状 | 主な原因 | 確認コマンド・対処法 |
|---|---|---|
| DQ Web が起動しない | ライセンスキー不正 / HEAP 不足 / ポート競合 | `tail -50 ${OWL_BASE}/log/owl-web.log` |
| 内部 PostgreSQL が起動しない | ディスク容量不足 / パーミッション問題 | `ls -la ${OWL_BASE}/owl-postgres/` / `df -h` |
| Agent が Offline のまま | Metastore 接続失敗 / パスワード暗号化ミス | `tail -20 ${OWL_BASE}/log/owl-agent.log` |
| Spark UI が表示されない | Spark Master が起動失敗 | `ps -ef \| grep spark.deploy.master` |
| ログイン画面が出ない | DQ Web が起動していない / ポート閉鎖 | `ss -tlnp \| grep 9000` / `curl http://localhost:9000` |
| ジョブが RUNNING のまま停止 | Executor 起動失敗 / メモリ不足 | `ps -ef \| grep CoarseGrained` / Spark UI(:8080) 確認 |
| `java.lang.reflect.*` 系エラー | EXTRA_JVM_OPTIONS 未設定 | `grep EXTRA_JVM ${OWL_BASE}/config/owl-env.sh` |
| ULIMIT エラー（too many open files） | ファイルディスクリプタ上限超過 | `ulimit -n`（4096 以上であること） |

### 10.2 デバッグコマンド集

```bash
# ----- ログ確認 -----
# DQ Web のリアルタイムログ
tail -f "${OWL_BASE}/log/owl-web.log"

# DQ Agent のリアルタイムログ
tail -f "${OWL_BASE}/log/owl-agent.log"

# エラーのみ抽出
grep -n "ERROR" "${OWL_BASE}/log/owl-web.log" | tail -30

# ----- プロセス確認 -----
ps -ef | grep -E "owl|spark" | grep -v grep
jps -l

# ----- ネットワーク確認 -----
ss -tlnp | grep -E "9000|8080|7077|5432"

# 内部 PostgreSQL への接続確認
psql -h localhost -p 5432 -U owluser -d owlmetastore -c "\conninfo"

# ----- 設定ファイル確認 -----
grep -E "LICENSE|PORT|HEAP|JAVA_HOME" "${OWL_BASE}/config/owl-env.sh"
grep -E "datasource\.(url|username|password)" "${OWL_BASE}/config/owl.properties"
grep -E "spark|executor|driver" "${OWL_BASE}/config/agent.properties"

# ----- リソース確認 -----
free -h
df -h
du -sh "${OWL_BASE}/log/"*
```

### 10.3 よくある初回起動の失敗パターン

#### パターン A: 内部 PostgreSQL が起動しない

```bash
# PostgreSQL のログを確認
ls "${OWL_BASE}/owl-postgres/"
tail -50 "${OWL_BASE}/log/owl-web.log" | grep -i postgres

# 権限の問題の場合
sudo chown -R $(whoami):$(whoami) "${OWL_BASE}/owl-postgres/"
```

#### パターン B: ライセンスキーエラー

```bash
# ライセンスキーを再設定
cd "${OWL_BASE}"
./bin/owlmanage.sh setlic="${DQ_LICENSE_KEY}"
# "License Accepted" が出力されること

# owl-env.sh の設定を再確認
grep -E "LICENSE_KEY|LICENSE_NAME" "${OWL_BASE}/config/owl-env.sh"
```

#### パターン C: DQ Web は起動するが Agent が Offline

```bash
# owl.properties の接続設定確認
grep "spring.agent.datasource" "${OWL_BASE}/config/owl.properties"

# パスワードが ENC(...) 形式か確認
# 平文のままの場合は 5章の暗号化手順を再実施すること
```

#### パターン D: Spark Master に接続できない

```bash
# agent.properties の sparkmaster 確認
grep sparkmaster "${OWL_BASE}/config/agent.properties"
# → spark://localhost:7077 であること

# Spark Master プロセス確認
ps -ef | grep "spark.deploy.master.Master" | grep -v grep

# Spark Master が起動していない場合、手動で起動
"${OWL_BASE}/spark/sbin/start-master.sh"
```

---

## 11. 参考リンク

| ドキュメント | URL |
|---|---|
| スタンドアロンインストール | [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm) |
| 初期セットアップ完了 | [Complete the initial setup](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) |
| 設定オプション一覧 | [Configuration options](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) |
| Agent 設定 | [Configure agent](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_configure-agent.htm) |
| ディレクトリ構造 | [Directory structure](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ref_directory-structure.htm) |
| トラブルシューティング | [Troubleshooting](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-troubleshooting.htm) |
| インストール前提条件 | [Before you install](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-before-you-install.htm) |

---

> **本番環境への適用時の注意**: 本ドキュメントは検証を目的としており、SSL/HTTPS・Key Vault・バックアップ自動化・監視設定は省略している。本番環境への展開時は `azure-vm-setup.md` を参照のこと。
