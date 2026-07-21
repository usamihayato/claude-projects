# Collibra DQ Standalone 本番セットアップ手順書（Agent + Spark）

> **目的**: 本番用 Linux VM 上に Collibra DQ Agent と Spark Standalone を構築する  
> **対象バージョン**: Collibra DQ 2026.02  
> **対象 OS**: RHEL 9.x  
> **公式ドキュメント**: [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm)

---

## 既存ドキュメントとの対比

| 項目 | standalone-verification-setup.md | azure-vm-setup.md | **本ドキュメント（本番用）** |
|---|---|---|---|
| **構成** | DQ Web + Agent + Spark + 内部 PostgreSQL | Agent + Spark（Azure 依存あり） | **Agent + Spark のみ** |
| **Metastore** | 内部 PostgreSQL（localhost） | Azure DB for PostgreSQL | **外部 PostgreSQL** |
| **セットアップ時の起動** | 自動起動あり | 自動起動あり | **設定完了後に手動起動** |
| **クラウド依存** | なし | Azure（Key Vault / NSG 等） | **なし** |
| **用途** | 機能検証・ライセンス確認 | Azure 本番 | **汎用本番環境** |

---

## 構成図

```
本番用 Linux VM（単一台）
┌──────────────────────────────────────────┐
│                                          │
│  DQ Agent                                │
│  └─ 外部 DQ Web からジョブを受信 → Spark 投入 │
│                                          │
│  Spark Standalone                        │
│  ├─ Master（:7077）                      │
│  └─ Worker                               │
│                                          │
└──────────────────────────────────────────┘
         │
         │ JDBC（sslmode=require）
         ▼
外部 PostgreSQL（owlmetastore）

         ↕ Agent 登録・ジョブ指示
外部 DQ Web（別 VM / 既存環境）
```

> **DQ Web はこの VM に存在しない。**  
> Agent は外部の DQ Web（グループ会社共用 等）に登録して使用する。

---

## 目次

