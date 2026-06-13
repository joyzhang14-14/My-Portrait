#!/usr/bin/env python3
"""canvas v2:去噪快照 + 14B 窄拼接(对标库中 haiku 95%/98%)。
拆解:去噪=确定性(复用 canvas_local 行级闸)/拼接=14B 窄任务(滚动视口对齐去重叠)/
幻觉 guard=输出逐窗(24字)必须存在于某快照,不在=该段拒(写权零容忍)。
diff 时间线仍用 canvas_local 确定性产出。
"""
import sqlite3, os, json, re, sys, datetime
import canvas_local as CL

con = CL.con

def clean_frame_lines(words, kwords, line_freq=None):
    """两遍式:strong 行(背书≥0.5)定**帧级 x 锚**(该帧文档列位置——窗口移动自适应);
    低背书行须 跨帧频次≥2 ∧ x∈锚±0.08(GitHub/对话窗常驻行高频但列不同,锚拦)。
    返回 [(y, x, t)](y 升序)。"""
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
            bl.append((y, x, t))
        elif (r >= 0.15 and len(t) >= 15 and (line_freq is None or line_freq.get(k, 0) >= 2)
              and ax is not None and abs(x - ax) <= 0.08):
            bl.append((y, x, t))
    return sorted(bl)

def clean_frame_text(words, kwords, line_freq=None):
    return '\n'.join(t for _, _, t in clean_frame_lines(words, kwords, line_freq))

