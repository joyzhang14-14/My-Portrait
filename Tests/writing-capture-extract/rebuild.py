#!/usr/bin/env python3
"""阶段0:AX IME 重建(全本地)。
砍掉「text 有拉丁残渣才触发」的 gate;按 Enter 分段;每条只配自己的击键。
librime 候选 + 击键选字数字 = 确定性主力;MLX 仅在歧义(同音)时于候选集内消歧;
防幻觉硬 guard:英文不送 librime;模型新增的中文必须能追溯到 librime 候选,否则回滚。
设计依据见 Tests/writing-capture-extract/RESEARCH-ime-fix.md(R2/R4)。"""
import subprocess, re, os, difflib

ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
HAN = re.compile(r'[一-鿿]')
def has_han(s): return bool(HAN.search(s or ''))

# librime 已搬进项目(不再用 /tmp)。词库 rime/ice + ice-cands 大→gitignore;源码 rime/*.c 入库,重编见 rime/build.sh。
_RIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rime")
CANDS = os.path.join(_RIME, "cands"); LATTICE = os.path.join(_RIME, "lattice")
# 粘贴政策(用户裁定 2026-06-10):消息内单段已知粘贴 ≤ 此值且非纯粘贴 → 整条留;用户可调。
PASTE_MAX = int(os.environ.get('PORTRAIT_PASTE_MAX', '30'))   # 短粘贴保留上限(旋钮,前端可调;>此的粘贴段剥/丢)
# librime 解码接线开关(2026-06-27 用户裁定):采集层摇读修复后 AX 直接给汉字,
# librime「拼音→汉字」猜字(decode_run)成了误判隐患(猜错=错字,铁律里最坏类别)。
# 默认**关**:不解码,留拼音残渣 → 现有逃生门把它路由给口3 OCR(屏幕真值,比猜可靠)。
# 不影响:口3 拼音表匹配(不走 decode_run)、字面/英文/数字尾补全、guard。
# 历史黑洞数据/对照跑可置 PORTRAIT_LIBRIME_DECODE=1 临时开。
DECODE_LIBRIME = os.environ.get('PORTRAIT_LIBRIME_DECODE', '0') == '1'
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
def commit_syls(letters):
    """已上屏单元的音节切分(音节数 = 上屏汉字数,退格删字要用它)。按部署词库音节表贪心切分
    (ime_schema,零硬编码,换方案跟着词库走)。**必须进程内**:走 librime 会每个新串 spawn 一次
    子进程重载词库,生产跑直接拖垮。

    简拼要认(zhongy=zhong+y=重要2字 / bangw=bang+w=帮我2字):允许**至多 1 个残缺单元且只能在末尾**
    (= 简拼尾声母)。英文/乱码天然出局:sonnet→so|n|ne|t(残缺2个)、event→e|v|en|t、ubia→u|…(残缺
    在**开头**)。非拼音 → None,调用方走旧逐字弹,别动英文。"""
    if not letters: return None
    segs, i, n, inc = [], 0, len(letters), 0
    while i < n:
        for L in range(min(6, n - i), 0, -1):
            if SCH.is_complete_unit(letters[i:i + L]):
                segs.append(letters[i:i + L]); i += L; break
        else:
            if inc or segs == [] or i != n - 1:   # 残缺只许 1 个,且必须是末尾那个(简拼尾)
                return None
            segs.append(letters[i]); i += 1; inc = 1
    return segs or None

