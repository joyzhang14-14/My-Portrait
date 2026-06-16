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

CALIBRATION PRIOR
- The distribution is heavily skewed low. ~80% of events should score 0.0-2.0.
- 4.0+ is rare. 4.5+ is exceptional.

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

OUTPUT — return ONLY a JSON array, no prose, no fences:
[{"id": <int>, "evidence": "<quoted fragment>", "impact": <float>}, ...]"""


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
    engine.load()   # Codex 限流时切本地:impact 打分只看事件摘要(已脱敏元数据)
    print(f"[impact] {args.day}: {len(rows)} 事件待打分 · 本地 {engine.DEFAULT_MODEL}")

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
            arr = engine.call(con, args.day, "impact", msgs, expect="array",
                              max_tokens=2500)
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
                imp = max(0.0, min(5.0, float(x.get("impact", 0))))
                w = imp * (1 + math.log(1 + occ_of[e["id"]]))   # 当天:衰减项=1
                con.execute("UPDATE hybrid_events SET impact=?, raw_impact=?, "
                            "impact_evidence=?, weight=? WHERE id=?",
                            (imp, imp, (x.get("evidence") or "")[:300], round(w, 4),
                             e["id"]))
                done += 1
        print(f"  ✓ 批 {i//args.batch}: {len(chunk)} 事件打分")

    # 打分分布概览
    dist = con.execute("SELECT CASE WHEN impact<2 THEN '0-2' WHEN impact<3 THEN '2-3' "
                       "WHEN impact<4 THEN '3-4' ELSE '4+' END b, COUNT(*) "
                       "FROM hybrid_events WHERE day=? AND impact IS NOT NULL "
                       "GROUP BY b ORDER BY b", (args.day,)).fetchall()
    print(f"[done] 打分 {done} · 分布 " + " ".join(f"{r['b']}:{r[1]}" for r in dist))


if __name__ == "__main__":
    main()
