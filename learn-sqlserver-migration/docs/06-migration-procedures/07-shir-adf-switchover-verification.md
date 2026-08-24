# SHIR 張り替え方式 検証手順書
### 既存 ADF 用 SHIR サーバを一時的に DMS 専用機として使い、移行後に ADF へ戻す

---

## 検証の目的

DB 移行時、**既存の Azure Data Factory 用 SHIR が稼働中の Windows Server**に DMS 用の統合ランタイムを導入する想定です。
「ADF 用を停止して DMS 専用機とし、移行完了後に ADF 用へ戻す」という運用が**安全に往復できるか**を検証します。

| # | 検証したいこと | 判定基準 |
|---|---|---|
| ① | ADF 用構成のバックアップが取得できるか | `dmgcmd -gbf` がバックアップファイルを生成する |
| ② | DMS 用認証キーへの張り替えができるか | DMS 側で IR が「実行中」になる |
| ③ | 張り替え中、ADF 側がどう見えるか | ADF の IR ノードが「利用不可」表示になる |
| ④ | **ADF 用構成へ復元できるか（最重要）** | `dmgcmd -ibf` 後、ADF の IR が「実行中」に戻る |
| ⑤ | 復元後、ADF パイプラインが資格情報エラーなく動くか | Linked Service のテスト接続が成功する |
| ⑥ | 往復に要する所要時間 | 実測（ADF 停止許容時間の見積り根拠にする） |

---

## 前提となる公式仕様（先に押さえるべき制約）

| 制約 | 内容 | 影響 |
|---|---|---|
| **1台1インスタンス** | 「1台のマシンにインストールできる SHIR は 1 インスタンスのみ」 | **インストールパスを変えても 2 本目は入らない**。MSI は既存インストールのアップグレード/修復扱いになる |
| **1ノード = 1 IR** | ノードが登録できる統合ランタイムは常に 1 つ。別 IR へ移すには「アンインストール → 再インストール → 登録」 | サービス停止だけでは紐づけは外れない |
| **DMS は既存 ADF IR を流用不可** | 公式 Limitations に「ADF で作成した既存の SHIR を Azure DMS の移行に使うことはできない」と明記 | 共有 IR（Shared/Linked IR）による回避も不可 |
| **DMS 1インスタンス = 1 SHIR** | 「1つの Azure DMS には 1 つの SHIR のみを関連付ける」 | — |
| **資格情報は DPAPI 暗号化** | ローカル保存の資格情報は Windows DPAPI で暗号化されノードに保存される | サービスアカウントを変更すると復号できなくなる恐れ |

> **結論**：同居は不可。取り得るのは「**張り替え（再登録）→ 移行 → 復元**」のみ。
> 本手順書はこの往復が成立するかを検証するもの。

---

## 全体フロー

```
  【現状】                【移行期間中】              【復旧後】
 ┌──────────┐            ┌──────────┐            ┌──────────┐
 │ Win Server│            │ Win Server│            │ Win Server│
 │  SHIR     │            │  SHIR     │            │  SHIR     │
 │   └→ ADF  │  ──────→   │   └→ DMS  │  ──────→   │   └→ ADF  │
 └──────────┘  ①gbf      └──────────┘  ⑤ibf      └──────────┘
                ②uninstall              ⑥検証
                ③install
                ④-rn <DMSキー>

  ADF：トリガー無効化 ────────────────────────→ トリガー再有効化
                        （この間 ADF は全停止）
```

---

## 事前確認（検証前に必ず実施）

### A. 現行 SHIR の情報を控える

```powershell
# インストールパス確認（既定は C:\Program Files\Microsoft Integration Runtime\5.0\）
Get-ChildItem "C:\Program Files\Microsoft Integration Runtime"

# バージョン確認（DMS は 5.37 以上が必要）
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\DataTransfer\DataManagementGateway\ConfigurationManager" |
    Select-Object Version, DiacmdPath

# サービスアカウント確認（★ 復元時に同一である必要がある）
Get-CimInstance Win32_Service -Filter "Name='DIAHostService'" |
    Select-Object Name, StartName, State, PathName

# 自動更新サービスの状態
Get-Service DIAHostService, DIAUpdateService
```

