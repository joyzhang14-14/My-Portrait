#!/usr/bin/env python3
"""阶段0:AX IME 重建(全本地)。
砍掉「text 有拉丁残渣才触发」的 gate;按 Enter 分段;每条只配自己的击键。
librime 候选 + 击键选字数字 = 确定性主力;MLX 仅在歧义(同音)时于候选集内消歧;
防幻觉硬 guard:英文不送 librime;模型新增的中文必须能追溯到 librime 候选,否则回滚。
设计依据见 Tests/writing-capture-extract/RESEARCH-ime-fix.md(R2/R4)。"""
import subprocess, re, os

ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
HAN = re.compile(r'[一-鿿]')
def has_han(s): return bool(HAN.search(s or ''))

# librime 已搬进项目(不再用 /tmp)。词库 rime/ice + ice-cands 大→gitignore;源码 rime/*.c 入库,重编见 rime/build.sh。
_RIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rime")
CANDS = os.path.join(_RIME, "cands"); LATTICE = os.path.join(_RIME, "lattice")
# 粘贴政策(用户裁定 2026-06-10):消息内单段已知粘贴 ≤ 此值且非纯粘贴 → 整条留;用户可调。
PASTE_MAX = 30
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
# 单元完整性由部署词库判(ime_schema),不硬编码 'aeiouv' —— 换五笔/双拼/日韩方案不用改代码。
import ime_schema as SCH
def classify(py, picked):
    c = cands(py, 8)
    if c and c[0].lower() == py.lower():           # 信号B:rime 英文词典(attention/coding/google/gemini)
        return ('english', [])
    _, syls = lattice(py)
    single = [s for s, _ in syls if not SCH.is_complete_unit(s)]   # 残缺单元(g/l/x;a/e/o 在词库=完整)
    if picked is None:                              # 无选字数字(直接上屏 / 残尾)
        if len(single) >= 2:                        # gmail(g,l) / xpc(x,p,c) = 英文逐字
            return ('english', [])
        if syls and not SCH.is_complete_unit(syls[-1][0]):          # henbux 末尾 'x' 残缺
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
    # 低置信:TOP 不在词级候选里 = 逐字拼装非真词(卖个惨→买个参)→ 也要问模型(给逃生门机会)
    lowconf = bool(top) and top not in words
    if model_fn and (len(realalt) >= 1 or lowconf):
        DISAMBIG_CALLS[0] += 1
        picked = cv(model_fn({'mode': 'disambig', 'py': py, 'top': top, 'words': words,
                              'syls': [(s, c[:8]) for s, c in syls], 'context': context,
                              'lowconf': lowconf}) or '')
        # 逃生门:模型判「所有候选都不通顺」(没打完/词库外)→ 不解码,留残渣给口3(OCR三路)
        if picked == 'NONE':
            return (None, syls)
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
    # 尾段防漏(ting bu cuo d案,2026-06-11):keys_in_window 尾 pad(300ms)会带进**下条消息的
    # 前导键**(无<CR>收尾的残段),它抢走"尾部N段配N行"的对齐位,真run整段丢失→解码放弃。
    # 段数>行数 且 kw无<CR>收尾 且 残段与末行残渣无关(非等值/前缀双向)→ 弃残段。
    if (len(ksegs) > n and isinstance(ks, str) and not ks.rstrip().endswith('<CR>')):
        m_t = LATIN_TAIL.search(cv(lines[-1]) if lines else '')
        rl = m_t.group().replace(' ', '').lower().strip() if m_t else ''
        last_letters = ''.join(c for c in ksegs[-1] if c.isalpha()).lower()
        if not (rl and last_letters and (last_letters.startswith(rl) or rl.startswith(last_letters))):
            ksegs = ksegs[:-1]
    seg_for = [None] * n
    take = ksegs[-n:] if n <= len(ksegs) else ksegs        # 尾部 N 段配 N 行(早段是别的消息/草稿)
    for i in range(len(take)): seg_for[n - len(take) + i] = take[i]
    out_lines, infos = [], []
    for i, ln in enumerate(lines):
        if not cv(ln) and len(lines) > 1:   # R4守卫:多行中的空行=用户有意空白,不重建(防植入)
            out_lines.append(ln); infos.append({'reason': 'empty_line'}); continue
        fixed, info = _reconstruct_line(ln, seg_for[i] or [], context, model_fn)
        out_lines.append(fixed); infos.append(info)
    # 竞速尾标点(反引号案 ev1131,2026-06-11):闭引号键落在选字与发送CR之间,AX快照晚一拍漏收
    # ('"'键@28.940,CR@29.288,快照@29.666 无闭引号)。末行击键段以 '"' 收尾 + 全文 “ 多于 ”
    # → 击键背书 + 配对信号双证,补 ”。只做双引号(本案);无配对信号不动。
    joined = '\n'.join(out_lines)
    last_seg = ''.join(seg_for[-1]) if (seg_for and seg_for[-1]) else ''   # split_cr 段=char列表
    if (out_lines and last_seg.rstrip().endswith('"')
            and joined.count('“') > joined.count('”')):
        out_lines[-1] += '”'
        infos[-1] = {**(infos[-1] or {}), 'quote_fixed': True}
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
        # 字面残渣保护(宁缺毋错):含大写字母(IME 拼音必是小写;G/Joyzhang14 是字面)
        # 或单字母(g→个/e→呃 太险)→ 不解码,原样保留。AX 采到什么就是什么。
        # 或前导字符是 ./:@-_(域名/路径/邮箱:ikeyrent.com 的 com 是字面,不是拼音——
        # guard 放宽后 com→聪明 实锤回归,2026-06-10)
        if (any(c.isupper() for c in residue) or len(residue.replace(' ', '')) <= 1
                or (m.start() > 0 and cap[m.start() - 1] in './:@-_')):
            return cap, {'reason': 'literal_residue'}
        r_cap = residue.replace(' ', '').lower()
        kpicks = parse_picks(kseg)
        py_ks, pick_ks = (kpicks[-1][0], kpicks[-1][1]) if kpicks else ('', None)
        # captured 残渣是击键 run 前缀(captured 截断)→ 用击键(更完整,带选字数字);否则用 captured 残渣(免击键前导噪声)
        def _cp(a, b):
            n = 0
            for x, y in zip(a, b):
                if x != y: break
                n += 1
            return n
        # 击键终态优先(小修B,2026-06-10):用户退格改字后(meili<BS>ai=meilai),AX 残渣(mei li)是
        # 过期快照;py_ks 与残渣共同前缀≥3 且有选字数字确认上屏 → 信击键终态(最大保留最终输入)。
        # 末位失配再扫全部 picks(ting bu cuo d 案,2026-06-11):keys_in_window 尾 pad 会漏进
        # 下条消息前导键(末位 pick='shuo'),残渣对应的 run 在更早位 → 逆序找等值/前缀 run,
        # 取回其选字数字(同 #42 "扫全部 picks"原则;丢了数字 classify 不认,解码整段放弃)。
        if r_cap and not (py_ks and (py_ks.startswith(r_cap)
                  or (pick_ks is not None and _cp(py_ks, r_cap) >= 3))):
            for p, pk, _cpl in reversed(kpicks):
                if p == r_cap or p.startswith(r_cap):
                    py_ks, pick_ks = p, pk; break
        use_py = py_ks if (py_ks and r_cap and (py_ks.startswith(r_cap)
                  or (pick_ks is not None and _cp(py_ks, r_cap) >= 3))) else r_cap
        use_pick = pick_ks if use_py == py_ks else None
        # #42 英文截断:击键里的英文 run 比 captured 残渣更全(AX 漏末字,pipelin→pipeline)
        # → 击键背书补全。⚠️ IME 开着时选字数字会把英文 run 切进前面的 pick
        # (pipeline1ee → ('pipeline',选1)+('ee',残尾)),所以扫**全部** picks 找前缀匹配,不只看末位。
        comp = [p for p, _, _ in kpicks if r_cap and p != r_cap and p.startswith(r_cap) and _is_eng_tail(p)]
        if comp:
            best = max(comp, key=len)
            return cap + best[len(r_cap):], {'reason': 'eng_tail_completed', 'use_py': best}
        if use_py and _is_eng_tail(use_py):
            return cap, {'reason': 'residue_skip'}   # 完整英文词:原样,绝不脑补
        if use_py:
            kind, _ = classify(use_py, use_pick)
            if kind == 'chinese':
                base = cap[:m.start()].rstrip()
                han, _ = decode_run(use_py, (base + " ‖ " + context), model_fn)
                if han:
                    # 续接 run(看你怎么用了案,2026-06-11):匹配 run 之后、同段内(段尾=发送CR)
                    # 还有带选字数字的 run('l'选1=了)→ 用户确认上屏的字,一并解码追加。
                    # AX 残渣只泄漏到 yo,'l1'在射程外;选字数字=确认上屏,非脑补。
                    allowed_extra = set()
                    if use_py == py_ks:
                        mi = next((i for i, (p, pk, _c) in enumerate(kpicks)
                                   if p == py_ks and pk == pick_ks), None)
                        if mi is not None:
                            for p2, pk2, cpl2 in kpicks[mi + 1:]:
                                # ≥2字母才续接:单字母候选序在live输入法与librime间分歧
                                # (cands('l')=来里老啦了,用户输入法首位是了)→宁缺毋错不赌
                                if pk2 is None or not cpl2 or len(p2) < 2 or not p2.isalpha():
                                    break
                                k2, _ = classify(p2, pk2)
                                if k2 != 'chinese':
                                    break
                                h2, _ = decode_run(p2, (base + han + " ‖ " + context), model_fn)
                                if not h2:
                                    break
                                han += h2
                                allowed_extra |= set(ch for w in cands(p2, 8) for ch in w if HAN.match(ch))
                                allowed_extra |= set(ch for ch in lattice(p2)[0] if HAN.match(ch))
                    result = base + han
                    fin = guard(cap, result, set(ch for ch in cap if HAN.match(ch)) |
                                set(ch for c in lattice(use_py)[1] for cand in c[1] for ch in cand if HAN.match(ch)) |
                                set(ch for ch in lattice(use_py)[0] if HAN.match(ch)) |
                                set(ch for w in cands(use_py, 8) for ch in w if HAN.match(ch)) |
                                allowed_extra, set())
                    return fin, {'reason': 'residue', 'use_py': use_py, 'han': han}
            return cap, {'reason': 'residue_skip'}   # 残缺:保留原样,绝不脑补
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
    # 守卫(2026-06-10,v5-8回归):captured 非空但**无一个汉字**(纯英文行)→ 中文补尾不适用,
    # 原样返回。对齐逻辑对 cap_han=[] 真空成立,否则全部击键 run 会被当尾巴贴上(英文长文+拼音垃圾)。
    if cap and not cap_han:
        info['reason'] = 'no_han_in_cap'; return cap, info
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
            else: tail_text += py   # 逃生门 NONE:留拼音残渣(击键背书的字面),给口3 修
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
            # librime 词级确定性输出也是合法来源(诊断:缩写音节 h/x/c 的前6单字候选
            # 不含 话/型/错,guard 否决自家 TOP → 整条蒸发)。TOP/cands 来自用户击键的
            # 确定性解码,非模型写权;模型选字仍被 decode_run 硬校验独立钳死。
            a |= set(ch for ch in lattice(py)[0] if HAN.match(ch))
            for w in cands(py, 8): a |= set(ch for ch in w if HAN.match(ch))
    return a

