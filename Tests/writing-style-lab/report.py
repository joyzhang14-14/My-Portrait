#!/usr/bin/env python3
"""把 facets 渲染成 markdown —— 按 app-group 分节,组内逐维度列出。

用法:
  python3 report.py                 # 全部天,打到 stdout
  python3 report.py --day 2026-07-02 --out reports/2026-07-02.md
"""
import argparse
import json
import os

import labdb

DIM_ORDER = ["message_structure", "tone", "input_habits",
             "editing_habits", "punctuation_layout", "writing_mode"]
DIM_NAME = {"message_structure": "消息结构", "tone": "语气",
            "input_habits": "输入习惯", "editing_habits": "修改习惯",
            "punctuation_layout": "标点排版", "writing_mode": "写作习惯"}


def render_day(con, day):
    rows = labdb.facets_for_day(con, day)
    if not rows:
        return f"## {day}\n\n(无 facet — 先 `python3 run.py --day {day} --run`)\n"
    groups = {}
    for r in rows:
        groups.setdefault((r["group_key"], r["group_label"]), []).append(r)

    out = [f"## {day}\n"]
    for (gk, label), frs in sorted(groups.items(), key=lambda kv: kv[0][1] or ""):
        out.append(f"\n### {label}  `{gk}`\n")
        by_dim = {r["dim"]: r for r in frs}
        for dk in DIM_ORDER:
            r = by_dim.get(dk)
            if not r:
                continue
            name = DIM_NAME.get(dk, dk)
            if not r["present"]:
                out.append(f"- **{name}**: —(无稳定习惯)")
                continue
            ev = json.loads(r["evidence"] or "[]")
            ev_s = "；".join(ev[:3])
            out.append(
                f"- **{name}**: {r['label'] or ''} "
                f"[{r['confidence'] or '?'}] — {r['pattern'] or ''}"
                + (f"\n  - 证据: {ev_s}" if ev_s else "")
                + f"\n  - `{r['model'] or ''}`"
            )
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day")
    ap.add_argument("--out")
    args = ap.parse_args()
    con = labdb.connect()
    if args.day:
        days = [args.day]
    else:
        days = [r["day"] for r in con.execute(
            "SELECT DISTINCT day FROM facets ORDER BY day").fetchall()]
    md = "# 写作风格提炼(本地 MLX)· 产出\n\n" + \
         "\n".join(render_day(con, d) for d in days)
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        open(args.out, "w", encoding="utf-8").write(md)
        print(f"written {args.out}")
    else:
        print(md)


if __name__ == "__main__":
    main()
