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

def commit_marks(con, bundle, day):
    """返回 (commit_times, send_times):commit 全部时刻 + ﻿\\n 框清空(真发送)标记时刻。"""
    evs = con.execute(
        "SELECT edit_log FROM typing_events WHERE bundle_id=? "
        "AND strftime('%Y-%m-%d',started_at/1000,'unixepoch')=? ORDER BY started_at",
        (bundle, day)).fetchall()
    cts, sts = [], []
    for (el,) in evs:
        try:
            arr = json.loads(el or '[]')
        except Exception:
            arr = []
        for e in arr:
            if e.get('kind') == 'commit':
                ts = int(e.get('ts') or 0)
                cts.append(ts)
                if '\n' in (e.get('text') or '') or '\r' in (e.get('text') or ''):
                    sts.append(ts)
    return sorted(cts), sorted(sts)

def segment_keystrokes(con, bundle, day, send_win=1500):
    """每个 <CR> **默认是发送**(击键回车=Discord发送,zero-loss)。唯一例外=**IME 确认上屏英文**
    (sandisk案):回车前那串键是**英文键盘**(input_source=keylayout)且无 ﻿\\n 框清空标记 → 确认回车,合并。
    判英文只信 input_source(commit里拼音也是拉丁,分不开;﻿\\n 仅53个<回车123,太稀疏不能反推)。
    ⚠️历史数据 input_source=NULL → 永远发送(回退 v2,sandisk 会拆,新数据才合并)。返回 [{...,py,dirty}]。"""
    rows = con.execute(
        "SELECT ts_ms,char,is_backspace,modifiers,input_source FROM keystroke_log "
        "WHERE bundle_id=? AND strftime('%Y-%m-%d',ts_ms/1000,'unixepoch')=? ORDER BY ts_ms",
        (bundle, day)).fetchall()
    _, sts = commit_marks(con, bundle, day)
    import bisect
    def near(arr, t):
        i = bisect.bisect_left(arr, t - send_win)
        return i < len(arr) and arr[i] <= t + send_win
    segs, cur, srcs, dirty, last_isrc = [], [], set(), False, None
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
            # shift+return(mod 含 shift 位=8)= **消息内换行**,不是发送(用户实证:换行用 shift+return)。
            # ⚠️md&7 只抓 cmd 组合(1/2/4),抓不到 shift(8);不修则 claudefordesktop 23个换行被当发送切碎。
            if md & 8:
                continue                                    # 换行,不切,内容续上(多行结构由 AX 真字提供)
            # 合并条件:回车前那串键是英文键盘(keylayout)+ 无框清空标记 = IME确认上屏英文(sandisk)
            eng_confirm = (last_isrc and 'keylayout' in last_isrc) and not near(sts, ts)
            if eng_confirm:
                continue                                    # 确认回车 → 不切,合并
            if cur:
                segs.append({'t0': cur[0][0], 't1': cur[-1][0], 'cr_ts': ts,
                             'py': ''.join(x[1] for x in cur), 'src': set(srcs), 'dirty': dirty})
            cur, srcs, dirty = [], set(), False
        else:
            cur.append((ts, c))
            if isrc:
                srcs.add(isrc); last_isrc = isrc
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

def segment_sends(con, bundle, day):
    """**给 faithful_v2 整合用**:只产发送边界 + commit 真字主体(captured),不解码。
    每个真发送段配 commit 真字(按击键边界逐条落)。返回 [{t0,t1,captured,dirty}]。
    下游由 faithful_v2 完整链(reconstruct + literal_tail + 口3 + 14B)做文字复原/补尾/消歧。"""
    ksegs = [s for s in segment_keystrokes(con, bundle, day) if not s.get('unsent')]
    ksegs.sort(key=lambda s: s['cr_ts'] or s['t1'])
    cm = all_commits(con, bundle, day)
    out, ci, prev = [], 0, 0
    for i, s in enumerate(ksegs):
        cr = s['cr_ts'] or s['t1']
        # 上界 = 下一条**开始打字**之前(IME commit 有滞后,本条末字「重要」的 commit 常落在 cr 之后、
        # 下条打字之前;旧 AX 用事件 FINAL text 等所有 commit 落定才完整,这里同理收滞后尾)
        upper = (ksegs[i + 1]['t0'] - 50) if i + 1 < len(ksegs) else (cr + 60000)
        chunk = []
        while ci < len(cm) and cm[ci][0] < upper:
            if cm[ci][0] > prev:
                chunk.append(cm[ci][1])
            ci += 1
        prev = cr
        han = ''.join(c for c in ''.join(chunk) if HAN.match(c))   # 真字主体(汉字优先,丢拼音残片)
        out.append({'t0': s['t0'], 't1': cr, 'captured': han, 'dirty': s['dirty']})
    return out

def build_sends(con, bundle, day, model_fn=None):
    """独立原型用:segment_sends + 自己调 reconstruct(无补尾链,只看切分/复原雏形)。
    整合进 faithful_v2 走 segment_sends(让完整链补尾/消歧)。"""
    import rebuild as R
    out = []
    ksegs = {(s['t0']): s for s in segment_keystrokes(con, bundle, day) if not s.get('unsent')}
    for s in segment_sends(con, bundle, day):
        py = ksegs.get(s['t0'], {}).get('py', '')
        txt, _ = R.reconstruct_message(s['captured'], py, model_fn=model_fn)
        out.append({'t0': s['t0'], 't1': s['t1'], 'text': cv(txt),
                    'via': 'AX真字' if s['captured'] else 'librime', 'dirty': s['dirty']})
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
