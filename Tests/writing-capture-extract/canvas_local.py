#!/usr/bin/env python3
"""canvas 本地化 v1:OCR 帧序列确定性重建(零模型)。
管线:doc URL 过滤帧 → 几何法圈正文列(bbox 行重建+主列对齐) → 跨帧出现率滤 chrome
(已保存/保存中/菜单:几乎每帧都在;正文行随滚动来去) → 行级相似度合并+多帧投票纠 OCR 错字
→ 产出 final_text + diff 时间线(commit/delete,保留现有 canvas_fusion 的 diff feature)。
用法:python3 canvas_local.py <doc_url_like> <t0 'YYYY-mm-dd HH:MM'> <t1>
"""
import sqlite3, os, json, re, sys, datetime
from difflib import SequenceMatcher

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))

def norm(s):
    s = (s or '').replace('（', '(').replace('）', ')').replace('，', ',').replace('！', '!')
    return re.sub(r'\s+', ' ', s).strip()

def frame_lines(words):
    """词级 bbox → 行(y 聚类 + x 排序)。返回 [(y, x_left, text, n_words)]。"""
    ws = [w for w in words if (w.get('text') or '').strip() and w.get('confidence', 0) >= 0.3]
    ws.sort(key=lambda w: (w['top'], w['left']))
    lines, cur = [], []
    for w in ws:
        if cur and abs(w['top'] - cur[-1]['top']) > max(0.008, cur[-1].get('height', 0.01) * 0.6):
            lines.append(cur); cur = []
        cur.append(w)
    if cur: lines.append(cur)
    # 双簇拆分:OCR 把相邻两行词交错并行(行距小+top抖动)→ 行内 top 极差 > 0.6行高 时按中位拆
    split = []
    for ln in lines:
        tops = [w['top'] for w in ln]
        h = max((w.get('height', 0.01) for w in ln), default=0.01)
        if len(ln) >= 6 and max(tops) - min(tops) > h * 0.6:
            mid = sorted(tops)[len(tops) // 2]
            a = [w for w in ln if w['top'] <= mid]
            b = [w for w in ln if w['top'] > mid]
            if a: split.append(a)
            if b: split.append(b)
        else:
            split.append(ln)
    lines = split
    out = []
    for ln in lines:
        ln.sort(key=lambda w: w['left'])
        # x 间隙切段(同 y 不同窗口的词会被拼成一行:下载弹窗中文+Docs正文混行 → 垃圾过审):
        # 相邻词水平间隙 > 0.05 屏宽 → 切开,每段独立成"行"走准入
        segs, cur = [], [ln[0]]
        for w in ln[1:]:
            prev = cur[-1]
            if w['left'] - (prev['left'] + prev.get('width', 0)) > 0.05:
                segs.append(cur); cur = []
            cur.append(w)
        segs.append(cur)
        for sg in segs:
            out.append((sg[0]['top'], sg[0]['left'], norm(' '.join(w['text'] for w in sg)), len(sg)))
    return out

def body_lines(lines, kwords):
    """正文行准入 v3(行级击键背书):行的英文词(≥4字母)中 ∈击键词集占比 ≥0.5 → 正文行。
    列投票被自指污染破防(Terminal 里 Claude 会话引用过 essay 原文,两窗都含击键词);
    行级判据下污染无害:终端引用的 essay 片段文本与 Docs 行相同 → 行池合并而非重复;
    claude 解释文字/命令行(bash/sqlite/permissions 等非用户词)占比低 → 拦。"""
    out = []
    for (y, x, t, n) in lines:
        if n < 3: continue
        toks = re.findall(r'[a-z]{4,}', t.lower())
        if len(toks) < 2: continue
        hit = sum(1 for w in toks if w in kwords)
        if hit / len(toks) >= 0.5:
            out.append((y, t))
    return out

def key_of(t):
    """行的查重键:去空白小写前36字(OCR 错字容忍靠相似度合并,键只做粗桶)。"""
    return re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:36]

