#!/usr/bin/env python3
"""终态三步(当天 sessions 全 completed 后跑):
  a. summarize:每个多成员事件由全部成员重写最终摘要
  b. merge:    检索出的相似 open 事件对 → 二选一"应合并?"(收 decide 漏网的重复)
  c. join:     每事件 top-K 历史事件 → 逐个二选一"同一持续活动?"

  python3 finalize_day.py --day 2026-06-07 [--model …] [--skip-join]

三段可独立开关:--skip-summarize / --skip-merge / --skip-join。
join-only(只补 occurrence,不动当天粒度):
  python3 finalize_day.py --day … --force --skip-summarize --skip-merge
join 幂等:重跑跳过 joined_rel 已非空的事件。
"""
import argparse
import json
import sys

import labdb
import retrieve
import source


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--merge-floor", type=float, default=0.25,
                    help="merge 候选对的最低检索分")
    ap.add_argument("--join-topk", type=int, default=3)
    ap.add_argument("--skip-summarize", action="store_true")
    ap.add_argument("--skip-merge", action="store_true")
    ap.add_argument("--skip-join", action="store_true")
    ap.add_argument("--no-finalize-status", action="store_true",
                    help="不把 open 事件翻 finalized(留待后续补 merge/join)")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    con = labdb.connect()
    if labdb.pending_sessions(con, args.day) and not args.force:
        print("⛔ 这天还有 pending session,先跑完 run_day.py(或 --force)。")
        sys.exit(1)

    import engine
    import prompts
    engine.load(args.model or engine.DEFAULT_MODEL)

    # ── a. summarize ──────────────────────────────────────────────
    events = [] if args.skip_summarize else labdb.open_events(con, args.day)
    for e in events:
        members = json.loads(e["member_ids"])
        if len(members) < 2:
            continue                      # 单成员:describe 的摘要已够
        rows = [con.execute("SELECT * FROM raw_sessions WHERE id=?", (m,)).fetchone()
                for m in members]
        try:
            out = engine.call(con, args.day, "summarize",
                              prompts.summarize(e, rows), max_tokens=300)
            with con:
                con.execute("UPDATE events SET title=?, summary=?, "
                            "updated_at_ms=? WHERE id=?",
                            (out.get("title") or e["title"],
                             out.get("summary") or e["summary"],
                             labdb.now_ms(), e["id"]))
            print(f"  ✓ summarize [{e['id']}] {out.get('title')}")
        except Exception as ex:           # noqa: BLE001
            print(f"  ✗ summarize [{e['id']}] {ex}(保留原摘要)")

    # ── b. merge ──────────────────────────────────────────────────
    events = [] if args.skip_merge else labdb.open_events(con, args.day)
    idf = retrieve.build_idf([retrieve.event_tokens(e) for e in events]) if events else {}
    merged_away = set()
    for i, a in enumerate(events):
        if a["id"] in merged_away:
            continue
        for b in events[i + 1:]:
            if b["id"] in merged_away:
                continue
            s = retrieve.score(retrieve.event_tokens(a), retrieve.event_tokens(b), idf)
            if s < args.merge_floor:
                continue
            try:
                out = engine.call(con, args.day, "merge",
                                  prompts.merge(a, b), max_tokens=32)
            except Exception as ex:       # noqa: BLE001
                print(f"  ✗ merge [{a['id']}]×[{b['id']}] {ex}")
                continue
            if out.get("merge") is True:
                with con:
                    ma = json.loads(a["member_ids"]) + json.loads(b["member_ids"])
                    ta = sorted(set(json.loads(a["tags"]) + json.loads(b["tags"])))
                    con.execute("UPDATE events SET member_ids=?, tags=?, "
                                "updated_at_ms=? WHERE id=?",
                                (json.dumps(ma), json.dumps(ta, ensure_ascii=False),
                                 labdb.now_ms(), a["id"]))
                    con.execute("UPDATE events SET status='merged', merged_into=?, "
                                "updated_at_ms=? WHERE id=?",
                                (a["id"], labdb.now_ms(), b["id"]))
                    con.execute("UPDATE raw_sessions SET event_id=? WHERE event_id=?",
                                (a["id"], b["id"]))
                merged_away.add(b["id"])
                print(f"  ✓ merge [{b['id']}] → [{a['id']}] {a['title']}")

    # ── c. join historical ───────────────────────────────────────
    if not args.skip_join:
        hist = source.load_historical_events(args.day)
        hist_tok = [(h["rel"], retrieve.hist_tokens(h)) for h in hist]
        idf_h = retrieve.build_idf([t for _, t in hist_tok])
        by_rel = {h["rel"]: h for h in hist}
        for e in labdb.open_events(con, args.day):
            if e["joined_rel"]:
                continue                   # 幂等:已 join 过的跳过(重跑安全)
            top = retrieve.top_k(retrieve.event_tokens(e), hist_tok, idf_h,
                                 k=args.join_topk, floor=0.10)
            for rel, _s in top:
                try:
                    out = engine.call(con, args.day, "join",
                                      prompts.join_historical(e, by_rel[rel]),
                                      max_tokens=32)
                except Exception as ex:   # noqa: BLE001
                    print(f"  ✗ join [{e['id']}] vs {rel} {ex}")
                    continue
                if out.get("same_ongoing") is True:
                    with con:
                        con.execute("UPDATE events SET joined_rel=?, "
                                    "updated_at_ms=? WHERE id=?",
                                    (rel, labdb.now_ms(), e["id"]))
                    print(f"  ✓ join [{e['id']}] {e['title']} → {rel}")
                    break                  # 第一个命中即定

    if not args.no_finalize_status:
        with con:
            con.execute("UPDATE events SET status='finalized', updated_at_ms=? "
                        "WHERE day=? AND status='open'", (labdb.now_ms(), args.day))
    print(f"[done] {args.day} → inspect_day.py --day {args.day}")


if __name__ == "__main__":
    main()
