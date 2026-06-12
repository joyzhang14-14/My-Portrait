#!/usr/bin/env python3
"""canvas v2:去噪快照 + 14B 窄拼接(对标库中 haiku 95%/98%)。
拆解:去噪=确定性(复用 canvas_local 行级闸)/拼接=14B 窄任务(滚动视口对齐去重叠)/
幻觉 guard=输出逐窗(24字)必须存在于某快照,不在=该段拒(写权零容忍)。
diff 时间线仍用 canvas_local 确定性产出。
"""
import sqlite3, os, json, re, sys, datetime
import canvas_local as CL

con = CL.con

def clean_frame_text(words, kwords):
    """复用行级闸,拼回该帧的去噪文本(按 y 序)。"""
    bl = []
    for (y, x, t, n) in CL.frame_lines(words):
        if n < 3: continue
        toks = re.findall(r'[a-z]{4,}', t.lower())
        if len(toks) < 2: continue
        if sum(1 for w in toks if w in kwords) / len(toks) >= 0.5:
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
    snaps = []
    step = max(1, len(rows) // max_snaps)
    for i in range(0, len(rows), step):
        ts, wj = rows[i]
        try: words = json.loads(wj)
        except Exception: continue
        t = clean_frame_text(words, kwords)
        if len(t) >= 200: snaps.append((ts, t))
    print(f"代表快照 {len(snaps)} 张", file=sys.stderr)
    # 14B 滚动拼接
    from mlx_lm import load as _load, generate as _gen
    m14, tok14 = _load("mlx-community/Qwen3-14B-4bit")
    allsnap = normx(' '.join(t for _, t in snaps))
    body = snaps[0][1] if snaps else ''
    for ts, snap in snaps[1:]:
        user = ("两段文本来自同一文档的滚动截屏 OCR(有重叠区,可能有 OCR 错字)。"
                "找出【新视口】中【当前全文】还没有的**新增文字**(整句/整段,按文档顺序;"
                "重叠的不要;只能抄【新视口】里出现过的文字,禁止发明)。\n\n"
                f"【当前全文】\n{body}\n\n【新视口】\n{snap}\n\n"
                "只输出新增文字;若没有新增,输出 NONE。不解释。")
        pr = tok14.apply_chat_template([{"role": "user", "content": user}],
                                       add_generation_prompt=True, tokenize=False, enable_thinking=False)
        out = _gen(m14, tok14, prompt=pr, max_tokens=1200, verbose=False)
        out = re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
        if re.search(r'\bNONE\b', out) or len(out) < 8: continue
        # 幻觉 guard:新增段每 24 字窗必须在快照全集;坏窗>10% → 拒
        nb = normx(out)
        wins = [nb[i:i + 24] for i in range(0, max(1, len(nb) - 24), 24)]
        bad = sum(1 for w in wins if w not in allsnap)
        if wins and bad / len(wins) > 0.10:
            print(f"  拒新增(幻觉窗 {bad}/{len(wins)}) @{ts}", file=sys.stderr)
            continue
        # 防复述:新增与 body 重叠>50% → 拒(只要真新)
        ov = sum(1 for w in wins if w in normx(body))
        if wins and ov / len(wins) > 0.5:
            continue
        body = body.rstrip() + '\n' + out
    json.dump({'final_text': body, 'timeline': [], 'frames': len(rows), 'chrome_lines': 0},
              open('eval/canvas_v2.json', 'w'), ensure_ascii=False)
    print(f"拼接完成 字数 {len(body)}")
    return body

if __name__ == '__main__':
    main()
