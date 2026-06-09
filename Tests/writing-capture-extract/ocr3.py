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

# 拼音前缀松弛:用户没打完(yo→yong),续文汉字的完整音节须以剩余字母开头。
EXTS = ['', 'g', 'n', 'ng', 'i', 'u', 'o', 'e', 'a', 'ai', 'ei', 'ao', 'ou', 'an', 'en',
        'ang', 'eng', 'ong', 'ia', 'ie', 'iao', 'iu', 'ian', 'in', 'iang', 'ing', 'iong',
        'ua', 'uo', 'uai', 'ui', 'uan', 'un', 'uang', 'ue']

def syl_cands(p):
    """p 若能整体解析成一个音节,返回其候选字集;否则 None。"""
    if not p or not p.isalpha(): return None
    top, syls = R.lattice(p)
    if len(syls) == 1:
        return set(ch for c in syls[0][1] for ch in c if HAN.match(ch))
    return None

def verify_tail(cont, leftover):
    """续文 cont 逐字过击键账 leftover(字母串)。返回验证通过的尾巴前缀。"""
    L = leftover.replace(' ', '').lower()
    out = []
    for ch in cont:
        if ch in '，。！？、…,.!? ':                     # 标点放行不消费(IME 标点不在字母账里)
            out.append(ch); continue
        if ch.isascii():
            if L and L[0].lower() == ch.lower():
                out.append(ch); L = L[1:]; continue
            break
        if not HAN.match(ch): break
        matched = False
        for plen in range(min(6, len(L)), 0, -1):        # 贪心:先试最长击键前缀
            p = L[:plen]
            for ext in EXTS:                              # 完整音节 或 前缀松弛(yo→yong)
                cs = syl_cands(p + ext)
                if cs and ch in cs:
                    out.append(ch); L = L[plen:]; matched = True; break
            if matched: break
        if not matched: break
    # 去掉尾部悬空标点
    while out and out[-1] in '，。！？、…,.!? ': out.pop()
    return ''.join(out), L

APP_PAT = {'Discord': '%iscord%', 'claudefordesktop': '%laude%', 'xinWeChat': '%eChat%',
           'Safari': '%afari%', 'Notes': '%otes%'}

def ocr_frames(app_short, t0, t1):
    pat = APP_PAT.get(app_short, '%' + app_short[:6] + '%')
    return con.execute("SELECT timestamp_ms, full_text FROM frames WHERE app_name LIKE ? "
                       "AND timestamp_ms BETWEEN ? AND ? ORDER BY timestamp_ms",
                       (pat, t0, t1)).fetchall()

def complete_tail(app_short, text, send_ts, leftover_keys, post_s=120):
    """口3 主函数:对一条疑似缺尾的记录,OCR 锚定 + 击键验证补尾。
    返回 (fixed_text, info)。补不了 → 原样返回(宁缺毋错)。"""
    # 干净前缀 = 去掉尾部 latin 残渣;锚 = 前缀末 3-6 字
    m = R.LATIN_TAIL.search(text)
    base = text[:m.start()].rstrip() if m else text
    residue = (m.group().strip() if m else '')
    if len(cv(base)) < 3:
        return text, {'why': 'base太短无法锚定'}
    leftover = (residue.replace(' ', '') + leftover_keys).lower()
    best = ('', None)
    for ts, ft in ocr_frames(app_short, send_ts - 2000, send_ts + post_s * 1000):
        ft = ft or ''
        for k in (6, 5, 4, 3):                            # 锚从长到短
            anchor = cv(base)[-k:]
            if len(anchor) < 3: continue
            idx = ft.find(anchor)
            if idx < 0: continue
            cont = ft[idx + len(anchor): idx + len(anchor) + 30]
            tail, rem = verify_tail(cont, leftover)
            if len(cv(tail)) > len(cv(best[0])):
                best = (tail, {'frame_ts': ts, 'anchor': anchor, 'cont': cont[:20], 'left_after': rem})
            break                                         # 本帧已用最长可用锚
    if best[0]:
        return base + best[0], {'fixed': True, **best[1]}
    return text, {'why': '无帧锚定命中或击键验证失败'}


# ---- 标注案例测试 ----
def keys_after(bundle, t0, t1):
    rows = con.execute("SELECT char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? "
                       "AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms", (bundle, t0, t1)).fetchall()
    o = ''
    for c, bs, md in rows:
        if bs or (md & 7) != 0 or not c or c in ('\n', '\r'): continue
        o += c
    return o

CASES = [
    # (案例名, ev, 记录文本substring, 期望尾巴)
    ("H 特定的人", 1131, "就是你有什么问题就问", "特定的人"),
    ("I Google的生态", 1132, "大多数人都很喜欢", "Google的生态"),
    ("yi x→一次测试", 646, "我用你seedance余额跑yi x", "一次测试"),
    ("te d→特点", 1132, "每个ai有自己的te d", "特点"),
    ("yo→用", None, "看你怎么yo", "用"),
    ("k n→看论文", None, "我就拿那个k n", "看论文"),
    ("卖个惨", 1123, "mai ge can", "卖个惨"),
]

if __name__ == "__main__":
    import extract_compare_v2 as X
    def find_send(substr, evid=None, day=None):
        q = "SELECT id,bundle_id FROM typing_events WHERE edit_log LIKE ?" + (" AND id=?" if evid else "")
        args = (f'%{substr[:10]}%',) + ((evid,) if evid else ())
        for eid, bundle in con.execute(q, args).fetchall():
            evs = X.loadev([eid])
            for ev in evs:
                for text, t0, t1, is_send in R.event_sends_with_ts(ev, X):
                    if substr[:8] in text:
                        return ev['bundle'].split('.')[-1], ev['bundle'], text, t1
        return None
    for name, evid, substr, want in CASES:
        hit = find_send(substr, evid)
        if not hit:
            print(f"✗ {name}: 找不到对应发送记录"); continue
        app, bundle, text, ts = hit
        lk = keys_after(bundle, ts - 1500, ts + 8000)      # race 区击键(尾巴可能在发送后落账)
        fixed, info = complete_tail(app, text, ts, lk)
        ok = want in fixed
        print(f"{'✓' if ok else '✗'} {name}: {text[:24]!r} → {fixed[:40]!r}  {info if not ok else ''}")