def apply_bs(toks):
    """消化退格 —— 按输入法「提交(上屏)」语义,不是裸字符弹栈(2026-07-11 用户裁定的打字行为)。

    规则:拼音串后面跟**选字数字**,就说明前面那串**已被输入法变成屏幕上的汉字**,原始字母就此
    退出解码缓冲;此后一个退格删的是**屏幕上的一个字**,既不是一个字母也不是那个数字:
      · 单音节 na1      → 上屏 1 字(那)  → 整个单元删掉
        (旧码只弹数字,残留 na 与下一个 na 粘成 nana → librime「娜娜」= ev461 叠字+同音错)
      · 多音节 dabao1   → 上屏 2 字(打包)→ 只砍末音节,剩下的仍是已上屏文字(→ da1 = 打)
      · 英文/残渣 sonnet1 → 不是拼音上屏,数字是字面 → 保持旧逐字弹(否则英文词会被整个吞掉)

    ⚠️**空格/回车也是提交信号,但这里不敢用**:击键流(<6/25 无 input_source)分不出中英文模式,
    而英文每个词后面都跟空格,且 but/say/am 这类短英文词恰好能当简拼解析(bu+t / sa+y)——把
    「英文词+空格」当上屏会把英文整个吞掉(实测 ev690 英文文章的 which 被吃)。有 input_source
    (≥6/13)判定中文输入法时才能开空格信号。<CR> 的提交语义(尾巴)同理,归 keystroke 主导重构。"""
    out = []
    for t in toks:
        if t == '<BS>':
            if out and out[-1].isdigit() and len(out) >= 2 and out[-2].isalpha():
                j = len(out) - 2
                while j >= 0 and out[j].isalpha(): j -= 1
                syls = commit_syls(''.join(out[j + 1:len(out) - 1]))
                if syls is None:
                    out.pop()                          # 英文/残渣:数字/空格是字面 → 照旧弹一个
                elif len(syls) == 1:
                    del out[j + 1:]                    # 上屏 1 个字 → 整单元删掉
                else:
                    del out[j + 1:]                    # 上屏多个字 → 只删末字
                    out.extend(''.join(syls[:-1])); out.append('1')   # 其余仍是已上屏文字(默认首选)
            elif out: out.pop()
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
    if not DECODE_LIBRIME:
        return (None, [])   # 接线已拔:不猜字,等同逃生门 → 调用方留拼音残渣给口3 OCR
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
def reconstruct_message(captured, ks, context="", model_fn=None, eng_literals=None):
    """多行消息按行对齐重建:captured 按 \\n 切行,击键按 <CR> 切段,取尾部 N 段配 N 行,逐行重建后拼回。
    eng_literals:该事件「英文字面」拉丁 run 集合(小写去空格,faithful 侧据双return/input_source 算),
    guard 据此防过度解码(em→恶魔)。"""
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
        fixed, info = _reconstruct_line(ln, seg_for[i] or [], context, model_fn, eng_literals)
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

def _reconstruct_line(captured, kseg, context="", model_fn=None, eng_literals=None):
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
        # 或 residue 是该事件的「英文字面」run(双return/input_source 背书:em→恶魔,2026-06-16)——
        # 不靠长度(ni/wo 也是2字母小写拼音),靠输入法信号判中英文
        if (any(c.isupper() for c in residue) or len(residue.replace(' ', '')) <= 1
                or (m.start() > 0 and cap[m.start() - 1] in './:@-_')
                or (eng_literals and residue.replace(' ', '').lower() in eng_literals)):
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
    s = s.strip()
    if not s: return False
    words = s.split()
    if len(words) >= 2:
        # 多词拉丁尾:含 ≥1 个标准英文词(≥2字母且 rime 英文词典命中,cands 返回单词自己)
        # = 英文短语(lemme check en),不解码;全是短拼音音节(te d/hen bu x/shang hai,
        # 逐词解成中文)= 拼音简拼尾,放行解码。修 ev1013 英文被拼成'了么么车诚恳'。
        return any(len(w) >= 2 and (c := cands(w, 1)) and c[0].lower() == w.lower()
                   for w in words)
    s = s.replace(' ', '')
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

