# SHIR 張り替え方式 検証手順書
### 既存 ADF 用 SHIR サーバを一時的に DMS 専用機として使い、移行後に ADF へ戻す

---

## 検証の目的

DB 移行時、**既存の Azure Data Factory 用 SHIR が稼働中の Windows Server**に DMS 用の統合ランタイムを導入する想定です。
「ADF 用を停止して DMS 専用機とし、移行完了後に ADF 用へ戻す」という運用が**安全に往復できるか**を検証します。

| # | 検証したいこと | 判定基準 |
|---|---|---|
| ① | DMS 用認証キーへの張り替えができるか（`-k`方式） | DMS 側で IR が「実行中」になる |
| ② | 張り替え中、ADF 側がどう見えるか | ADF の IR ノードが「利用不可」表示になる |
| ③ | **ADF 用へ戻せるか（最重要）** | `-k`でADFキーに戻すだけで、ADF の IR が「実行中」に戻る |
| ④ | 復元後、ADF パイプラインが資格情報エラーなく動くか | Linked Service のテスト接続が成功する |
| ⑤ | 往復に要する所要時間 | 実測（ADF 停止許容時間の見積り根拠にする） |

> **実際に検証した結果、`-k`（キー上書き）だけで ADF ⇔ DMS の往復切り替えが両方向とも成立することを確認しました。**
> アンインストール／再インストール、バックアップからの復元は**不要**でした（詳細は下記「なぜ`-k`だけで足りるのか」参照）。
> 本書はこの`-k`方式をメイン手順とし、アンインストール／再インストールを伴う方式は
> 後述の「コンティンジェンシー」セクションとして別途まとめています。

---

## 前提となる公式仕様（先に押さえるべき制約）

| 制約 | 内容 | 影響 |
|---|---|---|
| **1台1インスタンス** | 「1台のマシンにインストールできる SHIR は 1 インスタンスのみ」 | **インストールパスを変えても 2 本目は入らない**。MSI は既存インストールのアップグレード/修復扱いになる |
| **1ノード = 1 IR** | ノードが登録できる統合ランタイムは常に 1 つ | 同時に2つのIRに繋ぐことはできない（ただし**アンインストール無しでも`-k`で登録先を切り替えられる**ことを実際に確認済み） |
| **DMS は既存 ADF IR を流用不可** | 公式 Limitations に「ADF で作成した既存の SHIR を Azure DMS の移行に使うことはできない」と明記 | 共有 IR（Shared/Linked IR）による回避も不可。張り替えが必須 |
| **DMS 1インスタンス = 1 SHIR** | 「1つの Azure DMS には 1 つの SHIR のみを関連付ける」 | — |
| **資格情報は DPAPI 暗号化・ノードのローカルディスクに保存** | Linked Service のパスワードは「オンプレミス」（＝ノード自身）にDPAPI暗号化されて保存される。**クラウド側に恒久的な複製は無い** | アンインストール（＝ローカルファイル消失）や別マシン移行の場合のみ、バックアップが無いと復旧不能になる |

> **結論**：ADFとDMSの同居は不可。ただし張り替え自体は「`-k`でキーを上書き→サービス再起動」という
> 軽量な方法だけで両方向とも成立する。アンインストールを伴わない限り、ローカルの資格情報ファイルは
> 消えないため、バックアップ／復元も基本的には不要。

---

## なぜ `-k` だけで足りるのか（検証で判明した仕組み）

1. Linked Service の資格情報は、**ノードのローカルディスク**にDPAPI暗号化されて保存される（構成マネージャーの「資格情報ストア：オンプレミス」表示で確認可能）
2. `-k` はこの登録先（どのIR/DMSインスタンスに接続するか）を切り替えるだけで、**ローカルの資格情報ファイル自体には触れない**
3. アンインストールしない限り、この暗号化ファイルは元のノード上にずっと残り続ける
4. そのため、ADF → DMS → ADF と登録先を`-k`で往復させても、**元のIR（ADF）に戻った瞬間、既存のローカル資格情報がそのまま使える**

