"""lab.db —— 断点续跑的真相库(同 event-local-lab/labdb 的路子)。

约束:确定性特征在 ingest 时算好写库;LLM 阶段一 (group × dimension) 一行
facet,写成功即 completed。崩溃/Ctrl-C 重跑靠 facets 表已有行自动跳过。

生产库(~/.portrait/portrait.sqlite)永远只读,本库是本地镜像 + 产出。
"""
import json
import os
import sqlite3
import time

LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lab.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS records(
  id           INTEGER PRIMARY KEY,      -- = 生产 writing_records.id
  day          TEXT NOT NULL,
  start_ts     INTEGER NOT NULL,
  end_ts       INTEGER NOT NULL,
  app          TEXT NOT NULL,
  url          TEXT,
  kind         TEXT,
  source       TEXT,
  text         TEXT NOT NULL,
  edit_log     TEXT NOT NULL DEFAULT '[]',
  context_summary TEXT,
  ks_count     INTEGER NOT NULL DEFAULT 0,   -- 命中的原始击键数(app+时间窗 join)
  features     TEXT NOT NULL DEFAULT '{}',   -- 确定性特征 json(见 features.py)
  ingested_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_records_day ON records(day, app);

CREATE TABLE IF NOT EXISTS facets(
  id           INTEGER PRIMARY KEY,
  day          TEXT NOT NULL,
  group_key    TEXT NOT NULL,      -- 上下文分组键(默认 = app bundle)
  group_label  TEXT,              -- 人类可读上下文名(如 "Slack")
  dim          TEXT NOT NULL,      -- 维度 key(见 dimensions.py)
  present      INTEGER NOT NULL DEFAULT 0,   -- 这个维度有没有值得记的习惯
  label        TEXT,
  pattern      TEXT,
  evidence     TEXT NOT NULL DEFAULT '[]',   -- json [str]
  confidence   TEXT,
  model        TEXT,
  raw          TEXT,              -- 模型原始 json,审计用
  created_at   INTEGER,
  UNIQUE(day, group_key, dim)
);
CREATE INDEX IF NOT EXISTS idx_facets_day ON facets(day, group_key);

CREATE TABLE IF NOT EXISTS llm_calls(
  id           INTEGER PRIMARY KEY,
  ts_ms        INTEGER,
  day          TEXT,
  purpose      TEXT,          -- = dimension key
  group_key    TEXT,
  prompt_chars INTEGER,
  output       TEXT,
  ok           INTEGER,
  latency_ms   INTEGER,
  model        TEXT
);

CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
"""


def now_ms():
    return int(time.time() * 1000)


def connect():
    con = sqlite3.connect(LAB_DB)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    return con


# ---------------- ingest ----------------

def day_ingested(con, day):
    return con.execute("SELECT COUNT(*) FROM records WHERE day=?",
                       (day,)).fetchone()[0] > 0


def upsert_record(con, r):
    """r: dict(id,day,start_ts,end_ts,app,url,kind,source,text,edit_log,
    context_summary,ks_count,features)。幂等 REPLACE(重算特征可覆盖)。"""
    with con:
        con.execute(
            "INSERT OR REPLACE INTO records(id,day,start_ts,end_ts,app,url,kind,"
            "source,text,edit_log,context_summary,ks_count,features,ingested_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (r["id"], r["day"], r["start_ts"], r["end_ts"], r["app"], r.get("url"),
             r.get("kind"), r.get("source"), r["text"], r.get("edit_log", "[]"),
             r.get("context_summary"), r.get("ks_count", 0),
             json.dumps(r.get("features", {}), ensure_ascii=False), now_ms()),
        )


def records_for_day(con, day):
    return con.execute("SELECT * FROM records WHERE day=? ORDER BY start_ts",
                       (day,)).fetchall()


def groups_for_day(con, day):
    """按 group_key(app)聚合当天记录。返回 [(group_key, [rows])]。"""
    rows = records_for_day(con, day)
    groups = {}
    for r in rows:
        groups.setdefault(r["app"], []).append(r)
    return sorted(groups.items(), key=lambda kv: -len(kv[1]))


# ---------------- facets(LLM 产出) ----------------

def facet_done(con, day, group_key, dim):
    return con.execute(
        "SELECT 1 FROM facets WHERE day=? AND group_key=? AND dim=?",
        (day, group_key, dim)).fetchone() is not None


def write_facet(con, day, group_key, group_label, dim, out, model):
    with con:
        con.execute(
            "INSERT OR REPLACE INTO facets(day,group_key,group_label,dim,present,"
            "label,pattern,evidence,confidence,model,raw,created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (day, group_key, group_label, dim,
             1 if out.get("present") else 0, out.get("label"), out.get("pattern"),
             json.dumps(out.get("evidence", []), ensure_ascii=False),
             out.get("confidence"), model,
             json.dumps(out, ensure_ascii=False), now_ms()),
        )


def facets_for_day(con, day):
    return con.execute(
        "SELECT * FROM facets WHERE day=? ORDER BY group_key, dim",
        (day,)).fetchall()


def log_call(con, day, purpose, group_key, prompt_chars, output, ok,
             latency_ms, model):
    with con:
        con.execute(
            "INSERT INTO llm_calls(ts_ms,day,purpose,group_key,prompt_chars,"
            "output,ok,latency_ms,model) VALUES(?,?,?,?,?,?,?,?,?)",
            (now_ms(), day, purpose, group_key, prompt_chars,
             (output or "")[:2000], 1 if ok else 0, latency_ms, model),
        )
