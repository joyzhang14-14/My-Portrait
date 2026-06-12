#!/usr/bin/env python3
"""v2 Phase B2:day-outline —— 滑窗扫全天 digest,14B 把一天写成章节叙事。

解决 v1 的根因(单 session 孤证):打错字的一闪而过、转译测试内容被当
真实活动,都需要前后文交叉印证。digest 已把 session 压到 ~200 字,
~40 个/窗 + 上一窗章节接力,14B 拿到的就是"整天的故事"。

  python3 outline_day.py --day 2026-06-07 [--window 40] [--limit-windows 2]

前置:clean_day.py 跑完(digest 全就位)。
checkpoint:chapters 表,每窗一批章节落库;断点续跑从未覆盖的 session 续。
⚠️ 跑之前先跟用户确认。
"""
import argparse
import datetime
import json
import sys

import labdb
from run_day import other_lab_running

OUTLINE_MODEL = "mlx-community/Qwen3-14B-4bit"


def hhmm(ms):
    return datetime.datetime.fromtimestamp(ms / 1000,
                                           datetime.timezone.utc).strftime("%H:%M")


def digest_line(s):
    d = (s["digest"] or "").split("\n")[0]
    return f"{hhmm(s['start_ms'])} {s['app']} | {d[:150]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default=OUTLINE_MODEL)
    ap.add_argument("--window", type=int, default=40)
    ap.add_argument("--limit-windows", type=int, default=0, help="烟雾测试:只跑前 N 窗")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if not args.force and other_lab_running():
        print("⛔ faithful_v2.py 还在跑。等它停,或 --force。")
        sys.exit(1)

    con = labdb.connect()
    rows = con.execute(
        "SELECT * FROM raw_sessions WHERE day=? AND status='pending' "
        "AND digest IS NOT NULL ORDER BY start_ms", (args.day,)).fetchall()
    if not rows:
        print("没有可 outline 的 session(先跑 clean_day.py,或全部已 completed)。")
        return
    missing = con.execute(
        "SELECT COUNT(*) FROM raw_sessions WHERE day=? AND status='pending' "
        "AND digest IS NULL", (args.day,)).fetchone()[0]
    if missing:
        print(f"⛔ 还有 {missing} 个 pending session 没 digest —— 先跑完 clean_day.py。")
        sys.exit(1)

    covered = labdb.outline_progress(con, args.day)
    todo = [s for s in rows if s["id"] not in covered]
    if not todo:
        print("outline 已完成(全部 session 已归章)→ eventize_day.py")
        return
    print(f"[outline] {args.day}: {len(todo)} session(s) 未归章,窗口 {args.window}")

    import engine
    import prompts
    engine.load(args.model)

    by_id = {s["id"]: s for s in rows}
    win_n = 0
    i = 0
    while i < len(todo):
        win = todo[i:i + args.window]
        i += len(win)
        win_n += 1
        if args.limit_windows and win_n > args.limit_windows:
            print(f"[stop] --limit-windows={args.limit_windows} 到。重跑续。")
            return
        chapters = labdb.chapters_for_day(con, args.day)
        carry = ("If the first sessions continue the last chapter above, put "
                 "them in continue_last_with." if chapters else
                 "No chapters yet — start fresh.")
        lines = [(s["id"], digest_line(s)) for s in win]
        try:
            out = engine.call(con, args.day, "outline",
                              prompts.outline_window(args.day, lines, chapters, carry),
                              max_tokens=1200, retries=2)
        except Exception as e:                          # noqa: BLE001
            print(f"  ✗ window {win_n} ERROR {e}(未落库,重跑续)")
            return

        def ids_of(slist):
            out_ids = []
            for tok in slist or []:
                t = str(tok).lstrip("s")
                if t.isdigit() and int(t) in by_id:
                    out_ids.append(int(t))
            return out_ids

        win_ids = {s["id"] for s in win}
        assigned = set()
        # 接力:并进上一章
        cont = [x for x in ids_of(out.get("continue_last_with")) if x in win_ids]
        if cont and chapters:
            last = chapters[-1]
            merged = json.loads(last["session_ids"]) + cont
            with con:
                con.execute("UPDATE chapters SET session_ids=? WHERE id=?",
                            (json.dumps(merged), last["id"]))
            assigned.update(cont)
            print(f"  ↪ window {win_n}: {len(cont)} session(s) 续上章 [{last['title']}]")
        # 新章节
        seq = (chapters[-1]["seq"] + 1) if chapters else 1
        for ch in out.get("chapters") or []:
            sids = [x for x in ids_of(ch.get("sessions")) if x in win_ids
                    and x not in assigned]
            if not sids or not ch.get("title"):
                continue
            labdb.insert_chapter(con, args.day, seq, ch["title"],
                                 ch.get("narrative") or "", sids)
            assigned.update(sids)
            print(f"  ✓ window {win_n}: 章节[{seq}] {ch['title']} ({len(sids)} sessions)")
            seq += 1
        # LLM 漏掉的 → 兜进最近的章(保证覆盖完整,镜像生产 coverGaps)
        leftover = [s["id"] for s in win if s["id"] not in assigned]
        if leftover:
            chapters = labdb.chapters_for_day(con, args.day)
            if chapters:
                last = chapters[-1]
                merged = json.loads(last["session_ids"]) + leftover
                with con:
                    con.execute("UPDATE chapters SET session_ids=? WHERE id=?",
                                (json.dumps(merged), last["id"]))
                print(f"  ⚠ window {win_n}: {len(leftover)} 漏归 → 兜进 [{last['title']}]")
            else:
                labdb.insert_chapter(con, args.day, 1, "uncategorized",
                                     "sessions the model failed to assign", leftover)

    n_ch = len(labdb.chapters_for_day(con, args.day))
    print(f"[done] outline 完成:{n_ch} 章 → eventize_day.py --day {args.day}")


if __name__ == "__main__":
    main()
