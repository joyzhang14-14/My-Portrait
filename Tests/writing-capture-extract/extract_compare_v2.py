#!/usr/bin/env python3
"""v2: 新 unifiedExtract 加「事件内占位符多发送」拆分。
事件内发送 = commit 背书的 delete,紧挨标记:空事件→空白/零宽;非空事件→占位符
(本事件内既注入(paste/commit)又被 delete、≥6字、含真字符)。这样 claudefordesktop
的 OCR合成/Canvas/可以改OCR 等真发送回来,Spiffy(挨\xa0非占位符)仍排除。"""
import sqlite3, os, json, difflib, re

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def emptyZW(s): return all((c.isspace() or ord(c) in ZW) for c in (s or ''))
def sim(a, b): return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if a and b else 0.0
def cover(v, cs): return sum(b.size for b in difflib.SequenceMatcher(None, v, cs, autojunk=False).get_matching_blocks())/len(v) if v and cs else 0.0
def related(a, b): return sim(a, b) >= 0.5 or a.startswith(b) or b.startswith(a)
def cstream(arr): return ''.join(cv(e.get('text', '') or '') for e in arr if e.get('kind') == 'commit')

def loadev(ids):
    out = []
    for e in ids:
        r = con.execute("SELECT id,session_start,end_value,edit_log,bundle_id,started_at,ended_at FROM typing_events WHERE id=?", (e,)).fetchone()
        if not r: continue
        # 本事件窗内的「回车键」时间戳(区分真发送 vs 退格删的草稿)
        rets = [x[0] for x in con.execute(
            "SELECT ts_ms FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND char IN (?, ?)",
            (r[4], r[5]-2000, r[6]+2000, "\n", "\r")).fetchall()]
        out.append(dict(id=r[0], ss=r[1] or '', endv=r[2] or '', arr=json.loads(r[3]), bundle=r[4],
                        returns=rets, started_at=r[5], ended_at=r[6]))
    return out

# ---- 旧版(占位符集合 ≥3) ----
def collectPH(logs):
    c = {}
    for endv, log in logs:
        evn = cv(endv)
        if not evn: continue
        try: arr = json.loads(log)
        except: continue
        if any((e.get('kind') in ('commit', 'paste')) and cv(e.get('text', '') or '') == evn for e in arr):
            c[evn] = c.get(evn, 0) + 1
    return set(k for k, v in c.items() if v >= 3)
def isReset_o(s, PH): return emptyZW(s) or cv(s) in PH
def within_o(ev, PH):
    arr = ev['arr']; out = []
    for i, e in enumerate(arr):
        if e.get('kind') != 'delete': continue
        raw = e.get('text', '') or ''
        if not raw or isReset_o(raw, PH): continue
        pm = i > 0 and isReset_o(arr[i-1].get('text', '') or '', PH)
        nm = i+1 < len(arr) and isReset_o(arr[i+1].get('text', '') or '', PH)
        if not (pm or nm): continue
        t = cv(raw)
        if len(t) >= 2: out.append(t)
    return out
def oldExtract(evs, PH):
    msgs = []; cur = None
    for k, e in enumerate(evs):
        we = within_o(e, PH); msgs += we
        ev = cv(e['endv']); evReset = isReset_o(e['endv'], PH)
        if not evReset and ev: cur = ev
        nextReset = k+1 < len(evs) and isReset_o(evs[k+1]['ss'], PH)
        if nextReset:
            if cur: msgs.append(cur); cur = None
        elif evReset:
            if cur and not we: msgs.append(cur)
            cur = None
    if cur: msgs.append(cur)
    seen = set(); return [m for m in msgs if m and not (m in seen or seen.add(m))]

# ---- 新版 v2 ----
def phMarkers(arr):
    # 占位符 = app **paste** 注入(不是用户 commit 敲的)又被 delete 清掉的值。
    # 只认 paste:否则把"打了又删的普通词"(sonnet/fang dao)误当占位符标记,
    # 导致紧挨它的中途删除(这边有/生成)被误判成发送。
    inj, dele = set(), set()
    for e in arr:
        k = e.get('kind'); t = cv(e.get('text', '') or '')
        if not t: continue
        if k == 'paste': inj.add(t)
        elif k == 'delete': dele.add(t)
    return {t for t in (inj & dele) if len(t) >= 6 and re.search(r'[A-Za-z一-鿿]', t)}

# run 级占位符:整库以 paste(app 注入)出现 ≥2 次、短、含真字符的值。
# 补 per-event ph 抓不到的「只作为 commit-endValue 静止、不删」的占位符(如 ev1183 的 Write a message…)。
def runPlaceholders():
    cnt = {}
    for (log,) in con.execute("SELECT edit_log FROM typing_events").fetchall():
        try: arr = json.loads(log)
        except: continue
        for e in arr:
            if e.get('kind') == 'paste':
                t = cv(e.get('text', '') or '')
                if t: cnt[t] = cnt.get(t, 0) + 1
    return {k for k, v in cnt.items() if v >= 5 and 6 <= len(k) <= 40 and re.search(r'[A-Za-z一-鿿]', k)}