| 控える項目 | 値 |
|---|---|
| インストールパス | |
| SHIR バージョン | |
| サービスアカウント（StartName） | |
| ノード名 | |
| 所属する ADF 名 / IR 名 | |
| 登録済みノード数（最大4） | |

### B. ADF 側の資格情報の保存先を判定する（★未確認事項）

復元に失敗した場合の影響度が変わるため、必ず先に確認します。

| 保存先 | 見分け方 | 復元失敗時の影響 |
|---|---|---|
| **Azure Key Vault** | ADF Studio → Linked Service の認証欄が「Azure Key Vault」参照になっている | **軽微**。SHIR ローカルに資格情報が無いため、IR の再登録だけで復旧する |
| **ローカル保存（既定）** | パスワードが Linked Service に直接入力されている / `encryptedCredential` が定義に含まれる | **要注意**。復元失敗時は Linked Service を1つずつ編集し、資格情報を再プッシュする必要がある |

```powershell
# ADF の Linked Service 定義を全件出力して encryptedCredential の有無を確認
Get-AzDataFactoryV2LinkedService -ResourceGroupName "<RG名>" -DataFactoryName "<ADF名>" |
    ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            HasEncryptedCred = ($_.Properties | ConvertTo-Json -Depth 10) -match 'encryptedCredential'
            UsesKeyVault     = ($_.Properties | ConvertTo-Json -Depth 10) -match 'AzureKeyVaultSecret'
        }
    } | Format-Table -AutoSize
```

> **判定結果によっては方針を見直すこと**
> ローカル保存かつ Linked Service が多数ある場合、張り替え方式のリスクが跳ね上がります。
> その場合は「別マシンに DMS 用 SHIR を立てる」案への切り替えを推奨します。

---

## STEP 1｜ADF 用構成のバックアップ取得（最重要）

バックアップファイルには**ノードキーとデータストア資格情報**が含まれます。これが復元の生命線です。

```powershell
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"

# パスワードは必ず記録・厳重保管すること（紛失＝復元不可）
.\dmgcmd.exe -gbf "D:\shir-backup\adf-shir-backup-20260824.json" "<パスワード>"
```

| 確認項目 | 判定基準 |
|---|---|
| ファイルが生成されたか | 指定パスにファイルが存在する |
| ファイルサイズ | 0 バイトでない |
| 退避 | **サーバ外**（別サーバ or 安全な共有）にもコピーを保管 |

> ⚠ バックアップファイルとパスワードは資格情報を含む機微データ。取り扱いに注意。

### 併せて取得しておくもの

```powershell
# レジストリのバックアップ（切り分け用）
reg export "HKLM\SOFTWARE\Microsoft\DataTransfer\DataManagementGateway" D:\shir-backup\shir-reg.reg /y

# 設定ファイル・ログの退避
Copy-Item "C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe.config" D:\shir-backup\ -Force
Copy-Item "C:\ProgramData\Microsoft\Data Transfer\Data Management Gateway" D:\shir-backup\programdata\ -Recurse -Force
```

---

## STEP 2｜ADF 側の停止

| 手順 | 操作 |
|---|---|
| 1 | ADF Studio → 管理 → トリガー → 稼働中トリガーを**すべて停止** |
| 2 | 実行中パイプラインが無いことを監視画面で確認 |
| 3 | 他チームへ ADF 停止期間を周知（★調整必須） |
| 4 | 自動更新を停止（張り替え中のバージョン変動を防ぐ）：`.\dmgcmd.exe -tus` |

> **検証時の確認ポイント**：ADF の IR ノードが「利用不可」になった際、ADF 側にアラート/エラー通知が飛ぶか（運用監視への影響確認）

---

## STEP 3｜DMS 用への張り替え

### 方式は2通り。**検証では両方試して比較すること**