# ===== 粘贴旁路三道闸(2026-07-15,v6 审核坐实 47 条粘贴违规)=====
# 教训:**别再试图「检测粘贴」**(右键粘/拖拽/自动补全/程序输出,路子堵不完)。
# 只问一件事:**这些字有没有击键背书**(用户铁律:只记 commit 背书的内容)。
# 闸A(下面 paste_pressed)= 发现「这个事件里发生过粘贴」→ 给闸C 上膛;
# 闸B(extract_compare_v2.injected_texts/cstream)= 把粘贴伪装成的 commit 从背书流里剔掉;
# 闸C(下面 commit_backed)= 成品逐行必须能被 commit 流解释,解释不了的行裁掉。
PASTE_GATE = os.environ.get('PORTRAIT_PASTE_GATE', '1') == '1'   # 前端开关
def paste_pressed(X, ev):
    """闸A:有没有**物理 ⌘V**(modifiers 0x01=Command,已核 KeystrokeCharLogger.swift:68)。
    ⚠️为什么不能只信 edit_log 的 kind='paste':edit_log 只记事件**开始之后**的 diff,⌘V 在
    started_at 之前按下,粘进来的内容就成了事件的「初始状态」,一条 paste 记录都没有
    (ev342:⌘V 早 109ms,936 字符 yt-dlp 终端输出零 paste 记录,靠 end_value 整段进了成品)。
    击键流是这种情况下唯一的铁证。

    回扫窗 = **上一个同 app 事件结束 → 本事件结束,无限时长**(用户裁定 2026-07-16):
    两个事件之间不管隔多久按的 ⌘V,粘进来的内容都只会落在本事件的初始状态里(自动合并进本
    事件),归因唯一、不会算错到别的事件头上。第一版固定 2 秒窗是按 ev342(早 109ms)标定的,
    v8 审核实测 ⌘V 早 3~33 秒的粘贴全漏(x.com 链接/多伦多地址案)。"""
    st = ev.get('started_at') or 0
    prev = X.con.execute(
        "SELECT MAX(ended_at) FROM typing_events WHERE bundle_id=:b AND ended_at < :st",
        {"b": ev['bundle'], "st": st}).fetchone()[0]
    return X.con.execute(
        "SELECT 1 FROM keystroke_log WHERE bundle_id=:b AND ts_ms BETWEEN :a AND :c "
        "AND char='v' AND (modifiers&1)=1 LIMIT 1",
        {"b": ev['bundle'], "a": (prev + 1) if prev is not None else 0,
         "c": (ev.get('ended_at') or st) + 500}).fetchone() is not None

TRIM_MIN_LINE = 5        # 强背书回落档:2~4 字的行在几百字 commit 流里 LCS 必然撞上('> ok'/'join')
TRIM_COVER = 0.8         # 强背书回落档的行级 cover 门槛(只在字母对账不过时启用,见 commit_backed)

def _line_backing(X, t, cs):
    """闸C 的行级对账基础:[(行, 去空格长度, 未背书字符数)],空行的未背书 = None。
    **未背书字符数 = 行长×(1-块cover)** —— 存量框剥离 `unhand` 公式(submit 分支既有先例)的行级版。

    块cover:**双方去空格**后只数**连续匹配块**(纯 ASCII 块 ≥3 字符,含汉字块 ≥2 字符,单字符不算)。
    两个都是实测教训:
    · 裸 LCS 单字符散点作弊:`[Instagram] Setting up session` 的字母散落在组内拼音流
      (zheshigeiwo…)里,碎配凑出 cover≈0.4 → 43×0.6=26 混过 30 闸(ev342)。块门槛按字符集
      分档:IME 上屏粒度就是 1~2 个汉字,真打的中文天然是 2 字块;汉字字表大,2 字块撞库
      概率远低于 ASCII —— 连续性就是"真打过"的指纹。
    · 不去空格,`Pipeline A - 1, A - 2` 这种空格隔开的单字符永远成不了块(通道行实证:
      带空格块 cover 只有 0.65 误裁;去空格后真打序列连成长块,0.93,未背书 6)。
    实测边距:通道行(真打)未背书 6 ≪ 30 ≪ yt 行 38 / ev598 泄漏行 62·88(全粘贴)。"""
    cs_ns = re.sub(r'\s', '', cs or '')
    def _cov(a):
        if not a or not cs_ns:
            return 0.0
        tot = 0
        for b in difflib.SequenceMatcher(None, a, cs_ns, autojunk=False).get_matching_blocks():
            seg = a[b.a:b.a + b.size]
            if b.size >= 3 or (b.size == 2 and HAN.search(seg)):
                tot += b.size
        return tot / len(a)
    out = []
    for ln in t.split('\n'):
        c = re.sub(r'\s', '', cv(ln))
        out.append((ln, len(c), len(c) * (1 - _cov(c)) if c else None))
    return out

