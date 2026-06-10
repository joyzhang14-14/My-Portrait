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

@functools.lru_cache(maxsize=2048)
def syl_cands(p):
    """p 若能整体解析成一个编码单元,返回其候选字集;否则 None(由部署的 rime 方案决定)。"""
    if not p or not p.isalpha(): return None
    top, syls = R.lattice(p)
    if len(syls) == 1:
        return frozenset(ch for c in syls[0][1] for ch in c if S.is_output_char(ch))
    return None

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

def verify_tail(cont, leftover):
    """续文 cont 过击键账。账先剥选字数字/空格;账开头可能是 base 部分的击键(对不上尾巴),
    用「跳过前缀」搜索。返回 (tail, consumed=消费的账上字母数)。"""
    L0 = re.sub(r'[^a-z]', '', (leftover or '').lower())
    best = ('', 0)
    for off in range(len(L0)):
        tail, rem = _verify_at(cont, L0[off:])
        consumed = len(L0) - off - len(rem)
        if len(tail) > len(best[0]) or (len(tail) == len(best[0]) and consumed > best[1]):
            best = (tail, consumed)
        if len(tail) >= len(cont) - 2: break             # 几乎全验上了,够了
    return best

APP_PAT = {'Discord': '%iscord%', 'claudefordesktop': '%laude%', 'xinWeChat': '%eChat%',
           'Safari': '%afari%', 'Notes': '%otes%'}

def pick_frames(app_short, url, send_ts, fwd_s=60):
    """帧规则(用户指令的工程化解释):同 app(+url);**return 后最早的可用帧优先**
    (前向扫 ≤60s,因为紧邻的下一帧常还没渲染到该消息);都锚不上 → 回退发送前最近一帧;
    再没有 → 空(跳过 OCR,不传)。早帧优先防"下一条消息粘连"。"""
    pat = APP_PAT.get(app_short, '%' + app_short[:6] + '%')
    cond, args = "app_name LIKE :p", {"p": pat}
    if url:
        cond += " AND browser_url = :u"; args["u"] = url
    after = con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                        f"AND timestamp_ms >= :a AND timestamp_ms <= :b ORDER BY timestamp_ms",
                        {**args, "a": send_ts, "b": send_ts + fwd_s * 1000}).fetchall()
    cands = list(after)
    # 用户灵感:发完常秒切走 → 前向窗内可能没拍到/没渲染。前向窗内出现**异 app** 帧(=切走了)
    # → 把「切走后第一次回到本 app(+url) 的帧」也纳入(采集切 app 时会拍,切回瞬间消息仍在对话区)。
    # 检测窗=前向窗 60s(不用 5s:typing_pause=500ms 意味着只有秒切才漏帧,但异 app 首帧
    # 出现时机不可控——app_switch 归属漂移 + 新 app 可能 idle 30s 才出帧;多一帧候选代价≈0,验证兜底)。
    sw = con.execute("SELECT timestamp_ms FROM frames WHERE NOT (app_name LIKE :p) "
                     "AND timestamp_ms > :a AND timestamp_ms <= :a5 ORDER BY timestamp_ms LIMIT 1",
                     {"p": pat, "a": send_ts, "a5": send_ts + fwd_s * 1000}).fetchone()
    if sw:
        back = con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                           f"AND timestamp_ms > :sw ORDER BY timestamp_ms LIMIT 1",
                           {**args, "sw": sw[0]}).fetchone()
        if back and all(back[0] != t for t, _ in cands):
            cands.append(back)
    before = con.execute(f"SELECT timestamp_ms, full_text FROM frames WHERE {cond} "
                         f"AND timestamp_ms < :a ORDER BY timestamp_ms DESC LIMIT 1",
                         {**args, "a": send_ts}).fetchall()
    return cands + list(before)

def complete_tail(app_short, text, send_ts, leftover_keys, url=None, other_texts=()):
    """口3 主函数:OCR 锚定 + 击键验证补尾。返回 (fixed_text, info)。三护栏(宁缺毋错):
    ① 残渣替换必须消费 ≥ 残渣字母数的击键(XPC→X 拒;yi x→一下测 放行)
    ② 尾巴若是同 bundle 另一条记录的前缀 → 粘连,拒(赛博永生+数字人)
    ③ 锚定/验证不过 → 原样返回。"""
    m = R.LATIN_TAIL.search(text)
    base = text[:m.start()].rstrip() if m else text
    residue_letters = len(re.sub(r'[^a-zA-Z]', '', m.group())) if m else 0
    if len(cv(base)) < 3:
        return text, {'why': 'base太短无法锚定'}
    frames = pick_frames(app_short, url, send_ts)
    if not frames:
        return text, {'why': '无同app/url帧,跳过OCR'}
    others = [cv(o).replace(' ', '') for o in other_texts if o]
    for ts, ft in frames:                                 # 时间序:最早锚定命中即用
        ft = ft or ''
        for k in (6, 5, 4, 3):
            anchor = cv(base)[-k:]
            if len(anchor) < 3: continue
            idx = ft.find(anchor)
            if idx < 0: continue
            cont = ft[idx + len(anchor): idx + len(anchor) + 30]
            tail, consumed = verify_tail(cont, leftover_keys)
            tn = cv(tail).replace(' ', '')
            if not tn:
                break                                     # 本帧锚上了但验证空,换下一帧
            if residue_letters and consumed < residue_letters:
                return text, {'why': f'消费{consumed}<残渣{residue_letters}字母,拒(防截短)'}
            if any(o.startswith(tn) for o in others):
                return text, {'why': f'尾巴={tn[:10]}是另一条记录前缀,拒(防粘连)'}
            return base + tail, {'fixed': True, 'frame_ts': ts, 'anchor': anchor,
                                 'cont': cont[:20], 'consumed': consumed}
    return text, {'why': '所有帧锚定/击键验证未过'}


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
