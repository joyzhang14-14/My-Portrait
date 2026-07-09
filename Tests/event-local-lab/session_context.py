#!/usr/bin/env python3
"""确定性会话上下文富化:app / 主体(subject)/ 跟谁(with)/ 在哪(where)。

铁律(确定性优先):app 是前台 app(100% 有),window 带 subject/who/where(495/1200 非空,
可靠免费)——这些是元数据,确定性附加,不指望 2507 聚合时保住(实测标题 8/87、tag 18/87 才带)。
产物挂到事件:e["apps"]={前台app:计数}、e["context"]={subjects,with,where}、并把 app/人名并进 tags。

  from session_context import enrich_events; enrich_events(events, con, day)   # in-place
"""
import json
import re
import collections

# app 名 → tag(小写连字符;CJK 名保留原样,可检索)
_APP_TAG = {"my portrait": "my-portrait", "my meeting": "my-meeting", "微信": "wechat",
            "google chrome": "chrome", "notification center": "notification-center"}
# subject 只从这些 GUI app 的 window 挖(window=真文档/页面标题);Terminal/shell 的 window
# 是状态栏残渣(⠐✳ sourcekit-lsp caffeinate),不挖。
_GUI_SUBJECT_APPS = {"safari", "google chrome", "chrome", "obsidian", "xcode", "preview",
                     "finder", "notes", "备忘录", "word", "pages", "keynote", "sourcetree"}
_CHAT_APPS = {"discord", "微信", "wechat", "messages", "信息", "telegram", "whatsapp", "mail", "邮件"}

# window 里的"跟谁"(确定性)
_WHO_RX = [
    re.compile(r"@([^\s|@#-][^|@]*?)\s*[-–]\s*Discord"),        # @何成 - Discord
    re.compile(r"#[^|]*\|\s*([^-–|]+?)\s*[-–]\s*Discord"),      # #皇片 | 头尖尖 - Discord
    re.compile(r"^(.+?)\s*[-–]\s*(?:Messages|信息|Telegram|WhatsApp)\s*$"),
]
# vision items 里的"跟谁"(微信 window 空,靠 items):"与Lucifer的对话"/"chat with X"/"聊天窗口与X"
_WHO_ITEM_RX = [
    re.compile(r"(?:与|和|跟)\s*([^\s的,，]{1,20})\s*的?(?:对话|聊天|消息)"),
    re.compile(r"chat(?:ting)?\s+with\s+([A-Za-z0-9_一-鿿]{1,20})", re.I),
    re.compile(r"聊天窗口与\s*([^\s的,，]{1,20})"),
]
# window/url 里的"在哪"(地图/校/政府域名)
_WHERE_RX = [
    re.compile(r"\b([A-Za-z][\w.-]*\.(?:edu|k12\.[a-z]{2}\.us|gov))\b"),
    re.compile(r"(Google Maps|Apple Maps|Apple 地图|高德地图|百度地图)"),
]
_CTRL = re.compile(r"[⠀-⣿ -⁯✳◂▸●⠐⠂]+")   # 盲文/状态符/残渣
_APP_SUFFIX = re.compile(r"\s*[-–|]\s*(?:Google Chrome|Safari|Obsidian(?:\s+[\d.]+)?"
                         r"|Xcode|Finder|Preview|Sourcetree)\s*$", re.I)


def _norm_tag(app):
    a = (app or "").strip().lower()
    return _APP_TAG.get(a, a.replace(" ", "-"))


def _mine_window(app, window):
    """从 (app, window) 挖 who/where/subject。subject 仅 GUI app;残渣先剥。"""
    w = _CTRL.sub(" ", (window or "")).strip()
    w = re.sub(r"\s{2,}", " ", w)
    al = (app or "").strip().lower()
    subs, whos, wheres = [], [], []
    if not w or w.lower() == al:
        return subs, whos, wheres
    for rx in _WHO_RX:
        m = rx.search(w)
        if m and m.group(1).strip():
            whos.append(m.group(1).strip())
    for rx in _WHERE_RX:
        m = rx.search(w)
        if m:
            wheres.append(m.group(1).strip())
    if not whos and al in _GUI_SUBJECT_APPS:   # subject 只从 GUI app 的干净 window 挖
        s = _APP_SUFFIX.sub("", w).strip(" -–|")
        if s and s.lower() != al and re.search(r"[A-Za-z一-鿿]", s):
            subs.append(s[:60])
    return subs, whos, wheres


def _who_from_items(app, items):
    """微信这类 window 空的,从 vision items 挖聊天对象。"""
    if (app or "").strip().lower() not in _CHAT_APPS:
        return []
    whos = []
    for it in items:
        for rx in _WHO_ITEM_RX:
            m = rx.search(it)
            if m and m.group(1).strip():
                whos.append(m.group(1).strip())
    return whos


