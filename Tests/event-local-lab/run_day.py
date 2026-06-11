#!/usr/bin/env python3
"""主循环:一次一个 session,断点续跑。

  python3 run_day.py --day 2026-06-07 [--limit 5] [--model …] [--dry-run]

每个 session:检索候选 → [LLM decide] join/new → [LLM describe(仅 new)]
→ 单事务写库+标 completed。Ctrl-C 安全,重跑自动续。
⚠️ 跑之前先跟用户确认(faithful_v2.py 常在占机器)。
"""
import argparse
import json
import subprocess
import sys

import labdb
import retrieve
import source


def other_lab_running():
    try:
        out = subprocess.run(["pgrep", "-f", "faithful_v2.py"],
                             capture_output=True, text=True)
        return bool(out.stdout.strip())
    except Exception:
        return False


def ensure_ingested(con, day):
    if labdb.day_ingested(con, day):
        return
    sessions = source.load_day_sessions(day)
    labdb.ingest_sessions(con, day, sessions)
    n_ok = sum(1 for s in sessions if s["status"] == "pending")
    print(f"[ingest] {day}: {len(sessions)} sessions "
          f"({n_ok} pending, {len(sessions)-n_ok} skipped_no_ocr)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 个(烟雾测试)")
    ap.add_argument("--topk", type=int, default=6)
    ap.add_argument("--dry-run", action="store_true",
                    help="不加载模型:只 ingest + 打印每个 session 的检索候选")
    ap.add_argument("--force", action="store_true",
                    help="忽略 faithful_v2.py 正在跑的保护")
    args = ap.parse_args()

    if not args.dry_run and not args.force and other_lab_running():
        print("⛔ faithful_v2.py 还在跑(writing-capture 实验)。等它停,或 --force。")
        sys.exit(1)

    con = labdb.connect()
    ensure_ingested(con, args.day)

    pend = labdb.pending_sessions(con, args.day)
    if not pend:
        print("没有 pending session —— 这天已处理完(或全被 skip)。")
        return
    if args.limit:
        pend = pend[:args.limit]
    print(f"[run] {args.day}: {len(pend)} session(s) to process")

    if args.dry_run:
        events = labdb.open_events(con, args.day)
        idf = retrieve.build_idf([retrieve.session_tokens(s) for s in pend])
        for i, s in enumerate(pend):
            cands = [(e["id"], retrieve.event_tokens(e)) for e in events]
            top = retrieve.top_k(retrieve.session_tokens(s), cands, idf, args.topk)
            print(f"  [{i+1}/{len(pend)}] {s['app']} · {s['window'][:40]} → "
                  f"candidates {top}")
        return

    import engine
    import prompts
    engine.load(args.model or engine.DEFAULT_MODEL)

    done = 0
    for s in pend:
        events = labdb.open_events(con, args.day)        # 每轮重读(含新建的)
        idf = retrieve.build_idf(
            [retrieve.session_tokens(s)] + [retrieve.event_tokens(e) for e in events])
        cands = retrieve.top_k(
            retrieve.session_tokens(s),
            [(e["id"], retrieve.event_tokens(e)) for e in events],
            idf, k=args.topk)
        cand_rows = [e for e in events if e["id"] in {c[0] for c in cands}]

        try:
            if cand_rows:
                d = engine.call(con, args.day, "decide",
                                prompts.decide(s, cand_rows),
                                session_id=s["id"], max_tokens=64)
            else:
                d = {"decision": "new"}                  # 没有候选,不浪费一次调用

            if d.get("decision") == "join" and any(
                    e["id"] == d.get("event_id") for e in cand_rows):
                labdb.complete_session_join(con, s["id"], d["event_id"])
                title = next(e["title"] for e in cand_rows
                             if e["id"] == d["event_id"])
                print(f"  ✓ #{s['id']} {s['app'][:20]:20s} → JOIN [{d['event_id']}] {title}")
            else:
                desc = engine.call(con, args.day, "describe",
                                   prompts.describe(s),
                                   session_id=s["id"], max_tokens=300)
                if not desc.get("title") or not desc.get("summary"):
                    raise ValueError(f"describe missing fields: {desc}")
                eid = labdb.complete_session_new_event(con, s["id"], args.day, desc)
                print(f"  ✓ #{s['id']} {s['app'][:20]:20s} → NEW  [{eid}] {desc['title']}")
            done += 1
        except KeyboardInterrupt:
            print(f"\n[stop] 手动中断。已完成 {done},重跑同命令续。")
            return
        except Exception as e:                           # noqa: BLE001
            labdb.fail_session(con, s["id"], e)
            print(f"  ✗ #{s['id']} {s['app'][:20]:20s} → ERROR {e} (保持 pending,重跑会再试)")

    left = len(labdb.pending_sessions(con, args.day))
    print(f"[done] processed {done};剩余 pending {left}"
          + ("" if left else f" → 可以跑 finalize_day.py --day {args.day}"))


if __name__ == "__main__":
    main()
