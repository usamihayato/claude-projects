# Collibra Data Quality & Observability Classic セットアップ手順

> **対象バージョン**: 2026.02（最新）  
> **作成日**: 2026-04-13  
> **対象読者**: 社内導入担当SE（Azure / AKS 基盤）

---

## 目次

1. [前提条件チェックリスト](#1-前提条件チェックリスト)
2. [スタンドアロンインストール](#2-スタンドアロンインストール)
3. [Kubernetes（AKS）インストール](#3-kubernetesaksインストール)
4. [DQ Agent セットアップ](#4-dq-agent-セットアップ)
5. [主要設定ファイル リファレンス](#5-主要設定ファイル-リファレンス)
6. [PostgreSQL メタストア設定](#6-postgresql-メタストア設定)
7. [SSL / HTTPS 設定](#7-ssl--https-設定)
8. [アップグレード手順](#8-アップグレード手順)

---

## 1. 前提条件チェックリスト

### OS・ブラウザ

| 項目 | 要件 |
|------|------|
| **OS** | RHEL 8.x / 9.x |
| **ブラウザ** | Chrome 70.0+、Firefox 52.8+、Safari 12.0.1+ |

### Java・Spark バージョン互換表

| DQ バージョン | Java | Spark |
|-------------|------|-------|
| **2026.02 以降** | **17** | **4.1.0** |
| 2025.08 〜 2026.01 | 17 | 3.5.6 |
| 2025.02 〜 2025.07 | 17 | 3.5.3 |
| 2025.01 以前 | 8 / 11 | 2.3.0 〜 3.4.1 |

### ハードウェア（スタンドアロン）

| 規模 | CPU | RAM |
|------|-----|-----|
| 小規模 | 16コア | 128 GB |
| 中規模 | 32コア | 256 GB |
| 大規模 | 64コア | 512 GB |

### ソフトウェア前提条件

```bash
# Java 17 インストール確認
java -version

# ULIMIT 確認（4096 以上であること）
ulimit -n

# ULIMIT を恒久的に設定する場合（/etc/security/limits.conf に追記）
echo "* soft nofile 4096" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 4096" | sudo tee -a /etc/security/limits.conf
```

### 権限要件

| 構成 | SUDO 権限 |
|------|----------|
| 内部 PostgreSQL を使用するスタンドアロン | **必須** |
| 外部 PostgreSQL を使用するスタンドアロン | 不要（推奨） |
| Kubernetes | 不要 |

---

## 2. スタンドアロンインストール

### ステップ 1: 環境変数の設定

```bash
export OWL_BASE=/opt/owl                   # インストール先ディレクトリ
export OWL_METASTORE_USER=owl             # PostgreSQL ユーザー名
export OWL_METASTORE_PASS=<password>      # PostgreSQL パスワード
```

### ステップ 2: パッケージのダウンロード・展開

Collibra Product Resource Center からフルパッケージをダウンロードし、展開する。

```bash
tar -xvf dq-full-package.tar.gz
cd dq
```

### ステップ 3: セットアップスクリプト実行

**内部 PostgreSQL を使用する場合**（SUDO 権限が必要）:

```bash
./setup.sh \
  -owlbase=$OWL_BASE \
  -user=$OWL_METASTORE_USER \
  -pgpassword=$OWL_METASTORE_PASS \
  -options=postgres,spark,owlweb,owlagent
```

**外部 PostgreSQL を使用する場合**（推奨）:

```bash
./setup.sh \
  -owlbase=$OWL_BASE \
  -user=$OWL_METASTORE_USER \
  -pgpassword=$OWL_METASTORE_PASS \
  -options=spark,owlweb,owlagent \
  -pgserver="<host>:<port>/<database>"
```

**主要なオプション引数**:

| パラメータ | 例 | 説明 |
|-----------|-----|------|
| `-owlbase=` | `/opt/owl` | インストール先ディレクトリ |
| `-user=` | `ec2-user` | インストール実行ユーザー |
| `-port=` | `9000` | DQ Web ポート番号 |
| `-pgserver=` | `host:5432/db` | 外部 PostgreSQL の接続先 |
| `-options=` | `spark,owlweb,owlagent` | インストールするコンポーネント |

### ステップ 4: ライセンスキーの設定

`$OWL_BASE/config/owl-env.sh` を編集する:

```bash
export OWL_LICENSE_KEY="<ライセンスキー>"
export OWL_LICENSE_NAME="<ライセンス名>"
```

### ステップ 5: Java 17 用 JVM オプションの追加（2025.02 以降）

同じく `owl-env.sh` に追記する:

```bash
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"
```

### ステップ 6: サービスの起動・停止

```bash
# 起動
cd $OWL_BASE && ./owlmanage.sh start

# 停止
./owlmanage.sh stop

# 再起動
./owlmanage.sh restart
```

### ステップ 7: 動作確認

```bash
# プロセス確認
ps -ef | grep owl

# DQ Web UI へのアクセス
# → http://<SERVER_IP>:9000

# Spark Cluster UI
# → http://<SERVER_IP>:8080
```

DQ Web UI にログイン後、**Admin Console → Agent Configuration** に Agent が表示されていれば正常。

---

## 3. Kubernetes（AKS）インストール

### 前提条件

- AKS クラスター（Kubernetes 1.29 〜 1.34）が稼働していること
- `kubectl`・`helm` がローカルにインストールされていること
- Collibra とのライセンス契約が完了していること
  - 契約完了後、**Collibra から Helm チャート（ZIP）がメールで配布**される（`helm repo add` 方式ではない）
  - コンテナイメージは **Collibra 管理のプライベートレジストリ**でホストされており、認証情報もメールで提供される
  - セキュリティポリシー上、受け取ったイメージを **ACR（Azure Container Registry）等の自社レジストリにミラーリングして使うことが推奨**される

### ステップ 1: AKS クラスターへの接続・名前空間作成

```bash
# AKS への接続
az aks get-credentials \
  --resource-group <RG_NAME> \
  --name <CLUSTER_NAME>

# 名前空間作成
kubectl create namespace collibra-dq
```

### ステップ 2: コンテナレジストリの認証設定

```bash
kubectl create secret docker-registry collibra-registry \
  --docker-server=<collibra-registry-host> \
  --docker-username=<username> \
  --docker-password=<password> \
  --docker-email=<email> \
  -n collibra-dq
```

### ステップ 3: values.yaml の作成

```yaml
global:
  version:
    dq: "2026.02"
    spark: "4.1.0"

  configMap:
    data:
      license_key: "<LICENSE_KEY>"
      license_name: "<LICENSE_NAME>"

  web:
    admin:
      email: "admin@example.com"
      password: "<PASSWORD>"           # 後述のパスワード要件を参照
    service:
      type: LoadBalancer               # 外部公開する場合
      port: 9000

  # ---- Azure Key Vault 統合（推奨） ----
  secretProvider:
    provider: "akv"
    vault_name: "<VAULT_NAME>"
    tenant_id: "<TENANT_ID>"
    client_id: "<MANAGED_IDENTITY_ID>"
    subscription_id: "<SUBSCRIPTION_ID>"
    resource_group: "<RG_NAME>"

# PostgreSQL メタストア
metastore:
  enabled: true
  persistence:
    enabled: true
    size: 100Gi
    storageClassName: "managed-premium"   # AKS 向け Azure Disk

# DQ Web
owl-web:
  replicaCount: 2
  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

# DQ Agent
owl-agent:
  replicaCount: 2
  resources:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "4"
      memory: "8Gi"

# Spark Worker
spark:
  replicas: 3
  resources:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "4"
      memory: "8Gi"
```

> **Admin パスワード要件**:  
> 8〜72文字 / 大文字1文字以上 / 数字1文字以上 / 特殊文字（`!@#%$^&*?_~`）1文字以上 / ユーザーID（admin）を含まない

### ステップ 4: Helm でデプロイ

```bash
helm upgrade --install collibra-dq \
  --namespace collibra-dq \
  --values /path/to/values.yaml \
  --set image.pullSecrets[0].name=collibra-registry \
  /path/to/chart/dq
```

### ステップ 5: Pod 起動確認

```bash
# Pod の状態確認
kubectl get pods -n collibra-dq

# 各コンポーネントのログ確認
kubectl logs -n collibra-dq -l app=owl-web -f
kubectl logs -n collibra-dq -l app=owl-agent -f
kubectl logs -n collibra-dq -l app=owl-metastore -f
```

### ステップ 6: サービス・エンドポイントの確認

```bash
kubectl get svc -n collibra-dq
```

**LoadBalancer の場合**: `EXTERNAL-IP` が払い出されたら `http://<EXTERNAL-IP>:9000` でアクセス可能。

### ステップ 7: Azure Key Vault 統合（シークレット管理）

```bash
# Key Vault へのシークレット登録
az keyvault secret set \
  --vault-name <VAULT_NAME> \
  --name metastore-password --value <PASSWORD>

az keyvault secret set \
  --vault-name <VAULT_NAME> \
  --name license-key --value <LICENSE_KEY>

# AKS マネージド ID への Key Vault アクセス権限付与
MANAGED_IDENTITY_ID=$(az aks show \
  --name <CLUSTER_NAME> \
  --resource-group <RG_NAME> \
  --query identity.principalId -o tsv)

az keyvault set-policy \
  --name <VAULT_NAME> \
  --object-id $MANAGED_IDENTITY_ID \
  --secret-permissions get list
```

> **参照**: [Securely pass sensitive values to the Helm Chart](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_passing-sensitive-values-to-helm-based-deployments.htm)

---

## 4. DQ Agent セットアップ

DQ Agent は、PostgreSQL メタストアをポーリングしてジョブを取得・実行するコンポーネント。

> **環境ごとの設定方法の対応**
>
> | 方法 | スタンドアロン（RHEL VM） | AKS（Kubernetes） |
> |------|:---:|:---:|
> | 方法 A: `setup.sh` による自動インストール | ✓ | — |
> | 方法 B: 設定ファイル手動編集 | ✓ | — |
> | 方法 C: Admin Console から設定 | ✓ | ✓ |
> | 方法 D: Helm values.yaml で設定 | — | ✓ |
>
> スタンドアロンは **RHEL VM 上の JVM プロセス**として動作する。k3s / Kubernetes は不要。  
> k3s が必要になるのは Edge コンポーネント（データソース接続）のみ。

---

### 方法 A: setup.sh による自動インストール（スタンドアロン専用）

```bash
./setup.sh \
  -owlbase=$OWL_BASE \
  -options=owlagent \
  -pguser=$OWL_METASTORE_USER \
  -pgpassword=$OWL_METASTORE_PASS
```

### 方法 B: 設定ファイルの手動編集（スタンドアロン専用）

#### ステップ 1: パスワードの暗号化

```bash
cd $OWL_BASE
./owlmanage.sh encrypt=<平文パスワード>
# → 暗号化済み文字列が出力される
```

#### ステップ 2: `$OWL_BASE/config/owl.properties` の編集

```properties
# ライセンス
owldomain=<license-name>

# DQ Web のメタストア接続
spring.datasource.url=jdbc:postgresql://<DB_HOST>:5432/owlmetastore?currentSchema=public
spring.datasource.username=<METASTORE_USER>
spring.datasource.password=<ENCRYPTED_PASSWORD>
spring.datasource.driver-class-name=org.postgresql.Driver

# Agent のメタストア接続
spring.agent.datasource.url=jdbc:postgresql://<DB_HOST>:5432/owlmetastore?currentSchema=public
spring.agent.datasource.username=<METASTORE_USER>
spring.agent.datasource.password=<ENCRYPTED_PASSWORD>
spring.agent.datasource.driver-class-name=org.postgresql.Driver
```

#### ステップ 3: `$OWL_BASE/config/agent.properties` の設定（Spark Standalone 用）

初回起動時に自動生成される。必要に応じて以下を編集する:

```properties
# Spark 実行設定
sparksubmitmode=native
sparkhome=/path/to/spark
sparkmaster=spark://<SPARK_MASTER_HOST>:7077

# メタストア接続
metastorehost=<DB_HOST>
metastoreport=5432
metastoredb=owlmetastore
metastoreuser=<METASTORE_USER>
metastorepassword=<ENCRYPTED_PASSWORD>

# Agent 識別子
agentid=2
```

### 方法 C: Admin Console から設定（スタンドアロン・AKS 共通）

1. DQ Web UI → **Settings → Admin Console** を開く
2. **Agent Configuration** を選択
3. 以下の項目を入力する:

| 設定項目 | 値例 | 説明 |
|---------|------|------|
| Agent Display Name | `MyAgent001` | 任意の表示名 |
| Base Path | `/opt/owl` | インストールディレクトリ（スタンドアロン時） |
| Spark Deployment Mode | `Client` / `Cluster` | Spark 実行モード |
| Number of Executors | `4` | Executor 数 |
| Executor Memory (GB) | `8` | Executor メモリ |
| Driver Memory (GB) | `4` | Driver メモリ |
| Executor Cores | `2` | Executor コア数 |

4. データソース接続を左パネルから右パネルへ割り当てる

### 方法 D: Helm values.yaml で設定（AKS 専用）

AKS 環境では `owl-agent` セクションで Agent の動作を定義する。設定ファイルへの直接アクセスは不要。

```yaml
owl-agent:
  enabled: true
  replicaCount: 2
  env:
    - name: METASTORE_URL
      value: "jdbc:postgresql://<host>:5432/owlmetastore?currentSchema=public"
    - name: METASTORE_USER
      valueFrom:
        secretKeyRef:
          name: dq-secrets
          key: metastore_user
    - name: METASTORE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: dq-secrets
          key: metastore_password
    - name: SPARK_MASTER
      value: "spark://<spark-master>:7077"
  resources:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "4"
      memory: "8Gi"
```

デプロイ後のデータソース割当は **Admin Console（方法 C）** から行う。

> **参照**: [Set up a DQ agent](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/ta_configure-agent.htm)

---

## 5. 主要設定ファイル リファレンス

### `owl-env.sh`（環境変数・起動設定）

```bash
#!/bin/bash

# ===== ライセンス =====
export OWL_LICENSE_KEY="<LICENSE_KEY>"
export OWL_LICENSE_NAME="<LICENSE_NAME>"

# ===== パス =====
export OWL_BASE=/opt/owl
export SPARK_HOME=$OWL_BASE/spark
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk

# ===== Java 17 対応オプション =====
export EXTRA_JVM_OPTIONS="--add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens java.base/sun.util.calendar=ALL-UNNAMED"

# ===== DQ Web ポート =====
export SERVER_PORT=9000

# ===== メモリ =====
export HEAP_MIN_SIZE=1g
export HEAP_MAX_SIZE=4g

# ===== ログ =====
export LOG_DIR=$OWL_BASE/logs
export LOG_LEVEL=INFO

# ===== PostgreSQL 接続 =====
export SPRING_DATASOURCE_URL="jdbc:postgresql://localhost:5432/owlmetastore?currentSchema=public"
export SPRING_DATASOURCE_USERNAME=owl
export SPRING_DATASOURCE_PASSWORD=<ENCRYPTED_PASSWORD>

# ===== コネクションプーリング =====
export SPRING_DATASOURCE_TOMCAT_MAXACTIVE=20
export SPRING_DATASOURCE_TOMCAT_MAXIDLE=10
export SPRING_DATASOURCE_TOMCAT_MAXWAIT=30000

# ===== マルチテナント（デフォルト: 無効） =====
export MULTITENANTMODE=FALSE

# ===== CORS =====
export CORS_ALLOWED_ORIGINS=http://localhost:3000,https://app.example.com

# ===== LDAP 認証（オプション） =====
export LDAP_ENABLED=false
export LDAP_URL=ldap://ldap.example.com:389
export LDAP_BASE_DN=cn=users,dc=example,dc=com
export LDAP_BIND_DN=cn=admin,dc=example,dc=com
export LDAP_BIND_PASSWORD=<PASSWORD>
export LDAP_USER_SEARCH_FILTER=(uid={0})

# ===== ファイルアップロード =====
export ALLOWED_UPLOAD_FILE_TYPES=.csv,.xlsx,.xls,.parquet,.json
export MAX_UPLOAD_FILE_SIZE=104857600   # 100MB
```

---

## 6. PostgreSQL メタストア設定

### データベース・ユーザーの初期作成

```sql
-- ユーザー作成
CREATE ROLE owl WITH LOGIN PASSWORD '<PASSWORD>';
ALTER ROLE owl CREATEDB;
ALTER ROLE owl CREATEROLE;

-- データベース作成
CREATE DATABASE owlmetastore OWNER owl;

-- 権限付与
GRANT ALL PRIVILEGES ON DATABASE owlmetastore TO owl;
GRANT ALL PRIVILEGES ON SCHEMA public TO owl;
```

### JDBC 接続文字列パターン

| 接続先 | 接続文字列 |
|--------|-----------|
| ローカル | `jdbc:postgresql://localhost:5432/owlmetastore?currentSchema=public` |
| リモート（SSL） | `jdbc:postgresql://db.example.com:5432/owlmetastore?currentSchema=public&sslmode=require` |
| Azure DB for PostgreSQL | `jdbc:postgresql://myserver.postgres.database.azure.com:5432/owlmetastore?currentSchema=public&sslmode=require` |
| AWS RDS | `jdbc:postgresql://mydb.xxx.us-east-1.rds.amazonaws.com:5432/owlmetastore?currentSchema=public` |

### パスワードの暗号化

`owl.properties` に記載するパスワードは必ず暗号化する:

```bash
cd $OWL_BASE
./owlmanage.sh encrypt=<平文パスワード>
# 出力された暗号化文字列を owl.properties に設定
```

---

## 7. SSL / HTTPS 設定

### キーストア作成（PKCS12 形式を推奨）

```bash
keytool -genkey -alias owl-cert \
  -keystore /opt/owl/certs/keystore.p12 \
  -storetype PKCS12 \
  -keyalg RSA -keysize 2048 \
  -validity 365 \
  -storepass <KEYSTORE_PASSWORD>
```

### `owl-env.sh` への SSL 設定追記

```bash
export SERVER_HTTPS_ENABLED=true
export SERVER_HTTP_ENABLED=false         # HTTP を無効化する場合
export SERVER_SSL_KEY_TYPE=PKCS12
export SERVER_SSL_KEY_STORE=/opt/owl/certs/keystore.p12
export SERVER_SSL_KEY_STORE_PASSWORD=<KEYSTORE_PASSWORD>
export SERVER_SSL_KEY_ALIAS=owl-cert
```

---

## 8. アップグレード手順

> **重要**: アップグレード前に必ずメタストアのバックアップを取ること。ロールバックはサポートされない。

### ステップ 1: 現バージョン確認

DQ Web UI 右上の About アイコンから確認する。

### ステップ 2: メタストアのバックアップ

**スタンドアロン**:

```bash
pg_dump -h localhost -U owl -d owlmetastore > /backup/metastore_$(date +%Y%m%d).sql
```

**Kubernetes**:

```bash
kubectl exec -it <METASTORE_POD_NAME> -n collibra-dq -- \
  pg_dump -U owl -d owlmetastore > /backup/metastore_$(date +%Y%m%d).sql
```

### ステップ 3: Java・Spark のバージョン互換性確認

```bash
java -version
$SPARK_HOME/bin/spark-submit --version
```

[バージョン互換表](#javaspark-バージョン互換表)を参照し、必要に応じて Java / Spark を先にアップグレードする。

---

### スタンドアロンのアップグレード

#### ステップ 4: 新パッケージの展開

```bash
cd /tmp
tar -xvf dq-full-package-<NEW_VERSION>.tar.gz
cd dq
```

#### ステップ 5: サービス停止

```bash
cd $OWL_BASE && ./owlmanage.sh stop
```

#### ステップ 6: JAR ファイルのバックアップ・差し替え

```bash
mv $OWL_BASE/bin $OWL_BASE/bin.backup
mkdir -p $OWL_BASE/bin
cp /tmp/dq/bin/* $OWL_BASE/bin/
```

#### ステップ 7: スクリプトの更新

```bash
cp /tmp/dq/owlmanage.sh $OWL_BASE/
cp /tmp/dq/owlcheck.sh $OWL_BASE/
chmod +x $OWL_BASE/owlmanage.sh $OWL_BASE/owlcheck.sh
```

#### ステップ 8: サービス起動・動作確認

```bash
./owlmanage.sh start
ps -ef | grep owl
# → http://<SERVER_IP>:9000 にアクセスしてバージョンを確認
```

---

### Kubernetes（AKS）のアップグレード

#### ステップ 4: Helm チャート更新

```bash
helm upgrade collibra-dq \
  --namespace collibra-dq \
  --set global.version.dq=<NEW_VERSION> \
  --set global.version.spark=<NEW_SPARK_VERSION> \
  /path/to/new/chart/dq
```

#### ステップ 5: ローリングアップデートの確認

```bash
kubectl rollout status deployment/owl-web -n collibra-dq
kubectl rollout status deployment/owl-agent -n collibra-dq
```

#### ステップ 6: 動作確認

```bash
kubectl logs -n collibra-dq -l app=owl-web -f
# → DQ Web UI にログインしてバージョンを確認
```

---

## 参考ドキュメントリンク

| ドキュメント | URL |
|------------|-----|
| スタンドアロンインストール | [Install on self-hosted Spark Standalone](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/ta_standalone-install.htm) |
| スタンドアロン初期セットアップ | [Complete the Initial Setup](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/ta_standalone-complete-initial-setup.htm) |
| スタンドアロン設定オプション | [Additional Standalone Configuration Options](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/ref_standalone-configuration-options.htm) |
| Kubernetes インストール | [Installing on self-hosted Kubernetes](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/to_dq-cloud-native.htm) |
| Kubernetes デプロイ | [Deploy on Self-hosted Kubernetes](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_cloud-deploy.htm) |
| Helm シークレット管理 | [Securely pass sensitive values to the Helm Chart](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/CloudNativeDeployment/ta_passing-sensitive-values-to-helm-based-deployments.htm) |
| Agent セットアップ | [Set up a DQ agent](https://productresources.collibra.com/docs/collibra/latest/Content/DataQuality/Installation/ta_configure-agent.htm) |
| アップグレード手順 | [Upgrade Collibra DQ](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ta_upgrade-collibra-dq.htm) |
| アップグレード要件 | [Upgrade requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/Installation/Upgrade/ref_upgrade-requirements.htm) |
| システム要件 | [System requirements](https://productresources.collibra.com/docs/collibra/dqc/latest/Content/DataQuality/DQArchitecture/to_system-requirements.htm) |
