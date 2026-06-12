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

CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
"""


def now_ms():
    return int(time.time() * 1000)


def connect():
    con = sqlite3.connect(LAB_DB)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    # 迁移:Phase B(OCR 清洗)的 digest 列。老库无此列时补上。
    cols = [r[1] for r in con.execute("PRAGMA table_info(raw_sessions)")]
    if "digest" not in cols:
        con.execute("ALTER TABLE raw_sessions ADD COLUMN digest TEXT")
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
                "frame_ids,ocr,status,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (day, s["start_ms"], s["end_ms"], s["app"], s.get("window"),
                 s.get("url"), json.dumps(s["frame_ids"]), s["ocr"],
                 s.get("status", "pending"), now_ms()),
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
