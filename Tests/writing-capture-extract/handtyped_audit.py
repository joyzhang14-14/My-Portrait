#!/usr/bin/env python3
"""按"最终落字"审计:手打并发出/留下的内容,会成为某 event 的 end_value 或 submit;
粘贴后清掉、或打了又删的草稿,只在 delete 里出现,既不是 end_value 也没 submit。
commit 是带删改的中间增量(还常丢),不能直接拿来比 —— 用 end_value/submit 才准。"""
import sqlite3, os, json, datetime, difflib

DB = os.path.expanduser("~/.portrait/portrait.sqlite")
con = sqlite3.connect(DB)

def day_range(d):
    base = int(datetime.datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    return base, base+86400000

def cov(text, blob):
    if not text or not blob: return 0.0
    sm = difflib.SequenceMatcher(None, text, blob, autojunk=False)
    return sum(b.size for b in sm.get_matching_blocks())/len(text)

def streams(ev_ids):
    """收集这组 event 的 submit / end_value / paste / delete 文本"""
    if not ev_ids: return {"submit":"","endval":"","paste":"","delete":""}
    q = "SELECT edit_log, end_value FROM typing_events WHERE id IN (%s)" % ",".join("?"*len(ev_ids))
    sub, ev, pst, dele = [], [], [], []
    for log, endval in con.execute(q, ev_ids).fetchall():
        if endval: ev.append(endval)
        try: entries = json.loads(log)
        except: continue
        for e in entries:
            k, t = e.get("kind"), e.get("text", "")
            if not t: continue
            if k == "submit": sub.append(t)
            elif k == "paste": pst.append(t)
            elif k == "delete": dele.append(t)
    return {"submit":"".join(sub), "endval":"".join(ev), "paste":"".join(pst), "delete":"".join(dele)}

def audit(table, date):
    lo, hi = day_range(date)
    rows = con.execute(
        f"SELECT id, app, source, text, reference_typing_event_ids "
        f"FROM {table} WHERE start_ts BETWEEN ? AND ?", (lo, hi)).fetchall()
    flagged, kept, canvas, noref = [], 0, 0, 0
    for rid, app, source, text, refs in rows:
        if source not in ("ax_cleaned", "merged"):
            canvas += 1; continue
        try: ev_ids = [int(x) for x in (json.loads(refs) if refs else [])]
        except: ev_ids = []
        if not ev_ids:
            noref += 1; continue
        s = streams(ev_ids)
        final_cov = max(cov(text, s["submit"]), cov(text, s["endval"]))   # 发出去/最终留下
        paste_cov = cov(text, s["paste"])                                  # 来自粘贴
        del_cov   = cov(text, s["delete"])                                 # 出现在删除块
        if final_cov < 0.50:        # 既没发出、也不是字段最终值 = 草稿/被清掉,没真留下
            why = "纯粘贴" if paste_cov >= 0.7 else ("删除块/草稿" if del_cov >= 0.5 else "无来源")
            flagged.append((rid, app.split(".")[-1], source, final_cov, paste_cov, del_cov, why, text))
        else:
            kept += 1
    return rows, flagged, kept, canvas, noref

DATES = ["2026-05-27", "2026-05-28", "2026-05-29", "2026-06-05"]
TABLES = [("库里", "writing_records"), ("新跑", "writing_records_staged")]

for date in DATES:
    print(f"\n{'='*72}\n{date}")
    for label, tbl in TABLES:
        rows, flagged, kept, canvas, noref = audit(tbl, date)
        print(f"  [{label}/{tbl}] 总{len(rows)} | 留(真发出/最终值){kept} | "
              f"⚠️没真留下{len(flagged)} | canvas{canvas} | 无ref{noref}")
        for rid, app, source, fc, pc, dc, why, text in flagged:
            head = text.replace("\n", " ")[:44]
            print(f"      #{rid} {app}/{source} [{why}] final{fc:.0%} paste{pc:.0%} del{dc:.0%}  {head!r}")