| 方式 | コマンド | 公式の位置づけ |
|---|---|---|
| **方式A（推奨・公式手順）** | アンインストール → 再インストール → `-rn "<DMSキー>"` | 「別 IR へ登録し直すには、アンインストール後に再インストールして登録する」と公式が明記 |
| 方式B（キー上書き） | `.\dmgcmd.exe -k "<DMSキー>"` | 公式に「**新しい IR のキーだと以前のノードがオフラインになる可能性がある。注意して使うこと**」と警告あり |

```powershell
# 方式A
# 1. コントロールパネルから "Microsoft Integration Runtime" をアンインストール
# 2. DMS のページからダウンロードした MSI で再インストール（バージョン 5.37 以上）
# 3. DMS の認証キーで登録
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -rn "<DMS が発行した認証キー>" "<ノード名>"
```

### 確認項目

| # | 確認 | 判定基準 |
|---|---|---|
| 3-1 | DMS 側で IR が認識されるか | Azure Portal の DMS → 統合ランタイムが「実行中」 |
| 3-2 | ADF 側の表示 | IR ノードが「利用不可」になる（＝想定通り） |
| 3-3 | アンインストールで ADF ノードが自動削除されるか | ADF の IR ノード一覧に残るか消えるかを記録（**ノード上限4** の消費に関わる） |
| 3-4 | SQL Server への接続 | SHIR 診断ツール → 接続のテストで移行元 SQL Server に到達 |
| 3-5 | 通信要件 | ADF 用に許可済みの FQDN で足りるか（→ [06-network-verification-procedure.md](06-network-verification-procedure.md) と併せて確認） |

---

## STEP 4｜DB 移行の実施

移行本体の手順は対象別の手順書を参照。

| 移行先 | 手順書 |
|---|---|
| Azure SQL Database | [02-sql-db-dms-offline.md](02-sql-db-dms-offline.md) |
| Azure SQL Managed Instance | [04-sql-mi-dms-offline.md](04-sql-mi-dms-offline.md) |

> **検証では実移行まで行わず、テスト用小規模 DB を1本流して完走することを確認すれば十分**

---

## STEP 5｜ADF 用への復元（★本検証の本丸）

```powershell
# 1. コントロールパネルから "Microsoft Integration Runtime" をアンインストール
#    ※ サービスアカウントは STEP 1 で控えた値と同一にすること

# 2. 再インストール（バックアップ取得時と同じバージョンが望ましい）

# 3. バックアップファイルから復元
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -ibf "D:\shir-backup\adf-shir-backup-20260824.json" "<パスワード>"

# 4. サービス再起動
.\dmgcmd.exe -r
```

### 確認項目

| # | 確認 | 判定基準 | 結果 |
|---|---|---|---|
| 5-1 | `-ibf` がエラーなく完了するか | 正常終了 | |
| 5-2 | ADF 側で IR が「実行中」に戻るか | ADF Studio → 管理 → 統合ランタイム | |
| 5-3 | ノード名が元と同じか | STEP 1 で控えた値と一致 | |
| 5-4 | **Linked Service のテスト接続が成功するか** | 各 Linked Service で「接続のテスト」 | |
| 5-5 | パイプラインが正常完走するか | 代表的なパイプラインを手動実行 | |
| 5-6 | DMS 側に登録が残っていないか | DMS の IR が「利用不可」になる | |
| 5-7 | 自動更新サービスの再開 | `.\dmgcmd.exe -sus` | |

---

## STEP 6｜復元失敗時のリカバリ手順

`-ibf` が失敗した場合、または Linked Service の接続テストが失敗した場合。

| 症状 | 原因の想定 | 対処 |
|---|---|---|
| `-ibf` がエラー | サービスアカウント不一致（DPAPI で復号不可） | STEP 1 で控えたアカウントに `-ssa` で戻してから再試行 |
| `-ibf` がエラー | バージョン不一致 | バックアップ取得時と同じ SHIR バージョンを入れ直す |
| IR は実行中だが接続テスト失敗 | 資格情報が復元されていない | **ADF Studio で Linked Service を開き、パスワードを再入力して保存**（資格情報が SHIR へ再プッシュされる） |
| ノードが「利用不可」のまま | ADF 側に旧ノードが残存 | ADF の IR ノード一覧から旧ノードを削除し、新しい認証キーで `-rn` 登録し直す |
| どうしても戻らない | — | ADF で**新しい SHIR を作成**し、全 Linked Service の IR 参照を差し替え（★所要時間大。事前に手順と時間を見積もっておくこと） |

