#!/usr/bin/env python3
"""口3 · 三路验证原型(AX骨架 + 击键物理 + OCR渲染),确定性,零模型。
治:发送瞬间 race 丢尾(H/I)、没打完的拼音(yo/te d/k n/yi x)、librime 词库外(卖个惨)。

流程:
1. 锚定:记录的干净前缀(去掉尾部 latin 残渣)取末 3-6 字,在发送后 OCR 帧里找锚点
2. 提取:锚点后的续文 = 候选尾巴(屏幕渲染 = IME 最终选字的事实)
3. 验证:续文逐字过击键账 —— 汉字:剩余击键字母须是该字拼音的前缀(librime 候选集证明);
   ASCII:逐字面匹配。别人的消息/屏幕噪声过不了击键验证 → 幻觉无门。
跑测试:python3 ocr3.py(对标注的 7 个硬案例)"""
import sqlite3, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rebuild as R

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
cv = R.cv
HAN = R.HAN

# 方案知识(单元表/输出字符集)全部来自部署词库 —— 零硬编码,换五笔/双拼/日韩 = 换 rime 目录。
import functools
import ime_schema as S

_UNIT_CHARS = [None]   # 编码单元 → 词库全集候选字(char_units 反查,一次构建)
@functools.lru_cache(maxsize=2048)
def syl_cands(p):
    """p 若是部署方案的编码单元,返回**词库全集**候选字;否则 None。
    2026-06-11 yi x案:原用 lattice 候选窗(仅前6字),'试'在 shi 窗外 → 一下测试 验证断链只回一下测。
    击键背书本义=这串键在部署方案下能产出的任何字,窗口截断是实现意外非设计护栏。"""
    if not p or not p.isalpha(): return None
    if _UNIT_CHARS[0] is None:
        rev = {}
        for ch, units in S.char_units().items():
            for u in units: rev.setdefault(u, set()).add(ch)
        _UNIT_CHARS[0] = {u: frozenset(cs) for u, cs in rev.items()}
    return _UNIT_CHARS[0].get(p)

def _verify_at(cont, L):
    """从击键账 L 的当前位置逐字验证续文 cont。返回 (验证通过的尾巴, 剩余账)。"""
    out = []
    for ch in cont:
        if ch in '，。！？、…,.!? ':                     # 标点放行不消费(IME 标点不在字母账里)
            out.append(ch); continue
        if ch.isascii():
            if L and L[0] == ch.lower():
                out.append(ch); L = L[1:]; continue
            break
        if not S.is_output_char(ch): break               # 非本输入方案能产出的字符 = 屏幕噪声
        matched = False
        for plen in range(min(6, len(L)), 0, -1):        # 贪心:先试最长击键前缀
            p = L[:plen]
            for syl in S.units_with_prefix(p):            # 只探真实编码单元(词库提取)
                cs = syl_cands(syl)
                if cs and ch in cs:
                    out.append(ch); L = L[plen:]; matched = True; break
            if matched: break
        if not matched: break
    while out and out[-1] in '，。！？、…,.!? ': out.pop()
    return ''.join(out), L

def verify_tail(cont, leftover, suffix_only=False):
    """续文 cont 过击键账。账先剥选字数字/空格;账开头可能是 base 部分的击键(对不上尾巴),
    用「跳过前缀」搜索。返回 (tail, consumed=消费的账上字母数)。
    suffix_only(Writ案治本,2026-06-12):竞速尾的键必落在**账尾**(回车前最后一段没进AX的键)
    ——消费须到达账尾(rem≤2 容错),否则是消息中段键冒领(writign 验 Writ)/占位符无键,拒。
    中英文界面占位符一起治本:它们在账尾没有对应击键。"""
    L0 = re.sub(r'[^a-z]', '', (leftover or '').lower())
    best = ('', 0)
    for off in range(len(L0)):
        tail, rem = _verify_at(cont, L0[off:])
        consumed = len(L0) - off - len(rem)
        if suffix_only and len(rem) > 2:
            continue                                     # 消费没到账尾 = 中段冒领,此 off 作废
        if len(tail) > len(best[0]) or (len(tail) == len(best[0]) and consumed > best[1]):
            best = (tail, consumed)
        if len(tail) >= len(cont) - 2: break             # 几乎全验上了,够了
    return best

