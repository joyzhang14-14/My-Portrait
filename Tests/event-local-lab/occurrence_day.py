#!/usr/bin/env python3
"""hybrid 下游:跨天 occurrence / merge —— 对生产历史事件**只读**。

读 ~/.portrait/events/<历史天>/*.md 的 frontmatter(只读,绝不改生产文件),
为每个 hybrid 事件找"同一持续活动"的历史事件:命中则记 occurrence 日期列表
+ 历史事件引用,只写进 lab.db。镜像生产 Backfill 的 join+occurrence,但只读。

检索(IDF top-K)+ 一次云端判定(批候选,选续接的那个或 null)。

  python3 occurrence_day.py --day 2026-06-07 [--window 90] [--topk 5] [--force]
断点续:occurrences 列已非空的跳过。⚠️ 云端调用,跑前确认。
"""
import argparse
import json
import os
import re

import cloud
import engine
import labdb
import retrieve
import source

_OCC = re.compile(r"^occurrences:\s*\[(.*?)\]", re.M)


def _hist_occurrences(rel):
    """只读历史事件文件,取其 occurrences 日期列表。"""
    path = os.path.join(source.EVENTS_DIR, rel)
    try:
        text = open(path, encoding="utf-8", errors="replace").read(4000)
    except OSError:
        return []
    m = _OCC.search(text)
    if not m or not m.group(1).strip():
        return []
    return [d.strip().strip('"') for d in m.group(1).split(",") if d.strip()]


def _match_prompt(day, e, cands):
    tags = ", ".join(json.loads(e["tags"]))
    lines = []
    for i, (rel, _s) in enumerate(cands, 1):
        h = by_rel[rel]
        lines.append(f"[{i}] {h['title']} — {h['summary'][:120]} · tags: "
                     f"{', '.join(h['tags'])} · ({h['day']})")
    user = f"""Today's event ({day}):
title: {e['title']}
summary: {e['summary'][:300]}
tags: {tags}

Past events from earlier days (candidates):
{chr(10).join(lines)}

Is today's event a CONTINUATION of the SAME ongoing activity/project as ONE of
these — the same project/task/conversation carried across days, NOT merely a
similar topic or the same app? If yes, give that candidate's number; else null.
Answer ONLY JSON: {{"match": <number> or null}}"""
    return [{"role": "system", "content": "You decide if two events are the same "
             "ongoing activity across days. Answer with ONE JSON object only."},
            {"role": "user", "content": user}]


by_rel = {}


def main():
    global by_rel
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--window", type=int, default=90)
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    con = labdb.connect()
    for col in ("occurrences TEXT", "historical_ref TEXT", "historical_title TEXT"):
        name = col.split()[0]
        if name not in [r[1] for r in con.execute("PRAGMA table_info(hybrid_events)")]:
            con.execute(f"ALTER TABLE hybrid_events ADD COLUMN {col}")
    con.commit()

    hist = source.load_historical_events(args.day, window_days=args.window)
    by_rel = {h["rel"]: h for h in hist}
    print(f"[occurrence] {args.day}: 历史事件 {len(hist)} 个(前 {args.window} 天,只读)"
          f" · provider={cloud.load_config()['provider']}")
    hist_tok = [(h["rel"], retrieve.hist_tokens(h)) for h in hist]
    idf = retrieve.build_idf([t for _, t in hist_tok]) if hist_tok else {}

    rows = con.execute("SELECT * FROM hybrid_events WHERE day=?"
                       + ("" if args.force else " AND occurrences IS NULL")
                       + " ORDER BY id", (args.day,)).fetchall()
    if not rows:
        print("无待处理事件。"); return

    merged = solo = 0
    for e in rows:
        occ_dates, ref, htitle = [args.day], None, None
        top = retrieve.top_k(retrieve.event_tokens(e), hist_tok, idf,
                             k=args.topk, floor=0.10) if hist_tok else []
        if top:
            try:
                raw, lat = cloud.cloud_call(_match_prompt(args.day, e, top),
                                            max_tokens=60)
                out = engine.parse_json(raw, "object")
                mi = out.get("match")
                if isinstance(mi, int) and 1 <= mi <= len(top):
                    ref = top[mi - 1][0]
                    htitle = by_rel[ref]["title"]
                    occ_dates = sorted(set(_hist_occurrences(ref) + [args.day]))
                labdb.log_call(con, args.day, "occurrence", None,
                               sum(len(m["content"]) for m in _match_prompt(args.day, e, top)),
                               raw, True, lat)
            except Exception as ex:                        # noqa: BLE001
                print(f"  ✗ h{e['id']} {ex}")
        with con:
            con.execute("UPDATE hybrid_events SET occurrences=?, historical_ref=?, "
                        "historical_title=? WHERE id=?",
                        (json.dumps(occ_dates), ref, htitle, e["id"]))
        if ref:
            merged += 1
            print(f"  ✓ h{e['id']} {e['title'][:38]} → 续接 {ref}  occ={len(occ_dates)}天")
        else:
            solo += 1
    print(f"[done] 跨天续接 {merged} · 当天独立 {solo} · 共 {len(rows)}")


if __name__ == "__main__":
    main()
