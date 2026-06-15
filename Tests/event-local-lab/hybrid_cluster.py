#!/usr/bin/env python3
"""hybrid 的云端聚类半边 —— 全天脱敏 digest → 云端全局聚类 → 事件。

hybrid 架构(隐私边界):
  OCR 原文(本地·敏感) → [本地 clean·小模型] 脱敏 digest → [redact 闸 PII 掩码]
  → 只有脱敏 digest 上云 → [本道:云端全局聚类+命名+摘要] → 事件落库

为什么云端这半边:本地 14B 在"全天全局视野/事件边界/技术深度"上有结构性天花板
(对比报告已证),云端强模型在这块碾压;而 digest 已脱敏,原文永不出本地。

  python3 hybrid_cluster.py --day 2026-06-07 [--batch 80] [--limit-batches N]
                            [--reset]

无损 A/B:只读现成 digest(不重跑本地 clean、不动本地 events/session 状态),
产出写独立 hybrid_events 表 → 同一天同一批 digest 上,本地 v3 / hybrid / 生产
三方可直接比。
断点续:每批一个事务 + hybrid_progress 记账,Ctrl-C 安全,重跑续。
⚠️ 走云端 API(花你账上的 token),跑之前先跟用户确认。
"""
import argparse
import json
import sys
import time

import cloud
import engine          # 只用 parse_json(不加载 mlx)
import labdb

CLUSTER_MAXTOK = 8000
CARRY_MAX = 40          # 给云端的"今天已成型事件"join 候选上限

HYBRID_SCHEMA = """
CREATE TABLE IF NOT EXISTS hybrid_events(
  id            INTEGER PRIMARY KEY,
  day           TEXT NOT NULL,
  batch_idx     INTEGER NOT NULL,
  title         TEXT NOT NULL,
  summary       TEXT NOT NULL,
  type          TEXT NOT NULL DEFAULT 'experience',
  tags          TEXT NOT NULL DEFAULT '[]',
  facets        TEXT NOT NULL DEFAULT '[]',
  member_ids    TEXT NOT NULL DEFAULT '[]',
  join_ref      TEXT,
  created_at_ms INTEGER,
  updated_at_ms INTEGER);
CREATE INDEX IF NOT EXISTS idx_hev_day ON hybrid_events(day);
CREATE TABLE IF NOT EXISTS hybrid_progress(
  day        TEXT NOT NULL,
  batch_idx  INTEGER NOT NULL,
  status     TEXT NOT NULL DEFAULT 'done',
  n_events   INTEGER,
  ts_ms      INTEGER,
  PRIMARY KEY(day, batch_idx));
"""

SYSTEM = (
    "You cluster a user's screen-activity sessions into semantic EVENTS for a "
    "personal memory system. Input sessions are PRIVACY-REDACTED activity "
    "digests (sensitive specifics already masked). Always answer with ONE JSON "
    "object only.")