APP_PAT = {'Discord': '%iscord%', 'claudefordesktop': '%laude%', 'xinWeChat': '%eChat%',
           'Safari': '%afari%', 'Notes': '%otes%'}

def pick_frames(app_short, url, send_ts, fwd_s=60):
    """帧降级链(2026-06-16 用户设计):按**优先级**返回候选帧,消费方(proofread/verify)逐帧试,
    第一个过「锚定+击键验证」的即用;全不过 = 原样返回(用户接受)。级别(高→低,按帧不按秒):
      ①+② return 后同 app(+url)帧(时间序,第一帧最先)③ 切回帧(切走后第一次回本 app 的帧)
      ④ return 前一帧 ⑤ 异 app 转场漂移帧(切走后第一帧,**至多 1**,可能还带旧 app 画面)
      ⑥ 切回点异 app 转场帧(回本 app 前最后一个异 app 帧,**至多 1**)。
    异 app 级各只取 1 帧:切走只转场那第一帧可能留旧画面,取多了是抓串(用户裁定:不会两帧都异 app)。
    每帧仍过锚+击键验证才采纳,异 app 级只在 ①-④ 全失败时兜底。**同 app = 同 host url**(SPA 路径容错)。"""
    pat = APP_PAT.get(app_short, '%' + app_short[:6] + '%')
    cond, args = "app_name LIKE :p", {"p": pat}
    if url:
        # 同站匹配(2026-06-15 #13 chatgpt.com 案):typing_events.url 带 SPA 路径,frames.browser_url
        # 常只到域名 → 精确相等把 OCR 帧滤光。改 scheme+host 前缀 LIKE,容路径差异;同站约束仍防串站。
        m = re.match(r'(https?://[^/]+)', url)
        if m:
            cond += " AND browser_url LIKE :u"; args["u"] = m.group(1) + '%'
        else:
            cond += " AND browser_url = :u"; args["u"] = url
    cands, seen = [], set()
    def add(row):
        if row and row[0] not in seen:
            cands.append(row); seen.add(row[0])
    # ①+② return 后同 app(+url)帧,时间序(第一帧最优先)
    for row in con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                           f"AND timestamp_ms >= :a AND timestamp_ms <= :b ORDER BY timestamp_ms",
                           {**args, "a": send_ts, "b": send_ts + fwd_s * 1000}).fetchall():
        add(row)
    # 切走后第一个异 app 帧(转场)—— 切回帧(③)和异 app 兜底(⑤)都基于它
    sw = con.execute("SELECT timestamp_ms, full_text FROM frames WHERE NOT (app_name LIKE :p) "
                     "AND timestamp_ms > :a AND timestamp_ms <= :a5 ORDER BY timestamp_ms LIMIT 1",
                     {"p": pat, "a": send_ts, "a5": send_ts + fwd_s * 1000}).fetchone()
    # ③ 切回帧:切走后第一次回本 app(+url)的帧
    back = None
    if sw:
        back = con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                           f"AND timestamp_ms > :sw ORDER BY timestamp_ms LIMIT 1",
                           {**args, "sw": sw[0]}).fetchone()
        add(back)
    # ④ return 前一帧(同 app)
    add(con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                    f"AND timestamp_ms < :a ORDER BY timestamp_ms DESC LIMIT 1",
                    {**args, "a": send_ts}).fetchone())
    # ⑤ 异 app 转场漂移帧:切走后第一帧(至多 1,可能还带旧 app 画面)
    add(sw)
    # ⑥ 切回点异 app 转场帧:回本 app(back)前最后一个异 app 帧(至多 1)
    if back:
        add(con.execute("SELECT timestamp_ms, full_text FROM frames WHERE NOT (app_name LIKE :p) "
                        "AND timestamp_ms < :bk AND timestamp_ms >= :a ORDER BY timestamp_ms DESC LIMIT 1",
                        {"p": pat, "bk": back[0], "a": send_ts}).fetchone())
    return cands