is_history_frame = CL.is_history_frame   # 判据下沉 canvas_local,timeline 线共用

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
    # 解析一次 + 剔除版本历史帧(旧版以干净文本重现的污染源)
    frames = []
    for ts, wj in rows:
        try: words = json.loads(wj)
        except Exception: continue
        if is_history_frame(words): continue
        frames.append((ts, words))
    print(f"剔除历史帧 {len(rows) - len(frames)} 张", file=sys.stderr)
    # 代表帧:时间均匀取 max_snaps 张,每张去噪;太短(<200字)跳过
    from collections import Counter as _CF
    line_freq = _CF()
    for ts, words in frames[::3]:
        for (y, x, t, n) in CL.frame_lines(words):
            if n >= 3:
                line_freq[re.sub(r'[^a-z0-9一-鿿]', '', t.lower())[:30]] += 1
    # 拼接快照:均匀 22-24 张(实证最优形态;喂更多快照会撑爆 merge:
    # 50-60张→顶层吞行→自愈拒→直连爆膨胀,滚动折叠同样雪球)。
    # "昙花一现"区域(结尾只在1-2帧出镜)不靠加快照解决,靠末端终愈 pass 兜底
    snaps = []
    step = max(1, len(frames) // max_snaps)
    for i in range(0, len(frames), step):
        ts, words = frames[i]
        t = clean_frame_text(words, kwords, line_freq)
        if len(t) >= 200: snaps.append((ts, t))
    # 全帧清洗行池(delete 派生素材):行 → [首见帧序, 末见帧序, 原文]
    line_pool = {}
    for i, (ts, words) in enumerate(frames):
        for (y, x, t) in clean_frame_lines(words, kwords, line_freq):
            nl = normx(t)
            if len(nl) < 12: continue
            ent = line_pool.setdefault(nl, [i, i, t])
            ent[1] = i
    print(f"代表快照 {len(snaps)} 张 | 行池 {len(line_pool)} 行", file=sys.stderr)
    # 层级归并(v2c):组内6张一次性拼→组块再拼一次。每层输出有界,无滚动膨胀/截断。
    from mlx_lm import load as _load, generate as _gen
    m14, tok14 = _load("mlx-community/Qwen3-14B-4bit")
    allsnap = normx(' '.join(t for _, t in snaps))
    def merge_once(parts, label):
        if len(parts) == 1:
            listing = f"【文本】\n{parts[0]}"
        else:
            listing = '\n\n'.join(f"【片段{i+1}】\n{p}" for i, p in enumerate(parts))
        user = ("以下片段来自同一文档的滚动截屏 OCR,**按拍摄时间先后排列**(片段越靠后越新),"
                "相邻片段有重叠区,可能有 OCR 错字。作者写作中会反复修改:同一段落可能在不同片段里"
                "出现新旧两个版本。把它们拼成这一区域的完整文本:用重叠区对齐;"
                "**同一段落新旧版本冲突时,只保留时间更靠后的片段里的版本,旧版整段丢弃**;"
                "重叠只保留一份,同一句话在输出里最多出现一次;"
                "按文档顺序;**只能用片段里出现过的文字,禁止发明**。\n\n"
                f"{listing}\n\n输出拼接后的完整文本,不解释。")
        pr = tok14.apply_chat_template([{"role": "user", "content": user}],
                                       add_generation_prompt=True, tokenize=False, enable_thinking=False)
        out = _gen(m14, tok14, prompt=pr, max_tokens=3800, verbose=False)
        out = re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
        nb = normx(out)
        wins = [nb[i:i + 24] for i in range(0, max(1, len(nb) - 24), 24)]
        # 半窗容差(98%假说):窗含1-2个OCR错字修复时整窗∉快照,但至少一半12字干净——
        # 任一半∈快照=错字修复放行;两半都不在=真幻觉拒。释放14B隐性纠错,大幻觉仍拦。
        bad = sum(1 for w in wins if w not in allsnap
                  and w[:12] not in allsnap and w[12:] not in allsnap)
        if wins and bad / len(wins) > 0.10:
            print(f"  {label} 拒(幻觉窗 {bad}/{len(wins)}),回退片段直连", file=sys.stderr)
            return '\n'.join(parts)
        # 注:merge 层不做完整性自愈——它与"旧版整段丢弃"指令天然冲突
        # (实证:正确丢旧版被当吞行,踩 30% 阀误回退直连→爆膨胀)。
        # 完整性由末端终愈 pass 统一兜底,merge 允许有损
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
    # 终稿仲裁 trim:被重写的旧版在终读池(剔历史后会话末段帧)里缺席 → 剪。
    # 判据=与评测/guard 同口径的半窗容差(更严的判据已实证错位大开杀戒:
    # 半窗口径天然原谅小幅改写,只有整段重写才该剪)。
    # 终读池=末 25% 非历史帧(会话相对量,本样本≈115min;墙钟常数已废)。
    # 安全阀:剪句>20% = 多半没有收尾通读,终读池不可信 → 整体放弃 trim(宁多勿错)。
    k = max(1, int(len(frames) * 0.25))
    pool = [t for ts, words in frames[-k:]
            for (y, x, t, n) in CL.frame_lines(words) if n >= 3]
    hay = normx(' '.join(pool))
    def in_final(s):
        ns = normx(s)
        if len(ns) < 24: return not ns or ns in hay
        ws = [ns[i:i + 24] for i in range(0, len(ns) - 23, 12)]
        return sum(1 for w in ws if w in hay or w[:12] in hay or w[12:] in hay) / len(ws) >= 0.5
    body_pretrim = body
    sents = re.split(r'(?<=[。.!?!?\n])', body)
    kept = [s for s in sents if in_final(s)]
    cut_sents = [s for s in sents if not in_final(s)]   # 真删除内容(timeline delete 来源)
    cut_n = len(cut_sents)
    pool_ok = cut_n <= 0.2 * len(sents)
    if not pool_ok:
        print(f"终稿仲裁弃用(剪句 {cut_n}/{len(sents)} 超阀,疑无通读动作)", file=sys.stderr)
    else:
        body = ''.join(kept)
        print(f"终稿仲裁剪句 {cut_n}", file=sys.stderr)
    # 终愈=尾部终态化:结尾以"尾区域最后一次出镜的帧"为唯一真相源。
    # 从成品尾部向前找最近的有帧命中的 24 字锚,锚之后的一切(被删中间态如
    # 'it can remember what…'、OCR 烂变体堆尾)整体替换为含锚最后一帧的文档列延续。
    # ⚰️行池续接四败留档:①cnt≥2 频次闸选反(标签页像素稳定高频,真内容 OCR 抖动
    # 变体各 cnt=1)②击键背书背不动(survey/Claude 窗打的字同进词集)③同列邻居判据
    # 被顶栏破功 ④逐段续接+新颖度闸仍堆变体(中间态与终态在终读池里分不开,
    # in_final 无力,唯一可靠=区域最后观测)
    if pool_ok:
        def norm_map(raw):
            return [i for i, ch in enumerate(raw) if normx(ch)]
        bodyn = normx(body)
        # ① 真相帧 R:尾段(末300字)所有锚的"最后命中帧"取最大——单锚会锚进中间态
        #   (实证:末24字含'it can'中间态,锚到idx462而非终态帧)
        grams = [(off, bodyn[off:off + 24])
                 for off in range(max(0, len(bodyn) - 300), len(bodyn) - 23, 6)]
        best_fr = -1
        for i, (ts, words) in enumerate(frames):
            hay = normx(' '.join(t for (y, x, t, n) in CL.frame_lines(words) if n >= 3))
            if i > best_fr and any(g in hay for _, g in grams):
                best_fr = i
        if best_fr >= 0:
            # ② 剪点:成品里 R 支持的最靠后的锚;锚后(R 不支持=中间态/烂变体)整体替换为 R 的延续
            ls = clean_frame_lines(frames[best_fr][1], kwords, line_freq)
            jr = ' '.join(t for _, _, t in ls)
            jn = normx(jr)
            cutp = None
            for off, g in reversed(grams):
                p = jn.rfind(g)
                if p >= 0: cutp = (off, p); break
            if cutp:
                off, p = cutp
                mj, mb = norm_map(jr), norm_map(body)
                keep = body[:mb[off + 23] + 1]
                ext = jr[mj[p + 23] + 1:] if p + 24 < len(jn) else ''
                ext = re.sub(r'[」\s]+$', '', ext)
                print(f"尾部终态化:截后缀 {len(bodyn) - off - 24} 字→接真相帧续 "
                      f"{len(normx(ext))} 字(帧idx{best_fr})", file=sys.stderr)
                body = keep + ext
        body = re.sub(r'[A-Za-z]{5,}', fix_word, body)   # 终态化段补词典纠错
    # diff 时间线:从成品派生,与文章自洽(用户裁定:commit−delete 必须能合成最终文章)。
    # commit=成品逐句+首次成稿帧时刻(逐句拼接=最终文章,构造保证);
    # delete=终稿仲裁剪掉的旧版句+最后在场时刻(实证为真删除)。
    # ⚰️行池启发式 timeline(canvas_local)退役:OCR 碎行不可读+假 delete(15条里8条
    # 半窗命中 gold)+与拼接成品两条线天然合不回文章
    fhays2 = [(ts, normx(' '.join(t for (y, x, t, n) in CL.frame_lines(words) if n >= 3)))
              for ts, words in frames]
    def seen_span(s):
        ns = normx(s)
        if len(ns) < 8: return (None, None)
        ws = [ns[i:i + 24] for i in range(0, max(1, len(ns) - 23), 12)]
        def pres(hay):
            return sum(1 for w in ws if w in hay or (len(w) >= 20 and
                       (w[:12] in hay or w[12:] in hay))) / len(ws) >= 0.5
        idxs = [ts for ts, hay in fhays2 if pres(hay)]
        return (idxs[0], idxs[-1]) if idxs else (None, None)
    timeline, prev_ts = [], None
    for sent in re.split(r'(?<=[。.!?!?\n])', body):
        st = sent.strip()
        if not st: continue
        f, _ = seen_span(st)
        ts_c = f or prev_ts or (frames[0][0] if frames else 0)
        timeline.append((ts_c, 'commit', st))
        prev_ts = ts_c
    # delete 派生(行池聚类;对齐生产 canvas_fusion 的删除事件——用户指认两案:
    # ADHD 写后94秒删/China 21:13:53 改写,旧法"只记 trim 剪句"在拼接层就被
    # 14B 选版淘汰的旧版根本到不了 trim,漏)。候选四闸:不在成品(maj<0.4)∧
    # 不在终读池(maj<0.2,标签页/别窗常驻垃圾天然排除)∧ 击键16-gram背书
    # (用户真打过;survey/Claude引用文被聚类吸收)∧ len≥24。
    # 共享16-gram聚类+二次合并(代表互含),代表=击键覆盖率最高再取最长;
    # 簇内最晚末见帧=删除时刻。gold 开发期校验:26簇 0 假删
    if pool_ok:
        bodyn3 = normx(body)
        nbuf = normx(''.join(buf))
        def maj(nl, hh):
            ws = [nl[i:i + 24] for i in range(0, max(1, len(nl) - 23), 12)]
            return sum(1 for w in ws if w in hh or (len(w) >= 20 and
                       (w[:12] in hh or w[12:] in hh))) / len(ws)
        cands = []
        for nl, (fi, la, ln) in line_pool.items():
            if len(nl) < 24: continue
            if maj(nl, bodyn3) >= 0.4: continue
            if maj(nl, hay) >= 0.2: continue
            if not any(nl[q:q + 16] in nbuf for q in range(0, max(1, len(nl) - 15), 8)):
                continue
            cands.append((nl, la, ln))
        parent = {}
        def find(a):
            while parent.get(a, a) != a: a = parent[a]
            return a
        gram_owner = {}
        for idx, (nl, la, ln) in enumerate(cands):
            parent.setdefault(idx, idx)
            for q in range(0, max(1, len(nl) - 15), 8):
                g = nl[q:q + 16]
                if g in gram_owner: parent[find(idx)] = find(gram_owner[g])
                else: gram_owner[g] = idx
        from collections import defaultdict as _dd
        clus = _dd(list)
        for idx, c in enumerate(cands): clus[find(idx)].append(c)
        def kwcov(nl):
            gs = [nl[q:q + 16] for q in range(0, max(1, len(nl) - 15), 8)]
            return sum(1 for g in gs if g in nbuf) / len(gs)
        groups = []
        for mem in clus.values():
            rep = max(mem, key=lambda c: (round(kwcov(c[0]), 1), len(c[0])))
            groups.append([rep, max(c[1] for c in mem), mem])
        # 二次合并:代表互含(maj≥0.5)的碎簇并掉(同段落的截断变体/引用)
        groups.sort(key=lambda g: -len(g[0][0]))
        merged = []
        for g in groups:
            host = next((m for m in merged if maj(g[0][0], m[0][0]) >= 0.5), None)
            if host: host[1] = max(host[1], g[1])
            else: merged.append(g)
        dels = {}
        for rep, la, mem in merged:
            nlr = rep[0]
            # 击键可证存活闸:代表行里击键能背书的 16-gram 大半仍在成品 = 假删
            # (烂OCR孤儿变体冒充删除;实证:huge idea 案 'wemmto srgurap' 三处都活)
            tg = [nlr[q:q + 16] for q in range(0, max(1, len(nlr) - 15), 8)
                  if nlr[q:q + 16] in nbuf]
            if tg and sum(1 for g in tg if g in bodyn3) / len(tg) >= 0.5:
                continue
            txt = re.sub(r'[A-Za-z]{5,}', fix_word, rep[2]).strip()
            # trim 剪句若与本簇同段,用其干净文本(出自 LLM 拼接体,可读性好)
            for cs in cut_sents:
                if maj(normx(cs), nlr) >= 0.5 or maj(nlr, normx(cs)) >= 0.5:
                    txt = cs.strip(); break
            key = normx(txt)
            ts_d = frames[la][0]
            if key not in dels or ts_d > dels[key][0]:   # 同文去重,取最晚=真删除时刻
                dels[key] = (ts_d, txt)
        for ts_d, txt in dels.values():
            timeline.append((ts_d, 'delete', txt))
    # 不按时间重排:commit 段保持文档序(逐条拼接=最终文章,构造性自洽);
    # 每条自带 ts,展示侧需要时间视图时自行排序
    print(f"timeline:成品句 commit {sum(1 for e in timeline if e[1]=='commit')} "
          f"+ delete {sum(1 for e in timeline if e[1]=='delete')}", file=sys.stderr)
    json.dump({'final_text': body, 'body_pretrim': body_pretrim, 'timeline': timeline,
               'frames': len(rows), 'chrome_lines': 0},
              open('eval/canvas_v2.json', 'w'), ensure_ascii=False)
    print(f"拼接完成 字数 {len(body)}")
    return body

if __name__ == '__main__':
    main()
