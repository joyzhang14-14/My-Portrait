#!/usr/bin/env python3
"""组装层:原始 typing_events + keystroke_log → MessageGroup(完整消息候选)。
**复用已验证逻辑,不重新设计**:移植生产 WritingCaptureWorker.unifiedExtract / extract_compare_v2.newExtract
的跨事件草稿(cur)、reset 切分、事件内连发(withinSends)、占位符(只认 paste 注入)、组级击键 gate、
mergePrefixDrafts(前缀草稿合并)。**输入是原始 typing_events,不读 writing_records_staged。**
按你的要求加 paste 片段级过滤:只去掉被 paste 支撑的片段,保留同事件手打 commit 片段,不留 paste 主体、不整组删。
"""
import sqlite3, os, json, difflib, re

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def emptyZW(s): return all((c.isspace() or ord(c) in ZW) for c in (s or ''))
def sim(a, b): return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if a and b else 0.0
def cover(v, cs): return sum(b.size for b in difflib.SequenceMatcher(None, v, cs, autojunk=False).get_matching_blocks())/len(v) if v and cs else 0.0
def related(a, b): return sim(a, b) >= 0.5 or a.startswith(b) or b.startswith(a)
def cstream(arr): return ''.join(cv(e.get('text', '') or '') for e in arr if e.get('kind') == 'commit')

# ---- run 级占位符(paste 注入 ≥5 次)----  [复用 extract_compare_v2.runPlaceholders]
def runPlaceholders():
    cnt = {}
    for (log,) in con.execute("SELECT edit_log FROM typing_events").fetchall():
        try: arr = json.loads(log)
        except Exception: continue
        for e in arr:
            if e.get('kind') == 'paste':
                t = cv(e.get('text', '') or '')
                if t: cnt[t] = cnt.get(t, 0) + 1
    return {k for k, v in cnt.items() if v >= 5 and 6 <= len(k) <= 40 and re.search(r'[A-Za-z一-鿿]', k)}
RUNPH = runPlaceholders()
EMPTY_OK = {0x200B, 0x200C, 0x200D, 0xFEFF, 0x0A, 0x0D, 0x09, 0x20}   # 不含 \xa0
def emptyBox(s): return all(ord(c) in EMPTY_OK for c in (s or ''))

def phMarkers(arr):
    # 占位符 = app **paste** 注入又被 delete 清掉的值(只认 paste,见 extract_compare_v2 注释)。
    inj, dele = set(), set()
    for e in arr:
        k = e.get('kind'); t = cv(e.get('text', '') or '')
        if not t: continue
        if k == 'paste': inj.add(t)
        elif k == 'delete': dele.add(t)
    return {t for t in (inj & dele) if len(t) >= 6 and re.search(r'[A-Za-z一-鿿]', t)}

def withinSends(arr, ph, returns=()):    # [复用 extract_compare_v2.withinSends]
    cs = cstream(arr); out = []
    def isMark(j):
        if j < 0 or j >= len(arr): return False
        raw = arr[j].get('text', '') or ''
        return emptyBox(raw) or cv(raw) in ph or cv(raw) in RUNPH
    def sent(ts):
        return ts is not None and any(ts - 1800 <= rt <= ts + 200 for rt in returns)
    for i, e in enumerate(arr):
        if e.get('kind') != 'delete': continue
        t = cv(e.get('text', '') or '')
        if len(t) < 2 or t in ph or t in RUNPH: continue
        if not (isMark(i - 1) or isMark(i + 1)): continue
        if cover(t, cs) < 0.5: continue
        if not sent(e.get('ts')): continue
        out.append((t, e.get('ts')))
    return out

