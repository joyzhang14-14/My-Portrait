#!/usr/bin/env python3
"""阶段0:AX IME 重建(全本地)。
砍掉「text 有拉丁残渣才触发」的 gate;按 Enter 分段;每条只配自己的击键。
librime 候选 + 击键选字数字 = 确定性主力;MLX 仅在歧义(同音)时于候选集内消歧;
防幻觉硬 guard:英文不送 librime;模型新增的中文必须能追溯到 librime 候选,否则回滚。
设计依据见 Tests/writing-capture-extract/RESEARCH-ime-fix.md(R2/R4)。"""
import subprocess, re

ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
HAN = re.compile(r'[一-鿿]')
def has_han(s): return bool(HAN.search(s or ''))

CANDS = "/tmp/rime-test/cands"; LATTICE = "/tmp/rime-test/lattice"
_cc = {}; _lc = {}
def cands(py, n=8):
    py = py.replace(" ", "").lower()
    if len(py) < 1 or not py.isalpha(): return []
    k = (py, n)
    if k in _cc: return _cc[k]
    try:
        o = subprocess.run([CANDS, py, str(n)], capture_output=True, text=True, timeout=10).stdout
        r = [ln.split("] ", 1)[1].strip() for ln in o.splitlines() if "] " in ln]
    except Exception: r = []
    _cc[k] = r; return r
def lattice(py):
    py = py.replace(" ", "").lower()
    if py in _lc: return _lc[py]
    top, syls = "", []
    try:
        o = subprocess.run([LATTICE, py], capture_output=True, text=True, timeout=10).stdout
        for ln in o.splitlines():
            if ln.startswith("TOP "): top = ln[4:].strip()
            elif ln.startswith("SYL "):
                m = ln[4:].split(":", 1)
                if len(m) == 2: syls.append((m[0].strip(), m[1].split()))
    except Exception: pass
    _lc[py] = (top, syls); return (top, syls)

# ---- 击键解析(assembleKeystrokeText 格式:字母/数字/标点 + <CR> + <BS>)----
def _toks(ks): return re.findall(r'<CR>|<BS>|.', ks or '')
def apply_bs(toks):
    out = []
    for t in toks:
        if t == '<BS>':
            if out: out.pop()
        else: out.append(t)
    return out
def split_cr(ks):
    """击键串 → 按回车切的消息段列表(每段是 char 列表,已消化退格)"""
    segs, cur = [], []
    for t in apply_bs(_toks(ks)):
        if t == '<CR>': segs.append(cur); cur = []
        else: cur.append(t)
    if cur: segs.append(cur)
    return segs

def parse_picks(seg):
    """seg=char 列表 → [(pinyin, pick_idx|None, complete)]。
    选字数字 1-indexed → idx=n-1;空格/标点 → 默认首选 idx0;结尾挂字母无收尾 → complete=False。"""
    out, buf = [], ""
    for ch in seg:
        if ch.isalpha(): buf += ch.lower()
        elif ch.isdigit() and buf:
            n = int(ch)
            if 1 <= n <= 9: out.append((buf, n - 1, True)); buf = ""
            # 0 或异常数字:忽略(不并进拼音)
        elif not ch.isalnum():            # 标点/空格 = 一个拼音段收尾(默认首选)
            if buf: out.append((buf, 0, True)); buf = ""
    if buf: out.append((buf, None, False))  # 结尾无收尾 = 可能残缺/英文
    return out

# ---- 分类:english / incomplete / chinese ----
def classify(py, picked):
    c = cands(py, 8)
    if c and c[0].lower() == py.lower():           # 信号B:rime 英文词典(attention/coding/google/gemini)
        return ('english', [])
    _, syls = lattice(py)
    single = [s for s, _ in syls if len(s) == 1 and s not in 'aeiouv']  # 单辅音音节
    if picked is None:                              # 无选字数字(直接上屏 / 残尾)
        if len(single) >= 2:                        # gmail(g,l) / xpc(x,p,c) = 英文逐字
            return ('english', [])
        if syls and len(syls[-1][0]) == 1 and syls[-1][0] not in 'aeiouv':  # henbux 末尾 'x'
            return ('incomplete', [])
        if not c or not has_han(c[0]):              # 解不出中文
            return ('english', [])
    if c and has_han(c[0]):
        return ('chinese', c)
    return ('incomplete', [])

