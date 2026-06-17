#!/usr/bin/env python3
"""hybrid 下游:给 hybrid_events 打 impact 0-5 分 + 算 weight。

照搬生产 ImpactScorer 的 rubric(Prompts.swift:137-178):分布偏低、80% 落 0-2、
4+ 罕见、evidence 必须引摘要片段。云端(Codex)批打分,每批 20 个。

weight = impact × (1+ln(1+occurrence_days))(当天打分,days_since_last=0,衰减项=1)。

  python3 impact_day.py --day 2026-06-07 [--batch 20] [--force]
断点续:impact 列已非空的跳过。⚠️ 云端调用,跑前确认。
"""
import argparse
import json
import math

import cloud
import engine
import labdb

ALPHA = 0.3   # 与生产 config [memory].alpha 一致(衰减项当天为 1,这里只用频次项)

RUBRIC = """You score the long-term IMPORTANCE of each user activity event for the \
user's PERSONAL PROFILE. Scale: 0.0-5.0 (float).

CALIBRATION PRIOR — calibrate the WHOLE batch together, not each in isolation.
- The distribution is heavily skewed low. ~80% of events should score 0.0-2.0.
  In a batch of 20, expect most at 0.5-2.0, only a few at 3.0+, rarely any 4.0+.
- USE THE FULL RANGE, including below 1.0: idle glances, app-switching, a
  background app, checking the time / notifications → 0.0-0.9. Do NOT floor
  everything at 1.0+; a day has genuinely pointless moments.
- If your scores cluster in 2.0-3.0, you are OVER-scoring — pull routine items
  down. Routine coding/browsing/chatting is 1-2, not 3.
- 4.0+ is rare (needs a concrete outcome / decision / milestone in the summary).
  4.5+ is exceptional. Most days have zero 4.0+ events; some have one.

CALIBRATION EXAMPLES (generic — match the SHAPE/scale, not the wording):
  glanced at the clock, switched between apps ............... 0.3
  scrolled a feed / had a song playing in the background .... 1.0
  a few back-and-forth chat messages, checked a dashboard ... 1.5
  read an article, normal browsing, finished routine homework 2.0
  an hour of focused coding that fixed a specific bug ....... 3.2
  weighed options and DECIDED on an architecture / approach . 4.2
  a candid conversation that shifted a relationship ........ 4.6

ANCHORS — calibrate strictly. Most events should be 0-2.
  0.0-0.9  pointless (idle glance, background app, checking the time).
  1.0-1.9  trivial / passive (a few messages, glancing at a dashboard, a song playing).
  2.0-2.9  routine engagement worth noting (chatting a while, reading an article,
           normal browsing, finishing homework, looking something up).
  3.0-3.5  noteworthy activity, a solid completed engagement ("I did X"):
           an hour of focused coding on a feature, a substantive call, an appointment.
  3.6-4.0  noteworthy WITH weight, something shifted/was achieved ("X mattered"):
           a milestone, a revealing conversation, real progress on a stuck problem.
  4.1-4.8  pivotal, might be remembered for a year (a tech decision, an emotionally
           significant exchange, a real decision, a breakthrough).
  4.9-5.0  life-changing.

RULES
- Score from the SUMMARY content, NOT the app or duration. Idle/browsing in any app = 1-2.
- 4.0+ requires a concrete outcome, decision, milestone, or emotional weight in the summary.
- 3.0-3.5 uses verbs did/spent/read/chatted; 3.6-4.0 uses finished/decided/realized.
- Repeated days (high occurrences_days) only MILDLY raise the score. A routine is still a routine.
- "evidence" MUST quote/paraphrase a specific fragment of the summary. No specifics → score <= 2.0.
- "kind": classify the activity from the SUMMARY content (works in ANY language):
    "active"  = hands-on creation / coding / debugging / writing / a real decision,
                or a genuine back-and-forth conversation.
    "passive" = browsing, reading a dashboard, watching, skimming, or merely CHECKING
                an account / usage / billing / limits / settings without changing them.
    "idle"    = pointless glance, a background app, checking the time / notifications.

OUTPUT — return ONLY a JSON array, no prose, no fences:
[{"id": <int>, "kind": "active|passive|idle", "evidence": "<quoted fragment>", "impact": <float>}, ...]"""

# #5 确定性降权:云端模型常给琐事虚高分(2+),不肯用低端量程。语言无关的修法
# = 语义信号让模型出(下面 RUBRIC 要它给 "kind":active/passive/idle,它读内容判、
# 跟标题语言无关),代码只按 kind 卡天花板。这是 A 排序干净的机制(琐事 impact 近 0
# → weight 沉底),但不靠任何硬编码关键词。
_KIND_CEIL = {"idle": 0.5, "passive": 1.2}   # active 不设顶,用模型原分