def complete_tail(app_short, text, send_ts, leftover_keys, url=None, other_texts=(), prev_text=None):
    """口3 主函数:OCR 锚定 + 击键验证补尾。返回 (fixed_text, info)。三护栏(宁缺毋错):
    ① 残渣替换必须消费 ≥ 残渣字母数的击键(XPC→X 拒;yi x→一下测 放行)
    ② 尾巴若是同 bundle 另一条记录的前缀 → 粘连,拒(赛博永生+数字人)
    ③ 锚定/验证不过 → 原样返回。"""
    m = R.LATIN_TAIL.search(text)
    base = text[:m.start()].rstrip() if m else text
    residue_letters = len(re.sub(r'[^a-zA-Z]', '', m.group())) if m else 0
    if len(cv(base)) < 3:
        # 短base前条锚(我的意思案,2026-06-12 用户截图实证):base<3字自锚不动 → 锚前一条消息尾,
        # 验证续文须以 base 开头且更长 → 整条替换(替换模式;护栏:击键消费≥4/不粘下一条)。
        bn = cv(base).replace(' ', '')
        if prev_text and bn:
            pb = cv(prev_text).replace('\n', ' ')
            others0 = [cv(o).replace(' ', '') for o in other_texts if o]
            for ts, ft in pick_frames(app_short, url, send_ts):
                if ts < send_ts: continue                  # 前条锚只看发送后帧(同 ocr_snippet)
                ft = ft or ''
                for k in (8, 6, 4, 2):
                    anchor = pb[-k:].strip() if len(pb) >= k else pb
                    if len(anchor) < 2: continue
                    idx = ft.find(anchor)
                    if idx < 0: continue
                    cont = ft[idx + len(anchor): idx + len(anchor) + 30]
                    vt, consumed = verify_tail(cont, leftover_keys)
                    vtn = cv(vt).replace(' ', '')
                    if (vtn.startswith(bn) and len(vtn) > len(bn) and consumed >= 4
                            and not any(o.startswith(vtn) for o in others0)):
                        return cv(vt), {'fixed': True, 'via': '前条锚', 'frame_ts': ts,
                                        'anchor': anchor, 'consumed': consumed}
                    break
        return text, {'why': 'base太短无法锚定'}
    frames = pick_frames(app_short, url, send_ts)
    if not frames:
        return text, {'why': '无同app/url帧,跳过OCR'}
    others = [cv(o).replace(' ', '') for o in other_texts if o]
    for ts, ft in frames:                                 # 时间序:最早锚定命中即用
        # 干净文本补尾(residue=0,竞速尾/单字母族)只认 return 后帧(用户裁定 2026-06-12:
        # 没有就算了)——竞速尾在发送前不可能渲染,发送前兜底帧对这族是隐患。
        if residue_letters == 0 and ts < send_ts:
            continue
        ft = ft or ''
        for k in (6, 5, 4, 3):
            anchor = cv(base)[-k:]
            if len(anchor) < 3: continue
            idx = ft.find(anchor)
            if idx < 0: continue
            cont = ft[idx + len(anchor): idx + len(anchor) + 30]
            # 干净文本(residue=0)= 竞速尾域:键必在账尾,suffix_only 防中段冒领/占位符(中英文通治)
            tail, consumed = verify_tail(cont, leftover_keys, suffix_only=(residue_letters == 0))
            tn = cv(tail).replace(' ', '')
            if not tn:
                break                                     # 本帧锚上了但验证空,换下一帧
            if residue_letters and consumed < residue_letters:
                return text, {'why': f'消费{consumed}<残渣{residue_letters}字母,拒(防截短)'}
            # 干净文本补尾下限(关SIP'米'案,2026-06-12):residue=0 时原消费护栏恒过,
            # OCR 帧邻行单字杂讯可乘虚贴上 → 尾≥2字且消费≥4(同前条锚口径)。
            if residue_letters == 0 and (len(tn) < 2 or consumed < 4):
                return text, {'why': f'干净文本尾过短/消费不足(tn={tn[:6]},consumed={consumed}),拒(防杂讯字)'}
            # Writ案(2026-06-12 用户指认:writ无输入支持只有OCR):干净文本补的尾为纯ASCII
            # ——OCR续文实测是聊天框占位符'Write a message…'前缀,击键消费被消息中段英文
            # run(writign)偏移冒领。中文IME竞速尾必含汉字,纯ASCII尾一律拒。
            if residue_letters == 0 and not any(not ch.isascii() for ch in tn):
                return text, {'why': f'干净文本纯ASCII尾(tn={tn[:8]}),拒(Writ案:占位符/界面词风险)'}
            if any(o.startswith(tn) for o in others):
                return text, {'why': f'尾巴={tn[:10]}是另一条记录前缀,拒(防粘连)'}
            return base + tail, {'fixed': True, 'frame_ts': ts, 'anchor': anchor,
                                 'cont': cont[:20], 'consumed': consumed}
    return text, {'why': '所有帧锚定/击键验证未过'}


