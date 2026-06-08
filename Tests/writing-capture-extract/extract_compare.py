#!/usr/bin/env python3
"""完整对照:旧 unifiedExtract(占位符集合+reset启发式) vs 新版(edit_log 回放)。
四天所有真实 AX 会话各跑两遍,逐会话 diff。重点:① 新版丢了旧版采到的真消息(回归)
② 修复(占位符/碎片消失、演进长消息回来)。会话边界从 staged 的 reference_typing_event_ids
重建(同一 ref-list = 一个 session)。"""
import sqlite3, os, json, difflib, sys

DB = os.path.expanduser("~/.portrait/portrait.sqlite")
con = sqlite3.connect(DB)
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def emptyZW(s): return all((c.isspace() or ord(c) in ZW) for c in (s or ''))
def sim(a, b): return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if a and b else 0.0
def cover(v, cs): return sum(b.size for b in difflib.SequenceMatcher(None, v, cs, autojunk=False).get_matching_blocks())/len(v) if v and cs else 0.0
def related(a, b): return sim(a, b) >= 0.5 or a.startswith(b) or b.startswith(a)

def loadev(ids):
    out = []
    for e in ids:
        r = con.execute("SELECT id,session_start,end_value,edit_log FROM typing_events WHERE id=?", (e,)).fetchone()
        if r: out.append(dict(id=r[0], ss=r[1] or '', endv=r[2] or '', arr=json.loads(r[3])))
    return out

# ---------- 旧 unifiedExtract 复刻 ----------
def collectPlaceholders(all_event_logs):
    counts = {}
    for endv, log in all_event_logs:
        evn = cv(endv)
        if not evn: continue
        try: arr = json.loads(log)
        except: continue
        if any((e.get('kind') in ('commit', 'paste')) and cv(e.get('text', '') or '') == evn for e in arr):
            counts[evn] = counts.get(evn, 0) + 1
    return set(k for k, v in counts.items() if v >= 3)

def isReset_old(s, PH): return emptyZW(s) or cv(s) in PH
def withinSends_old(ev, PH):
    arr = ev['arr']; out = []
    for i, e in enumerate(arr):
        if e.get('kind') != 'delete': continue
        raw = e.get('text', '') or ''
        if not raw or isReset_old(raw, PH): continue
        pm = i > 0 and isReset_old(arr[i-1].get('text', '') or '', PH)
        nm = i+1 < len(arr) and isReset_old(arr[i+1].get('text', '') or '', PH)
        if not (pm or nm): continue
        t = cv(raw)
        if len(t) >= 2: out.append(t)
    return out
def oldExtract(evs, PH):
    msgs = []; cur = None
    for k, e in enumerate(evs):
        we = withinSends_old(e, PH); msgs += we
        ev = cv(e['endv']); evReset = isReset_old(e['endv'], PH)
        if not evReset and ev: cur = ev
        nextReset = k+1 < len(evs) and isReset_old(evs[k+1]['ss'], PH)
        if nextReset:
            if cur: msgs.append(cur); cur = None
        elif evReset:
            if cur and not we: msgs.append(cur)
            cur = None
    if cur: msgs.append(cur)
    seen = set(); return [m for m in msgs if m and not (m in seen or seen.add(m))]

# ---------- 新 unifiedExtract 复刻(= 已接受的 v3) ----------
def cstream(arr): return ''.join(cv(e.get('text', '') or '') for e in arr if e.get('kind') == 'commit')
def newExtract(evs):
    msgs = []; cur = None
    def emit(m):
        if m and len(m) >= 1: msgs.append(m)
    for k, e in enumerate(evs):
        arr = e['arr']; cs = cstream(arr); endv = cv(e['endv']); endEmpty = emptyZW(e['endv'])
        delset = {cv(x.get('text', '') or '') for x in arr if x.get('kind') == 'delete'}
        for x in arr:
            if x.get('kind') == 'submit':
                st = cv(x.get('text', '') or '')
                if len(st) >= 2:
                    if cur and not related(st, cur): emit(cur)
                    emit(st); cur = None
        if endEmpty:
            for i, x in enumerate(arr):
                if x.get('kind') != 'delete': continue
                t = cv(x.get('text', '') or '')
                if len(t) < 2: continue
                nbr = (i+1 < len(arr) and emptyZW(arr[i+1].get('text', '') or '')) or (i > 0 and emptyZW(arr[i-1].get('text', '') or ''))
                if nbr and cover(t, cs) >= 0.5:
                    if cur and not related(t, cur): emit(cur); cur = None
                    emit(t)
            cur = None
        elif endv:
            injected = cover(endv, cs) < 0.5
            resting = endv in delset
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

# ---------- 跑四天,重建会话,diff ----------
PLACEHOLDERS_LIKE = ['Write a message', 'Type / for commands', 'Describe a task or ask a question', 'Reply']
def looks_placeholder(m): return any(p in m for p in PLACEHOLDERS_LIKE)

DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
all_logs = con.execute("SELECT end_value,edit_log FROM typing_events").fetchall()
PH = collectPlaceholders(all_logs)

report = []
tot_old = tot_new = tot_ph_old = tot_ph_new = tot_regress = 0
for day in DAYS:
    rows = con.execute(
        "SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged "
        "WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall()
    sessions = []
    for (refs,) in rows:
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        if ids: sessions.append(ids)
    for ids in sessions:
        evs = loadev(ids)
        if not evs: continue
        old = oldExtract(evs, PH); new = newExtract(evs)
        ph_o = [m for m in old if looks_placeholder(m)]
        ph_n = [m for m in new if looks_placeholder(m)]
        # 回归:旧版有、新版无、且不是占位符的(真消息被新版丢)
        regress = [m for m in old if not looks_placeholder(m)
                   and not any(related(m, n) or m in n for n in new)]
        tot_old += len(old); tot_new += len(new)
        tot_ph_old += len(ph_o); tot_ph_new += len(ph_n); tot_regress += len(regress)
        if regress or ph_o or ph_n:
            report.append((day, ids[:1], len(old), len(new), ph_o, ph_n, regress, old, new))

print(f"四天合计: 旧版产 {tot_old} 条 / 新版产 {tot_new} 条")
print(f"占位符泄漏: 旧 {tot_ph_old} → 新 {tot_ph_new}")
print(f"⚠️回归(新版丢的真消息): {tot_regress} 条")
print("=" * 70)
for day, ev0, no, nn, ph_o, ph_n, regress, old, new in report:
    print(f"\n[{day}] session ev{ev0[0]}…  旧{no}条 → 新{nn}条")
    if ph_o: print(f"  旧版占位符泄漏: {[m[:30] for m in ph_o]}")
    if ph_n: print(f"  ⚠️新版仍占位符: {[m[:30] for m in ph_n]}")
    if regress:
        print(f"  ⚠️⚠️回归(新版丢了): {[m[:40] for m in regress]}")