def paste_minor(X, t, cs):
    """规则「粘贴少数派整条留」(用户裁定 2026-07-16):**粘贴的字符数 < 全文除粘贴外的字符数
    → 整条原样保留,不裁**。粘贴量用未背书字符数估(闸A 上膛的事件里,没击键背书的就是粘的)。
    这是粘贴政策「非纯粘贴」条款的记录级完整形态:你自己的话为主、捎带一点引用/链接的消息,
    引用是内容的一部分,裁了反而残(v8 审核误裁 3 条全是这种:ev598 阶段5 段 190 字手打陪着
    行尾 40 字 URL 连坐 / ev888 全手打但 AX commit 缺页)。文档浏览(粘贴占绝对多数)不受益。"""
    rows = [(n, u) for _, n, u in _line_backing(X, t, cs) if u is not None]
    unbacked = sum(u for _, u in rows)
    return unbacked < sum(n for n, _ in rows) - unbacked

def commit_backed(X, t, cs):
    """闸C(用户裁定 2026-07-15:**严格 30 闸,一切以击键为主**,不做任何内容/形态硬编码)。
    只对**粘贴占多数**的记录开火(少数派在 gate 里被 paste_minor 整条放行,到不了这儿):

    行规则只有一条 —— **未背书字符数 ≤ PASTE_MAX 留,超了裁**(见 _line_backing):
      · 全手打的行:未背书≈0 → 留(IME 反复改写 LCS 只有 0.79 也不怕,通道行案)
      · 短行(≤30):cover 再低未背书也 ≤30 → 自动留(「先用apify找到爆款视频」23 字)
      · 掺粘贴的长行:ev598 localhost 行 193字×0.42=81 → 裁;yt-dlp 行 43~116 字全裁

    **多数背书守卫(零新常数)**:留下来的行里未背书量仍超背书量 → 纯粘贴射程(回看旧成品 md
    的记录只有「- 内容不全」5 字是打的,文档短行每行 ≤30 全过线,`https://…` 打穿 P0 的教训)
    → 回落到只留强背书行(块cover≥TRIM_COVER 且去空格 ≥TRIM_MIN_LINE 字)。"""
    rows = [(ln, n, u) for ln, n, u in _line_backing(X, t, cs) if u is not None and u <= PASTE_MAX]
    backed_m = sum(n - u for _, n, u in rows)
    unbacked_m = sum(u for _, _, u in rows)
    if unbacked_m > backed_m:
        rows = [(ln, n, u) for ln, n, u in rows
                if n >= TRIM_MIN_LINE and (1 - u / n) >= TRIM_COVER]
    return '\n'.join(ln for ln, _, _ in rows).strip()

