#!/usr/bin/env python3
"""v2 Phase C:章节 → 事件(代替 v1 的 per-session decide/describe)。

significance gate:单 session 且 <2min 的章节不独立成事件,折进时间上
最近的章(胰腺癌打错字这类碎片死在门口)。每章一次 describe(带前后章
上下文),一个事务落事件 + 全部成员标 completed。
之后照旧:finalize_day.py 跑 merge 兜底(章节数少,几乎没活)+ 历史 join。

  python3 eventize_day.py --day 2026-06-07 [--limit 3]
⚠️ 跑之前先跟用户确认。
"""
import argparse
import json
import sys

import labdb
from run_day import other_lab_running

MIN_SOLO_MS = 2 * 60 * 1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if not args.force and other_lab_running():
        print("⛔ faithful_v2.py 还在跑。等它停,或 --force。")
        sys.exit(1)

    con = labdb.connect()
    chapters = [c for c in labdb.chapters_for_day(con, args.day)
                if c["status"] == "open"]
    if not chapters:
        print("没有 open 章节(先跑 outline_day.py,或全部已 eventize)。")
        return

    def sess_rows(ch):
        ids = json.loads(ch["session_ids"])
        return [con.execute("SELECT * FROM raw_sessions WHERE id=?", (i,)).fetchone()
                for i in ids]

    # significance gate:碎章折进前一个 open/eventized 章(没有就后一个)。
    all_ch = labdb.chapters_for_day(con, args.day)
    folded = 0
    for idx, ch in enumerate(all_ch):
        if ch["status"] != "open":
            continue
        rows = [r for r in sess_rows(ch) if r]
        dur = sum(r["end_ms"] - r["start_ms"] for r in rows)
        if len(rows) == 1 and dur < MIN_SOLO_MS:
            target = all_ch[idx - 1] if idx > 0 else (
                all_ch[idx + 1] if idx + 1 < len(all_ch) else None)
            if target is None:
                continue
            merged = json.loads(target["session_ids"]) + json.loads(ch["session_ids"])
            with con:
                con.execute("UPDATE chapters SET session_ids=? WHERE id=?",
                            (json.dumps(merged), target["id"]))
                con.execute("DELETE FROM chapters WHERE id=?", (ch["id"],))
            folded += 1
            print(f"  ∅ 碎章折叠 [{ch['title']}] → [{target['title']}]")
    if folded:
        print(f"[gate] 折叠 {folded} 个碎章")

    import engine
    import prompts
    engine.load(args.model or engine.DEFAULT_MODEL)

    chapters = [c for c in labdb.chapters_for_day(con, args.day)
                if c["status"] == "open"]
    if args.limit:
        chapters = chapters[:args.limit]
    all_ch = labdb.chapters_for_day(con, args.day)
    by_seq = {c["seq"]: c for c in all_ch}
    done = 0
    for ch in chapters:
        rows = [r for r in sess_rows(ch) if r]
        if not rows:
            continue
        try:
            desc = engine.call(con, args.day, "describe",
                               prompts.describe_chapter(
                                   ch, rows,
                                   by_seq.get(ch["seq"] - 1), by_seq.get(ch["seq"] + 1)),
                               max_tokens=300, retries=2)
            if not desc.get("title") or not desc.get("summary"):
                raise ValueError(f"missing fields: {desc}")
            member_ids = [r["id"] for r in rows]
            with con:
                cur = con.execute(
                    "INSERT INTO events(day,title,summary,type,facets,tags,"
                    "member_ids,created_at_ms,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?)",
                    (args.day, desc["title"], desc["summary"],
                     desc.get("type", "experience"),
                     json.dumps(desc.get("facets", []), ensure_ascii=False),
                     json.dumps(desc.get("tags", []), ensure_ascii=False),
                     json.dumps(member_ids), labdb.now_ms(), labdb.now_ms()))
                eid = cur.lastrowid
                con.execute("UPDATE chapters SET event_id=?, status='eventized' "
                            "WHERE id=?", (eid, ch["id"]))
                for sid in member_ids:
                    con.execute(
                        "UPDATE raw_sessions SET status='completed', event_id=?, "
                        "updated_at_ms=? WHERE id=?", (eid, labdb.now_ms(), sid))
            done += 1
            print(f"  ✓ 章[{ch['seq']}] {ch['title']} → 事件[{eid}] {desc['title']} "
                  f"({len(member_ids)} sessions)")
        except KeyboardInterrupt:
            print(f"\n[stop] 手动中断。已 eventize {done},重跑续。")
            return
        except Exception as e:                          # noqa: BLE001
            print(f"  ✗ 章[{ch['seq']}] {ch['title']} ERROR {e}(保持 open,重跑续)")

    demote_media_titles(con, args.day)

    left = len([c for c in labdb.chapters_for_day(con, args.day)
                if c["status"] == "open"])
    print(f"[done] eventized {done};剩余 open 章 {left}"
          + ("" if left else f" → finalize_day.py --day {args.day}"))


def demote_media_titles(con, day):
    """v3 #6 确定性兜底(无 LLM):事件标题命名了媒体 app,但该 app 占成员
    session <10% 且有非媒体 app 主导(≥30%)→ 从 snake_case 标题里摘掉媒体
    token。最后一道防线:即使上游全失守,spotify_...(2/82)也会被改名。"""
    import chrome
    media_low = {a.lower() for a in chrome.BG_MEDIA_APPS}
    fixed = 0
    for e in con.execute("SELECT id, title, member_ids FROM events WHERE day=?",
                         (day,)).fetchall():
        mids = json.loads(e["member_ids"])
        if not mids:
            continue
        apps = [r["app"] for r in con.execute(
            f"SELECT app FROM raw_sessions WHERE id IN ({','.join('?'*len(mids))})",
            mids).fetchall()]
        n = len(apps)
        from collections import Counter
        cnt = Counter(apps)
        title_toks = e["title"].split("_")
        media_in_title = [t for t in title_toks if t in media_low]
        if not media_in_title:
            continue
        # 标题里的媒体 app 占比 <10% 且有非媒体 app ≥30% → 摘掉媒体 token
        dominant = cnt.most_common(1)[0]
        dom_is_media = dominant[0].lower() in media_low
        for mt in media_in_title:
            share = sum(v for a, v in cnt.items() if a.lower() == mt) / n
            if share < 0.10 and not dom_is_media and dominant[1] / n >= 0.30:
                new_toks = [t for t in title_toks if t != mt]
                new_title = "_".join(new_toks).strip("_") or f"{dominant[0].lower()}_activity"
                with con:
                    con.execute("UPDATE events SET title=?, updated_at_ms=? WHERE id=?",
                                (new_title, labdb.now_ms(), e["id"]))
                fixed += 1
                print(f"  ⚖ #6 改名 [{e['id']}] '{e['title']}' → '{new_title}' "
                      f"({mt} {share:.0%} < 10%, 主导 {dominant[0]} {dominant[1]/n:.0%})")
                break
    if fixed:
        print(f"[#6] 媒体 app 误命名兜底:改名 {fixed} 个事件")


if __name__ == "__main__":
    main()
