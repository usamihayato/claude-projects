# =============================================================
# Snowflake Notebook: Excel ワークスペースアップ → テーブル保存
# =============================================================
#
# 【実行手順】
#   1. Snowsight のノートブック左側「Files」タブから Excel をアップロード
#   2. Cell 3 の FILE_NAME を実際のファイル名に変更
#   3. 初回のみ Cell 1〜Cell 3 をすべて実行
#      2回目以降は Cell 1 と Cell 3 だけ実行すれば OK
#
# 【テーブル構成】
#   EXCEL_UPLOADS
#     FILE_NAME    VARCHAR   : アップロードしたファイル名
#     UPLOADED_AT  TIMESTAMP : 保存日時（自動設定）
#     CONTENT      TEXT      : パース済み全テキスト（シート名＋行データ）
#     ROW_COUNT    NUMBER    : 有効行数
# =============================================================


# ---- Cell 1: ライブラリ インポート & パース関数定義 ----
# ※ ここに既存の extract_from_excel 関数をそのまま貼り付けてください

import io
from datetime import datetime
import openpyxl


def extract_from_excel(buffer: bytes, include_sheet_names: bool = True) -> str:
    """
    既存のパース関数をここに貼り付けてください。
    シグネチャ: (buffer: bytes, include_sheet_names: bool) -> str
    戻り値   : シート名＋行データを改行で結合した文字列
    """
    # ▼▼▼ 既存コードをここに貼り付け ▼▼▼
    wb = openpyxl.load_workbook(io.BytesIO(buffer), data_only=True)
    all_lines = []

    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]
        if include_sheet_names:
            all_lines.append(f"[Sheet: {sheet_name}]")
        for row in ws.iter_rows(values_only=True):
            line = "\t".join("" if v is None else str(v) for v in row)
            all_lines.append(line)

    return "\n".join(all_lines)
    # ▲▲▲ 既存コードここまで ▲▲▲


# ---- Cell 2: テーブル作成（初回のみ実行） ----

session.sql("""
    CREATE TABLE IF NOT EXISTS EXCEL_UPLOADS (
        FILE_NAME    VARCHAR(512)  NOT NULL,
        UPLOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
        CONTENT      TEXT,
        ROW_COUNT    NUMBER(10, 0)
    )
""").collect()

print("テーブル準備完了")


# ---- Cell 3: メインロジック ----

# ▼ アップロードしたファイル名を指定
FILE_NAME = "sample.xlsx"

# Snowflake Notebook の Files タブからアップしたファイルは /uploads/ に配置される
file_path = f"/uploads/{FILE_NAME}"

with open(file_path, "rb") as f:
    buffer = f.read()

# パース
content = extract_from_excel(buffer)

# 空行を除いた有効行数を集計
row_count = sum(1 for line in content.split("\n") if line.strip())

# Snowpark でテーブルに追記
from snowflake.snowpark import Row

df = session.create_dataframe([
    Row(
        FILE_NAME=FILE_NAME,
        UPLOADED_AT=datetime.now(),
        CONTENT=content,
        ROW_COUNT=row_count,
    )
])
df.write.mode("append").save_as_table("EXCEL_UPLOADS")

print(f"保存完了: {FILE_NAME}  ({row_count:,} 行)")