一方、`-gbf`/`-ibf`（バックアップ／復元）が本当に必要になるのは、**アンインストール・再インストールでローカルファイルそのものが消える場合**、または**別の新しいマシンに移行する場合**だけです。この2ケースは今回のメイン手順（往復切り替え）には該当しないため、コンティンジェンシー扱いとしています。

> **実践での気づき**：ノードの現在の登録先とバックアップファイルの由来が一致しないと、
> `-ibf`（バックアップのインポート）は「このバックアップファイルは別のIntegration Runtimeのものである
> 可能性があります」というエラーで**拒否される**（安全装置）。バックアップを使う場合は、
> 先に該当IRへ登録を戻してからインポートする必要がある。

---

## 全体フロー

```
  【現状】                【移行期間中】              【復旧後】
 ┌──────────┐            ┌──────────┐            ┌──────────┐
 │ Win Server│            │ Win Server│            │ Win Server│
 │  SHIR     │            │  SHIR     │            │  SHIR     │
 │   └→ ADF  │  ──────→   │   └→ DMS  │  ──────→   │   └→ ADF  │
 └──────────┘  ①-k <DMSキー>└──────────┘ ③-k <ADFキー>└──────────┘
                ②Restart-Service            ④Restart-Service

  ADF：トリガー無効化 ────────────────────────→ トリガー再有効化
                        （この間 ADF は全停止）
```

---

## 事前確認（検証前に必ず実施）

### A. 現行 SHIR の情報を控える

```powershell
# インストールパス確認（既定は C:\Program Files\Microsoft Integration Runtime\5.0\）
Get-ChildItem "C:\Program Files\Microsoft Integration Runtime"

# バージョン確認（DMS は 5.37 以上が必要。レジストリのVersionは空のことがあるので実ファイルを見る）
(Get-Item "C:\Program Files\Microsoft Integration Runtime\5.0\Shared\diahost.exe").VersionInfo.FileVersion

# サービスアカウント確認（★ 復元時に同一である必要がある）
Get-CimInstance Win32_Service -Filter "Name='DIAHostService'" |
    Select-Object Name, StartName, State, PathName

# 自動更新サービスの状態（無い場合もある。手動で止めている場合はそれも記録）
Get-Service DIAHostService -ErrorAction SilentlyContinue
Get-Service DIAUpdateService -ErrorAction SilentlyContinue
```

| 控える項目 | 値 |
|---|---|
| インストールパス | |
| SHIR バージョン | |
| サービスアカウント（StartName） | |
| ノード名 | |
| 所属する ADF 名 / IR 名 | |
| 登録済みノード数（最大4） | |

### B. ADF 側の資格情報の保存先を判定する

万一「別マシンに移行する」「アンインストールが必要になる」場合の影響度を事前に把握しておきます。

| 保存先 | 見分け方 | ローカルファイル消失時の影響 |
|---|---|---|
| **Azure Key Vault** | ADF Studio → Linked Service の認証欄が「Azure Key Vault」参照になっている | **軽微**。SHIR ローカルに資格情報が無いため、IR の再登録だけで復旧する |
| **ローカル保存（既定）** | パスワードが Linked Service に直接入力されている / `encryptedCredential` が定義に含まれる | **要注意**。アンインストール等でファイルが消えた場合、Linked Service を1つずつ編集し資格情報を再プッシュするか、事前バックアップから復元する必要がある |

> **最も手っ取り早い確認方法**：`vm-shir`で Microsoft Integration Runtime 構成マネージャーを開くと、
> ホーム画面に **「資格情報ストア：オンプレミス」** のように直接表示されます。
> Azure CLI/PowerShellで調べるまでもなく、この1行で判定できます
> （「オンプレミス」＝ローカル保存＝要注意パターン、と読み替えてください）。
>
> **SHIR/本番サーバー上で確認する必要はありません。** Linked Serviceの資格情報保存方式は
> ADFリソースの定義（ARMメタデータ）を見るだけなので、**Azure CLIがあればご自身の作業端末から
> 確認できます**。SHIRには何も追加インストールしない、という方針とも合致します
> （`Az.DataFactory` PowerShellモジュールが入っていない/入れたくない場合はこちらを使ってください）。

