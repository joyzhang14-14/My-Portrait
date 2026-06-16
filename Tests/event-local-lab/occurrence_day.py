#!/usr/bin/env python3
"""hybrid 下游:跨天 occurrence / merge —— 对生产历史事件**只读**。

读 ~/.portrait/events/<历史天>/*.md 的 frontmatter(只读,绝不改生产文件),
为每个 hybrid 事件找"同一持续活动"的历史事件:命中则记 occurrence 日期列表
+ 历史事件引用,只写进 lab.db。镜像生产 Backfill 的 join+occurrence,但只读。

检索(IDF top-K)+ **批处理**云端判定(一次判 N 个事件,各带自己的候选;
每事件单独 spawn 太慢,故批量)。

  python3 occurrence_day.py --day 2026-06-07 [--window 90] [--topk 5] [--evbatch 8] [--force]
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


def _batch_prompt(day, items, by_rel):
    """items: [(event_row, top_list)]。一次判多个事件。"""
    blocks = []
    for e, top in items:
        cands = "\n".join(
            f"  [{i}] {by_rel[rel]['title']} — {by_rel[rel]['summary'][:90]} ({by_rel[rel]['day']})"
            for i, (rel, _s) in enumerate(top, 1))
        blocks.append(f"EVENT {e['id']}: {e['title']} — {e['summary'][:150]}\n"
                      f"  candidates:\n{cands}")
    user = f"""Today is {day}. Each event below MIGHT continue an ongoing activity
from a past day. Be SELECTIVE — MOST events are NEW, not continuations. Joining a
past candidate adds ONE OCCURRENCE to a recurring activity, so a wrong join turns
occurrences into noise.

Join a candidate ONLY when this event genuinely IS the SAME thread carried across
days:
  • the same recurring routine, or
  • the same specific multi-day task/SESSION — the same bug, the same feature, the
    same document worked on again, or
  • the same ongoing conversation with the same person about the same thing.

A DIFFERENT episode of a similar activity is a NEW event — answer null:
  • worked on the SAME project/repo but a DIFFERENT feature, bug, or file → NEW.
  • chatted with the same person about a DIFFERENT topic → NEW.
  • "debugged My-Portrait" today and "debugged My-Portrait" last week on unrelated
    code are TWO events → NEW.
Working on the same project again is NOT a continuation by itself. When unsure,
answer null. Continuations are the exception, not the rule.

{chr(10).join(blocks)}

Answer ONLY one JSON object mapping each EVENT id to the matching candidate number,
or null if it is a NEW event. Keys must be the EVENT ids shown above.
Example: {{"12": 2, "13": null}}"""
    return [{"role": "system", "content": "You decide whether today's events continue "
             "a SAME-thread cross-day activity. Be selective; default to NEW (null). "
             "Answer ONE JSON object only."},
            {"role": "user", "content": user}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--window", type=int, default=14)   # 对齐生产 Backfill activeWindowDays=14
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--evbatch", type=int, default=8)
    ap.add_argument("--model", default="haiku")
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
    hist_tok = [(h["rel"], retrieve.hist_tokens(h)) for h in hist]
    idf = retrieve.build_idf([t for _, t in hist_tok]) if hist_tok else {}
    # 续接判定是轻任务,只看事件标题/摘要(已脱敏元数据,不碰原始 OCR)。
    # 用 Claude Haiku 云端(claude CLI,绕开 Codex 限流;比本地 14B 准、快)。
    print(f"[occurrence] {args.day}: 历史事件 {len(hist)} 个(前 {args.window} 天,只读)"
          f" · 云端 {args.model}")

    rows = con.execute("SELECT * FROM hybrid_events WHERE day=?"
                       + ("" if args.force else " AND occurrences IS NULL")
                       + " ORDER BY id", (args.day,)).fetchall()
    if not rows:
        print("无待处理事件。"); return

    def write(e, occ_dates, ref=None, htitle=None):
        with con:
            con.execute("UPDATE hybrid_events SET occurrences=?, historical_ref=?, "
                        "historical_title=? WHERE id=?",
                        (json.dumps(occ_dates), ref, htitle, e["id"]))

    # 先检索;无候选的直接当天独立,有候选的攒批
    items, solo = [], 0
    for e in rows:
        top = retrieve.top_k(retrieve.event_tokens(e), hist_tok, idf,
                             k=args.topk, floor=0.10) if hist_tok else []
        if top:
            items.append((e, top))
        else:
            write(e, [args.day]); solo += 1
    print(f"  有历史候选 {len(items)} 个(批量判定),无候选当天独立 {solo} 个")

    merged = 0
    for i in range(0, len(items), args.evbatch):
        chunk = items[i:i + args.evbatch]
        msgs = _batch_prompt(args.day, chunk, by_rel)
        try:
            raw, lat = cloud.cloud_call(msgs, model=args.model, max_tokens=400,
                                        timeout=120)
            out = engine.parse_json(raw, "object")
            labdb.log_call(con, args.day, "occurrence", None,
                           sum(len(m["content"]) for m in msgs), raw, True, lat)
        except Exception as ex:                            # noqa: BLE001
            print(f"  ✗ 批 {i//args.evbatch} {ex} → 本批全当天独立")
            for e, _t in chunk:
                write(e, [args.day])
            continue
        for e, top in chunk:
            mi = out.get(str(e["id"]), out.get(e["id"]))
            if isinstance(mi, bool):
                mi = None
            if isinstance(mi, int) and 1 <= mi <= len(top):
                ref = top[mi - 1][0]
                occ = sorted(set(_hist_occurrences(ref) + [args.day]))
                write(e, occ, ref, by_rel[ref]["title"])
                merged += 1
                print(f"    ✓ h{e['id']} {e['title'][:34]} → {ref} (occ {len(occ)}天)")
            else:
                write(e, [args.day])
        print(f"  批 {i//args.evbatch}: {len(chunk)} 事件 · {lat}ms")

    print(f"[done] 跨天续接 {merged} · 当天独立 {solo + len(items) - merged} · 共 {len(rows)}")


if __name__ == "__main__":
    main()