def app_profile(session_keys, key2row):
    """{foreground:{app:count}, subjects, with, where}。key2row: id→{app,window,items}。"""
    fg = collections.Counter()
    subs, whos, wheres = [], [], []
    for k in session_keys:
        r = key2row.get(k)
        if not r:
            continue
        fg[r["app"]] += 1
        s, wh, whr = _mine_window(r["app"], r.get("window"))
        subs += s; whos += wh + _who_from_items(r["app"], r.get("items") or []); wheres += whr
    dedup = lambda xs: list(dict.fromkeys(xs))
    return {"foreground": dict(fg.most_common()),
            "subjects": dedup(subs)[:6], "with": dedup(whos)[:6], "where": dedup(wheres)[:4]}


def _md_who_where():
    """审计修复(7-09):汇总层结构化 who/where 一直落在报告 MD 里(- who:/- where: 行),
    enrich 从没吃过 → 事件 context.with 5/65。从 CS.MD 解析,按事件聚合。自己(home
    用户名)从 who 里排除。"""
    import os
    import cluster_skeleton as CS
    me = os.path.basename(os.path.expanduser("~")).lower()
    out = {}
    try:
        md = open(CS.MD).read()
    except Exception:
        return out
    for m in re.finditer(r"\n## s(\d+) · .*?(?=\n## s|\Z)", md, re.S):
        seg, k = m.group(0), int(m.group(1))
        who_m = re.search(r"^- who: (.+)$", seg, re.M)
        where_m = re.search(r"^- where: (.+)$", seg, re.M)
        who = [w.strip() for w in who_m.group(1).split(",")
               if w.strip() and me not in w.strip().lower()] if who_m else []
        where = re.sub(r"[\[\]']", "", where_m.group(1)).strip() if where_m else ""
        if who or where:
            out[k] = (who, where)
    return out


def enrich_events(events, con, day):
    """in-place:给每个事件加 apps/context,并把 app名+人名 确定性并进 tags。"""
    import json as _json
    vitems = {r["session_key"]: _json.loads(r["items"])
              for r in con.execute("SELECT session_key, items FROM vision_items WHERE day=?", (day,))}
    key2row = {r["id"]: {"app": r["app"], "window": r["window"], "items": vitems.get(r["id"], [])}
               for r in con.execute("SELECT id, app, window FROM raw_sessions WHERE day=?", (day,))}
    md_ww = _md_who_where()
    for e in events:
        prof = app_profile(e["session_ids"], key2row)
        e["apps"] = prof["foreground"]
        e["context"] = {"subjects": prof["subjects"], "with": prof["with"], "where": prof["where"]}
        # 并入汇总层 who/where(频次排序,with 上限 6;where 取成员首个非空)
        wc = collections.Counter()
        for k in e["session_ids"]:
            for w in md_ww.get(k, ([], ""))[0]:
                wc[w] += 1
        merged = list(e["context"]["with"])
        for w, _ in wc.most_common():
            if w not in merged:
                merged.append(w)
        e["context"]["with"] = merged[:6]
        if not e["context"]["where"]:
            for k in e["session_ids"]:
                ww = md_ww.get(k, ([], ""))[1]
                if ww:
                    e["context"]["where"] = ww[:80]
                    break
        # 确定性并进 tags:主 app(≥2 段或唯一 app)+ 全部"跟谁"
        tags = list(e.get("tags") or [])
        low = {t.lower() for t in tags}
        add = []
        for app, c in prof["foreground"].items():
            if c >= 2 or len(prof["foreground"]) == 1:
                add.append(_norm_tag(app))
        add += [w for w in prof["with"]]
        for t in add:
            if t and t.lower() not in low:
                tags.append(t); low.add(t.lower())
        e["tags"] = tags
    return events


if __name__ == "__main__":
    import sys, labdb
    day = sys.argv[1] if len(sys.argv) > 1 else "2026-06-07"
    OBS = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local"
    con = labdb.connect()
    ev = json.load(open(f"{OBS}/v7c_local_events-{day}.json"))["events"]
    enrich_events(ev, con, day)
    withc = sum(1 for e in ev if e["context"]["with"])
    print(f"[enrich] {len(ev)} 事件 · 有'跟谁' {withc} · 样例:")
    for e in ev:
        if e["context"]["with"] or len(e["apps"]) > 1:
            print(f"  «{e['title'][:40]}» apps={e['apps']} with={e['context']['with']} "
                  f"subj={e['context']['subjects'][:2]}")