def _whole_residue_ocr(app_short, text, send_ts, leftover, url, others_n, base=''):
    """全残渣(整条机器解码,无对前缀可自锚)的 OCR 救援(补 :212 待建,从哪找的案 2026-06-17):
    机器猜首字(首音节通常可靠)锚 OCR 帧,取等长窗,要求 与机器猜同长 + 位置级重合≥半
    (确保是同一条消息、只是解错)+ 击键验证(OCR 窗能被击键解释,防抓到别条消息)→ 以屏幕为准。
    librime#1 与用户输入法#1 分歧(从那找到 vs 从哪找的,到/那 都同击键)时,OCR 是唯一裁判。
    base = text 的 commit/字面前缀(非机器猜),OCR 不得覆盖它(今天没来案 2026-06-29:base<3 走
    到这里时仍保护 commit 的「今天」;天/大 因「大」有 tai 读音击键分不开,只能靠来源:commit 不动)。"""
    m = cv(text).replace(' ', '')
    n = len(m)
    L = re.sub(r'[^a-z]', '', (leftover or '').lower())
    bn = cv(base).replace(' ', '')
    if n < 2 or n > 10 or len(L) < 2:                       # 只治短消息且有击键背书
        return text, {'why': '全残渣:长度/击键不满足'}
    for ts, ft in pick_frames(app_short, url, send_ts):
        ft = ft or ''
        for mt in re.finditer(re.escape(m[0]), ft):         # 机器猜首字锚(首音节通常可靠)
            cand = cv(ft[mt.start(): mt.start() + n + 3]).replace(' ', '')[:n]
            if len(cand) != n or cand == m:
                continue
            if bn and not cand.startswith(bn):              # OCR 覆盖了 commit 前缀(今大≠今天)→ 拒
                continue
            if sum(1 for i in range(n) if cand[i] == m[i]) < (n + 1) // 2:
                continue                                    # 位置级重合<半 = 不是同一条消息
            _, consumed = verify_tail(cand, leftover)        # OCR 窗须被击键解释(防抓别条消息)
            if consumed >= len(L) - 1 and not any(o.startswith(cand) for o in others_n):
                return cand, {'fixed': True, 'via': '全残渣OCR整句', 'frame_ts': ts, 'ocr_tail': cand}
    return text, {'why': '全残渣:OCR无等长近似匹配'}