```bash
# Linked Service名の一覧を確認
az datafactory linked-service list --resource-group <RG名> --factory-name <ADF名> --query "[].name" -o tsv

# 各Linked Serviceの定義から資格情報の保存方式を判定
az datafactory linked-service show \
  --resource-group <RG名> --factory-name <ADF名> --name <上で出てきた名前> \
  -o json | grep -Ei "encryptedCredential|AzureKeyVaultSecret"
```

`encryptedCredential`が出れば**ローカル保存**、`AzureKeyVaultSecret`が出れば**Key Vault参照**です。

`Az.DataFactory` PowerShellモジュールが使える環境であれば、以下でも同様に確認できます。

```powershell
Get-AzDataFactoryV2LinkedService -ResourceGroupName "<RG名>" -DataFactoryName "<ADF名>" |
    ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            HasEncryptedCred = ($_.Properties | ConvertTo-Json -Depth 10) -match 'encryptedCredential'
            UsesKeyVault     = ($_.Properties | ConvertTo-Json -Depth 10) -match 'AzureKeyVaultSecret'
        }
    } | Format-Table -AutoSize
```

---

## STEP 1｜ADF 用構成のバックアップ取得（保険として推奨・必須ではない）

`-k`方式では往復切り替えにバックアップは不要ですが、**アンインストールが必要になる不測の事態への保険**として、取得しておくことを推奨します（手間は数分程度）。

```powershell
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"

# パスワードは必ず記録・厳重保管すること
.\dmgcmd.exe -gbf "D:\shir-backup\adf-shir-backup-20260824.json" "<パスワード>"
```

> Integration Runtime構成マネージャーのUI（「バックアップを生成」ボタン）から実行することも可能です。
> その場合、拡張子は自動的に`.irbackup`になります（コマンドラインでは任意の拡張子を指定可能）。

| 確認項目 | 判定基準 |
|---|---|
| ファイルが生成されたか | 指定パスにファイルが存在する |
| ファイルサイズ | 0 バイトでない |

> ⚠ バックアップファイルとパスワードは資格情報を含む機微データ。取り扱いに注意。
> 本番運用では、サーバー外（別サーバや安全な共有）にもコピーを保管することが望ましい。

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

## STEP 3｜DMS 用への張り替え（`-k`方式）

```powershell
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -k "<DMS が発行した認証キー>"
```

> ⚠️ **`-k`実行後、自動ではサービスに反映されないことがある。** 構成マネージャーで新しい登録先への
> 接続が確認できない場合は、Windowsサービス（`Integration Runtime Service`＝実体は`DIAHostService`）を
> 手動でRestartする。

```powershell
Restart-Service DIAHostService
```

公式には「新しい IR のキーだと以前のノードがオフラインになる可能性がある。注意して使うこと」という警告がありますが、今回の検証では問題なく切り替えられました。

### 確認項目

| # | 確認 | 判定基準 |
|---|---|---|
| 3-1 | DMS 側で IR が認識されるか | Azure Portal の DMS → 統合ランタイムが「実行中/オンライン」 |
| 3-2 | ADF 側の表示 | IR ノードが「利用不可」になる（＝想定通り） |
| 3-3 | SQL Server への接続 | SHIR 診断ツール → 接続のテストで移行元 SQL Server に到達 |
| 3-4 | 通信要件 | ADF 用に許可済みの FQDN で足りるか（→ [06-network-verification-procedure.md](06-network-verification-procedure.md) と併せて確認） |

