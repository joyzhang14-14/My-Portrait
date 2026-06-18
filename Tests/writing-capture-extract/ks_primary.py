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

def all_commits(con, bundle, day):
    """全天该 bundle 的逐条 commit(ts, text),按时间排。文字复原真字来源(不预切)。"""
    evs = con.execute(
        "SELECT edit_log FROM typing_events WHERE bundle_id=? "
        "AND strftime('%Y-%m-%d',started_at/1000,'unixepoch')=? ORDER BY started_at",
        (bundle, day)).fetchall()
    cm = []
    for (el,) in evs:
        try:
            arr = json.loads(el or '[]')
        except Exception:
            arr = []
        for e in arr:
            if e.get('kind') == 'commit':
                t = (e.get('text') or '').replace('﻿', '')
                t = re.sub(r'[\n\r]', '', t)              # 去发送标记换行,只留内容字
                if t:
                    cm.append((int(e.get('ts') or 0), t))
    cm.sort()
    return cm

def build_sends(con, bundle, day, model_fn=None):
    """两流合并:击键 <CR> = 权威发送边界(全);逐条 commit 按时间戳落进它所属的段
    (prev_cr < ts ≤ cr+margin)→ 该段真字主体。reconstruct(真字, 击键):有真字根治同音,
    无真字退 librime。返回 [{t0,t1,text,via,dirty}],按发送时刻排。"""
    import rebuild as R
    ksegs = [s for s in segment_keystrokes(con, bundle, day) if not s.get('unsent')]
    ksegs.sort(key=lambda s: s['cr_ts'] or s['t1'])
    cm = all_commits(con, bundle, day)
    out = []
    ci = 0
    prev = 0
    for s in ksegs:
        cr = s['cr_ts'] or s['t1']
        chunk = []
        while ci < len(cm) and cm[ci][0] <= cr + 300:
            if cm[ci][0] > prev:
                chunk.append(cm[ci][1])
            ci += 1
        prev = cr
        raw = ''.join(chunk)
        han = ''.join(c for c in raw if HAN.match(c))      # 真字主体(汉字优先,丢拼音残片)
        txt, _ = R.reconstruct_message(han, s['py'], model_fn=model_fn)
        out.append({'t0': s['t0'], 't1': cr, 'text': cv(txt),
                    'via': 'AX真字' if han else 'librime', 'dirty': s['dirty']})
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
