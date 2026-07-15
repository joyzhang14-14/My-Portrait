"""数据源(全部只读):
1. ~/.portrait/portrait.sqlite 的 frames → Tier-1 规则 merge → sessions
   (镜像生产 Tier1Merger:app+window 相同 + 间隙 ≤5min;OCR ≥60 字才进 LLM,
   每 session 截 600 字 —— 跟生产 Backfill 的 minOcrChars/maxOcrChars 一致)
2. ~/.portrait/events/<day>/*.md 的 frontmatter → 历史事件卡片(join 候选)
"""
import glob
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import chrome

PORTRAIT_DB = os.path.expanduser("~/.portrait/portrait.sqlite")
EVENTS_DIR = os.path.expanduser("~/.portrait/events")

GAP_MS = 5 * 60 * 1000
# 中间噪音容忍(2026-07-15 用户定案,补上 Tier1Merger 设计文档 §6.4 写了但从未实现的行为):
# 切屏一瞥(≤3 帧且首尾 ≤15 秒)夹在同一 key 的流中间 → 噪音帧整段丢弃,session 不切。
# 时间闸必须有:帧是事件驱动的,静止画面出帧稀,3 帧可能横跨几分钟真活动。
NOISE_MAX_FRAMES = 3
NOISE_MAX_SPAN_MS = 15 * 1000
MIN_OCR_CHARS = 60
# 12000(原2000,云端是 600):质量线 7-02 实测 593/1200 条恰=2000 —— 截断自伤
# (长对话正文保真仅 8%,且污染保真率基线测量)。本地 token 免费,放开到 12000
# 基本等于不截,只兜病态长会话;下游消费者(digest LLM / OCR并集 / 锚点旁路)自行控量。
MAX_OCR_CHARS = 12000
FRAME_LIMIT = 5000          # 镜像生产 frames(on:limit:)


def day_bounds_utc(day: str):
    d = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start = int(d.timestamp() * 1000)
    return start, start + 86_400_000


def read_frames(day: str):
    start, end = day_bounds_utc(day)
    con = sqlite3.connect(f"file:{PORTRAIT_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        return con.execute(
            "SELECT id, timestamp_ms, app_name, window_name, browser_url, "
            "COALESCE(full_text,'') AS full_text FROM frames "
            "WHERE timestamp_ms >= :a AND timestamp_ms < :b "
            "ORDER BY timestamp_ms LIMIT :lim",
            {"a": start, "b": end, "lim": FRAME_LIMIT},
        ).fetchall()
    finally:
        con.close()


def drop_transition_noise(frames):
    """切屏一瞥剔除(在 tier1_merge 之前跑)。

    判定:一段连续同 key 帧,≤NOISE_MAX_FRAMES 帧、首尾 ≤NOISE_MAX_SPAN_MS,
    夹在**同一 key** 的流中间(前后 key 相同),且自身 app 与前后 app 不同
    → 整段丢弃(不进任何 session;用户 2026-07-15 定案:一瞥不统计,只记大事件)。
    丢弃后前后两段自然被 tier1_merge 接回一个 session(gap 含一瞥时长,受 ≤5min 闸约束)。

    保守边界:同 app 的窗口标题闪变不算噪音(标题变=内容变,丢了伤真活动);
    A→b→C(前后不同流)不算夹心,不丢 —— 那类残余碎片由 v12_day 的存根层接住。
    """
    key = lambda f: (f["app_name"], f["window_name"] or "")
    out, i, n = [], 0, len(frames)
    while i < n:
        j = i
        while j < n and key(frames[j]) == key(frames[i]):
            j += 1
        run = frames[i:j]
        span = run[-1]["timestamp_ms"] - run[0]["timestamp_ms"]
        prev_key = key(out[-1]) if out else None
        next_key = key(frames[j]) if j < n else None
        if (len(run) <= NOISE_MAX_FRAMES and span <= NOISE_MAX_SPAN_MS
                and prev_key is not None and prev_key == next_key
                and run[0]["app_name"] != out[-1]["app_name"]):
            i = j          # 夹在同一条流中间的异 app 一瞥 → 丢弃
            continue
        out.extend(run)
        i = j
    return out


