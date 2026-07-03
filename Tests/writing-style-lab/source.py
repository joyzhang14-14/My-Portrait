"""数据源(生产库全部只读)—— ~/.portrait/portrait.sqlite。

对每条 writing_record:
  1. 按 app(bundle_id)+ 时间窗 [start_ts,end_ts] join keystroke_log 取原始击键
     (**不**用 reference_keystroke_range —— 实测多为 '{}',见审查文档);
  2. 确定性算特征(features.record_features);
  3. 写进本地 lab.db(labdb.upsert_record)。

过滤同生产 distiller:edit_log 空的记录(粘贴/CLI import,无击键时序)跳过。
"""
import os
import sqlite3
from datetime import datetime, timezone

import features
import labdb

PORTRAIT_DB = os.path.expanduser("~/.portrait/portrait.sqlite")


def _ro():
    con = sqlite3.connect(f"file:{PORTRAIT_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def day_bounds_utc(day: str):
    d = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start = int(d.timestamp() * 1000)
    return start, start + 86_400_000


def available_days():
    con = _ro()
    try:
        rows = con.execute(
            "SELECT DISTINCT date(start_ts/1000,'unixepoch') d, COUNT(*) c "
            "FROM writing_records "
            "WHERE edit_log IS NOT NULL AND edit_log NOT IN ('','[]') "
            "GROUP BY d ORDER BY d"
        ).fetchall()
        return [(r["d"], r["c"]) for r in rows]
    finally:
        con.close()


def _keystrokes(con, app, start_ts, end_ts):
    return con.execute(
        "SELECT ts_ms, char, is_backspace, input_source FROM keystroke_log "
        "WHERE bundle_id=:app AND ts_ms BETWEEN :a AND :b ORDER BY ts_ms",
        {"app": app, "a": start_ts, "b": end_ts},
    ).fetchall()


def ingest_day(lab_con, day: str, *, force=False):
    """把 day 当天的 writing_records + 击键特征灌进 lab.db。幂等。"""
    if labdb.day_ingested(lab_con, day) and not force:
        return 0
    a, b = day_bounds_utc(day)
    con = _ro()
    n = 0
    try:
        recs = con.execute(
            "SELECT id,start_ts,end_ts,app,url,text,edit_log,context_summary,"
            "source,kind FROM writing_records "
            "WHERE start_ts>=:a AND start_ts<:b "
            "AND edit_log IS NOT NULL AND edit_log NOT IN ('','[]') "
            "ORDER BY start_ts",
            {"a": a, "b": b},
        ).fetchall()
        for r in recs:
            ks = _keystrokes(con, r["app"], r["start_ts"], r["end_ts"])
            feats = features.record_features(r["text"], r["edit_log"], ks)
            labdb.upsert_record(lab_con, {
                "id": r["id"], "day": day,
                "start_ts": r["start_ts"], "end_ts": r["end_ts"],
                "app": r["app"], "url": r["url"], "kind": r["kind"],
                "source": r["source"], "text": r["text"],
                "edit_log": r["edit_log"], "context_summary": r["context_summary"],
                "ks_count": len(ks), "features": feats,
            })
            n += 1
    finally:
        con.close()
    return n