def proofread_tail(app_short, text, model_tail, send_ts, leftover_keys, url=None, other_texts=()):
    """校对模式:Phase1 **模型参与重建**的尾巴,用 OCR 渲染事实核对(的/得、哟/用、同音错一族)。
    base = text 去掉模型尾;锚定 base;OCR 续文过击键验证后若与模型尾不同 → 以屏幕为准。
    护栏同补尾:不变短 / 不粘下一条 / 验证不过不动。"""
    mt = cv(model_tail).replace(' ', '')
    if not mt or not cv(text).endswith(mt):
        return text, {'why': '无模型尾/对不上'}
    base = text[:len(text) - len(model_tail)]
    if len(cv(base)) < 3:
        # 全残渣(整条机器解码,无对前缀可自锚)→ 整句 OCR 匹配(2026-06-17 从哪找的案,补 :212 待建)
        others_n = [cv(o).replace(' ', '') for o in other_texts if o]
        return _whole_residue_ocr(app_short, text, send_ts, leftover_keys, url, others_n, base=base)
    frames = pick_frames(app_short, url, send_ts)
    if not frames:
        return text, {'why': '无同app/url帧'}
    others = [cv(o).replace(' ', '') for o in other_texts if o]
    han_mt = sum(1 for ch in mt if not ch.isascii())
    for ts, ft in frames:
        ft = ft or ''
        for k in (6, 5, 4, 3):
            anchor = cv(base)[-k:]
            if len(anchor) < 3: continue
            idx = ft.find(anchor)
            if idx < 0: continue
            cont = ft[idx + len(anchor): idx + len(anchor) + len(model_tail) + 12]
            tail, consumed = verify_tail(cont, leftover_keys)
            tn = cv(tail).replace(' ', '')
            if tn == mt:
                return text, {'why': 'OCR与模型一致,校对通过'}
            # 替换护栏(不过 → 换下一帧再看,不轻举妄动):
            # 长度不短于模型尾 / 消费 ≥2×汉字数(哟 来自2字母,杂讯 g 消费1 拒)/
            # 同类(汉字尾不能换成纯ASCII)/ 不粘下一条
            ok = (tn and len(tn) >= len(mt)
                  and consumed >= max(2, 2 * han_mt)
                  and (han_mt == 0 or any(not ch.isascii() for ch in tn))
                  and not any(o.startswith(tn) for o in others))
            if ok:
                return base + tail, {'fixed': True, 'via': '校对', 'frame_ts': ts,
                                     'model_tail': model_tail, 'ocr_tail': tail, 'consumed': consumed}
            break                                         # 本帧不行,换下一帧
    return text, {'why': '所有帧校对未过(或与模型一致性未确认),保守不动'}


def ocr_snippet(app_short, url, text, send_ts, prev_text=None, seg='', fwd_s=60, width=70):
    """审核取证(Phase1.75 referee 用):返回 (OCR片段, 帧ts, 锚定模式 self/prev/before)。
    锚定优先级:① 记录自身前缀(原文+空白归一双试)② 前一条消息锚(自身是错字时自锚必失败,
    真身渲染在前一条之后——卖个惨 的关键;须过击键预检防截到 chrome/他人消息,且跳过发送前帧)。
    无锚 → ('', None, '')。"""
    base = cv(text).replace('\n', ' ')
    width = max(width, min(len(base) + 20, 200))           # 宽度随记录伸缩(审查修)
    frames = pick_frames(app_short, url, send_ts, fwd_s=fwd_s)
    for ts, ft in frames:
        ft = ft or ''
        ftn = re.sub(r'\s', '', ft)
        for k in (8, 6, 4, 3):
            anchor = base[:k].strip()
            if len(anchor) < 3: continue
            mode = 'self' if ts >= send_ts else 'before'
            idx = ft.find(anchor)
            if idx >= 0:
                return ft[max(0, idx - 12): idx + width], ts, mode
            an = anchor.replace(' ', '')                   # 空白归一再试(OCR 常乱插空格,审查修)
            idx = ftn.find(an)
            if idx >= 0:
                return ftn[max(0, idx - 12): idx + width], ts, mode
    if prev_text:
        pb = cv(prev_text).replace('\n', ' ')
        for ts, ft in frames:
            if ts < send_ts: continue                      # prev 锚只看发送后帧(审查修)
            ft = ft or ''
            for k in (8, 6, 4, 2):
                anchor = pb[-k:].strip() if len(pb) >= k else pb
                if len(anchor) < 2: continue   # prev锚放宽到2字(短消息如'明天';击键预检兜底,小修C)
                idx = ft.find(anchor)
                if idx < 0: continue
                cont = ft[idx + len(anchor): idx + len(anchor) + width + 20]
                # 确定性预检(审查修):真身必有若干字过击键验证;chrome/他人消息验不上
                vt, _c = verify_tail(cont, seg)
                if len(cv(vt).replace(' ', '')) >= 2:
                    return cont, ts, 'prev'
    return '', None, ''



