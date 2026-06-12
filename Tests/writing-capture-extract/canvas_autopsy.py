#!/usr/bin/env python3
"""坏窗验尸(纯离线,零模型):把 canvas_v2 产出中不命中 gold 的窗逐个追溯回
源头快照行,报背书率/跨帧频次/x偏移,归类噪声来源。gold 内容不展示(用户指令),
只展示坏窗本身(定义上∉gold)。"""
import json, re, sys, datetime
import canvas_local as CL
import canvas_merge as CM

con = CL.con

def windows(s, w=24):
    return [s[i:i + w] for i in range(0, max(1, len(s) - w), w)]

def hit(c, hay):
    return c in hay or (c[:12] in hay and len(c) >= 20) or (c[12:] in hay and len(c) >= 20)

def main(url_like='1DY0bEhGGZB', t0s='2026-05-28 18:00', t1s='2026-05-29 02:00', max_snaps=24):
    rec = CM.normx(json.load(open('eval/canvas_v2.json'))['final_text'])
    gold = CM.normx(open('eval/canvas_gold.txt').read())
    bad = [c for c in windows(rec) if not hit(c, gold)]
    print(f"坏窗 {len(bad)}/{len(windows(rec))}")
    # 重建快照(确定性,与 canvas_merge.main 同口径)
    T0 = int(datetime.datetime.strptime(t0s, '%Y-%m-%d %H:%M').timestamp() * 1000)
    T1 = int(datetime.datetime.strptime(t1s, '%Y-%m-%d %H:%M').timestamp() * 1000)
    rows = con.execute(
        "SELECT timestamp_ms, ocr_words_json FROM frames WHERE browser_url LIKE :u "
        "AND timestamp_ms BETWEEN :a AND :b AND ocr_words_json IS NOT NULL ORDER BY timestamp_ms",
        {"u": f"%{url_like}%", "a": T0, "b": T1}).fetchall()
    ks = con.execute("SELECT char, is_backspace, modifiers FROM keystroke_log WHERE bundle_id LIKE '%Safari%' "
                     "AND ts_ms BETWEEN :a AND :b ORDER BY ts_ms", {"a": T0, "b": T1}).fetchall()
    buf = []
    for c, bs, md in ks:
        if (md & 7) != 0: continue
        if bs:
            if buf: buf.pop()
            continue
        if c: buf.append(c if c not in ('\n', '\r') else ' ')
    kwords = set(re.findall(r'[a-z]{4,}', ''.join(buf).lower()))
    from collections import Counter as _CF
    line_freq = _CF()
    for ts, wj in rows[::3]:
        try: words = json.loads(wj)
        except Exception: continue
        for (y, x, t, n) in CL.frame_lines(words):
            if n >= 3:
                line_freq[re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:30]] += 1
    # 收集每张代表快照的(行文本, r, freq, x, 锚距),与 clean_frame_text 同逻辑
    step = max(1, len(rows) // max_snaps)
    lines_all = []   # (snap_i, y, x, t, r, freq, ax)
    for si, i in enumerate(range(0, len(rows), step)):
        ts, wj = rows[i]
        try: words = json.loads(wj)
        except Exception: continue
        cand = []
        for (y, x, t, n) in CL.frame_lines(words):
            if n < 3: continue
            toks = re.findall(r'[a-z]{4,}', t.lower())
            if len(toks) < 2: continue
            r = sum(1 for w in toks if w in kwords) / len(toks)
            cand.append((y, x, t, r))
        strong_x = [round(x / 0.02) for (_, x, _, r) in cand if r >= 0.5]
        ax = None
        if strong_x:
            from collections import Counter as _CA
            ax = _CA(strong_x).most_common(1)[0][0] * 0.02
        for (y, x, t, r) in cand:
            k = re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:30]
            admitted = r >= 0.5 or (r >= 0.15 and len(t) >= 15 and line_freq.get(k, 0) >= 2
                                    and ax is not None and abs(x - ax) <= 0.08)
            if admitted:
                lines_all.append((si, y, x, t, r, line_freq.get(k, 0), ax))
    # 逐坏窗找源头行(行 normx 包含坏窗任一半)
    from collections import Counter as catc
    cats = catc()
    for bi, w in enumerate(bad):
        srcs = []
        for (si, y, x, t, r, fq, ax) in lines_all:
            nt = CM.normx(t)
            if w in nt or (w[:12] in nt) or (w[12:] in nt):
                srcs.append((si, x, t, r, fq, ax))
        if srcs:
            si, x, t, r, fq, ax = srcs[0]
            path = 'strong' if r >= 0.5 else 'weak'
            cats[path] += 1
            dx = abs(x - ax) if ax is not None else -1
            print(f"[{bi}] {path} r={r:.2f} freq={fq} dx={dx:.3f} snap{si} ×{len(srcs)}源 | {t[:60]}")
        else:
            cats['no_source(LLM改写)'] += 1
            print(f"[{bi}] 无源头行(半窗容差放进来的拼接产物) | {w[:48]}")
    print(f"\n归类: {dict(cats)}")

if __name__ == '__main__':
    main()