> **実践での気づき（3-2）**：ADFポータルの`ir-verify`ブレードは、切り替え直後は
> しばらく「実行中」のまま**古い状態がキャッシュ表示**され続けた（ハートビート途絶の検知に
> タイムラグがあるため）。バッジ表示の変化を待つより、**Linked Serviceの「テスト接続」を
> 実行して意図的に失敗させる方が確実で早い確認方法**だった。
> 実際に `Failed to connect to Integration Runtime or connection is broken unexpectedly.`
> （エラーコード9054）で失敗することを確認できれば、機能的には「利用不可」と判定してよい。
>
> ポータルの状態バッジは「実行中」→（しばらくして）**「実行中（制限付き）」**という警告状態を経て
> 「利用不可」へ段階的に遷移した。バッジが完全に「利用不可」になるまで待たなくても、
> Linked Serviceのテスト接続失敗＋「制限付き」表示の時点で切り替わったと判断してよい。
>
> **注意**：この段階でADF Studio上の古いノード/IRを手動削除しないこと。STEP 5の復元検証（`-k`で
> 戻すだけで済むか）ができなくなる。復元がどうしても失敗した場合の最終手段として温存しておく。

---

## STEP 4｜DB 移行の実施

移行本体の手順は対象別の手順書を参照。

| 移行先 | 手順書 |
|---|---|
| Azure SQL Database | [02-sql-db-dms-offline.md](02-sql-db-dms-offline.md) |
| Azure SQL Managed Instance | [04-sql-mi-dms-offline.md](04-sql-mi-dms-offline.md) |

> **検証では実移行まで行わず、テスト用小規模 DB を1本流して完走することを確認すれば十分**
> （06の検証で既に同一構成での移行成功を確認済みの場合、この STEP は「済み」として扱ってよい）

---

## STEP 5｜ADF 用への復元（`-k`方式・★本検証の本丸）

```powershell
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -k "<ADF/ir-verify が発行した認証キー>"
```

キーが必要な場合の再取得：

```bash
az datafactory integration-runtime list-auth-key \
  --resource-group <RG名> --factory-name <ADF名> --name <IR名> \
  --query authKey1 -o tsv
```

STEP 3と同様、サービスの手動Restartが必要な場合があります。

```powershell
Restart-Service DIAHostService
```

### 確認項目

| # | 確認 | 判定基準 | 結果 |
|---|---|---|---|
| 5-1 | `-k`実行後、エラーなく完了するか | 正常終了 | |
| 5-2 | ADF 側で IR が「実行中」に戻るか | ADF Studio → 管理 → 統合ランタイム | |
| 5-3 | ノード名が元と同じか | STEP A で控えた値と一致（アンインストールしていないため当然一致するはず） | |
| 5-4 | **Linked Service のテスト接続が成功するか** | 各 Linked Service で「接続のテスト」（**バックアップの復元操作なしで**成功するはず） | |
| 5-5 | パイプラインが正常完走するか | 代表的なパイプラインを手動実行 | |
| 5-6 | DMS 側に登録が残っていないか | DMS の IR が「利用不可」になる | |
| 5-7 | 自動更新サービスの再開 | `.\dmgcmd.exe -sus` | |

> **実測結果**：`-k`でADFキーに戻すだけで、Linked Serviceのテスト接続は**バックアップの復元
> （`-ibf`）を一切行わずに成功**した。ローカルの資格情報ファイルがアンインストールされずに
> 残っていたため、ADF側が再認識した時点で自動的に使えるようになったと考えられる。
>
> 参考として、同じバックアップファイルを使って`-ibf`（バックアップのインポート）も試したところ、
> **ADFへの登録を先に戻した後であれば正常にインポートできる**ことを確認した（登録を戻す前＝
> DMSに登録されたままの状態でインポートしようとすると、「別のIRのバックアップ」として拒否される）。

---

## コンティンジェンシー：`-k`方式が使えない場合の再インストール方式

`-k`での切り替え・復元がうまくいかない場合（サービスが起動しない、資格情報が壊れている、
別マシンへ完全移行する必要がある等）の最終手段です。事前にSTEP 1でバックアップを取得済みであることが前提です。

### 切り替え（アンインストール→再インストール→登録）

```powershell
# 1. コントロールパネルから "Microsoft Integration Runtime" をアンインストール
# 2. DMS のページからダウンロードした MSI で再インストール（バージョン 5.37 以上）
# 3. DMS の認証キーで登録
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -rn "<DMS が発行した認証キー>" "<ノード名（省略可）>"
```

