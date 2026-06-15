#!/usr/bin/env python3
"""提取库中 writing_records(写作采集 source,排除 cli_import=claude-code CLI 导入)→ md 对照文档。
用法:PORTRAIT_DAYS=... python3 gen_library_md.py  (默认 5/30-6/2)"""
import sqlite3, os
con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = os.environ.get('PORTRAIT_DAYS', '2026-05-30,2026-05-31,2026-06-01,2026-06-02').split(',')
OUT = os.environ.get('LIB_OUT', '/Users/joyzhang14/Desktop/Obsidian/5.30-6.2-库中产出.md')

nd = [f"# 库中产出·对照({DAYS[0][5:]}–{DAYS[-1][5:]})\n",
      "> 生产 pipeline 真实存入 `writing_records` 的**写作采集**记录(source≠cli_import)。与「本地新pipeline产出」对照看。",
      "> ⚠️ 已排除 `cli_import`(claude-code CLI 对话导入,非 AX/屏幕/击键采集,本地 pipeline 不产出,不可比)。按 UTC 切日。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
tot = 0
for day in DAYS:
    rows = con.execute(
        "SELECT app, source, kind, text FROM writing_records "
        "WHERE strftime('%Y-%m-%d', start_ts/1000, 'unixepoch')=:d AND source != 'cli_import' "
        "ORDER BY start_ts", {"d": day}).fetchall()
    cli_n = con.execute(
        "SELECT COUNT(*) FROM writing_records WHERE strftime('%Y-%m-%d', start_ts/1000, 'unixepoch')=:d "
        "AND source = 'cli_import'", {"d": day}).fetchone()[0]
    tot += len(rows)
    nd.append(f"## {day}\n")
    nd.append(f"### 📦 库中·成品（{len(rows)}）\n")
    for i, (app, source, kind, text) in enumerate(rows, 1):
        app_s = (app or 'unknown').split('.')[-1]
        nd.append(f"**{i}.** `[{source}/{kind}]` 📍 `{app_s}`\n\n> " + (text or '').replace("\n", "\n> ") + "\n")
    nd.append(f"\n> (另有 cli_import/claude-code CLI {cli_n} 条已排除,非采集来源)\n")
    nd.append("\n---\n")
open(OUT, 'w', encoding='utf-8').write("\n".join(nd))
print(f"已写 {OUT} | 写作采集记录 {tot} 条")