RUNPH = runPlaceholders()
EMPTY_OK = {0x200B, 0x200C, 0x200D, 0xFEFF, 0x0A, 0x0D, 0x09, 0x20}  # 零宽/换行/制表/普通空格,**不含 \xa0**
def emptyBox(s): return all(ord(c) in EMPTY_OK for c in (s or ''))   # 严格"输入框空"(\xa0 不算)
def withinSends(arr, endEmpty, ph, returns=()):
    cs = cstream(arr); out = []
    def isMark(j):
        if j < 0 or j >= len(arr): return False
        raw = arr[j].get('text', '') or ''
        return emptyBox(raw) or cv(raw) in ph or cv(raw) in RUNPH   # 严格空 或 占位符
    def sent(ts):   # 这条 delete 前 ~1.8s 有回车键 = 真发送;没有(退格删的)= 草稿
        return ts is not None and any(ts-1800 <= rt <= ts+200 for rt in returns)
    for i, e in enumerate(arr):
        if e.get('kind') != 'delete': continue
        t = cv(e.get('text', '') or '')
        if len(t) < 2 or t in ph or t in RUNPH: continue   # 占位符的 delete 本身不抓
        if not (isMark(i-1) or isMark(i+1)): continue
        if cover(t, cs) < 0.5: continue
        if not sent(e.get('ts')): continue                 # 没回车 = 打了又删的草稿,不当发送
        out.append(t)
    return out
def newExtract(evs):
    msgs = []; cur = None
    def emit(m):
        if m and len(m) >= 1: msgs.append(m)
    for k, e in enumerate(evs):
        arr = e['arr']; cs = cstream(arr); endv = cv(e['endv']); endEmpty = emptyZW(e['endv'])
        ph = phMarkers(arr); delset = {cv(x.get('text', '') or '') for x in arr if x.get('kind') == 'delete'}
        for x in arr:
            if x.get('kind') == 'submit':
                st = cv(x.get('text', '') or '')
                if len(st) >= 2:
                    if cur and not related(st, cur): emit(cur)
                    emit(st); cur = None
        for t in withinSends(arr, endEmpty, ph, e.get('returns', ())):
            if cur and not related(t, cur): emit(cur); cur = None
            emit(t)
        if endEmpty:
            cur = None
        elif endv:
            ssv = cv(e['ss'])
            # 注入(占位符/粘贴)= 既没 commit 背书、又不是从 session_start 演进来的。
            # (跨事件长消息前半在上个事件打的,本事件 commit 覆盖低,但 session_start 已含其前缀)
            injected = cover(endv, cs) < 0.2 and not (ssv and related(endv, ssv))
            resting = endv in delset or endv in ph or endv in RUNPH
            if not injected and not resting:
                if cur and not related(endv, cur): emit(cur)
                cur = endv
            elif cur:
                emit(cur); cur = None
        if k+1 < len(evs) and cur:
            ns = cv(evs[k+1]['ss'])
            if emptyZW(evs[k+1]['ss']) or not related(ns, cur):
                emit(cur); cur = None
    if cur: emit(cur)
    seen = set(); return [m for m in msgs if not (m in seen or seen.add(m))]

# ---- 全量对照 ----
def latin_tail(m):  # 末尾生拼音残渣(A组#8会处理),不算回归
    v = m
    while v and v[-1] in ' ' or (v and v[-1].isascii() and v[-1].isalpha()): v = v[:-1]
    return len(m) - len(v)
def is_residue(m): return len(m) <= 4 or latin_tail(m) >= 2
PLH = ['Write a message', 'Type / for commands', 'Describe a task or ask a question']
def is_ph(m): return any(p in m for p in PLH)

DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = collectPH(con.execute("SELECT end_value,edit_log FROM typing_events").fetchall())
tot_o = tot_n = ph_n = regress = 0; reg_list = []
for day in DAYS:
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        evs = loadev(ids)
        if not evs: continue
        old = oldExtract(evs, PH); new = newExtract(evs)
        tot_o += len(old); tot_n += len(new)
        ph_n += sum(1 for m in new if is_ph(m))
        # 真回归 = 旧有、新无、不是占位符、不是残渣
        for m in old:
            if is_ph(m) or is_residue(m): continue
            if not any(related(m, n) or m in n for n in new):
                regress += 1; reg_list.append((day, ids[0], m))
print(f"旧 {tot_o} 条 / 新v2 {tot_n} 条 | 新版占位符泄漏 {ph_n} | ⚠️真回归 {regress} 条")
for day, ev0, m in reg_list:
    print(f"  [{day}] ev{ev0}: {m[:55]!r}")
