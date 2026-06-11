#!/usr/bin/env python3
"""报告:lab 事件 vs 生产 events/<day>/(云端大模型产出)并排对照 + 运行统计。
不打分 —— v1 先人工看(用户定的:先看跑得怎么样,再做细化指标)。

  python3 inspect_day.py --day 2026-06-07     → reports/2026-06-07.md
"""
import argparse
import glob
import json
import os

import labdb
import source


def lab_events(con, day):
    return con.execute(
        "SELECT * FROM events WHERE day=? AND status!='merged' ORDER BY id",
        (day,)).fetchall()


def prod_events(day):
    out = []
    for path in sorted(glob.glob(os.path.join(source.EVENTS_DIR, day, "*.md"))):
        if os.path.basename(path) == "INDEX.md":
            continue
        text = open(path, encoding="utf-8", errors="replace").read(8000)
        t = source._FM_TITLE.search(text)
        s = source._FM_SUMMARY.search(text)
        if t:
            out.append({"title": t.group(1), "summary": (s.group(1) if s else "")})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    args = ap.parse_args()
    con = labdb.connect()

    lab = lab_events(con, args.day)
    prod = prod_events(args.day)
    stats = con.execute(
        "SELECT status, COUNT(*) n FROM raw_sessions WHERE day=? GROUP BY status",
        (args.day,)).fetchall()
    calls = con.execute(
        "SELECT purpose, COUNT(*) n, SUM(ok=0) fails, AVG(latency_ms) avg_ms "
        "FROM llm_calls WHERE day=? GROUP BY purpose", (args.day,)).fetchall()

    lines = [f"# Event 本地化对照 · {args.day}", ""]
    lines.append("## 运行统计")
    lines.append("| session 状态 | 数 |")
    lines.append("|---|---|")
    for r in stats:
        lines.append(f"| {r['status']} | {r['n']} |")
    lines.append("")
    lines.append("| LLM 调用 | 次数 | 失败 | 平均耗时 |")
    lines.append("|---|---|---|---|")
    for r in calls:
        lines.append(f"| {r['purpose']} | {r['n']} | {r['fails']} | "
                     f"{(r['avg_ms'] or 0)/1000:.1f}s |")

    # 生产语义:join 历史事件 = 不建新文件,给老事件 +occurrence、追加
    # frame ids、清 distilledInto。报告按此口径分区,跟云端产出可比
    # (云端 events/<day>/ 目录里也只有"新事件",join 进了老文件)。
    new_ev = [e for e in lab if not e["joined_rel"]]
    occ_ev = [e for e in lab if e["joined_rel"]]
    lines.append("")
    lines.append(f"## 本地 14B 产出 · 新事件({len(new_ev)})")
    for e in new_ev:
        members = len(json.loads(e["member_ids"]))
        lines.append(f"\n### [{e['id']}] {e['title']}  ({members} sessions)")
        lines.append(f"{e['summary']}")
        lines.append(f"tags: {', '.join(json.loads(e['tags']))}")
    lines.append("")
    lines.append(f"## 本地 14B 产出 · 老事件复现,occurrence+1({len(occ_ev)})")
    lines.append("(移植生产时:不建新文件,recordOccurrence + 追加 frameIds + 清 distilledInto)")
    for e in occ_ev:
        members = len(json.loads(e["member_ids"]))
        lines.append(f"\n### → {e['joined_rel']}")
        lines.append(f"当天活动({members} sessions): {e['title']} — {e['summary'][:150]}")

    lines.append("")
    lines.append(f"## 生产(云端)产出({len(prod)} 个事件)")
    for p in prod:
        lines.append(f"\n### {p['title']}")
        lines.append(p["summary"])

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{args.day}.md")
    open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print(f"[report] {out}  (lab {len(lab)} vs prod {len(prod)} events)")


if __name__ == "__main__":
    main()
