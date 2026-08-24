# Azure SQL Database 障害対応 要件・設計方針

> **作成日**: 2026-08-24
> **対象**: Azure SQL Database（移行後の運用設計）
> **関連**: [05-sql-db-audit-log-requirements.md](./05-sql-db-audit-log-requirements.md)（同様に「DB へのログインを避けたい」という運用方針を継承）

---

## 要件

| # | 要件 |
|---|---|
| 1 | 障害対応は基本的に **Azure Portal で完結**させる |
| 2 | 運用担当者は **DB へのログイン（＝データ閲覧が可能な状態）を極力行わない** |
| 3 | ログインがどうしても必要になるケースを明確にし、**データを見せずに調査だけさせる**手段を用意する |

---

## 結論（先に要点）

| 障害の種類 | Azure Portal だけで完結するか |
|---|---|
| 接続できない（接続エラー・ファイアウォール） | ✅ 完結する |
| サービス停止・可用性低下（Azure 側障害） | ✅ 完結する |
| CPU 高騰・パフォーマンス劣化（過去〜直近の分析） | ✅ 完結する（DB ログイン不要） |
| デッドロックの**発生検知・傾向把握** | ✅ 完結する |
| デッドロックの**原因クエリの特定（詳細）** | ✅ 概ね完結する（Intelligent Insights が自動分析） |
| ブロッキングが解消しない（**リアルタイムに session を特定して KILL**） | ❌ **Portal だけでは不可**。DMV クエリでのログインが必要 |
| ストレージ逼迫 | ✅ 完結する |
| リストア（誤操作・破損からの復旧） | ✅ 完結する |
| フェイルオーバー（geo-replication） | ✅ 完結する |

> **結論**：日常的な障害対応の**8〜9割は Azure Portal だけで完結**します。
> ログインがほぼ必須になるのは「**今まさに起きているブロッキングを解消するために特定セッションを KILL する**」ケースだけです。
> このケースについても、**データを見せない権限設計**（後述）で「ログイン＝データ閲覧」を切り離せます。

---

## Azure Portal だけで完結する障害対応

### ① 接続できない

| 機能 | 内容 |
|---|---|
| **診断と解決策の表示**（Diagnose and solve problems） | リソースメニューから起動。「Network」で検索すると Network Troubleshooter が DNS / VNet / SQL 接続を自動チェック |
| Azure SQL 接続チェッカー | Microsoft 提供の PowerShell スクリプト。よくある設定ミスを自動検出し解決策を提示 |
| ファイアウォール設定 | Azure Portal の「ネットワーク」ブレードで直接変更可能 |

### ② サービス停止・可用性低下

| 機能 | 内容 |
|---|---|
| リソース正常性（Resource Health） | リソースメニューにあり、Azure 側の障害かどうかを即座に判別できる |
| Service Health | サブスクリプション単位で進行中の Azure 障害を確認 |
| サポート要求 | 「ヘルプ + サポート」から起票。Standard 以上のサポートプランなら緊急時は Severity A（1時間以内に一次応答）で起票可能 |

### ③ CPU 高騰・パフォーマンス劣化

**ここが最重要**：Query Store が自動収集したデータを Portal が可視化する仕組みのため、**DB ログインなしで**過去〜直近の分析ができます。

| 機能 | 内容 |
|---|---|
| **Query Performance Insight** | 「インテリジェントなパフォーマンス」メニュー配下。CPU 使用率の推移と、その時間帯の**上位クエリ**（CPU・実行時間・実行回数順）を表示 |
| **Intelligent Insights** | AI がワークロードを継続監視し、性能劣化を検知すると**根本原因分析**と改善提案を自動生成（診断ログとして出力、通常1時間程度で分析完了） |
| パフォーマンスの推奨事項（Advisor） | インデックス推奨などを Portal 上で確認・適用可能 |
| 自動チューニング | インデックス作成・実行プラン強制修正を自動化可能。有効化すれば CPU 高騰の再発を予防 |
| スケールアップ | vCore / DTU 引き上げも Portal 完結 |

> ⚠ **注意点**：Query Performance Insight はクエリの**SQL 文（テキスト）**を表示します。
> パラメータ化されていないクエリだと、SQL 文の**リテラル値**（＝ WHERE 句の検索値など）が見えてしまう場合があります。行データそのもの（テーブルの中身）は見えませんが、「一切何も見せたくない」場合はこの点だけ留意してください。

### ④ デッドロック

| 機能 | 内容 |
|---|---|
| **Deadlocks メトリック** | Azure Monitor の標準メトリック。発生**件数**をグラフ化・アラート設定可能。デッドロックマネージャーが victim を選定した後に発火 |
| **Intelligent Insights** | デッドロックの多発も性能劣化パターンとして自動検知し、根本原因分析に含まれる |

→ 「デッドロックが起きているか」「どのくらいの頻度か」「（多くの場合）何が原因か」は Portal だけで把握できます。

### ⑤ ストレージ逼迫・リストア・フェイルオーバー

| 機能 | 内容 |
|---|---|
| ストレージ使用率メトリック | Portal のメトリックエクスプローラー / アラートで完結 |
| **ポイントインタイムリストア（PITR）** | Portal の「復元」ボタンから、DB へログインせず復元操作が可能 |
| **強制フェイルオーバー**（geo-replication 構成時） | Portal のボタン操作のみ。DB ログイン不要 |

