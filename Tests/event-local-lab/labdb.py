"""lab.db —— 断点续跑的真相库。

核心约束(用户定):每处理一簇 raw data → event 先写库 → 写库成功后才把
对应 raw data 标 completed。这里把"写 event + 标 completed"做成**同一个
事务**,崩溃/Ctrl-C 后重跑自动跳过 completed 的 session。
"""
import json
import os
import sqlite3
import time

LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lab.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS raw_sessions(
  id            INTEGER PRIMARY KEY,
  day           TEXT NOT NULL,
  start_ms      INTEGER NOT NULL,
  end_ms        INTEGER NOT NULL,
  app           TEXT NOT NULL,
  window        TEXT,
  url           TEXT,
  frame_ids     TEXT NOT NULL,          -- json [int]
  ocr           TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending',  -- pending/completed/skipped_no_ocr/failed
  event_id      INTEGER,                -- 归属(completed 时必填)
  error         TEXT,
  updated_at_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_sessions_day ON raw_sessions(day, status);

CREATE TABLE IF NOT EXISTS events(
  id            INTEGER PRIMARY KEY,
  day           TEXT NOT NULL,
  title         TEXT NOT NULL,
  summary       TEXT NOT NULL,
  type          TEXT NOT NULL DEFAULT 'experience',
  facets        TEXT NOT NULL DEFAULT '[]',   -- json [str]
  tags          TEXT NOT NULL DEFAULT '[]',   -- json [str]
  member_ids    TEXT NOT NULL DEFAULT '[]',   -- json [session id]
  joined_rel    TEXT,                          -- 历史事件 relPath(finalize join)
  status        TEXT NOT NULL DEFAULT 'open',  -- open/merged/finalized
  merged_into   INTEGER,                       -- status=merged 时指向幸存者
  created_at_ms INTEGER,
  updated_at_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_events_day ON events(day, status);

CREATE TABLE IF NOT EXISTS llm_calls(
  id           INTEGER PRIMARY KEY,
  ts_ms        INTEGER,
  day          TEXT,
  purpose      TEXT,        -- decide/describe/summarize/merge/join
  session_id   INTEGER,
  prompt_chars INTEGER,
  output       TEXT,
  ok           INTEGER,
  latency_ms   INTEGER
);

CREATE TABLE IF NOT EXISTS chapters(
  id            INTEGER PRIMARY KEY,
  day           TEXT NOT NULL,
  seq           INTEGER NOT NULL,        -- 章节顺序
  title         TEXT NOT NULL,
  narrative     TEXT NOT NULL,           -- outline 写的章节叙事
  session_ids   TEXT NOT NULL DEFAULT '[]',
  event_id      INTEGER,                 -- Phase C 落成的事件
  status        TEXT NOT NULL DEFAULT 'open',   -- open/eventized
  created_at_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_chapters_day ON chapters(day, seq);

-- 视觉层留存:每 session 视觉模型(Qwen3-VL-8B)看图产出的 items,durable 供其他 pipeline 复用。
-- 键=day+session_key(v4 merged-session 的锚点 part id);幂等 upsert。items 是原始视觉产物,
-- 不含下游 14B 的 doing/kw(那些在 视觉增量v4b-<day>.md)。
CREATE TABLE IF NOT EXISTS vision_items(
  day           TEXT NOT NULL,
  session_key   INTEGER NOT NULL,
  parts         TEXT NOT NULL DEFAULT '[]',   -- json [raw_sessions.id]
  app           TEXT,
  model         TEXT,
  total_frames  INTEGER,
  kept_frames   INTEGER,
  items         TEXT NOT NULL DEFAULT '[]',   -- json [str] 视觉逐帧 append-only 产物
  created_ms    INTEGER,
  PRIMARY KEY(day, session_key)
);
CREATE INDEX IF NOT EXISTS idx_vision_day ON vision_items(day);

CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
"""


def now_ms():
    return int(time.time() * 1000)


def connect():
    con = sqlite3.connect(LAB_DB)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    # 迁移:Phase B(OCR 清洗)的 digest 列 + v3 的 bg_media 列。老库补。
    cols = [r[1] for r in con.execute("PRAGMA table_info(raw_sessions)")]
    if "digest" not in cols:
        con.execute("ALTER TABLE raw_sessions ADD COLUMN digest TEXT")
    if "bg_media" not in cols:
        con.execute("ALTER TABLE raw_sessions ADD COLUMN bg_media INTEGER DEFAULT 0")
    return con


def sessions_needing_clean(con, day):
    return con.execute(
        "SELECT * FROM raw_sessions WHERE day=? AND status='pending' "
        "AND digest IS NULL ORDER BY start_ms", (day,)
    ).fetchall()


def set_digest(con, sess_id, digest):
    with con:
        con.execute("UPDATE raw_sessions SET digest=?, updated_at_ms=? WHERE id=?",
                    (digest, now_ms(), sess_id))


def mark_noise(con, sess_id):
    with con:
        con.execute("UPDATE raw_sessions SET status='skipped_noise', "
                    "updated_at_ms=? WHERE id=?", (now_ms(), sess_id))


def day_ingested(con, day):
    return con.execute(
        "SELECT COUNT(*) FROM raw_sessions WHERE day=?", (day,)
    ).fetchone()[0] > 0


def ingest_sessions(con, day, sessions):
    """sessions: list[dict]。幂等由调用方用 day_ingested 把关。"""
    with con:
        for s in sessions:
            con.execute(
                "INSERT INTO raw_sessions(day,start_ms,end_ms,app,window,url,"
                "frame_ids,ocr,bg_media,status,updated_at_ms) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (day, s["start_ms"], s["end_ms"], s["app"], s.get("window"),
                 s.get("url"), json.dumps(s["frame_ids"]), s["ocr"],
                 s.get("bg_media", 0), s.get("status", "pending"), now_ms()),
            )


def pending_sessions(con, day):
    return con.execute(
        "SELECT * FROM raw_sessions WHERE day=? AND status='pending' "
        "ORDER BY start_ms", (day,)
    ).fetchall()


def open_events(con, day):
    return con.execute(
        "SELECT * FROM events WHERE day=? AND status='open' ORDER BY id", (day,)
    ).fetchall()


def complete_session_new_event(con, sess_id, day, desc):
    """NEW 路径:建事件 + 标 completed,单事务。返回 event_id。"""
    with con:
        cur = con.execute(
            "INSERT INTO events(day,title,summary,type,facets,tags,member_ids,"
            "created_at_ms,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?)",
            (day, desc["title"], desc["summary"], desc.get("type", "experience"),
             json.dumps(desc.get("facets", []), ensure_ascii=False),
             json.dumps(desc.get("tags", []), ensure_ascii=False),
             json.dumps([sess_id]), now_ms(), now_ms()),
        )
        eid = cur.lastrowid
        con.execute(
            "UPDATE raw_sessions SET status='completed', event_id=?, "
            "updated_at_ms=? WHERE id=?", (eid, now_ms(), sess_id),
        )
    return eid


def complete_session_join(con, sess_id, event_id):
    """JOIN 路径:成员追加 + 标 completed,单事务。"""
    with con:
        row = con.execute("SELECT member_ids FROM events WHERE id=?",
                          (event_id,)).fetchone()
        members = json.loads(row["member_ids"])
        if sess_id not in members:
            members.append(sess_id)
        con.execute("UPDATE events SET member_ids=?, updated_at_ms=? WHERE id=?",
                    (json.dumps(members), now_ms(), event_id))
        con.execute(
            "UPDATE raw_sessions SET status='completed', event_id=?, "
            "updated_at_ms=? WHERE id=?", (event_id, now_ms(), sess_id),
        )


def fail_session(con, sess_id, err):
    """失败:只记 error,**保持 pending** —— 重跑会再试(LLM 偶发失败是常态)。"""
    with con:
        con.execute("UPDATE raw_sessions SET error=?, updated_at_ms=? WHERE id=?",
                    (str(err)[:500], now_ms(), sess_id))


def _ensure_digest_col(con):
    cols = [r[1] for r in con.execute("PRAGMA table_info(vision_items)")]
    if "digest" not in cols:          # v1.2 结构化 digest(activity/who/context/specifics/social)
        with con:
            con.execute("ALTER TABLE vision_items ADD COLUMN digest TEXT")


def save_vision_digest(con, day, key, parts, app, model, total_frames, kept_frames, digest):
    """v1.2 会话级结构化 digest 落库(可复用资产:event / writing-style / personality 都吃这张表)。"""
    _ensure_digest_col(con)
    with con:
        con.execute(
            "INSERT INTO vision_items(day,session_key,parts,app,model,total_frames,"
            "kept_frames,items,digest,created_ms) VALUES(?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(day,session_key) DO UPDATE SET model=excluded.model,"
            "digest=excluded.digest,created_ms=excluded.created_ms",
            (day, int(key), json.dumps(parts), app, model, total_frames, kept_frames,
             "[]", json.dumps(digest, ensure_ascii=False), now_ms()))


def vision_digests_for_day(con, day, model=None):
    """{session_key: digest dict} —— 复用入口(不限 event)。"""
    _ensure_digest_col(con)
    sql = "SELECT session_key, digest FROM vision_items WHERE day=:d AND digest IS NOT NULL"
    args = {"d": day}
    if model:
        sql += " AND model=:m"
        args["m"] = model
    return {r[0]: json.loads(r[1]) for r in con.execute(sql, args)}


def save_vision_items(con, day, key, parts, app, model, total_frames, kept_frames, items):
    """视觉产物 durable 落库(幂等 upsert)。供其他 pipeline 复用,不再赌 /tmp。"""
    with con:
        con.execute(
            "INSERT OR REPLACE INTO vision_items(day,session_key,parts,app,model,"
            "total_frames,kept_frames,items,created_ms) VALUES(?,?,?,?,?,?,?,?,?)",
            (day, int(key), json.dumps(parts), app, model, total_frames, kept_frames,
             json.dumps(items, ensure_ascii=False), now_ms()))


def vision_items_for_day(con, day):
    """{session_key: {parts, app, model, items, ...}} —— 复用入口。"""
    out = {}
    for r in con.execute("SELECT * FROM vision_items WHERE day=?", (day,)):
        out[r["session_key"]] = {"parts": json.loads(r["parts"]), "app": r["app"],
                                 "model": r["model"], "total_frames": r["total_frames"],
                                 "kept_frames": r["kept_frames"], "items": json.loads(r["items"])}
    return out


def log_call(con, day, purpose, session_id, prompt_chars, output, ok, latency_ms):
    with con:
        con.execute(
            "INSERT INTO llm_calls(ts_ms,day,purpose,session_id,prompt_chars,"
            "output,ok,latency_ms) VALUES(?,?,?,?,?,?,?,?)",
            (now_ms(), day, purpose, session_id, prompt_chars,
             (output or "")[:2000], 1 if ok else 0, latency_ms),
        )


# ---------------- v2 章节 ----------------

def chapters_for_day(con, day):
    return con.execute(
        "SELECT * FROM chapters WHERE day=? ORDER BY seq", (day,)).fetchall()


def insert_chapter(con, day, seq, title, narrative, session_ids):
    with con:
        con.execute(
            "INSERT INTO chapters(day,seq,title,narrative,session_ids,created_at_ms)"
            " VALUES(?,?,?,?,?,?)",
            (day, seq, title, narrative, json.dumps(session_ids), now_ms()))


def outline_progress(con, day):
    """已被任一章节覆盖的 session id 集合(断点续跑:从未覆盖处继续)。"""
    covered = set()
    for ch in chapters_for_day(con, day):
        covered.update(json.loads(ch["session_ids"]))
    return covered


def eventize_chapter(con, chapter_id, event_id, member_ids):
    """章节 → 事件 + 全部成员 session 标 completed,单事务。"""
    with con:
        con.execute("UPDATE chapters SET event_id=?, status='eventized' WHERE id=?",
                    (event_id, chapter_id))
        for sid in member_ids:
            con.execute(
                "UPDATE raw_sessions SET status='completed', event_id=?, "
                "updated_at_ms=? WHERE id=?", (event_id, now_ms(), sid))
