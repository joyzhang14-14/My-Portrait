#!/usr/bin/env python3
"""keystroke 主导架构(用户 2026-06-18 设计)· 两流合并。
  · keystroke <CR> = 完整发送骨架,每键都记,一个不丢
  · AX commit 流按 \\ufeff\\n(框清空=发送标记)切 = 各条发送的真字(根治同音)
  · 两流按时间合并:commit 有真字用真字,commit 漏掉的(空洞)靠击键 librime 补
本文件**独立**,不碰 faithful_v2。先在 5/25 Discord 验证,对了再整合(挂 PORTRAIT_ARCH 开关)。
"""
import sqlite3, os, json, re
DB = os.path.expanduser("~/.portrait/portrait.sqlite")
HAN = re.compile(r'[一-鿿]')
def han_n(s): return len(HAN.findall(s or ''))
def cv(s): return re.sub(r'\s', '', s or '')

def segment_keystrokes(con, bundle, day):
    """按 <CR> 切击键段。返回 [{t0,t1,cr_ts,py,src,dirty}]。<BS> 即时回放;不丢任何段。"""
    rows = con.execute(
        "SELECT ts_ms,char,is_backspace,modifiers,input_source FROM keystroke_log "
        "WHERE bundle_id=? AND strftime('%Y-%m-%d',ts_ms/1000,'unixepoch')=? ORDER BY ts_ms",
        (bundle, day)).fetchall()
    segs, cur, srcs, dirty = [], [], set(), False
    for ts, c, bs, md, isrc in rows:
        if md & 7:
            continue
        if bs:
            if cur and cur[-1][1].isdigit():
                dirty = True
            if cur:
                cur.pop()
            continue
        if not c:
            continue
        if c in ('\n', '\r'):
            if cur:
                segs.append({'t0': cur[0][0], 't1': cur[-1][0], 'cr_ts': ts,
                             'py': ''.join(x[1] for x in cur), 'src': set(srcs), 'dirty': dirty})
            cur, srcs, dirty = [], set(), False
        else:
            cur.append((ts, c))
            if isrc:
                srcs.add(isrc)
    if cur:
        segs.append({'t0': cur[0][0], 't1': cur[-1][0], 'cr_ts': None,
                     'py': ''.join(x[1] for x in cur), 'src': set(srcs), 'dirty': dirty, 'unsent': True})
    return segs

def commit_sends(con, bundle, day):
    """AX commit 流按 \\ufeff\\n(发送标记=框清空)切。返回 [{t0,t1,han,raw}](每条=一次发送的真字)。"""
    evs = con.execute(
        "SELECT edit_log FROM typing_events WHERE bundle_id=? "
        "AND strftime('%Y-%m-%d',started_at/1000,'unixepoch')=? ORDER BY started_at",
        (bundle, day)).fetchall()
    sends, buf = [], []        # buf=[(ts,text)]
    def flush():
        nonlocal buf
        if buf:
            sends.append(buf)
            buf = []
    for (el,) in evs:
        try:
            arr = json.loads(el or '[]')
        except Exception:
            arr = []
        for e in arr:
            if e.get('kind') != 'commit':
                continue
            ts = int(e.get('ts') or 0)
            txt = (e.get('text') or '').replace('﻿', '')
            if not txt:
                continue
            if '\n' in txt or '\r' in txt:
                parts = re.split(r'[\n\r]+', txt)
                if parts[0]:
                    buf.append((ts, parts[0]))
                flush()                                   # \n = 发送
                for p in parts[1:-1]:
                    if p:
                        sends.append([(ts, p)]); flush()
                if parts[-1]:
                    buf.append((ts, parts[-1]))
            else:
                buf.append((ts, txt))
        flush()                                           # 事件边界=发送会话结束
    out = []
    for s in sends:
        raw = ''.join(t for _, t in s)
        out.append({'t0': s[0][0], 't1': s[-1][0],
                    'han': ''.join(c for c in raw if HAN.match(c)), 'raw': raw})
    return out

def build_sends(con, bundle, day, model_fn=None):
    """两流合并:每个 <CR> 段配对时间最近的 commit 发送(取真字);commit 漏的退 librime。
    返回 [{t0,t1,text,via,dirty}],按发送时间排。"""
    import rebuild as R
    ksegs = [s for s in segment_keystrokes(con, bundle, day) if not s.get('unsent')]
    csends = commit_sends(con, bundle, day)
    used = [False] * len(csends)
    out = []
    for s in ksegs:
        send_ts = s['cr_ts'] or s['t1']
        # 配对:发送时刻 ±2s 内、未用过、commit 有汉字 的 commit 发送
        best, bi = None, -1
        for i, c in enumerate(csends):
            if used[i] or not c['han']:
                continue
            if c['t1'] - 2500 <= send_ts <= c['t1'] + 2500:
                if best is None or abs(c['t1'] - send_ts) < abs(best['t1'] - send_ts):
                    best, bi = c, i
        captured = best['han'] if best else ''
        if best:
            used[bi] = True
        txt, _ = R.reconstruct_message(captured, s['py'], model_fn=model_fn)
        out.append({'t0': s['t0'], 't1': send_ts, 'text': cv(txt),
                    'via': 'AX真字' if captured else 'librime', 'dirty': s['dirty']})
    out.sort(key=lambda r: r['t1'])
    return out

if __name__ == "__main__":
    con = sqlite3.connect(DB)
    B = os.environ.get('KSP_BUNDLE', 'com.hnc.Discord')
    day = os.environ.get('KSP_DAY', '2026-05-25')
    sends = build_sends(con, B, day)
    print(f"=== {day} {B.split('.')[-1]} keystroke 主导·两流合并 ===")
    print(f"发送 {len(sends)} 条(AX真字 {sum(1 for s in sends if s['via']=='AX真字')} / "
          f"librime补 {sum(1 for s in sends if s['via']=='librime')})\n", flush=True)
    for i, s in enumerate(sends, 1):
        dz = ' [dirty]' if s['dirty'] else ''
        print(f"  {i:3d} [{s['via']}]{dz}  {s['text'][:48]}", flush=True)