# ---- ts 感知:每条**真发送** + 它的击键时间窗(用 withinSends 同款判据,排除 IME 改写删除)----
def event_sends_with_ts(ev, X, group_cs=None, group_letters=None):
    """返回 [(text, ks_start_ts, ks_end_ts, is_send)]:真 within-event 发送(占位符/空框夹+回车背书)
    + submit + 末尾未发送 endValue。X = extract_compare_v2 模块(借 cstream/phMarkers/emptyBox/cover/RUNPH)。
    group_cs:组级 commit 流(#40 用户裁定:发送清空快照当成品)——跨事件长文(中段插入/补尾在后续事件,
    Blueprint 案)的快照对单事件 commit 流只盖 ~35%,被手打闸误杀;组级取证 0.66 过。粘贴不进 commit 流,防 autofill 本意不变。"""
    arr = ev['arr']; ph = X.phMarkers(arr); returns = ev.get('returns', ())
    cs = X.cstream(arr, ev.get('inj'))   # 闸B:粘贴伪装的 commit 不进背书流
    # #44/#45:已知占位符(KNOWN_PH)即使是 commit 注入(非 paste)也认作占位符标记/过滤——
    # phMarkers 只认 paste(防普通词误判),known 列表是白名单,commit 注入也安全。
    # inj(2026-07-10 用户裁定):无击键背书的注入 commit(X.injected_texts,loadev 算好)。
    # ⚠️ 只做**内容过滤**(delete 文本/endValue 草稿),**不当 isMark 标记**——占位符轮换=清框信号
    # 可当 marker;但自动补全/重渲染注入不是清框信号,当 marker 会给旁邻 delete 发假「发送」通行证
    # (全库 diff 实证:ev1132 多出 note book 假发送/lin k·ke y·booking 垃圾升格,已回撤)。
    inj = ev.get('inj', ())
    def isMark(j):
        if j < 0 or j >= len(arr): return False
        raw = arr[j].get('text', '') or ''
        return X.emptyBox(raw) or X.cv(raw) in ph or X.cv(raw) in X.RUNPH or X.is_ph(X.cv(raw))
    def sent(ts):
        return ts is not None and any(ts - 1800 <= rt <= ts + 200 for rt in returns)
    out = []
    lone_cands = []   # 单字汉字 delete 候选,函数末按「本事件有无别的产出」判孤儿 vs 成品补丁
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
    stripped_hit = [False]
    # 闸A 上膛:本事件有粘贴痕迹(物理 ⌘V / edit_log paste 段 / 巨块注入 commit)→ 出口过闸C 裁剪。
    # **只在有粘贴证据时开火**:没证据的事件维持原行为,不动跨事件长文(#40 Blueprint 案的 endValue
    # 快照对组流只盖 ~35%,无差别上闸C 会把真手打长文裁碎)。
    armed = PASTE_GATE and bool(pastes or inj or paste_pressed(X, ev))
    def gate(recs):
        if not armed:
            return recs
        cs_use = group_cs or cs
        gl = group_letters if group_letters is not None else \
            len(re.sub(r'[^a-zA-Z]', '', keys_in_window(
                X.con, ev['bundle'], ev.get('started_at'), ev.get('ended_at'))))
        o = []
        for t, a, b, s in recs:
            ct = X.cv(t)
            # 纯粘贴不留(粘贴政策 2026-06-10):已知 paste 段就把整条盖满了 —— endValue 分支原本
            # 没走这道判(只有 delete 分支走),ev3421「我有一个app目前」的 edit_log 里明明白白
            # 一条 paste 记录、内容跟 endValue 一模一样、击键流全空,照样进了成品。
            if pastes and sum(len(p) for p in pastes if p in ct) >= len(ct):
                continue
            # 字母下界闸(header 案 ev664 同款,只给 ≤120 字短记录):网页(ChatGPT/Gemini/ollama)
            # 打字时 AX 一个 commit 都不记,cover 恒 0,只能靠"组内敲的字母 ≥ 需要的字数"背书。
            # ⚠️按**组**数不按单事件:endValue 跨事件累积,「空洞骑士怎么」的击键在本组更早的事件里
            # (ev3557 实证,单事件窗口 11<14 误杀)。只证明"敲够了键",不证明产出,所以长文不豁免。
            if len(ct) <= 120:
                need = sum(1 for ch in ct if not ch.isascii()) + len(re.sub(r'[^a-zA-Z]', '', ct))
                if gl >= need:
                    o.append((t, a, b, s)); continue
            # 规则「粘贴少数派整条留」(用户裁定 2026-07-16,见 paste_minor):手打为主的消息
            # 里捎带的引用/链接是内容的一部分,整条原样留,不进逐行裁剪。
            if paste_minor(X, t, cs_use):
                o.append((t, a, b, s)); continue
            nt = commit_backed(X, t, cs_use)          # 粘贴占多数 → 逐行 30 闸 + 多数背书守卫
            if nt: o.append((nt, a, b, s))
        return o
    for i, e in enumerate(arr):
        k = e.get('kind'); t = X.cv(e.get('text', '') or ''); ts = e.get('ts')
        if ts is None: continue
        if k == 'submit' and len(t) >= 1:   # 单字 submit 也算真发送(6/？/额/哈 等都是有效输入,2026-06-29 用户裁定先全 pass 观察)
            # 存量框剥离(作文反馈案 ev692/694/699,2026-06-12 用户裁定:粘贴>30 消除,只留手打需求):
            # submit 全文=存量大文本(早先粘贴/前轮延续,无本事件击键背书)+手打增量(AX text)。
            # 全文对击键 cover<0.5(非本事件手打)而增量 cover≥0.4(简拼宽容)→ 只记增量。
            stale = t[:max(0, len(t) - len(txc))] if txc else ''
            unhand = len(stale) * (1 - X.cover(stale, group_cs or cs)) if stale else 0
            if (txc and len(t) > 2 * len(txc)
                    # 小存量不剥(VALIS_BEATOVEN_API_KEY案):存量中**非手打**字符(组流盖不住的)
                    # ≤PASTE_MAX → 粘贴政策'单段≤30整条留'优先;剥离只治大存量(作文案≈292)
                    and unhand > PASTE_MAX
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
                    # 剥离命中:同事件早先的回车竞速渣候选(zh/shi/go,IME改写删除+回车凑巧)
                    # 是同一发送动作的中间残骸——留着会被重建解成错字版(shi→事态你帮我改变)
                    # 与真身并存,清掉(只清短渣,不动多发送事件的其他真消息)
                    out[:] = [o for o in out
                              if not (o[3] and len(X.cv(o[0])) < max(4, len(txc) // 2))]
                    t = txc
                    stripped_hit[0] = True   # endv草稿同步废弃(见函数尾)
            out.append((t, prev_ts, ts, True)); prev_ts = ts
        elif k == 'delete':
            # 单字 delete 分档(2026-07-02 用户设计,事件内结构判别,定义B):
            #   所有单字符(汉字/英文/标点/数字)先收候选,￼ 图片占位符除外;
            #   函数末按「本事件有无 commit 打字/产出」定夺:有=编辑时产生的/成品补丁→弃字丢;无=孤儿留。
            if not t or t in ph or t in X.RUNPH or X.is_ph(t) or t in inj: continue
            if len(t) < 2:
                if t != '￼': lone_cands.append((t, prev_ts, ts))   # ￼=图片占位符,非文字残渣
                continue
            # 发送清空(ChatGPT等网页:打字时AX没建任何typing_event,只在发送清空记一个光杆delete,
            # text=完整消息+\n,end_value空)。delete原文以\n结尾(发送含回车)+附近击键有回车(sent)+
            # 框已清空 → 真发送,即便无占位符标记/无commit背书也认(2026-06-16 ChatGPT ev734案);
            # 草稿select-all-delete无\n、无回车,天然排除
            send_clear = ((e.get('text', '') or '').endswith('\n') and sent(ts)
                          and X.emptyZW(ev['endv']))
            if not (isMark(i - 1) or isMark(i + 1) or send_clear): continue
            pv = paste_verdict(t)
            if pv is False:                              # 大粘贴:剥离粘贴段,手打需求留
                if not sent(ts): continue
                rem = strip_pastes(t)
                if rem: out.append((rem, prev_ts, ts, True)); prev_ts = ts
                continue
            if pv is None and X.cover(t, group_cs or cs) < 0.5 and not send_clear: continue   # 手打铁律兜底(send_clear豁免:网页打字没进commit流)
            if not sent(ts): continue                    # 回车检测:无回车=IME改写删除/草稿,不是发送
            out.append((t, prev_ts, ts, True)); prev_ts = ts
    endv = X.cv(ev['endv'])
    # 剥离命中的事件:endv草稿='存量+已入册真身'合成残影(这个我怎么写比较好案,2026-06-12)
    # ——存量是本不该记的粘贴问题文本,增量已剥离入册,留着必成重复,废弃
    if stripped_hit[0]:
        return gate(out)
    if endv and not X.emptyZW(ev['endv']) and not X.is_ph(endv) and endv not in inj and endv not in ph:   # 占位符/注入/纯粘贴 endValue 整条不出(ph=事件内 paste 标记:占位符轮换或纯粘贴草稿,只记手打)
        out.append((endv, prev_ts, ev.get('ended_at') or prev_ts, False))
    # 单字 delete 事件内结构判别(2026-07-02 用户设计,定义B):本事件有产出(out 非空)或有 commit
    # 打字活动(cs 非空)= 编辑时产生的/成品补丁 → 单字是弃字,丢;两者皆无(纯删一个已存在字符)→
    # 孤儿 residue,留 is_send=False,下游标 ~residue 进未定区。
    if not out and not X.cv(cs):
        out.extend((lt, lp, lts, False) for lt, lp, lts in lone_cands)
    return gate(out)

EQLEN_WIN_MS = 300_000   # 等长条款时间窗 5min(2026-07-07 审计修):同 ctx_window 语境断点——
# 隔了一个语境断点的等长文本是两条真输入,不是同一次编辑的快照。
# 实证:vos/vcd 1.5min(该杀,窗内)/ stage1↔stage2 9.4min(误杀,ev389 'pro模型prompt v2-stage1'
# 被 stage2 当编辑快照杀掉——两条不同查询,加窗救回)。⚠️ 秒级等长近邻(IMG_9843/9844 文件名)时间窗救不了,内容维度另议。
def dedup_truncated(records, cover_fn):
    """类4/5a:丢掉「endValue 截断态(is_send=False)且内容大部分被某更长记录覆盖」的草稿快照。
    records=[(text, is_send, app, ts)]。cover_fn(a,b)=a 的内容被 b 覆盖的比例(LCS)。真发送(is_send=True)永不丢。"""
    keep = []
    for i, (ta, sa, aa, tsa) in enumerate(records):
        if not sa and len(ta) >= 2:                       # 截断态草稿才考虑丢
            cta = cv(ta)
            covered = False
            for j, (tb, sb, ab, tsb) in enumerate(records):
                if i == j or ab != aa: continue
                ctb = cv(tb)
                if len(ctb) > len(cta) and (ctb.startswith(cta) or cover_fn(cta, ctb) >= 0.8):
                    covered = True; break             # cta 是 ctb 的早期/截断态
                # 等长编辑修正快照(vos↔vcd 互换案):同长高覆盖,时序靠后者=用户最终输入,前者丢。
                # 限 EQLEN_WIN_MS 内(同一次编辑的快照必然时间相邻;窗外=两条真输入,都留)
                if (j > i and len(ctb) == len(cta) and ctb != cta and cover_fn(cta, ctb) >= 0.9
                        and abs((tsb or 0) - (tsa or 0)) <= EQLEN_WIN_MS):
                    covered = True; break
            if covered: continue
        keep.append((ta, sa, aa, tsa))
    return keep

def keys_in_window(con, bundle, t0, t1, pad_start=2000, pad_end=300):
    # 发送的击键到回车(发送 ts)为止 → 尾 pad 小,免漏进下条消息
    rows = con.execute(
        "SELECT ts_ms,char,is_backspace,modifiers,input_source FROM keystroke_log "
        "WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",
        (bundle, (t0 or 0) - pad_start, (t1 or 0) + pad_end)).fetchall()
    o = ""
    for ts, c, bs, md, src in rows:
        if (md & 7) != 0: continue
        if bs: o += "<BS>"; continue
        if not c: continue
        # 输入法开着时,跟在**拼音**后的空格 = 选第一个候选(等价按 1),不是空格字符 → 归一成 '1',
        # 下游 parse_picks/apply_bs 的选字数字机器直接就对(上屏语义见 apply_bs)。三道闸缺一不可:
        #  ①input_source 背书是输入法(自 2026-06-13 才有值:inputmethod.*=输入法 / keylayout.*=键盘布局;
        #    此前 None 一律不转 —— 英文每个词后都跟空格,盲转会吞英文)
        #  ②前面那串必须真是拼音(commit_syls 认;不然「claude 」会被当成选字,连词间空格一起吃掉)
        #  ③全小写(拼音缓冲是小写;大写多是英文/专名字面,如「Z 」)
        if c == ' ' and src and 'inputmethod' in src and o[-1:].isalpha():
            run = re.search(r'[A-Za-z]+$', o).group()         # 结尾连续字母串 = 待上屏缓冲
            if run.islower() and commit_syls(run) is not None:
                o += "1"; continue
        o += "<CR>" if c in ("\n", "\r") else c
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