def newExtract(evs):    # [复用 extract_compare_v2.newExtract;返回 (text, 来源ev_id, ts) 便于建组]
    msgs = []; cur = None; cur_ev = None
    def emit(m, ev, ts=None):
        if m and len(m) >= 1: msgs.append({"text": m, "ev": ev, "ts": ts})
    for k, e in enumerate(evs):
        arr = e['arr']; cs = cstream(arr); endv = cv(e['endv']); endEmpty = emptyZW(e['endv'])
        ph = phMarkers(arr); delset = {cv(x.get('text', '') or '') for x in arr if x.get('kind') == 'delete'}
        for x in arr:
            if x.get('kind') == 'submit':
                st = cv(x.get('text', '') or '')
                if len(st) >= 2:
                    if cur and not related(st, cur['text']): emit(cur['text'], cur['ev'], cur['ts'])
                    emit(st, e['id'], x.get('ts')); cur = None
        for t, ts in withinSends(arr, ph, e.get('returns', ())):
            if cur and not related(t, cur['text']): emit(cur['text'], cur['ev'], cur['ts']); cur = None
            emit(t, e['id'], ts)
        if endEmpty:
            cur = None
        elif endv:
            ssv = cv(e['ss'])
            injected = cover(endv, cs) < 0.2 and not (ssv and related(endv, ssv))
            resting = endv in delset or endv in ph or endv in RUNPH
            if not injected and not resting:
                if cur and not related(endv, cur['text']): emit(cur['text'], cur['ev'], cur['ts'])
                cur = {"text": endv, "ev": e['id'], "ts": e['ended_at']}
            elif cur:
                emit(cur['text'], cur['ev'], cur['ts']); cur = None
        if k + 1 < len(evs) and cur:
            ns = cv(evs[k + 1]['ss'])
            if emptyZW(evs[k + 1]['ss']) or not related(ns, cur['text']):
                emit(cur['text'], cur['ev'], cur['ts']); cur = None
    if cur: emit(cur['text'], cur['ev'], cur['ts'])
    # 去重保序
    seen = set(); return [m for m in msgs if not (m['text'] in seen or seen.add(m['text']))]

# ---- paste 片段级过滤(你的要求)----
def paste_spans(ev_id):
    """该事件里 paste 注入的实质文本片段(≥4字),用于从消息里剔除 paste 支撑的片段。"""
    r = con.execute("SELECT edit_log FROM typing_events WHERE id=?", (ev_id,)).fetchone()
    if not r: return []
    out = []
    for e in json.loads(r[0]):
        if e.get('kind') == 'paste':
            t = cv(e.get('text', '') or '')
            if len(t) >= 4: out.append(t)
    return out

def filter_paste_fragment(text, ev_id):
    """只去掉被 paste 支撑的片段,保留手打片段。返回 (kept_text, removed_paste:bool)。
    不因同事件有手打 commit 就整组删;也不保留 paste 主体。"""
    kept, removed = text, False
    for ps in paste_spans(ev_id):
        if ps and ps in kept:
            kept = kept.replace(ps, "").strip()
            removed = True
    return kept, removed

# ---- mergePrefixDrafts(前缀草稿合并)----  [复用 unifiedExtract.mergePrefixDrafts 思路]
def is_send_clear_event(ev_id):
    """该事件是否有真发送(send-clear:框真清空——delete 掉实质内容后框变空/占位符)。"""
    r = con.execute("SELECT edit_log,end_value FROM typing_events WHERE id=?", (ev_id,)).fetchone()
    if not r: return False
    arr = json.loads(r[0])
    for i, e in enumerate(arr):
        if e.get('kind') == 'delete' and len(cv(e.get('text', '') or '')) >= 2:
            nxt = arr[i + 1] if i + 1 < len(arr) else None
            if nxt is None or emptyBox(nxt.get('text', '') or '') or cv(nxt.get('text', '')) in RUNPH:
                return True
    return emptyBox(r[1] or '')

def merge_prefix_drafts(records):
    """未发送草稿 且 是更晚某条的严格前缀 → 早期快照,丢。发送过的不丢。"""
    drop = set()
    for i, r in enumerate(records):
        if is_send_clear_event(r['ev']): continue
        a = r['text'].strip()
        if not a: continue
        if any(j != i and o['text'].strip() != a and o['text'].strip().startswith(a)
               for j, o in enumerate(records)):
            drop.add(i)
    return [r for i, r in enumerate(records) if i not in drop]