# ---- 标注案例测试 ----
def keys_segment(bundle, send_ts):
    """该消息的击键 <CR> 段(消息边界天然在 <CR>):取最后一键最接近 send_ts(±6s)的段。
    复用账本分段洞察 —— 段即消息,验证不会窜进下一条。"""
    rows = con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? "
                       "AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms", (bundle, send_ts - 60000, send_ts + 10000)).fetchall()
    segs, cur = [], []
    for ts, c, bs, md in rows:
        if (md & 7) != 0: continue
        if bs:
            if cur: cur.pop()
            continue
        if not c: continue
        if c in ('\n', '\r'):
            if cur: segs.append(cur); cur = []
        else:
            cur.append((ts, c))
    if cur: segs.append(cur)
    best, bd = '', 6001
    for seg in segs:
        d = abs(seg[-1][0] - send_ts)
        if d < bd: bd, best = d, ''.join(c for _, c in seg)
    if not best:                                           # 空段回退:打完停顿>6s才回车的消息(审查修)
        bd = 60001
        for seg in segs:
            d = abs(seg[-1][0] - send_ts)
            if d < bd: bd, best = d, ''.join(c for _, c in seg)
    return best

CASES = [
    # (案例名, ev, 记录文本substring, 期望尾巴)
    ("H 特定的人", 1131, "就是你有什么问题就问", "特定的人"),
    ("I Google的生态", 1132, "大多数人都很喜欢", "Google的生态"),
    ("yi x→一下测试(用户已确认)", 646, "我用你seedance余额跑yi x", "一下测"),
    ("te d→特点", 1132, "每个ai有自己的te d", "特点"),
    ("yo→用", None, "看你怎么yo", "用"),
    ("k n→看论文", None, "我就拿那个k n", "看论文"),
    ("卖个惨", 1123, "mai ge can", "卖个惨"),
]

if __name__ == "__main__":
    import extract_compare_v2 as X
    def find_send(substr, evid=None):
        """在事件的真实发送里找含 substr 的记录;返回 (app,bundle,text,t0,t1,next_t0)。
        next_t0 = 同 bundle 下一条发送的起点 —— 击键账以它截断,防验证窜进下一条消息。"""
        if evid: rows = [(evid,)]
        else: rows = con.execute("SELECT id FROM typing_events ORDER BY id").fetchall()
        for (eid,) in rows:
            evs = X.loadev([eid])
            for ev in evs:
                sends = R.event_sends_with_ts(ev, X)
                for i, (text, t0, t1, is_send) in enumerate(sends):
                    if substr[:8] in text or substr.replace(' ', '')[:8] in text.replace(' ', ''):
                        nxt = sends[i + 1][1] if i + 1 < len(sends) else None
                        return ev['bundle'].split('.')[-1], ev['bundle'], text, t0, t1, nxt
        return None
    for name, evid, substr, want in CASES:
        hit = find_send(substr, evid)
        if not hit:
            print(f"✗ {name}: 找不到对应发送记录"); continue
        app, bundle, text, t0, t1, nxt = hit
        lk = keys_segment(bundle, t1)                     # 击键账 = 本消息的 <CR> 段
        fixed, info = complete_tail(app, text, t1, lk)
        ok = want in fixed
        print(f"{'✓' if ok else '✗'} {name}: {text[:24]!r} → {fixed[:40]!r}  {info if not ok else ''}")
