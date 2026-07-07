#!/usr/bin/env python3
"""按「app × 对象/场景(scope)」分组跑维度 agent —— 实证「根据事件做分析」。

对比 run.py(只按 app 分组):这里先用 event_context 把每条 writing_record
关联到 event-lab 的 session window + vision items,再按 (app, scope) 分组,
每组独立跑维度。同一个 app 里「@某人私聊」和「#某频道」得到**各自的**风格 facet
—— 用户第一性需求(不同对象不同分析)的落地形态。

prompt 头部带 scope + vision 证据(英文指令已在 dimensions;这里只是上下文行)。
结果不进 facets 表,写 reports/scoped_<day>.md。

用法:
  python3 scoped_run.py --day 2026-06-05 --dims tone,message_structure --model 8B
"""
import argparse
import json
import os
import time

import dimensions
import engine
import event_context
import features
import labdb
import run as runmod
import source

ALIASES = {"4B": "mlx-community/Qwen3-4B-4bit", "8B": "mlx-community/Qwen3-8B-4bit"}


def build_scoped_messages(dim, app_label, scope, rows, agg, vision_lines,
                          events, max_records=15, text_cap=280):
    feat = {k: agg[k] for k in dim["feature_keys"]
            if k in agg and agg[k] not in (None, {}, [])}
    samples = []
    for r in rows[:max_records]:
        t = (r["text"] or "").strip().replace("\n", " ")
        if t:
            samples.append(f"- {t[:text_cap]}")
    vis = "\n".join(f"  · {v}" for v in vision_lines[:10]) or "  (none)"
    ev_line = ("; ".join(events[:5])) if events else "(event pipeline not run for this day)"
    user = (
        f"CONTEXT: app={app_label}  scope={scope}\n"
        f"  (scope comes from the window title — for chat apps it identifies the "
        f"conversation: '@name' = a DM with that person, '#channel | server' = a channel)\n"
        f"SCREEN EVIDENCE (vision model saw, same time window):\n{vis}\n"
        f"DAY EVENTS: {ev_line}\n"
        f"MEASURED FEATURES: {json.dumps(feat, ensure_ascii=False)}\n"
        f"MESSAGES the user typed IN THIS SCOPE ({len(rows)} records):\n"
        + "\n".join(samples)
        + f"\n\nAnswer for dimension「{dim['name']}」ONLY, about THIS scope only."
    )
    return [{"role": "system", "content": dim["system"]},
            {"role": "user", "content": user}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--dims", default="tone,message_structure")
    ap.add_argument("--model", default="8B")
    ap.add_argument("--min-group", type=int, default=2)
    args = ap.parse_args()

    day = args.day
    dims = [dimensions.DIM_BY_KEY[k] for k in args.dims.split(",")
            if k in dimensions.DIM_BY_KEY]
    con = labdb.connect()
    source.ingest_day(con, day)
    records = labdb.records_for_day(con, day)
    ctx = event_context.attach_scope(day, records)
    events = event_context.events_for_day(day)
    print(f"[join] {len(records)} 条记录,{len(ctx)} 条匹配到 session/scope")

    # 按 (app, scope) 分组
    groups = {}
    for r in records:
        c = ctx.get(r["id"], {"scope": "(未匹配)", "vision": []})
        groups.setdefault((r["app"], c["scope"]), {"rows": [], "vision": []})
        groups[(r["app"], c["scope"])]["rows"].append(r)
        for v in c["vision"]:
            if v not in groups[(r["app"], c["scope"])]["vision"]:
                groups[(r["app"], c["scope"])]["vision"].append(v)
    groups = {k: v for k, v in groups.items() if len(v["rows"]) >= args.min_group}
    print(f"[groups] {len(groups)} 个 (app × scope) 组:")
    for (app, scope), g in groups.items():
        print(f"    {runmod.app_name(app):10} × {scope[:40]:40} {len(g['rows'])} 条")

    engine.load(ALIASES.get(args.model, args.model))
    md = [f"# 按对象/场景分组的风格分析 · {day}\n"]
    for (app, scope), g in sorted(groups.items()):
        agg = features.aggregate(g["rows"])
        app_label = runmod.app_name(app)
        md.append(f"\n## {app_label} × **{scope}**  ({len(g['rows'])} 条)")
        for dim in dims:
            if dim["needs_ks"] and agg["ks_total"] < 40:
                continue
            msgs = build_scoped_messages(dim, app_label, scope, g["rows"], agg,
                                         g["vision"], events)
            t0 = time.time()
            try:
                out = engine.call(con, day, f"scoped:{dim['key']}", msgs,
                                  group_key=f"{app}|{scope[:40]}")
            except Exception as e:                    # noqa: BLE001
                out = {"present": None, "label": f"ERR {str(e)[:80]}"}
            ms = int((time.time() - t0) * 1000)
            mark = "✓" if out.get("present") else "·"
            print(f"  {mark} {app_label:9} {scope[:28]:28} {dim['key']:18} "
                  f"{(out.get('label') or '')[:22]} ({ms}ms)")
            md.append(f"- **{dim['name']}**: {out.get('label') or '—'} "
                      f"[{out.get('confidence') or '?'}] {out.get('pattern') or ''}")
            ev = "；".join((out.get("evidence") or [])[:3])
            if ev:
                md.append(f"  - 证据: {ev}")
    engine.unload()

    out_md = os.path.join("reports", f"scoped_{day}.md")
    os.makedirs("reports", exist_ok=True)
    open(out_md, "w", encoding="utf-8").write("\n".join(md))
    print(f"\n写出 {out_md}")


if __name__ == "__main__":
    main()
