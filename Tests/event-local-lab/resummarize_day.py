#!/usr/bin/env python3
"""hybrid 后处理:join 合并后给大事件重写 title+summary。

问题:hybrid_cluster 的跨批 join 只追加成员、不重写摘要 → 大事件(h6/229、
h7/355)的 summary 停在创建批的视角,反映不了它后来吸收的整天工作。

本阶段:对成员数 >= --min-members 的事件,沿成员时间轴**均匀采样**若干 digest
(看到事件首→尾的完整弧线),让云端重写一版忠实覆盖全程的 title+summary。

  python3 resummarize_day.py --day 2026-06-07 [--min-members 10] [--sample 24] [--force]

断点续:hybrid_events.resummarized 标记列,重跑跳过已重写;--force 重做。
⚠️ 走云端(Codex),跑前确认。
"""
import argparse
import json
import time

import cloud
import engine
import labdb

SYSTEM = ("You write one faithful event record for a personal memory system, "
          "from privacy-redacted activity digests. Answer with ONE JSON object only.")


def hhmm(ms):
    t = time.gmtime(ms // 1000)
    return f"{t.tm_hour:02d}:{t.tm_min:02d}"


def _sample(members, k):
    """沿(已按时间排序的)成员均匀取 k 个,首尾必含。"""
    if len(members) <= k:
        return members
    step = (len(members) - 1) / (k - 1)
    idx = sorted({round(i * step) for i in range(k)})
    return [members[i] for i in idx]


def _prompt(title, n, span, cards):
    user = f"""This is ONE event from a user's day, currently titled "{title}".
It was assembled from {n} screen-activity sessions spanning {span}. Below are
representative activity digests sampled chronologically across the WHOLE event:

{cards}

Rewrite a faithful record reflecting the ENTIRE span (not just the start).
- "title": <=60 chars, what the user was DOING across this event (no "App — Window").
- "summary": 3-5 sentences, third person ("the user"/"they"), citing concrete
  topics/entities from the digests. If the work shifted start→end, reflect that arc.
  The digests are already redacted — describe faithfully, don't invent specifics.

Answer ONLY JSON: {{"title": "...", "summary": "..."}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--min-members", type=int, default=10)
    ap.add_argument("--sample", type=int, default=24)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    day = args.day

    con = labdb.connect()
    cols = [r[1] for r in con.execute("PRAGMA table_info(hybrid_events)")]
    if "resummarized" not in cols:
        con.execute("ALTER TABLE hybrid_events ADD COLUMN resummarized INTEGER DEFAULT 0")
        con.commit()

    # 成员 digest:全天 session 一次性读进 dict 索引(避免动态 IN)
    sess = {r["id"]: r for r in con.execute(
        "SELECT id,start_ms,end_ms,app,window,digest FROM raw_sessions "
        "WHERE day=? AND digest IS NOT NULL", (day,)).fetchall()}

    evs = con.execute("SELECT id,title,member_ids,resummarized FROM hybrid_events "
                      "WHERE day=? ORDER BY id", (day,)).fetchall()
    todo = [e for e in evs if len(json.loads(e["member_ids"])) >= args.min_members
            and (args.force or not e["resummarized"])]
    if not todo:
        print(f"{day}: 无需重写(>= {args.min_members} 成员且未重写的事件为 0)。")
        return
    print(f"[resummarize] {day}: {len(todo)} 个事件待重写 · provider="
          f"{cloud.load_config()['provider']}")

    done = 0
    for e in todo:
        members = [m for m in json.loads(e["member_ids"]) if m in sess]
        members.sort(key=lambda m: sess[m]["start_ms"])
        if not members:
            continue
        span = f"{hhmm(sess[members[0]]['start_ms'])}-{hhmm(sess[members[-1]]['end_ms'])} UTC"
        picks = _sample(members, args.sample)
        cards = "\n".join(
            f"[{hhmm(sess[m]['start_ms'])}] {sess[m]['app']}: "
            f"{(sess[m]['digest'] or '').splitlines()[0][:140]}" for m in picks)
        msgs = _prompt(e["title"], len(members), span, cards)
        pc = sum(len(x["content"]) for x in msgs)
        try:
            raw, lat = cloud.cloud_call(msgs, timeout=180)
            obj = engine.parse_json(raw, "object")
            title = (obj.get("title") or e["title"]).strip()[:120]
            summary = (obj.get("summary") or "").strip()
            if not summary:
                raise ValueError("空 summary")
            with con:
                con.execute("UPDATE hybrid_events SET title=?, summary=?, "
                            "resummarized=1, updated_at_ms=? WHERE id=?",
                            (title, summary, labdb.now_ms(), e["id"]))
                con.execute("INSERT INTO llm_calls(ts_ms,day,purpose,session_id,"
                            "prompt_chars,output,ok,latency_ms) VALUES(?,?,?,?,?,?,?,?)",
                            (labdb.now_ms(), day, "resummarize", None, pc,
                             (raw or "")[:2000], 1, lat))
            done += 1
            print(f"  ✓ h{e['id']} ({len(members)}s) → {title[:55]} · {lat}ms")
        except KeyboardInterrupt:
            print(f"\n[stop] 中断,已重写 {done},重跑续。")
            return
        except Exception as ex:                            # noqa: BLE001
            print(f"  ✗ h{e['id']} → ERROR {ex}(未标记,重跑会再试)")

    print(f"[done] 重写 {done} 个 → 重新生成报告 report_hybrid.py --day {day}")


if __name__ == "__main__":
    main()