---

## Azure Portal だけでは完結しないケース

### ブロッキングが解消しない（リアルタイムでの session 特定・KILL）

Query Performance Insight や Intelligent Insights は**過去〜直近の集計データ**に基づく分析です。
「**今まさに** どのセッションが誰をブロックしているか」をリアルタイムに特定し、必要なら `KILL <session_id>` を実行する操作は、**DMV（`sys.dm_exec_requests` 等）への T-SQL クエリが必須**であり、これは Portal のメトリック画面では代替できません。

→ この場合のみ、**DB へのログインが必要**になります。

---

## ログインが必要な場合の対応方針

### Q. ログインは Azure Portal でもできる？

**できます。** SSMS のインストールは不要です。

| 方法 | 認証方式 | 特徴 |
|---|---|---|
| **Azure Portal の Query Editor** | SQL 認証 または Microsoft Entra 認証 | DB の「概要」ページから起動。ブラウザだけで T-SQL 実行が可能 |
| SSMS / Azure Data Studio | SQL 認証 または Microsoft Entra 認証 | 従来型。クライアント端末へのインストールが必要 |

Query Editor はサインイン画面で SQL 認証・Entra 認証のどちらも選択できるため、**運用担当者専用の Entra アカウントでの一時的なログイン**という形にすれば、資格情報の払い出し・棚卸しも Entra 側で一元管理できます。

### Q. 「データは見てはいけない」を、ログインしたまま守るには？

**運用担当者専用のログインに、DMV 参照権限だけを与え、ユーザーテーブルへの SELECT を明示的に拒否する**権限設計にします。

```sql
-- 障害対応専用ロールを作成
CREATE ROLE db_incident_responder;

-- DMV（パフォーマンス状態）の参照のみ許可
GRANT VIEW DATABASE PERFORMANCE STATE TO db_incident_responder;

-- ユーザーテーブルへの参照は明示的に拒否（スキーマ単位で一括拒否も可）
DENY SELECT ON SCHEMA::dbo TO db_incident_responder;

-- 障害対応担当者（Entra ユーザー）をロールに割り当て
ALTER ROLE db_incident_responder ADD MEMBER [oncall-user@yourtenant.onmicrosoft.com];
```

| 権限 | 用途 | 備考 |
|---|---|---|
| `VIEW DATABASE PERFORMANCE STATE` | `sys.dm_exec_requests` / `sys.dm_exec_sessions` / `sys.dm_os_waiting_tasks` 等のパフォーマンス系 DMV を参照可能 | Azure SQL Database では「VIEW SERVER STATE」に相当する権限がデータベース単位になったもの |
| `VIEW DATABASE STATE` | 上記に加えセキュリティ関連情報も見える | 障害対応目的なら `PERFORMANCE STATE` の方が範囲が狭く適切 |
| `DENY SELECT` | ユーザーテーブルの中身を一切見せない | ロールベースで明示的に拒否することで、誤って `SELECT * FROM 業務テーブル` を実行してもデータは返らない |

> この権限があれば、「ブロッキングの原因セッションを特定して `KILL` する」という障害対応の目的は果たしつつ、**業務データには一切アクセスできない状態**を維持できます。

---

## 障害対応フロー（まとめ）

```
                    障害発生
                       │
          ┌────────────┴────────────┐
          │  Azure Portal で切り分け  │
          │ （メトリック / QPI /       │
          │  Intelligent Insights /   │
          │  Diagnose and solve）     │
          └────────────┬────────────┘
                       │
        ┌──────────────┴──────────────┐
        │                              │
   原因を特定できた                リアルタイムの
   （CPU高騰／接続エラー／           ブロッキング等で
    Azure側障害／ストレージ）        特定セッションのKILLが必要
        │                              │
   Portal 内で対処                Query Editor（Portal）で
   （スケール変更／再起動／           db_incident_responder
    サポート起票／PITR復元／           ロールでログイン
    フェイルオーバー等）              → DMV参照 → KILL
        │                              │
        └──────────────┬──────────────┘
                       │
                    対応完了・記録
```

---

## 残課題

- [ ] `db_incident_responder` ロールの実運用フロー（誰がいつ Entra アカウントを割り当てるか）を決める
- [ ] Deadlocks / CPU / Storage の各メトリックにアラートルールを設定し、通知先（Teams / Email 等）を決める
- [ ] Query Performance Insight のクエリテキストにリテラル値が含まれる可能性について、社内のデータ取り扱いポリシー上問題ないか確認する

---

## 参考

| 内容 | URL |
|---|---|
| 高 CPU の診断とトラブルシューティング | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/high-cpu-diagnose-troubleshoot |
| ブロッキングの理解と解決 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/understand-resolve-blocking |
| デッドロックの分析と防止 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/analyze-prevent-deadlocks |
| Query Performance Insight | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/query-performance-insight-use |
| Intelligent Insights の概要 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/intelligent-insights-overview |
| メトリックとアラートによる監視 | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/monitoring-metrics-alerts |
| Azure Portal Query Editor | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/query-editor |
| サーバーロール（VIEW DATABASE STATE 等） | https://learn.microsoft.com/ja-jp/azure/azure-sql/database/security-server-roles |
| Azure サポート要求の作成方法 | https://learn.microsoft.com/ja-jp/azure/azure-portal/supportability/how-to-create-azure-support-request |

---

**作成日**: 2026-08-24