> **`-k`と`-rn`の違い**：`-k`は**既に登録されているノード**の接続先を切り替えるコマンド（本書のメイン手順で使用）。
> `-rn`は**アンインストールで登録情報が消えた後、新規ノードとして登録し直す**ためのコマンドで、
> ここでのみ必要になる。ノード名は省略可能で、省略した場合はコンピューター名が既定で使われる。

| # | 確認 | 判定基準 |
|---|---|---|
| C-1 | アンインストールでADFノードが自動削除されるか | ADFのIRノード一覧に残るか消えるかを記録（**ノード上限4**の消費に関わる） |

### 復元（アンインストール→再インストール→バックアップ復元）

```powershell
# 1. コントロールパネルから "Microsoft Integration Runtime" をアンインストール
#    ※ サービスアカウントは事前確認Aで控えた値と同一にすること
# 2. 再インストール（バックアップ取得時と同じバージョンが望ましい）
# 3. バックアップファイルから復元
cd "C:\Program Files\Microsoft Integration Runtime\5.0\Shared"
.\dmgcmd.exe -ibf "D:\shir-backup\adf-shir-backup-20260824.json" "<パスワード>"

# 4. サービス再起動
.\dmgcmd.exe -r
```

### 復元失敗時のリカバリ手順

| 症状 | 原因の想定 | 対処 |
|---|---|---|
| `-ibf` がエラー | サービスアカウント不一致（DPAPI で復号不可） | 事前確認Aで控えたアカウントに `-ssa` で戻してから再試行 |
| `-ibf` がエラー | バージョン不一致 | バックアップ取得時と同じ SHIR バージョンを入れ直す |
| `-ibf` がエラー：「別のIRのバックアップです」 | ノードの現在の登録先とバックアップの由来が不一致 | 先に該当のIRの認証キーで`-k`/`-rn`登録してから再度`-ibf`を試す |
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
| STEP 2〜3 の所要時間 | ADF 停止開始から DMS 利用可能までのリードタイム |
| STEP 5 の所要時間 | 移行完了から ADF 復旧までのリードタイム |
| 上記合計 | **ADF 停止許容時間の交渉材料** |
| `-k`実行後にサービス再起動が必要だったか | 本番手順書に明記すべき注意点 |
| DMS が追加要求した FQDN | ファイアウォール申請リスト |
| Linked Service の資格情報再入力が必要だったか | `-k`方式なら基本不要のはずだが、念のため記録 |

---

## リスク一覧と残課題

| # | リスク | 影響度 | 対策 |
|---|---|---|---|
| R-1 | `-k`実行後、サービスが新しい登録先を認識しない | 中 | `Restart-Service DIAHostService`を手順に明記（本検証で実際に必要だった） |
| R-2 | 移行期間中 ADF が全停止する | **高** | 停止許容時間を関係部署と事前調整。2TB 移行なら数日規模になり得る |
| R-3 | コンティンジェンシー（再インストール）が必要になった場合のサービスアカウント不一致 | 中 | 張り替え前後でアカウントを固定。`-ssa` で明示的に指定 |
| R-4 | SHIR 自動更新でバージョンが変動 | 中 | 張り替え期間中は `-tus` で更新サービスを停止 |
| R-5 | 移行中の CPU / メモリ / I-O / 帯域の占有 | 中 | ADF 停止中なので競合はないが、他アプリが同居していないか要確認 |
| R-6 | ADF の IR ノード上限（4）を消費（コンティンジェンシー時のみ） | 低 | 不要ノードを都度削除 |
| R-7 | バックアップファイル（資格情報を含む）の漏洩 | 中 | 保管場所のアクセス制御。移行完了後に安全に削除 |

### 残課題

- [ ] ADF の Linked Service 資格情報の保存先（Key Vault / ローカル）を確認する
- [ ] ADF 停止の許容時間を関係部署と調整する
- [ ] 検証環境（既存 ADF サーバと同等構成）を用意できるか確認する
- [ ] 本番の実機で`-k`方式が同様に機能するか（サービスアカウントやFIPS設定等、環境差分の影響を確認）

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
**改訂**: 2026-08-27（`-k`方式での往復切り替えを実証し、メイン手順として再構成。再インストール方式はコンティンジェンシーへ移動）