def tier1_merge(frames):
    """app+window 相同且间隙 ≤5min 的连续帧并成一个 session。"""
    sessions = []
    cur = None
    for f in frames:
        key = (f["app_name"], f["window_name"] or "")
        if (cur is not None and key == cur["key"]
                and f["timestamp_ms"] - cur["end_ms"] <= GAP_MS):
            cur["end_ms"] = f["timestamp_ms"]
            cur["frame_ids"].append(f["id"])
            cur["texts"].append(f["full_text"])
            if f["browser_url"] and not cur["url"]:
                cur["url"] = f["browser_url"]
            continue
        if cur is not None:
            sessions.append(cur)
        cur = {
            "key": key, "app": f["app_name"], "window": f["window_name"] or "",
            "url": f["browser_url"] or "", "start_ms": f["timestamp_ms"],
            "end_ms": f["timestamp_ms"], "frame_ids": [f["id"]],
            "texts": [f["full_text"]],
        }
    if cur is not None:
        sessions.append(cur)
    return sessions


def finish_session(s):
    """texts 去重拼接 + 截断,落库形态。OCR 不足 60 字 → skipped_no_ocr
    (仍入库留审计,镜像生产 dropped 统计)。
    v3 #1:每帧进 LLM 前确定性剥 UI chrome(菜单栏/时钟/默认标签),让
    4B 第一眼看到真实内容。v3 #2:媒体 app 空 window + dev 信号 → bg_media。"""
    seen, parts, total = set(), [], 0
    for t in s["texts"]:
        t = chrome.strip_session_text((t or "").strip())
        if not t or t in seen:
            continue
        seen.add(t)
        parts.append(t)
        total += len(t)
        if total >= MAX_OCR_CHARS:
            break
    ocr = " ⏎ ".join(parts)[:MAX_OCR_CHARS]
    return {
        "start_ms": s["start_ms"], "end_ms": s["end_ms"], "app": s["app"],
        "window": s["window"], "url": s["url"], "frame_ids": s["frame_ids"],
        "ocr": ocr,
        "bg_media": 1 if chrome.is_background_media(s["app"], s["window"], ocr) else 0,
        "status": "pending" if len(ocr) >= MIN_OCR_CHARS else "skipped_no_ocr",
    }


def load_day_sessions(day: str):
    return [finish_session(s) for s in tier1_merge(drop_transition_noise(read_frames(day)))]


# ---------------- 历史事件(join 候选) ----------------

_FM_TITLE = re.compile(r"^event_title:\s*\"?(.*?)\"?\s*$", re.M)
_FM_SUMMARY = re.compile(r"^event_summary:\s*\"?(.*?)\"?\s*$", re.M)
_FM_TAGS = re.compile(r"^tags:\s*\[(.*?)\]", re.M)


def load_historical_events(before_day: str, window_days: int = 14):
    """before_day 之前 window_days 内的生产事件卡片。只读 frontmatter。"""
    end = datetime.strptime(before_day, "%Y-%m-%d")
    days = [(end - timedelta(days=i)).strftime("%Y-%m-%d")
            for i in range(1, window_days + 1)]
    out = []
    for d in days:
        for path in sorted(glob.glob(os.path.join(EVENTS_DIR, d, "*.md"))):
            if os.path.basename(path) == "INDEX.md":
                continue
            try:
                text = open(path, encoding="utf-8", errors="replace").read(8000)
            except OSError:
                continue
            title = (_FM_TITLE.search(text) or [None]) and \
                (_FM_TITLE.search(text).group(1) if _FM_TITLE.search(text) else "")
            if not title:
                continue
            summary = _FM_SUMMARY.search(text)
            tags_m = _FM_TAGS.search(text)
            tags = [t.strip().strip('"') for t in tags_m.group(1).split(",")] \
                if tags_m and tags_m.group(1).strip() else []
            rel = os.path.relpath(path, EVENTS_DIR)
            out.append({
                "rel": rel, "title": title,
                "summary": (summary.group(1) if summary else "")[:200],
                "tags": tags, "day": d,
            })
    return out