def _demote(kind, imp):
    """按模型给的 kind 卡上限:idle→≤0.5,passive→≤1.2,active→原分。"""
    ceil = _KIND_CEIL.get((kind or "").strip().lower())
    return min(imp, ceil) if ceil is not None else imp


def _card(con, e):
    m = json.loads(e["member_ids"])
    rows = con.execute("SELECT start_ms,end_ms FROM raw_sessions WHERE id IN "
                       f"({','.join('?'*len(m))})", m).fetchall() if m else []
    dur = max(1, (max(r["end_ms"] for r in rows) - min(r["start_ms"] for r in rows))
              // 60000) if rows else 1
    try:
        occ = len(json.loads(e["occurrences"])) if e["occurrences"] else 1
    except (KeyError, IndexError, TypeError):
        occ = 1
    tags = ", ".join(json.loads(e["tags"]))
    return (f"{e['id']}. title: {e['title']}\n    summary: {e['summary'][:360]}\n"
            f"    meta: tags=[{tags}] · duration≈{dur}min · occurrences_days={occ}"), occ


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    con = labdb.connect()
    for col in ("impact REAL", "raw_impact REAL", "impact_evidence TEXT", "weight REAL"):
        name = col.split()[0]
        if name not in [r[1] for r in con.execute("PRAGMA table_info(hybrid_events)")]:
            con.execute(f"ALTER TABLE hybrid_events ADD COLUMN {col}")
    con.commit()

    rows = con.execute("SELECT * FROM hybrid_events WHERE day=?"
                       + ("" if args.force else " AND impact IS NULL")
                       + " ORDER BY id", (args.day,)).fetchall()
    if not rows:
        print(f"{args.day}: 无待打分事件(全部已有 impact 或无事件)。")
        return
    print(f"[impact] {args.day}: {len(rows)} 事件待打分 · 云端 {args.model}")

    occ_of = {}
    done = 0
    for i in range(0, len(rows), args.batch):
        chunk = rows[i:i + args.batch]
        cards = []
        for e in chunk:
            c, occ = _card(con, e)
            cards.append(c); occ_of[e["id"]] = occ
        msgs = [{"role": "system", "content": "You are a strict importance scorer. "
                 "Answer with ONE JSON array only."},
                {"role": "user", "content": RUBRIC + "\n\nEVENTS:\n" + "\n".join(cards)}]
        try:
            raw, lat = cloud.cloud_call(msgs, model=args.model, max_tokens=2500,
                                        timeout=120)
            arr = engine.parse_json(raw, "array")
            labdb.log_call(con, args.day, "impact", None,
                           sum(len(m["content"]) for m in msgs), raw, True, lat)
        except Exception as ex:                            # noqa: BLE001
            print(f"  ✗ 批 {i//args.batch} ERROR {ex}")
            continue
        by_id = {int(x["id"]): x for x in arr if "id" in x}
        with con:
            for e in chunk:
                x = by_id.get(e["id"])
                if not x:
                    print(f"  ⚠ h{e['id']} 模型没给分,跳过")
                    continue
                raw_imp = max(0.0, min(5.0, float(x.get("impact", 0))))
                imp = _demote(x.get("kind"), raw_imp)  # #5 按模型 kind 卡琐事天花板
                w = imp * (1 + math.log(1 + occ_of[e["id"]]))   # 当天:衰减项=1
                con.execute("UPDATE hybrid_events SET impact=?, raw_impact=?, "
                            "impact_evidence=?, weight=? WHERE id=?",
                            (imp, raw_imp, (x.get("evidence") or "")[:300], round(w, 4),
                             e["id"]))
                done += 1
        print(f"  ✓ 批 {i//args.batch}: {len(chunk)} 事件打分 · {lat}ms")

    # 打分分布概览
    dist = con.execute("SELECT CASE WHEN impact<2 THEN '0-2' WHEN impact<3 THEN '2-3' "
                       "WHEN impact<4 THEN '3-4' ELSE '4+' END b, COUNT(*) "
                       "FROM hybrid_events WHERE day=? AND impact IS NOT NULL "
                       "GROUP BY b ORDER BY b", (args.day,)).fetchall()
    print(f"[done] 打分 {done} · 分布 " + " ".join(f"{r['b']}:{r[1]}" for r in dist))


if __name__ == "__main__":
    main()