# ---- 解码单个拼音 run:lattice 整句最优(确定性打底)+ 模型同音消歧(音节集内,字数=音节数)----
DISAMBIG_CALLS = [0]   # 统计 14b 调用次数
def decode_run(py, context="", model_fn=None):
    """返回 (hanzi, syls)。**默认 TOP**;仅当词级候选有歧义且 model 给出「合法且≠TOP」的词才覆盖
    (词级 TOP 偏置:模型只在明显同音选错时才推翻,字数=音节数 + 每字∈对应音节候选集 硬校验)。"""
    top, syls = lattice(py)
    if not syls: return (None, [])
    han = top
    words = cands(py, 6)
    # 触发 disambig 的门:词级候选 ≥2 个「不同首字」的中文词(纯助词/emoji 变体不算真歧义),才值得问 14b
    realalt = [w for w in words if w != top and HAN.match(w[:1]) and w[:1] != top[:1]]
    if model_fn and len(realalt) >= 1:
        DISAMBIG_CALLS[0] += 1
        picked = cv(model_fn({'mode': 'disambig', 'py': py, 'top': top, 'words': words,
                              'syls': [(s, c[:8]) for s, c in syls], 'context': context}) or '')
        # 硬校验:字数==音节数 且 每字∈对应音节候选集;默认 TOP,只有合法才覆盖
        if picked and len(picked) == len(syls) and all(picked[i] in syls[i][1] for i in range(len(syls))):
            han = picked
    return (han, syls)

LATIN_TAIL = re.compile(r'[a-zA-Z][a-zA-Z ]*$')
# model_fn(payload)->str 可插拔。payload['mode']=='disambig' 走音节消歧;否则不调用。
def reconstruct_message(captured, ks, context="", model_fn=None):
    """多行消息按行对齐重建:captured 按 \\n 切行,击键按 <CR> 切段,取尾部 N 段配 N 行,逐行重建后拼回。"""
    cap = cv0(captured)
    lines = cap.split('\n')
    ksegs = [s for s in split_cr(ks) if any(c.isalnum() for c in s)] if isinstance(ks, str) else [ks]
    n = len(lines)
    seg_for = [None] * n
    take = ksegs[-n:] if n <= len(ksegs) else ksegs        # 尾部 N 段配 N 行(早段是别的消息/草稿)
    for i in range(len(take)): seg_for[n - len(take) + i] = take[i]
    out_lines, infos = [], []
    for i, ln in enumerate(lines):
        fixed, info = _reconstruct_line(ln, seg_for[i] or [], context, model_fn)
        out_lines.append(fixed); infos.append(info)
    return '\n'.join(out_lines), {'lines': infos}