def _hhmm(ms):
    t = time.gmtime(ms // 1000)
    return f"{t.tm_hour:02d}:{t.tm_min:02d}"


def _sess_card(r):
    dur = max(1, (r["end_ms"] - r["start_ms"]) // 60000)
    win = r["window"] or "(none)"
    head = f"[{r['id']}] {_hhmm(r['start_ms'])}-{_hhmm(r['end_ms'])} ({dur}min) · {r['app']} — {win}"
    dig = (r["digest"] or "").replace("\n", " ")
    return f"{head}\n    {dig}"


def _carry_cards(con, day):
    rows = con.execute(
        "SELECT id, title, summary, tags FROM hybrid_events WHERE day=? "
        "ORDER BY id DESC LIMIT ?", (day, CARRY_MAX)).fetchall()
    if not rows:
        return "(none yet)"
    out = []
    for r in rows:
        tags = ", ".join(json.loads(r["tags"]))
        out.append(f"[h{r['id']}] {r['title']} — {r['summary'][:100]} · tags: {tags}")
    return "\n".join(out)


def _prompt(day, batch, carry):
    cards = "\n".join(_sess_card(r) for r in batch)
    ids = [r["id"] for r in batch]
    user = f"""Cluster these activity sessions from {day} (UTC) into events.

An EVENT is what the USER was DOING (subject + intent), NOT which app was open.
Many sessions of one activity (e.g. messaging the same person repeatedly) are
ONE event. Sessions across apps serving one task are ONE event.

Events already formed earlier today (you may JOIN one if this continues it):
{carry}

Sessions to cluster (id, time, app — window, then redacted activity digest):
{cards}

HARD RULES (violating any makes the whole output invalid):
- EVERY session id {ids} MUST appear EXACTLY ONCE — inside some event's
  "session_ids", or in top-level "skipped".
- "title": <=60 chars, describes what the user was DOING. NEVER "App — Window".
- "summary": 2-4 sentences, third person ("the user"/"they"). Cite the concrete
  topics/entities AND technical anchors visible in the digests (commit hashes,
  file/function names, error strings, numeric IDs). The digests are already
  redacted — do NOT invent specifics that aren't there; describe faithfully.
- "type": "experience" (default) or "emotion" (only a clear emotional signal).
- "tags": 3-6 lowercase keywords. "portrait_facets": [] unless a STABLE identity
  signal (each {{"facet": "<skills|habits|interests|social|background|\
preferences|goals>", "value": "<short>"}}).
- "session_ids": non-empty list of ids this event covers.
- GRANULARITY: one event = ONE coherent accomplishment/topic, NOT a whole
  project-day. If the user fixed bug A, then built feature B, then chatted —
  that is THREE events, even in the same app/project. Prefer several focused
  events over one mega-bucket; do NOT lump distinct accomplishments together.
- Never bury a small but distinct activity (a brief social chat, a quick
  purchase, a one-off lookup) inside a large coding event — give it its own
  event so it stays visible.
- "join_existing": an "hN" handle ONLY if this event continues the EXACT SAME
  specific task as that one (same bug, same feature, same conversation). A
  different bug/feature in the same project is a NEW event. When unsure, new.

Answer ONLY this JSON:
{{"events": [{{"title": "...", "summary": "...", "type": "experience",
"tags": [...], "portrait_facets": [], "session_ids": [...],
"join_existing": null}}], "skipped": [...]}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def _write_batch(con, day, batch_idx, events, prompt_chars, raw, lat):
    """一批结果落库,单事务:新建/合并 hybrid_events + 记 progress + 记 llm_call。"""
    n = 0
    with con:
        for ev in events:
            sids = [int(x) for x in ev.get("session_ids", []) if str(x).isdigit()
                    or isinstance(x, int)]
            if not sids:
                continue
            title = (ev.get("title") or "").strip()[:120]
            summary = (ev.get("summary") or "").strip()
            if not title or not summary:
                continue
            etype = (ev.get("type") or "experience").lower()
            tags = json.dumps(ev.get("tags") or [], ensure_ascii=False)
            facets = json.dumps(ev.get("portrait_facets") or [], ensure_ascii=False)
            jref = ev.get("join_existing")
            join_id = None
            if isinstance(jref, str) and jref.startswith("h") and jref[1:].isdigit():
                cand = int(jref[1:])
                row = con.execute("SELECT member_ids FROM hybrid_events WHERE "
                                  "id=? AND day=?", (cand, day)).fetchone()
                if row:
                    join_id = cand
            if join_id is not None:                       # 合并进已有事件
                members = json.loads(row["member_ids"])
                for s in sids:
                    if s not in members:
                        members.append(s)
                con.execute("UPDATE hybrid_events SET member_ids=?, updated_at_ms=? "
                            "WHERE id=?", (json.dumps(members), labdb.now_ms(), join_id))
            else:                                          # 新事件
                con.execute(
                    "INSERT INTO hybrid_events(day,batch_idx,title,summary,type,"
                    "tags,facets,member_ids,join_ref,created_at_ms,updated_at_ms) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                    (day, batch_idx, title, summary, etype, tags, facets,
                     json.dumps(sids), jref if isinstance(jref, str) else None,
                     labdb.now_ms(), labdb.now_ms()))
            n += 1
        con.execute("INSERT OR REPLACE INTO hybrid_progress(day,batch_idx,status,"
                    "n_events,ts_ms) VALUES(?,?,?,?,?)",
                    (day, batch_idx, "done", n, labdb.now_ms()))
        con.execute("INSERT INTO llm_calls(ts_ms,day,purpose,session_id,prompt_chars,"
                    "output,ok,latency_ms) VALUES(?,?,?,?,?,?,?,?)",
                    (labdb.now_ms(), day, "hybrid_cluster", None, prompt_chars,
                     (raw or "")[:2000], 1, lat))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--batch", type=int, default=80)
    ap.add_argument("--limit-batches", type=int, default=0)
    ap.add_argument("--reset", action="store_true", help="清空本天 hybrid 产出重跑")
    args = ap.parse_args()

    con = labdb.connect()
    con.executescript(HYBRID_SCHEMA)
    if args.reset:
        with con:
            con.execute("DELETE FROM hybrid_events WHERE day=?", (args.day,))
            con.execute("DELETE FROM hybrid_progress WHERE day=?", (args.day,))
        print(f"[reset] 清空 {args.day} 的 hybrid 产出")

    rows = con.execute(
        "SELECT id, start_ms, end_ms, app, window, url, digest FROM raw_sessions "
        "WHERE day=? AND digest IS NOT NULL ORDER BY start_ms", (args.day,)).fetchall()
    if not rows:
        print(f"{args.day} 没有 digest,先跑 clean_day.py。")
        return
    batches = [rows[i:i + args.batch] for i in range(0, len(rows), args.batch)]
    done = {r[0] for r in con.execute(
        "SELECT batch_idx FROM hybrid_progress WHERE day=? AND status='done'",
        (args.day,)).fetchall()}
    cfg = cloud.load_config()
    print(f"[hybrid] {args.day}: {len(rows)} digest → {len(batches)} 批(×{args.batch}),"
          f"已完成 {len(done)} 批 · provider={cfg['provider']} model={cfg['model']}")

    ran = 0
    for bi, batch in enumerate(batches):
        if bi in done:
            continue
        if args.limit_batches and ran >= args.limit_batches:
            print(f"[stop] 到达 --limit-batches {args.limit_batches}")
            break
        msgs = _prompt(args.day, batch, _carry_cards(con, args.day))
        pc = sum(len(m["content"]) for m in msgs)
        try:
            raw, lat = cloud.cloud_call(msgs, max_tokens=CLUSTER_MAXTOK)
            obj = engine.parse_json(raw, "object")
            events = obj.get("events") or []
            skipped = obj.get("skipped") or []
            n = _write_batch(con, args.day, bi, events, pc, raw, lat)
            # 覆盖率自检(只警告,不阻断)
            covered = {int(s) for e in events for s in e.get("session_ids", [])
                       if str(s).isdigit() or isinstance(s, int)}
            covered |= {int(s) for s in skipped if str(s).isdigit() or isinstance(s, int)}
            ids = {r["id"] for r in batch}
            miss = ids - covered
            warn = f" ⚠ 漏 {len(miss)}" if miss else ""
            print(f"  ✓ 批{bi}: {len(batch)} digest → {n} 事件(skip {len(skipped)})"
                  f" · {lat}ms{warn}")
            ran += 1
        except KeyboardInterrupt:
            print(f"\n[stop] 手动中断。已完成 {len(done)+ran} 批,重跑续。")
            return
        except Exception as e:                            # noqa: BLE001
            con.execute("INSERT INTO llm_calls(ts_ms,day,purpose,session_id,"
                        "prompt_chars,output,ok,latency_ms) VALUES(?,?,?,?,?,?,?,?)",
                        (labdb.now_ms(), args.day, "hybrid_cluster", None, pc,
                         f"ERR {e}", 0, 0))
            con.commit()
            print(f"  ✗ 批{bi} → ERROR {e}(progress 未记,重跑会再试)")

    total = con.execute("SELECT COUNT(*) FROM hybrid_events WHERE day=?",
                        (args.day,)).fetchone()[0]
    print(f"[done] {args.day} hybrid 事件总数 {total} → 下一步 report")


if __name__ == "__main__":
    main()