# ---- ts 感知:每条**真发送** + 它的击键时间窗(用 withinSends 同款判据,排除 IME 改写删除)----
def event_sends_with_ts(ev, X, group_cs=None):
    """返回 [(text, ks_start_ts, ks_end_ts, is_send)]:真 within-event 发送(占位符/空框夹+回车背书)
    + submit + 末尾未发送 endValue。X = extract_compare_v2 模块(借 cstream/phMarkers/emptyBox/cover/RUNPH)。
    group_cs:组级 commit 流(#40 用户裁定:发送清空快照当成品)——跨事件长文(中段插入/补尾在后续事件,
    Blueprint 案)的快照对单事件 commit 流只盖 ~35%,被手打闸误杀;组级取证 0.66 过。粘贴不进 commit 流,防 autofill 本意不变。"""
    arr = ev['arr']; cs = X.cstream(arr); ph = X.phMarkers(arr); returns = ev.get('returns', ())
    # #44/#45:已知占位符(KNOWN_PH)即使是 commit 注入(非 paste)也认作占位符标记/过滤——
    # phMarkers 只认 paste(防普通词误判),known 列表是白名单,commit 注入也安全。
    def isMark(j):
        if j < 0 or j >= len(arr): return False
        raw = arr[j].get('text', '') or ''
        return X.emptyBox(raw) or X.cv(raw) in ph or X.cv(raw) in X.RUNPH or X.is_ph(X.cv(raw))
    def sent(ts):
        return ts is not None and any(ts - 1800 <= rt <= ts + 200 for rt in returns)
    out = []
    prev_ts = ev.get('started_at') or 0
    # 粘贴政策(用户裁定,零LLM):消息含已知 paste 段时——单段 ≤PASTE_MAX(30,可调)且
    # 粘贴占比 <100% → 整条留(跳过 cover 闸,粘贴术语如 'ElevenLabs Scribe v2 Realtime' 29字∈合法);
    # 单段 >PASTE_MAX 或纯粘贴 → 不留。无已知 paste → 原 cover 闸(手打铁律兜底,防 autofill/程序写入)。
    pastes = [X.cv(e.get('text', '') or '') for e in arr
              if e.get('kind') == 'paste' and len(X.cv(e.get('text', '') or '')) >= 2]
    def paste_verdict(t):
        inb = [p for p in pastes if p and p in t]
        if not inb: return None                          # 无已知粘贴 → 走原 cover 闸
        if any(len(p) > PASTE_MAX for p in inb): return False
        if sum(len(p) for p in inb) >= len(t): return False   # 纯粘贴
        return True
    def strip_pastes(t):
        """粘贴剥离(用户裁定 2026-06-12,作文反馈案 ev692/694/699):超限粘贴不再整条丢——
        去掉已知 paste 段,保留手打需求('时态你帮我改吧'/'够了吧')。剩余须过 cover 手打闸。"""
        rem = t
        for p in sorted(pastes, key=len, reverse=True):
            if p and p in rem: rem = rem.replace(p, '\n')
        rem = '\n'.join(ln for ln in rem.split('\n') if X.cv(ln)).strip()
        if len(X.cv(rem)) >= 2 and X.cover(X.cv(rem), group_cs or cs) >= 0.5:
            return rem
        return None
    txc = X.cv(ev.get('text') or '')
    for i, e in enumerate(arr):
        k = e.get('kind'); t = X.cv(e.get('text', '') or ''); ts = e.get('ts')
        if ts is None: continue
        if k == 'submit' and len(t) >= 2:
            # 存量框剥离(作文反馈案 ev692/694/699,2026-06-12 用户裁定:粘贴>30 消除,只留手打需求):
            # submit 全文=存量大文本(早先粘贴/前轮延续,无本事件击键背书)+手打增量(AX text)。
            # 全文对击键 cover<0.5(非本事件手打)而增量 cover≥0.4(简拼宽容)→ 只记增量。
            if (txc and len(t) > 2 * len(txc)
                    and sum(1 for ch in txc if not ch.isascii()) >= 3
                    and X.cover(t, group_cs or cs) < 0.5
                    and X.cover(txc, cs) >= 0.4):
                # 假submit不剥(ev616 vos/vcd案):框清空证人——60s内后续事件endv仍延续本全文
                # =框没清=幻影submit('写的更详细一些'是改稿动作非独立发送),保原文交主链幻影降级
                t_n = re.sub(r'\s', '', t)
                nxt = X.con.execute("SELECT end_value FROM typing_events WHERE bundle_id=:b "
                                    "AND started_at > :a AND started_at <= :a2",
                                    {"b": ev['bundle'], "a": ts, "a2": ts + 60000}).fetchall()
                if not any(t_n and t_n in re.sub(r'\s', '', X.cv(w or '')) for (w,) in nxt):
                    t = txc
            out.append((t, prev_ts, ts, True)); prev_ts = ts
        elif k == 'delete':
            if len(t) < 2 or t in ph or t in X.RUNPH or X.is_ph(t): continue
            if not (isMark(i - 1) or isMark(i + 1)): continue
            pv = paste_verdict(t)
            if pv is False:                              # 大粘贴:剥离粘贴段,手打需求留
                if not sent(ts): continue
                rem = strip_pastes(t)
                if rem: out.append((rem, prev_ts, ts, True)); prev_ts = ts
                continue
            if pv is None and X.cover(t, group_cs or cs) < 0.5: continue   # 手打铁律兜底(组级流取证,见 docstring)
            if not sent(ts): continue                    # 回车检测:无回车=IME改写删除/草稿,不是发送
            out.append((t, prev_ts, ts, True)); prev_ts = ts
    endv = X.cv(ev['endv'])
    if endv and not X.emptyZW(ev['endv']) and not X.is_ph(endv):   # 占位符 endValue(含拼接如"…他说")整条不出
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
                # 等长编辑修正快照(vos↔vcd 互换案):同长高覆盖,时序靠后者=用户最终输入,前者丢
                if j > i and len(ctb) == len(cta) and ctb != cta and cover_fn(cta, ctb) >= 0.9:
                    covered = True; break
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