def cv0(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip('　 \t\r')  # 保留 \n

def _reconstruct_line(captured, kseg, context="", model_fn=None):
    """两路:① captured 末尾有拼音残渣 → 直接解 captured 残渣(干净,免击键噪声);
    ② captured 是干净汉字、尾巴整段没进 captured → 用击键 run 级匹配补尾。"""
    cap = cv(captured)
    # ---- 路 ①:captured 末尾拼音残渣 → 调和 captured 残渣 + 击键 run,解码 ----
    m = LATIN_TAIL.search(cap)
    if m:
        residue = m.group().strip()
        r_cap = residue.replace(' ', '').lower()
        kpicks = parse_picks(kseg)
        py_ks, pick_ks = (kpicks[-1][0], kpicks[-1][1]) if kpicks else ('', None)
        # captured 残渣是击键 run 前缀(captured 截断)→ 用击键(更完整,带选字数字);否则用 captured 残渣(免击键前导噪声)
        use_py = py_ks if (py_ks and r_cap and py_ks.startswith(r_cap)) else r_cap
        use_pick = pick_ks if use_py == py_ks else None
        if use_py and not _is_eng_tail(use_py):
            kind, _ = classify(use_py, use_pick)
            if kind == 'chinese':
                base = cap[:m.start()].rstrip()
                han, _ = decode_run(use_py, (base + " ‖ " + context), model_fn)
                if han:
                    result = base + han
                    fin = guard(cap, result, set(ch for ch in cap if HAN.match(ch)) |
                                set(ch for c in lattice(use_py)[1] for cand in c[1] for ch in cand if HAN.match(ch)), set())
                    return fin, {'reason': 'residue', 'use_py': use_py, 'han': han}
            return cap, {'reason': 'residue_skip'}   # 英文/残缺:保留原样,绝不脑补
    # ---- 路 ②:无残渣,击键 run 级补尾 ----
    picks = parse_picks(kseg)
    runs = []   # (py, kind, syls)  syls=[(音节,[候选…])]
    for py, picked, complete in picks:
        kind, cl = classify(py, picked)
        syls = lattice(py)[1] if kind == 'chinese' else []
        runs.append((py, kind, syls))
    info = {'runs': [(r[0], r[1]) for r in runs]}
    if not any(r[1] == 'chinese' and r[2] for r in runs):
        info['reason'] = 'no_chinese_run'; return cap, info   # 全英文/残缺:原样,绝不脑补
    cap_han = [c for c in cap if HAN.match(c)]
    # 按序匹配已 commit 的汉字(同音字按候选集判),第一个匹配不上的 chinese run 起 = 尾巴
    pos = 0; tail = []
    for py, kind, syls in runs:
        if tail:
            tail.append((py, kind, syls)); continue
        if kind != 'chinese' or not syls:
            continue   # 英文/残缺在 commit 区:不消费汉字,跳过(留在原文里)
        n = len(syls)
        if pos + n <= len(cap_han) and all(cap_han[pos + i] in syls[i][1] for i in range(n)):
            pos += n   # 这段已正确 commit 在 captured 里(同音也认)
        else:
            tail.append((py, kind, syls))
    if not tail:
        info['reason'] = 'no_tail'; return cap, info          # 没尾巴 = captured 已完整,不动
    if pos < len(cap_han):
        info['reason'] = 'unaligned'; return cap, info        # 没消费完 captured 汉字 = 对不齐,保守不动
    # committed 前缀 = captured 去掉末尾拼音残渣(英文词不算残渣)
    base = cap
    m = LATIN_TAIL.search(cap)
    if m and not _is_eng_tail(m.group()): base = cap[:m.start()].rstrip()
    # 解码尾巴:每个 run 把「base + 已重建尾巴」当局部上下文喂消歧模型(判睡/水靠"5点__")
    tail_text = ""
    for py, kind, syls in tail:
        if kind == 'english': tail_text += py
        elif kind == 'chinese' and syls:
            han, _ = decode_run(py, (base + tail_text + " ‖ " + context), model_fn)
            if han: tail_text += han
        # incomplete: 丢(宁缺毋错)
    result = base + tail_text
    final = guard(cap, result, _allowed(runs, cap), {r[0] for r in runs if r[1] == 'english'})
    info['reason'] = 'rebuilt'; info['tail_text'] = tail_text; info['result'] = result
    return final, info

def _is_eng_tail(s):
    s = s.strip().replace(' ', '')
    if not s: return False
    c = cands(s, 1)
    return bool(c and c[0].lower() == s.lower())

def _allowed(runs, cap):
    a = set(ch for ch in cap if HAN.match(ch))
    for py, kind, syls in runs:
        if kind == 'chinese':
            for s, cl in syls:
                for cand in cl: a |= set(ch for ch in cand if HAN.match(ch))
    return a

# ---- ts 感知:每条**真发送** + 它的击键时间窗(用 withinSends 同款判据,排除 IME 改写删除)----
def event_sends_with_ts(ev, X):
    """返回 [(text, ks_start_ts, ks_end_ts, is_send)]:真 within-event 发送(占位符/空框夹+回车背书)
    + submit + 末尾未发送 endValue。X = extract_compare_v2 模块(借 cstream/phMarkers/emptyBox/cover/RUNPH)。"""
    arr = ev['arr']; cs = X.cstream(arr); ph = X.phMarkers(arr); returns = ev.get('returns', ())
    def isMark(j):
        if j < 0 or j >= len(arr): return False
        raw = arr[j].get('text', '') or ''
        return X.emptyBox(raw) or X.cv(raw) in ph or X.cv(raw) in X.RUNPH
    def sent(ts):
        return ts is not None and any(ts - 1800 <= rt <= ts + 200 for rt in returns)
    out = []
    prev_ts = ev.get('started_at') or 0
    for i, e in enumerate(arr):
        k = e.get('kind'); t = X.cv(e.get('text', '') or ''); ts = e.get('ts')
        if ts is None: continue
        if k == 'submit' and len(t) >= 2:
            out.append((t, prev_ts, ts, True)); prev_ts = ts
        elif k == 'delete':
            if len(t) < 2 or t in ph or t in X.RUNPH: continue
            if not (isMark(i - 1) or isMark(i + 1)): continue
            if X.cover(t, cs) < 0.5: continue
            if not sent(ts): continue                    # 回车检测:无回车=IME改写删除/草稿,不是发送
            out.append((t, prev_ts, ts, True)); prev_ts = ts
    endv = X.cv(ev['endv'])
    if endv and not X.emptyZW(ev['endv']):
        out.append((endv, prev_ts, ev.get('ended_at') or prev_ts, False))
    return out

def dedup_truncated(records, cover_fn):
    """类4/5a:丢掉「endValue 截断态(is_send=False)且内容大部分被某更长记录覆盖」的草稿快照。
    records=[(text, is_send, app)]。cover_fn(a,b)=a 的内容被 b 覆盖的比例(LCS)。真发送(is_send=True)永不丢。"""
    keep = []
    for i, (ta, sa, aa) in enumerate(records):
        if not sa and len(ta) >= 2:                       # 截断态草稿才考虑丢
            cta = cv(ta)
            covered = False
            for j, (tb, sb, ab) in enumerate(records):
                if i == j or ab != aa: continue
                ctb = cv(tb)
                if len(ctb) > len(cta) and (ctb.startswith(cta) or cover_fn(cta, ctb) >= 0.8):
                    covered = True; break             # cta 是 ctb 的早期/截断态
            if covered: continue
        keep.append((ta, sa, aa))
    return keep

def keys_in_window(con, bundle, t0, t1, pad_start=2000, pad_end=300):
    # 发送的击键到回车(发送 ts)为止 → 尾 pad 小,免漏进下条消息
    rows = con.execute(
        "SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",
        (bundle, (t0 or 0) - pad_start, (t1 or 0) + pad_end)).fetchall()
    o = ""
    for ts, c, bs, md in rows:
        if (md & 7) != 0: continue
        if bs: o += "<BS>"; continue
        if c: o += "<CR>" if c in ("\n", "\r") else c
    return o

def guard(cap, model_out, allowed_han, eng):
    """模型新增的每个汉字必须 ∈ allowed_han(librime 候选/原文);否则判幻觉,回退原文。
    英文 run 必须在输出里保持字面存在,否则也回退。"""
    if not model_out: return cap
    new_han = [ch for ch in model_out if HAN.match(ch) and ch not in cap]
    if any(ch not in allowed_han for ch in new_han):
        return cap                                  # 有无来源的新增汉字 = 幻觉 → 回退
    for e in eng:                                   # 英文词必须字面保留
        if e.lower() not in model_out.lower():
            return cap
    # 防删字:按**汉字数**比(拼音→汉字本来就变短,不能按字符长度)
    if sum(1 for c in model_out if HAN.match(c)) < sum(1 for c in cap if HAN.match(c)):
        return cap
    return model_out