# ---- 驱动:按天 + (app,url) 分组,从原始 typing_events 出发 ----
def load_day_events(date):
    rows = con.execute(
        "SELECT id,session_start,end_value,edit_log,bundle_id,url,started_at,ended_at "
        "FROM typing_events WHERE strftime('%Y-%m-%d', started_at/1000,'unixepoch')=? ORDER BY started_at",
        (date,)).fetchall()
    evs = []
    for r in rows:
        try: arr = json.loads(r[3])
        except Exception: continue
        rets = [x[0] for x in con.execute(
            "SELECT ts_ms FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND char IN (?, ?)",
            (r[4], (r[6] or 0) - 2000, (r[7] or 0) + 2000, "\n", "\r")).fetchall()]
        evs.append(dict(id=r[0], ss=r[1] or '', endv=r[2] or '', arr=arr, bundle=r[4], url=r[5],
                        returns=rets, started_at=r[6], ended_at=r[7]))
    return evs

def keystroke_gate_ok(group_evs, messages):
    """组级击键 gate:消息总字数远超无修饰击键数 = 预存内容/纯粘贴 → 整组丢。"""
    if not group_evs: return True
    s, e = group_evs[0]['started_at'], group_evs[-1]['ended_at']
    bundle = group_evs[0]['bundle']
    kc = con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? "
                     "AND (modifiers & 7)=0 AND is_backspace=0", (bundle, (s or 0) - 10000, (e or 0) + 10000)).fetchone()[0]
    total = sum(len(m['text']) for m in messages)
    return total <= kc * 3 + 10   # 消息量不超击键数 3 倍(中文拼音击键≥字数;短粘贴混打字也过)

def handtyped_ok(text, ev_id):
    """逐消息击键背书(铁律只记手打;不整组删):该消息文本是否被 commit 流覆盖 或 有足够物理击键。
    粘贴/预存的 Notes/表单 endValue:commit 覆盖低 + 无击键 → 丢。手打:commit 覆盖高 或 击键≥半数 → 留。"""
    t = cv(text)
    if not t: return False
    r = con.execute("SELECT edit_log,bundle_id,started_at,ended_at FROM typing_events WHERE id=?", (ev_id,)).fetchone()
    if not r: return False
    arr = json.loads(r[0]); cs = cstream(arr)
    if cover(t, cs) >= 0.6:   # 大半来自 commit(手打提交)→ 留
        return True
    kc = con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? "
                     "AND (modifiers & 7)=0 AND is_backspace=0",
                     (r[1], (r[2] or 0) - 10000, (r[3] or 0) + 1000)).fetchone()[0]
    return kc >= len(t) * 0.5   # 击键≥半数 → 手打;粘贴(≈0击键)→ 丢

def assemble_day(date):
    """返回该天所有 (app,url) 组装出的消息候选 [{text, ev, ts, app, url, paste_removed}]。"""
    evs = load_day_events(date)
    groups = {}
    for e in evs:
        groups.setdefault((e['bundle'], e['url']), []).append(e)
    out = []
    for (app, url), gev in groups.items():
        gev.sort(key=lambda x: x['started_at'])
        msgs = newExtract(gev)
        # ⚠️ 不用整组 keystroke_gate(你的铁律:不能因同事件有手打就整组删)。
        # 改:逐消息 paste 片段级过滤——粘贴支撑的片段去掉、手打片段保留、不留 paste 主体。
        msgs = merge_prefix_drafts(msgs)
        for m in msgs:
            kept, removed = filter_paste_fragment(m['text'], m['ev'])
            if not handtyped_ok(kept, m['ev']):      # 逐消息击键背书:粘贴/预存内容丢(不整组删)
                out.append({"text": kept, "ev": m['ev'], "app": app, "url": url, "dropped": "not_handtyped"})
                continue
            out.append({"text": kept, "raw_text": m['text'], "ev": m['ev'], "ts": m['ts'],
                        "app": app, "url": url, "paste_removed": removed})
    return out

if __name__ == "__main__":
    import sys
    for d in (sys.argv[1:] or ["2026-05-29"]):
        cands = assemble_day(d)
        kept = [c for c in cands if not c.get("dropped") and len(cv(c["text"])) >= 1]
        print(f"=== {d}: {len(kept)} 候选(组装后)===")
        for c in kept[:30]:
            tag = " [paste过滤]" if c.get("paste_removed") else ""
            print(f"  [{c['app'].split('.')[-1][:10]}] {c['text'][:42]!r}{tag}")