def is_history_frame(words):
    """Google Docs 版本历史帧判据:界面词(Version history/版本记录/作者条目)或
    删除线签名(词间连字符≥2 的行 ≥3:删除线穿词缝被 OCR 读成连字符)。
    历史帧让旧版以干净文本重现,污染快照/终稿仲裁/timeline,须剔除。"""
    n_strike = 0
    for (y, x, t, n) in frame_lines(words):
        tl = t.lower()
        if ('version history' in tl or '版本记录' in tl or 'restore this version' in tl
                or '恢复此版本' in tl or re.search(r'•\s*joy zhang', tl)):
            return True
        if re.search(r'[a-z]{3,}-[a-z]{2,}', tl) and t.count('-') >= 2:
            n_strike += 1
    return n_strike >= 3

def similar(a, b):
    return SequenceMatcher(None, a, b, autojunk=False).ratio()

def main(url_like, t0s, t1s, drop_history=False):
    T0 = int(datetime.datetime.strptime(t0s, '%Y-%m-%d %H:%M').timestamp() * 1000)
    T1 = int(datetime.datetime.strptime(t1s, '%Y-%m-%d %H:%M').timestamp() * 1000)
    rows = con.execute(
        "SELECT timestamp_ms, ocr_words_json FROM frames WHERE browser_url LIKE :u "
        "AND timestamp_ms BETWEEN :a AND :b AND ocr_words_json IS NOT NULL ORDER BY timestamp_ms",
        {"u": f"%{url_like}%", "a": T0, "b": T1}).fetchall()
    print(f"帧数: {len(rows)}", file=sys.stderr)
    # 击键词集(正文列投票锚):窗口期 Safari 击键流的英文词(≥4字母)
    ks = con.execute("SELECT char, is_backspace, modifiers FROM keystroke_log WHERE bundle_id LIKE '%Safari%' "
                     "AND ts_ms BETWEEN :a AND :b ORDER BY ts_ms", {"a": T0, "b": T1}).fetchall()
    buf = []
    for c, bs, md in ks:
        if (md & 7) != 0: continue
        if bs:
            if buf: buf.pop()
            continue
        if c: buf.append(c if c not in ('\n', '\r') else ' ')
    from collections import Counter as _C2
    kwfreq = _C2(re.findall(r'[a-z]{4,}', ''.join(buf).lower()))
    kwords = set(kwfreq)
    kw_has_cjk = any('一' <= c <= '鿿' for c in buf)
    print(f"击键词集: {len(kwords)}", file=sys.stderr)
    frames = []
    raw_fl = []
    for ts, wj in rows:
        try: words = json.loads(wj)
        except Exception: continue
        if drop_history and is_history_frame(words): continue
        raw_fl.append((ts, frame_lines(words)))
    # 两遍法 x 锚:第一遍击键背书收行 → 正文列左缘众数(GitHub页/写作建议对话与essay同词,
    # 行级背书拦不住,但它们在别的窗口列——x 锚拦);第二遍 背书∧列锚 双闸
    from collections import Counter as _C
    xs = _C()
    for ts, fl in raw_fl:
        for (y, t) in body_lines(fl, kwords):
            pass
    for ts, fl in raw_fl:
        for (y, x, t, n) in fl:
            toks = re.findall(r'[a-z]{4,}', t.lower())
            if len(toks) >= 3 and sum(1 for w in toks if w in kwords) / len(toks) >= 0.5:
                xs[round(x / 0.02)] += 1
    anchor = xs.most_common(1)[0][0] * 0.02 if xs else None
    print(f"正文列锚 x={anchor}", file=sys.stderr)
    USE_LLM = os.environ.get('CANVAS_LLM', '0') == '1'
    frame_ref = {}
    for ts, fl in raw_fl:
        bl = []
        for (y, x, t, n) in fl:
            if n < 3: continue
            if not kw_has_cjk:
                t = re.sub(r'[一-鿿][一-鿿0-9个,，()（）:：\s]*', ' ', t)   # 弹窗中文段剥离(击键无中文→中文必非正文)
                t = norm(t)
            toks = re.findall(r'[a-z]{4,}', t.lower())
            if len(toks) < 2: continue
            ratio = sum(1 for w in toks if w in kwords) / len(toks)
            in_anchor = anchor is not None and (anchor - 0.02 <= x <= anchor + 0.08)
            if ratio >= 0.5 and in_anchor:
                bl.append((y, t))                      # 强通过:背书+锚双证,免LLM
                frame_ref.setdefault(ts, []).append((round(x, 2), round(y, 2), t[:60]))
            elif USE_LLM and ratio >= 0.3:
                bl.append((y, f'\x01{x:.2f},{y:.2f}\x01' + t))   # 模糊带:编码坐标,T1空间仲裁
        if bl: frames.append((ts, sorted(bl)))
    # ---- 跨帧 chrome 过滤:行键出现率 >60% 且短行 = 界面常驻(已保存/保存中/菜单) ----
    from collections import Counter, defaultdict
    seen_in = Counter()
    for _, bl in frames:
        for k in set(key_of(t) for _, t in bl if t):
            seen_in[k] += 1
    nF = max(1, len(frames))
    chrome = {k for k, n in seen_in.items() if n / nF > 0.6 and len(k) < 30}
    # ---- 行池合并(多帧投票) ----
    # pool: gid -> {'texts': Counter, 'first_ts', 'last_ts', 'order_hint'}
    pool = {}
    order = []           # gid 全局顺序(按首次出现时的帧内邻接插入)
    timeline = []        # (ts, kind, text)
    prev_gids = []
    frame_gids = []
    for ts, bl in frames:
        cur_gids = []
        for y, t in bl:
            weak = t.startswith('\x01')
            wxy = None
            if weak:
                mm0 = re.match('\x01([-\\d.]+),([-\\d.]+)\x01(.*)', t, re.S)
                wxy = (float(mm0.group(1)), float(mm0.group(2)))
                t = mm0.group(3)
            if not t or key_of(t) in chrome or len(t) < 4: continue
            # 找池中相似行(先键桶,再相似度)
            gid = None
            k = key_of(t)
            tw = frozenset(re.findall(r'[a-z]{4,}', t.lower()))
            for g in order:
                gk = pool[g]['key']
                if similar(gk, k) >= 0.75 or (len(k) >= 12 and (k in gk or gk in k)):
                    gid = g; break
            if gid is None and len(tw) >= 3:
                # 词集 Jaccard 吸收:OCR 撕裂变体(词序乱/交错,字符 ratio 合并不了)
                # 词集重叠 ≥0.6 = 同一行的破损副本 → 计票不开新行
                for g in order:
                    gw_ = pool[g].get('words') or frozenset()
                    if gw_ and len(tw & gw_) / max(1, len(tw | gw_)) >= 0.6:
                        gid = g; break
            if gid is None:
                gid = len(pool)
                pool[gid] = {'texts': Counter(), 'first': ts, 'last': ts, 'key': k,
                             'words': frozenset(re.findall(r'[a-z]{4,}', t.lower()))}
                # 插入位置:跟随 cur_gids 最后一个已知行
                if cur_gids and cur_gids[-1] in order:
                    order.insert(order.index(cur_gids[-1]) + 1, gid)
                else:
                    order.append(gid)
                timeline.append((ts, 'commit', t))
            pool[gid]['texts'][t] += 1
            pool[gid]['last'] = ts
            pool[gid]['strong'] = pool[gid].get('strong', 0) + (0 if weak else 1)
            if weak and wxy and 'wxy' not in pool[gid]:
                pool[gid]['wxy'] = wxy; pool[gid]['wts'] = ts
            if len(t) > len(pool[gid]['key']):   # 键随更长版本更新(滚动中行被截断)
                pool[gid]['key'] = key_of(t)
                pool[gid]['words'] = frozenset(re.findall(r'[a-z]{4,}', t.lower()))
            cur_gids.append(gid)
        prev_gids = cur_gids
        frame_gids.append((ts, cur_gids))
    # delete 检测 v2(邻居否决):行 r 最后出现于 F;若其后存在帧 G 同时含 r 的前邻和后邻
    # 却不含 r → r 在 G 时刻已被删(旧版本段落:'Back to the time…'被改写)。
    # 滚动安全:整页滚走时邻居也不在 G,不触发。
    frame_sets = [(ts, set(gids)) for ts, gids in frame_gids]
    final_gids = []
    for g in order:
        p = pool[g]
        idx = order.index(g)
        nb = [order[j] for j in (idx - 1, idx + 1) if 0 <= j < len(order)]
        deleted = False
        if len(nb) >= 1:
            for ts, gs in frame_sets:
                if ts <= p['last']: continue
                if g not in gs and all(n in gs for n in nb):
                    deleted = True
                    timeline.append((ts, 'delete', p['texts'].most_common(1)[0][0]))
                    break
        if deleted: continue
        # 低票淘汰:出现 <3 帧(正文行平均被拍 10+ 次)= OCR 交错/截断残余
        if sum(p['texts'].values()) < 3: continue
        final_gids.append(g)
    # LLM 行级仲裁(零写权:只判正文Y/N,文本仍来自OCR投票+击键纠错;用户裁定:窗口位置
    # 不定+中文canvas,确定性闸不够泛化)。强通过(背书+锚)免审;weak-only 行分批问 14B。
    weak_gids = [g for g in final_gids if not pool[g].get('strong')]
    if weak_gids and os.environ.get('CANVAS_LLM', '0') == '1':
        from mlx_lm import load as _load, generate as _gen
        m14, tok14 = _load("mlx-community/Qwen3-14B-4bit")
        kws_sample = ' '.join(list(kwords)[:40])
        keep = set()
        B = 30
        for bi in range(0, len(weak_gids), B):
            batch = weak_gids[bi:bi + B]
            listing = '\n'.join(f"{j+1}. {pool[g]['texts'].most_common(1)[0][0][:90]}"
                                 for j, g in enumerate(batch))
            ref_lines = []
            for g in batch:
                rts = pool[g].get('wts')
                for (rx, ry, rt) in (frame_ref.get(rts) or [])[:3]:
                    ref_lines.append(f"  ({rx},{ry}) {rt}")
            refs = '\n'.join(sorted(set(ref_lines))[:6]) or '  (无)'
            listing = '\n'.join(
                f"{j+1}. ({pool[g].get('wxy', (0, 0))[0]:.2f},{pool[g].get('wxy', (0, 0))[1]:.2f}) "
                f"{pool[g]['texts'].most_common(1)[0][0][:90]}" for j, g in enumerate(batch))
            user = ("屏幕OCR一帧,多窗口并存(终端/聊天/浏览器/文档)。用户正在某个文档窗口写文章。\n"
                    "下面给出**已确认的文档正文行**及其归一化坐标(x,y=左上角,0~1)作为参照——"
                    "正文同属一个窗口,坐标列应一致:\n" + refs + "\n\n"
                    "待判行(坐标+文本):\n" + listing + "\n\n"
                    "逐行判断是否属于该文档的内容(含标题/副标题/作者/日期行;"
                    "界面元素/其他窗口/终端/聊天/AI建议=N)。输出'序号:Y'或'序号:N',不解释。")
            pr = tok14.apply_chat_template([{"role": "user", "content": user}],
                                           add_generation_prompt=True, tokenize=False, enable_thinking=False)
            out = _gen(m14, tok14, prompt=pr, max_tokens=8 * len(batch), verbose=False)
            for j, g in enumerate(batch):
                mm = re.search(rf'(?m)^\s*{j+1}\s*[.,:：、]\s*([YN])', out, re.I)
                if mm and mm.group(1).upper() == 'Y':
                    keep.add(g)
        print(f"LLM仲裁: weak {len(weak_gids)} 行,保留 {len(keep)}", file=sys.stderr)
        killed = {g for g in weak_gids if g not in keep}
        kill_texts = {pool[g]['texts'].most_common(1)[0][0] for g in killed}
        timeline[:] = [e for e in timeline if not (e[1] == 'commit' and e[2] in kill_texts)]
        final_gids = [g for g in final_gids if pool[g].get('strong') or g in keep]
    # 版本组去重:order 近邻(≤4)两行词集 Jaccard≥0.45 = 改写关系(整段改写时邻居否决失灵:
    # 'Back then, we had…' vs 终稿 'Back to the time, we got…')→ 留 last_ts 晚者,早者进 delete
    # 时间线(=改写历史可见,diff feature 增强)。OCR 交错行(词集=两行并集)同被吸收。
    drop_old = set()
    for ii, g1 in enumerate(final_gids):
        for g2 in final_gids[ii + 1: ii + 13]:
            w1, w2 = pool[g1].get('words') or frozenset(), pool[g2].get('words') or frozenset()
            if len(w1) < 3 or len(w2) < 3: continue
            if len(w1 & w2) / max(1, len(w1 | w2)) >= 0.45:
                old_g = g1 if pool[g1]['last'] < pool[g2]['last'] else g2
                if old_g not in drop_old:
                    drop_old.add(old_g)
                    timeline.append((pool[old_g]['last'], 'delete',
                                     pool[old_g]['texts'].most_common(1)[0][0]))
    final_gids = [g for g in final_gids if g not in drop_old]
    # 多帧投票定稿 + 击键词典纠错(rn→m 系统性 OCR 错字:leamed→learned;
    # 写权在确定性链路:只换成用户真打过的词,编辑距离≤1)
    def ed1(a, b):
        if abs(len(a) - len(b)) > 1: return False
        if len(a) == len(b): return sum(x != y for x, y in zip(a, b)) <= 1
        s, l = (a, b) if len(a) < len(b) else (b, a)
        for i in range(len(l)):
            if s == l[:i] + l[i+1:]: return True
        return False
    kw_by_len = {}
    for w in kwords: kw_by_len.setdefault(len(w), set()).add(w)
    def fix_word(m):
        w = m.group(0); wl = w.lower()
        if wl in kwords or len(wl) < 5: return w
        cands = []
        for L in (len(wl) - 1, len(wl), len(wl) + 1):
            cands += [c for c in kw_by_len.get(L, ()) if ed1(wl, c)]
        # OCR 物理混淆对 m↔rn(距离2但属字形混淆,leamed→learned):
        cands += [c for c in kwords if wl.replace('m', 'rn') == c or wl.replace('rn', 'm') == c]
        # 按击键频次选(中间态错词频次≈1,真词反复出现);freq<2 的候选不可信,弃修
        cands = [c for c in set(cands) if kwfreq[c] >= 2]
        if not cands: return w
        return max(cands, key=lambda c: kwfreq[c])
    final_lines = [re.sub(r'[A-Za-z]{5,}', fix_word, pool[g]['texts'].most_common(1)[0][0])
                   for g in final_gids]
    final_text = '\n'.join(final_lines)
    timeline.sort(key=lambda x: x[0])
    return final_text, timeline, len(frames), len(chrome)

if __name__ == '__main__':
    url = sys.argv[1] if len(sys.argv) > 1 else '1DY0bEhGGZB'
    t0 = sys.argv[2] if len(sys.argv) > 2 else '2026-05-28 18:00'
    t1 = sys.argv[3] if len(sys.argv) > 3 else '2026-05-29 02:00'
    ft, tl, nf, nc = main(url, t0, t1)
    json.dump({'final_text': ft, 'timeline': tl, 'frames': nf, 'chrome_lines': nc},
              open('eval/canvas_v1.json', 'w'), ensure_ascii=False)
    print(f"帧 {nf} | chrome 行 {nc} | 重建行 {ft.count(chr(10))+1} 字 {len(ft)} | timeline {len(tl)} 条")
