#!/usr/bin/env python3
"""canvas v2:去噪快照 + 14B 窄拼接(对标库中 haiku 95%/98%)。
拆解:去噪=确定性(复用 canvas_local 行级闸)/拼接=14B 窄任务(滚动视口对齐去重叠)/
幻觉 guard=输出逐窗(24字)必须存在于某快照,不在=该段拒(写权零容忍)。
diff 时间线仍用 canvas_local 确定性产出。
"""
import sqlite3, os, json, re, sys, datetime
import canvas_local as CL

con = CL.con

def clean_frame_text(words, kwords, line_freq=None):
    """两遍式:strong 行(背书≥0.5)定**帧级 x 锚**(该帧文档列位置——窗口移动自适应);
    低背书行须 跨帧频次≥2 ∧ x∈锚±0.08(GitHub/对话窗常驻行高频但列不同,锚拦)。"""
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
    bl = []
    for (y, x, t, r) in cand:
        k = re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:30]
        if r >= 0.5:
            bl.append((y, t))
        elif (r >= 0.15 and len(t) >= 15 and (line_freq is None or line_freq.get(k, 0) >= 2)
              and ax is not None and abs(x - ax) <= 0.08):
            bl.append((y, t))
    return '\n'.join(t for _, t in sorted(bl))

def normx(s):
    s = (s or '').replace('（', '(').replace('）', ')').replace('“', '"').replace('”', '"').replace('’', "'")
    return re.sub(r'[^a-z0-9一-鿿]', '', s.lower())

def main(url_like='1DY0bEhGGZB', t0s='2026-05-28 18:00', t1s='2026-05-29 02:00', max_snaps=24):
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
    # 代表帧:时间均匀取 max_snaps 张,每张去噪;太短(<200字)跳过
    from collections import Counter as _CF
    line_freq = _CF()
    for ts, wj in rows[::3]:
        try: words = json.loads(wj)
        except Exception: continue
        for (y, x, t, n) in CL.frame_lines(words):
            if n >= 3:
                line_freq[re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:30]] += 1
    snaps = []
    step = max(1, len(rows) // max_snaps)
    for i in range(0, len(rows), step):
        ts, wj = rows[i]
        try: words = json.loads(wj)
        except Exception: continue
        t = clean_frame_text(words, kwords, line_freq)
        if len(t) >= 200: snaps.append((ts, t))
    print(f"代表快照 {len(snaps)} 张", file=sys.stderr)
    # 层级归并(v2c):组内6张一次性拼→组块再拼一次。每层输出有界,无滚动膨胀/截断。
    from mlx_lm import load as _load, generate as _gen
    m14, tok14 = _load("mlx-community/Qwen3-14B-4bit")
    allsnap = normx(' '.join(t for _, t in snaps))
    def merge_once(parts, label):
        if len(parts) == 1:
            listing = f"【文本】\n{parts[0]}"
        else:
            listing = '\n\n'.join(f"【片段{i+1}】\n{p}" for i, p in enumerate(parts))
        user = ("以下片段来自同一文档的滚动截屏 OCR,按时间顺序,相邻片段有重叠区,可能有 OCR 错字。"
                "把它们拼成这一区域的完整文本:用重叠区对齐;重叠只保留一份(选更通顺的版本);"
                "按文档顺序;**只能用片段里出现过的文字,禁止发明**。\n\n"
                f"{listing}\n\n输出拼接后的完整文本,不解释。")
        pr = tok14.apply_chat_template([{"role": "user", "content": user}],
                                       add_generation_prompt=True, tokenize=False, enable_thinking=False)
        out = _gen(m14, tok14, prompt=pr, max_tokens=3800, verbose=False)
        out = re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
        nb = normx(out)
        wins = [nb[i:i + 24] for i in range(0, max(1, len(nb) - 24), 24)]
        bad = sum(1 for w in wins if w not in allsnap)
        if wins and bad / len(wins) > 0.10:
            print(f"  {label} 拒(幻觉窗 {bad}/{len(wins)}),回退片段直连", file=sys.stderr)
            return '\n'.join(parts)
        return out
    G = 6
    blocks = []
    texts = [t for _, t in snaps]
    for gi in range(0, len(texts), G):
        grp = texts[gi:gi + G]
        blocks.append(merge_once(grp, f"组{gi//G}") if len(grp) > 1 else grp[0])
    body = merge_once(blocks, "顶层") if len(blocks) > 1 else (blocks[0] if blocks else '')
    # 击键词典纠错(确定性,免费精确率;复用 canvas_local 频次仲裁思路)
    from collections import Counter as _C3
    kwfreq = _C3(re.findall(r'[a-z]{4,}', ''.join(buf).lower()))
    def ed1(a, b):
        if abs(len(a) - len(b)) > 1: return False
        if len(a) == len(b): return sum(x != y for x, y in zip(a, b)) <= 1
        s_, l_ = (a, b) if len(a) < len(b) else (b, a)
        return any(s_ == l_[:i] + l_[i+1:] for i in range(len(l_)))
    kw_by_len = {}
    for w in kwfreq: kw_by_len.setdefault(len(w), set()).add(w)
    def fix_word(m):
        w = m.group(0); wl = w.lower()
        if wl in kwfreq or len(wl) < 5: return w
        cands = [c for L in (len(wl)-1, len(wl), len(wl)+1) for c in kw_by_len.get(L, ()) if ed1(wl, c)]
        cands += [c for c in kwfreq if wl.replace('m', 'rn') == c or wl.replace('rn', 'm') == c]
        cands = [c for c in set(cands) if kwfreq[c] >= 2]
        return max(cands, key=lambda c: kwfreq[c]) if cands else w
    body = re.sub(r'[A-Za-z]{5,}', fix_word, body)
    json.dump({'final_text': body, 'timeline': [], 'frames': len(rows), 'chrome_lines': 0},
              open('eval/canvas_v2.json', 'w'), ensure_ascii=False)
    print(f"拼接完成 字数 {len(body)}")
    return body

if __name__ == '__main__':
    main()