1. [前提条件](#1-前提条件)
2. [変数定義](#2-変数定義)
3. [事前準備（OS 設定）](#3-事前準備os-設定)
4. [Java 17 のインストール](#4-java-17-のインストール)
5. [Collibra DQ パッケージの準備](#5-collibra-dq-パッケージの準備)
6. [インストール（setup.sh）](#6-インストールsetupsh)
7. [ライセンス・起動設定（owl-env.sh）](#7-ライセンス起動設定owl-envsh)
8. [メタストア接続設定（owl.properties）](#8-メタストア接続設定owlproperties)
9. [Spark 実行環境の設定（agent.properties）](#9-spark-実行環境の設定agentproperties)
10. [サービスの起動](#10-サービスの起動)
11. [systemd 登録（オプション）](#11-systemd-登録オプション)
12. [動作確認](#12-動作確認)
13. [DQ Web への Agent 登録](#13-dq-web-への-agent-登録)
14. [ログローテーション設定](#14-ログローテーション設定)
15. [トラブルシューティング](#15-トラブルシューティング)

---

## 1. 前提条件

### チェックリスト

- [ ] RHEL 9.x サブスクリプション有効（PAYG または BYOS）
- [ ] Java 17 インストール可能（dnf リポジトリ疎通 または RPM 入手済み）
- [ ] Collibra DQ 2026.02 インストーラー（tarball）を入手済み
- [ ] ライセンスキー・ライセンス名を Collibra から入手済み
- [ ] 外部 PostgreSQL ホストへの疎通確認（ポート 5432）
- [ ] 外部 PostgreSQL に `owlmetastore` データベースおよびユーザー作成済み
- [ ] 外部 DQ Web の URL・接続情報を確認済み

### ハードウェア要件（推奨）

| リソース | 最小 | 推奨 |
|---|---|---|
| vCPU | 4 | 8 |
| メモリ | 16 GB | 32 GB |
| ストレージ | 100 GB | 200 GB |

---

## 2. 変数定義

以降のコマンドで使用する変数を定義する。実環境に合わせて値を変更すること。

```bash
# ===== インストール設定 =====
export OWL_BASE="/opt/owl"
export OWL_USER="owl"
export DQ_INSTALL_DIR="/tmp/dq"

# ===== ライセンス =====
export DQ_LICENSE_KEY="<Collibraから提供されたライセンスキー>"
export DQ_LICENSE_NAME="<Collibraから提供されたライセンス名>"

# ===== 外部 PostgreSQL（Metastore） =====
export METASTORE_HOST="<外部 PostgreSQL のホスト名または IP>"
export METASTORE_PORT="5432"
export METASTORE_DB="owlmetastore"
export METASTORE_USER="owluser"
export METASTORE_PASS="<MetastoreのPAスワード（平文）>"

# ===== Java =====
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
```

---

## 3. 事前準備（OS 設定）

### 3.1 ULIMIT 設定

```bash
sudo tee -a /etc/security/limits.conf <<'EOF'
# Collibra DQ: ファイルディスクリプタ上限
*  soft  nofile  65536
*  hard  nofile  65536
EOF
```

> **公式要件**: `nofile` は **4096 以上**（Collibra 公式 Upgrade requirements より）。  
> 本手順では余裕を見て 65536 を設定しているが、4096 でも公式要件は満たす。  
> soft と hard を同じ値にすることで、起動スクリプト経由の起動時も確実に適用される。

設定反映の確認（再ログイン後）:

```bash
ulimit -n
# → 65536
```

### 3.2 実行ユーザーの作成

```bash
sudo useradd -m -s /bin/bash "${OWL_USER}"
```

### 3.3 インストールディレクトリの作成

```bash
sudo mkdir -p "${OWL_BASE}"
sudo chown "${OWL_USER}:${OWL_USER}" "${OWL_BASE}"
```

### 3.4 外部 PostgreSQL の疎通確認

```bash
# ポート疎通確認
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}"

# psql で接続確認（psql クライアントがある場合）
psql "host=${METASTORE_HOST} port=${METASTORE_PORT} dbname=${METASTORE_DB} user=${METASTORE_USER}" -c "\conninfo"
```

---

## 4. Java 17 のインストール

```bash
# インストール
sudo dnf install -y java-17-openjdk-devel

# バージョン確認
java -version
# → openjdk version "17.x.x"

# JAVA_HOME 確認
ls "${JAVA_HOME}/bin/java"
```

---

## 5. Collibra DQ パッケージの準備

```bash
# 作業ディレクトリ作成
mkdir -p "${DQ_INSTALL_DIR}"

# tarball を転送（SCP の例）
# scp collibra-dq-2026.02.tar.gz <user>@<vm>:"${DQ_INSTALL_DIR}/"

# 展開
cd "${DQ_INSTALL_DIR}"
tar -xzf collibra-dq-2026.02.tar.gz

# 実行権限付与
chmod +x setup.sh
chmod +x *.sh 2>/dev/null || true
```

---

## 6. インストール（setup.sh）

### 6.1 setup.sh の実行

`owl` ユーザーで実行する。`-options=spark,owlagent` のみ指定し、`owlweb` および `postgres` は**指定しない**。

```bash
sudo -u "${OWL_USER}" bash -c "
  cd '${DQ_INSTALL_DIR}' && \
  ./setup.sh \
    -owlbase='${OWL_BASE}' \
    -options=spark,owlagent \
    -pguser='${METASTORE_USER}' \
    -pgpassword='${METASTORE_PASS}' \
    -pgserver='${METASTORE_HOST}:${METASTORE_PORT}/${METASTORE_DB}'
"
```

| `-options=` の値 | 説明 |
|---|---|
| `spark` | Spark Standalone（Master + Worker）バイナリをインストール |
| `owlagent` | DQ Agent をインストール |
| ~~`owlweb`~~ | ~~DQ Web~~ — **本番では不要（別 VM に存在）** |
| ~~`postgres`~~ | ~~内部 PostgreSQL~~ — **外部 PostgreSQL を使用するため不要** |

### 6.2 インストール後の自動起動を停止

setup.sh 完了後にサービスが自動起動している場合は**即時停止**する（設定完了前に起動させない）。

```bash
"${OWL_BASE}/bin/owlmanage.sh" stop
```

### 6.3 インストール確認

```bash
ls -la "${OWL_BASE}/bin/"
# owlmanage.sh, owl-env.sh 等が存在すること

ls -la "${OWL_BASE}/spark/sbin/"
# start-master.sh, start-worker.sh 等が存在すること
```

---

## 7. ライセンス・起動設定（owl-env.sh）

### 7.1 owl-env.sh の編集

```bash
sudo -u "${OWL_USER}" vi "${OWL_BASE}/config/owl-env.sh"
```

以下の内容を設定する（既存の項目を上書きまたは追記）:

```bash
# ===== ライセンス =====
export LICENSE_KEY="<DQ_LICENSE_KEY の値>"
export LICENSE_NAME="<DQ_LICENSE_NAME の値>"

# ===== パス =====
export OWL_BASE=/opt/owl
export SPARK_HOME="${OWL_BASE}/spark"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk

# ===== Java 17 対応オプション（2026.02 必須） =====
# 検証環境での実機確認済みの値を使用すること
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.net=ALL-UNNAMED \
  --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
  --add-opens java.base/java.nio=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"

# ===== メモリ =====
export HEAP_MIN_SIZE=2g
export HEAP_MAX_SIZE=8g

# ===== ログ =====
export LOG_DIR="${OWL_BASE}/log"
export LOG_LEVEL=INFO
```

> **注意**: `SERVER_PORT` は DQ Web が存在しないため設定不要。

### 7.2 ライセンスキーの設定

```bash
cd "${OWL_BASE}/bin"
./owlmanage.sh setlic="${DQ_LICENSE_KEY}"
# → "License Accepted" と表示されれば成功
# ※ SLF4J の警告（No SLF4J providers were found）は正常。エラーではない。
```

---

## 8. メタストア接続設定（owl.properties）

### 8.1 パスワードの暗号化

**平文パスワードをそのまま設定しないこと。** 必ず暗号化して `ENC(...)` 形式で設定する。

```bash
cd "${OWL_BASE}/bin"
./owlmanage.sh encrypt="${METASTORE_PASS}"
```

出力例:

```
FIZGz/8aBcDeFgHiJkLmNoPqRsTuVwXyZ==
```

この出力文字列を手動で `ENC(...)` で囲む（ツールは `ENC()` を付けない）:

```
ENC(FIZGz/8aBcDeFgHiJkLmNoPqRsTuVwXyZ==)
```

### 8.2 owl.properties の編集

```bash
sudo -u "${OWL_USER}" vi "${OWL_BASE}/config/owl.properties"
```

**Agent Only 構成のため `spring.agent.datasource` のみ設定する**（`spring.datasource` は DQ Web 用のため不要）。

```properties
# ライセンス名
owldomain=<DQ_LICENSE_NAME の値>

# DQ Agent のメタストア接続（外部 PostgreSQL）
spring.agent.datasource.url=jdbc:postgresql://<METASTORE_HOST>:5432/owlmetastore?currentSchema=public&sslmode=require
spring.agent.datasource.username=owluser
spring.agent.datasource.password=ENC(<暗号化済み文字列>)
spring.agent.datasource.driver-class-name=org.postgresql.Driver
```

#### sslmode の選択肢

| sslmode | 説明 | 適用場面 |
|---|---|---|
| `require` | SSL 必須（証明書検証なし） | **外部 PostgreSQL（推奨）** |
| `verify-ca` | CA 証明書を検証 | 社内 CA を使用する場合 |
| `disable` | SSL 無効 | ローカル環境のみ（本番では非推奨） |

#### 設定確認

```bash
grep -E "spring.agent.datasource|owldomain" "${OWL_BASE}/config/owl.properties"
```

---

## 9. Spark 実行環境の設定（agent.properties）

setup.sh が `sparkmaster=yarn` をデフォルト設定している場合は、**Spark Standalone に変更する**。

```bash
grep "sparkmaster" "${OWL_BASE}/config/agent.properties"
```

`yarn` または `yarn-client` が設定されている場合は修正:

```bash
sudo -u "${OWL_USER}" sed -i \
  "s|^sparkmaster=.*|sparkmaster=spark://$(hostname -f):7077|" \
  "${OWL_BASE}/config/agent.properties"

# 確認
grep "sparkmaster" "${OWL_BASE}/config/agent.properties"
# → sparkmaster=spark://<hostname>:7077
```

> DQ Web UI の Agent 設定画面（Admin Console → Agents → Spark Master URL）からも変更可能。

---

## 10. サービスの起動

> **重要**: `owlmanage.sh start` は Spark（Master・Worker）を自動起動しない。  
> Spark は `spark/sbin/` スクリプトで手動起動する必要がある。

### 10.1 起動ラッパースクリプトの作成

```bash
sudo tee "${OWL_BASE}/bin/start-dq.sh" <<'EOF'
#!/bin/bash
set -e
OWL_BASE="/opt/owl"

echo "[1/3] Spark Master 起動..."
"${OWL_BASE}/spark/sbin/start-master.sh"

echo "[2/3] Spark Worker 起動..."
"${OWL_BASE}/spark/sbin/start-worker.sh" "spark://$(hostname -f):7077"

echo "[3/3] DQ Agent 起動（5秒待機後）..."
sleep 5
"${OWL_BASE}/bin/owlmanage.sh" start=owlagent

echo "起動完了"
EOF

sudo chmod +x "${OWL_BASE}/bin/start-dq.sh"
sudo chown "${OWL_USER}:${OWL_USER}" "${OWL_BASE}/bin/start-dq.sh"
```

### 10.2 停止スクリプトの作成

```bash
sudo tee "${OWL_BASE}/bin/stop-dq.sh" <<'EOF'
#!/bin/bash
OWL_BASE="/opt/owl"

echo "[1/2] DQ Agent 停止..."
"${OWL_BASE}/bin/owlmanage.sh" stop=owlagent || true

echo "[2/2] Spark 停止..."
"${OWL_BASE}/spark/sbin/stop-all.sh"

echo "停止完了"
EOF

sudo chmod +x "${OWL_BASE}/bin/stop-dq.sh"
sudo chown "${OWL_USER}:${OWL_USER}" "${OWL_BASE}/bin/stop-dq.sh"
```

### 10.3 起動実行

```bash
sudo -u "${OWL_USER}" "${OWL_BASE}/bin/start-dq.sh"
```

---

## 11. systemd 登録（オプション）

VM 再起動時の自動起動が必要な場合に設定する。

```bash
sudo tee /etc/systemd/system/collibra-dq.service <<EOF
[Unit]
Description=Collibra DQ Agent + Spark
After=network.target

[Service]
Type=forking
User=${OWL_USER}
WorkingDirectory=${OWL_BASE}
ExecStart=${OWL_BASE}/bin/start-dq.sh
ExecStop=${OWL_BASE}/bin/stop-dq.sh
TimeoutStartSec=120
TimeoutStopSec=60
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable collibra-dq
```

手動操作:

```bash
sudo systemctl start collibra-dq
sudo systemctl stop collibra-dq
sudo systemctl status collibra-dq
```

---

## 12. 動作確認

### 12.1 プロセス確認

```bash
# DQ Agent
ps -ef | grep owlagent | grep -v grep

# Spark Master
ps -ef | grep "spark.deploy.master.Master" | grep -v grep

# Spark Worker
ps -ef | grep "spark.deploy.worker.Worker" | grep -v grep
```

### 12.2 ポート確認

| ポート | コンポーネント | 確認コマンド |
|---|---|---|
| 7077 | Spark Master（Agent 接続先） | `ss -tlnp \| grep 7077` |
| 8080 | Spark Web UI | `ss -tlnp \| grep 8080` |
| 7007 | DQ Agent | `ss -tlnp \| grep 7007` |

```bash
ss -tlnp | grep -E "7077|8080|7007"
```

### 12.3 Spark Web UI 確認

```bash
curl -s http://localhost:8080 | grep -o "<title>.*</title>"
# → <title>Spark Master at spark://...</title>
```

### 12.4 外部 PostgreSQL 接続確認

Agent ログに接続エラーがないか確認:

```bash
tail -50 "${OWL_BASE}/log/owl-agent.log" | grep -iE "error|exception|connect"
```

### 12.5 Agent ログの正常パターン

```bash
tail -f "${OWL_BASE}/log/owl-agent.log"
```

正常時の出力例:

```
... Started OwlAgent in xx.xxx seconds
... Agent polling started
```

---

## 13. DQ Web への Agent 登録

この VM には DQ Web が存在しないため、**外部の DQ Web の Admin Console** から登録する。

### 13.1 Admin Console での登録手順

1. 外部 DQ Web にログイン（Admin 権限が必要）
2. `Admin` → `Agents` → `New Agent` を選択
3. 以下を入力:

| 項目 | 入力値 |
|---|---|
| **Agent Host** | この VM の IP またはホスト名 |
| **Agent Port** | `7007` |
| **Spark Master URL** | `spark://<この VM の FQDN>:7077` |

4. `Save` → `Online` 表示になれば登録完了

### 13.2 Agent のオンライン確認

```bash
# Agent ログで接続状態を確認
grep -i "online\|register\|connect" "${OWL_BASE}/log/owl-agent.log" | tail -20
```

---

## 14. ログローテーション設定

DQ のログファイルは自動ローテされない。`logrotate` を設定する。

```bash
sudo tee /etc/logrotate.d/collibra-dq <<'EOF'
/opt/owl/log/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
```

> **`copytruncate` が必須な理由**: Java プロセス（DQ Agent）はログファイルを起動時に開いたまま保持する。  
> 通常の `rename + create` 方式ではプロセスが古いファイルへ書き続けるため、  
> `copytruncate`（コピーしてから元ファイルを 0 バイトに切り詰める）を使用する必要がある。

動作確認:

```bash
sudo logrotate -d /etc/logrotate.d/collibra-dq   # ドライラン
sudo logrotate -f /etc/logrotate.d/collibra-dq   # 強制実行
```

---

## 15. トラブルシューティング

### 15.1 症状別対処表

| 症状 | 原因 | 対処 |
|---|---|---|
| Spark Master が起動しない | `start-master.sh` 未実行 | `"${OWL_BASE}/spark/sbin/start-master.sh"` を手動実行 |
| Spark UI（:8080）に接続できない | Spark Master が起動していない | ポート確認: `ss -tlnp \| grep 8080` |
| Agent が Offline のまま | `sparkmaster=yarn` のまま | `agent.properties` の `sparkmaster` を `spark://hostname:7077` に変更 |
| Metastore 接続エラー | 外部 PostgreSQL への疎通不可 / sslmode 不一致 | `nc -zv ${METASTORE_HOST} 5432` で疎通確認 |
| パスワード認証エラー | `ENC(...)` 形式になっていない | `owl.properties` の `password` が `ENC(...)` で囲まれているか確認 |
| `java.lang.reflect.*` 系エラー | `EXTRA_JVM_OPTIONS` 未設定 | `owl-env.sh` の `EXTRA_JVM_OPTIONS` 設定を確認 |
| ULIMIT エラー（too many open files） | ファイルディスクリプタ上限超過 | `ulimit -n`（4096 以上であること）/ limits.conf の設定を再確認 |
| ジョブが RUNNING のまま停止 | Spark Executor 起動失敗 / メモリ不足 | Spark UI（:8080）で Executor 状態を確認 |

### 15.2 デバッグコマンド集

```bash
# Agent ログをリアルタイム確認
tail -f "${OWL_BASE}/log/owl-agent.log"

# Spark Master ログ確認
tail -f "${OWL_BASE}/spark/logs/spark-*-org.apache.spark.deploy.master.Master-*.out"

# Spark Worker ログ確認
tail -f "${OWL_BASE}/spark/logs/spark-*-org.apache.spark.deploy.worker.Worker-*.out"

# 全ポート確認
ss -tlnp | grep -E "7077|7007|8080"

# 外部 PostgreSQL 疎通確認
nc -zv "${METASTORE_HOST}" "${METASTORE_PORT}" && echo "OK" || echo "NG"

# ライセンス確認
cd "${OWL_BASE}/bin" && ./owlmanage.sh setlic="${DQ_LICENSE_KEY}"

# ULIMIT 確認（owl ユーザーで実行）
sudo -u "${OWL_USER}" bash -c "ulimit -n"
```

### 15.3 owlmanage.sh の PostgreSQL パスに関する注意

setup.sh が内部 PostgreSQL を想定した古いパス（例: `pgsql-12`）を owlmanage.sh に書き込む場合がある。  
外部 PostgreSQL を使用する本番構成では内部 PostgreSQL を使用しないため影響はないが、  
`owlmanage.sh start=postgres` や `stop=postgres` を実行するとエラーになる点に注意する。

---

## 参考リンク

- [Collibra DQ インストール（Standalone）](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm)
- [Collibra DQ システム要件](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/co_system-requirements.htm)
- [検証環境セットアップ手順書](./standalone-verification-setup.md)
- [Azure VM セットアップ手順書](./azure-vm-setup.md)