> **検証では「わざと失敗させる」テストも実施することを推奨**
> 例：サービスアカウントを変えて `-ibf` を実行し、実際にどうなるかを確認しておく。
> 本番当日に初めて遭遇するより遥かに安全。

---

## 検証で必ず記録すること

| 記録項目 | 用途 |
|---|---|
| STEP 1〜3 の所要時間 | ADF 停止開始から DMS 利用可能までのリードタイム |
| STEP 5 の所要時間 | 移行完了から ADF 復旧までのリードタイム |
| 上記合計 | **ADF 停止許容時間の交渉材料** |
| アンインストール時の ADF ノードの挙動 | ノード上限4の消費有無 |
| DMS が追加要求した FQDN | ファイアウォール申請リスト |
| 資格情報の再入力が必要だった Linked Service 数 | 本番当日の作業量見積り |

---

## リスク一覧と残課題

| # | リスク | 影響度 | 対策 |
|---|---|---|---|
| R-1 | `-ibf` による復元が失敗し ADF が復旧しない | **高** | バックアップを複数世代・サーバ外保管。STEP 6 のリカバリ手順を事前に演習 |
| R-2 | 移行期間中 ADF が全停止する | **高** | 停止許容時間を関係部署と事前調整。2TB 移行なら数日規模になり得る |
| R-3 | サービスアカウント変更により DPAPI 復号不可 | 中 | 張り替え前後でアカウントを固定。`-ssa` で明示的に指定 |
| R-4 | SHIR 自動更新でバージョンが変動 | 中 | 張り替え期間中は `-tus` で更新サービスを停止 |
| R-5 | 移行中の CPU / メモリ / I-O / 帯域の占有 | 中 | ADF 停止中なので競合はないが、他アプリが同居していないか要確認 |
| R-6 | ADF の IR ノード上限（4）を消費 | 低 | 不要ノードを都度削除 |
| R-7 | バックアップファイル（資格情報を含む）の漏洩 | 中 | 保管場所のアクセス制御。移行完了後に安全に削除 |

### 残課題

- [ ] ADF の Linked Service 資格情報の保存先（Key Vault / ローカル）を確認する
- [ ] ADF 停止の許容時間を関係部署と調整する
- [ ] 検証環境（既存 ADF サーバと同等構成）を用意できるか確認する
- [ ] **代替案の再検討**：別マシンに DMS 用 SHIR を立てれば R-1〜R-4 がすべて消える。公式も「専用マシンへのインストール」を推奨しており、一時的な Windows VM のコストと本リスクを天秤にかけること

---

## 参考

| 内容 | URL |
|---|---|
| SHIR の作成（1台1インスタンス制約・dmgcmd の全コマンド） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-self-hosted-integration-runtime |
| データベース移行向け SHIR（DMS の制約・推奨事項） | https://learn.microsoft.com/ja-jp/data-migration/sql-server/self-hosted-integration-runtime |
| SHIR の自動更新 | https://learn.microsoft.com/ja-jp/azure/data-factory/self-hosted-integration-runtime-auto-update |
| SHIR のトラブルシューティング | https://learn.microsoft.com/ja-jp/azure/data-factory/self-hosted-integration-runtime-troubleshoot-guide |
| SHIR 診断ツール | https://learn.microsoft.com/ja-jp/azure/data-factory/self-hosted-integration-runtime-diagnostic-tool |
| 共有 SHIR（※DMS では利用不可） | https://learn.microsoft.com/ja-jp/azure/data-factory/create-shared-self-hosted-integration-runtime-powershell |

---

**作成日**: 2026-08-24
