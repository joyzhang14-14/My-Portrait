"""事件/对象上下文 join —— 把 writing_records 关联到 event-local-lab 的
raw_sessions / vision_items / events,给每条写作记录补上:

  - scope   : 对象/场景标签(来自 session 的 window 标题,如 "@zer02 - Discord"
              = 私聊对象、"#皇片 | 头尖尖 - Discord" = 频道)。**确定性来源**,
              遵守审查结论:对象只从 window/thread 标签推,绝不从消息内容猜。
  - vision  : 该时间窗 vision_items 的关键条目(Server/Channel/User/在看什么),
              喂给维度 agent 当场景证据。
  - event   : 当天事件标题(events / v4_events 若该天跑过),场景轴。

join 全部确定性:app 名映射(bundle_id ↔ event-lab 的 app_name)+ 时间窗重叠。
event-lab lab.db 只读。
"""
import json
import os
import re
import sqlite3

EVENT_LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "event-local-lab", "lab.db")

# bundle_id → event-lab app_name(frames.app_name)。查不到就用最后一段模糊匹配。
BUNDLE_TO_NAME = {
    "com.hnc.Discord": "Discord",
    "com.anthropic.claudefordesktop": "Claude",
    "com.google.Chrome": "Google Chrome",
    "com.apple.Safari": "Safari",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.apple.MobileSMS": "Messages",
    "md.obsidian": "Obsidian",
    "com.microsoft.VSCode": "Code",
    "com.apple.Terminal": "Terminal",
}


def _ro():
    con = sqlite3.connect(f"file:{EVENT_LAB_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _names_for_bundle(bundle: str):
    if bundle in BUNDLE_TO_NAME:
        return [BUNDLE_TO_NAME[bundle]]
    tail = bundle.split(".")[-1]
    return [tail, tail.capitalize()]


def scope_from_window(window: str, app_name: str) -> str:
    """window 标题 → 对象/场景短标签。确定性剥 app 名 chrome。
    "@zer02 - Discord" → "@zer02"(私聊) / "#皇片 | 头尖尖 - Discord" → "#皇片 | 头尖尖"
    剥不出来就原样;空 window → "(无窗口)"。"""
    w = (window or "").strip()
    if not w:
        return "(无窗口)"
    w = re.sub(rf"\s*[-—|·]\s*{re.escape(app_name)}\s*$", "", w, flags=re.I)
    return w.strip() or "(无窗口)"


def sessions_for_day(day: str):
    """event-lab 当天 raw_sessions(带 window)。"""
    con = _ro()
    try:
        return con.execute(
            "SELECT id, start_ms, end_ms, app, window FROM raw_sessions "
            "WHERE day=:d ORDER BY start_ms", {"d": day}).fetchall()
    finally:
        con.close()


def vision_for_sessions(day: str, session_ids):
    """session_id → vision items(list[str],截前 12 条)。"""
    if not session_ids:
        return {}
    con = _ro()
    try:
        qmarks = ",".join("?" for _ in session_ids)
        rows = con.execute(
            f"SELECT session_key, items FROM vision_items "
            f"WHERE day=? AND session_key IN ({qmarks})",
            [day, *session_ids]).fetchall()
        out = {}
        for r in rows:
            try:
                arr = json.loads(r["items"])
                if isinstance(arr, list) and arr:
                    out[r["session_key"]] = [str(x)[:120] for x in arr[:12]]
            except Exception:
                continue
        return out
    finally:
        con.close()


def events_for_day(day: str):
    """当天事件标题列表(v4_events 优先,fallback events)。没跑过返回 []。"""
    con = _ro()
    try:
        for table in ("v4_events", "events"):
            try:
                rows = con.execute(
                    f"SELECT title FROM {table} WHERE day=:d", {"d": day}).fetchall()
                if rows:
                    return [r["title"] for r in rows]
            except sqlite3.OperationalError:
                continue
        return []
    finally:
        con.close()


def attach_scope(day: str, records):
    """给 writing_records(labdb rows:start_ts/end_ts/app)逐条附加
    {scope, window, vision:[...]}——按 app 名匹配 + 时间窗重叠最大的 session。
    返回 {record_id: ctx}。没匹配的记录不在 dict 里(调用方按 scope="(未匹配)"处理)。"""
    sessions = sessions_for_day(day)
    out = {}
    hit_sessions = set()
    per_rec_sess = {}
    for r in records:
        names = [n.lower() for n in _names_for_bundle(r["app"])]
        best, best_ov = None, 0
        for s in sessions:
            sa = (s["app"] or "").lower()
            if not any(n in sa or sa in n for n in names):
                continue
            ov = min(r["end_ts"], s["end_ms"]) - max(r["start_ts"], s["start_ms"])
            if ov > best_ov:
                best, best_ov = s, ov
        if best is None:
            continue
        hit_sessions.add(best["id"])
        per_rec_sess[r["id"]] = best
    vision = vision_for_sessions(day, list(hit_sessions))
    for rid, s in per_rec_sess.items():
        app_name = s["app"] or ""
        out[rid] = {
            "scope": scope_from_window(s["window"], app_name),
            "window": s["window"] or "",
            "vision": vision.get(s["id"], []),
        }
    return out
