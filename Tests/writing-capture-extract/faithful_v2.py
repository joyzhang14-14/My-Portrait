#!/usr/bin/env python3
"""⚠️ failed 版本(2026-06,用户标记)—— 本地 14B disambig + 8B Pass4 的 IME 重建尝试,**待用户定点修**。
已知 bug(文件内注释也有):的/得助词、librime 词库无的 slang(如"卖个惨")、H/I 截断尾巴、canvas 跨app尾巴;
且**依赖旧 writing_records_staged 做分组**。用户在评估它、逐点修;改方向由用户决断。
librime 已搬进项目 rime/(不再用 /tmp)。生产当前仍是云端 haiku 老 pipeline。

阶段0 集成全量重跑:
event_sends_with_ts(真发送+is_send) → rebuild 重建(librime + 14b disambig + 残渣调和)
→ 组级击键 gate / slash gate → dedup_truncated(类4/5a) → is_residue → 8b Pass4 → 合云端 canvas
→ 写 Obsidian 对照文档。两阶段加载省内存:14b 重建 → 卸载 → 8b Pass4。"""
import json, os, re, sqlite3, gc
import harness as H
import rebuild as R
import extract_compare_v2 as X
import mlx_constrained as MC
import ocr3 as C3
from mlx_lm import load, generate

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()

# ---- helpers ----
def sess_events(ids):
    out = []
    for e in ids:
        r = con.execute("SELECT started_at,ended_at,bundle_id FROM typing_events WHERE id=?", (e,)).fetchone()
        if r: out.append(r)
    return out
def group_kc(ids):
    n = 0
    for st, et, b in sess_events(ids):
        n += con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND (modifiers&7)=0", (b, st-10000, et+10000)).fetchone()[0]
    return n
def assemble_keys(ids):
    rows = []
    for e in ids:
        rows += con.execute("SELECT kl.ts_ms,kl.char,kl.is_backspace,kl.modifiers FROM keystroke_log kl JOIN typing_events te ON kl.bundle_id=te.bundle_id WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000", (e,)).fetchall()
    o = ""
    for ts, c, bs, md in sorted(rows, key=lambda r: r[0]):
        if (md & 7) != 0: continue
        if bs: o += "<BS>"; continue
        if c: o += "<CR>" if c in ("\n", "\r") else c
    return o[:700]
def ctx_window(recent, ts, after=None, gap_ms=5 * 60 * 1000, max_n=6, max_chars=400):
    """时间邻域上下文(替代旧 convo_ctx 的「旧staged全天」):
    recent=[(ts,text)] 已按时间序;从 ts 向前逐条扩,**条间 gap >5min 停**(对话 session 边界),
    每侧 ≤6 条,总 ≤400 字。after 给了(口3 阶段)再向后扩 —— 双向语境。"""
    before_items = [(t, x) for t, x in recent if t is not None and t <= ts]
    out_b, last = [], ts
    for t, x in reversed(before_items):
        if last - t > gap_ms or len(out_b) >= max_n: break
        out_b.append(x); last = t
    out_b.reverse()
    out_a, last = [], ts
    for t, x in (after or []):
        if t is None or t < ts: continue
        if t - last > gap_ms or len(out_a) >= max_n: break
        out_a.append(x); last = t
    s, total = [], 0
    for x in out_b: s.append(f"  - {x[:60]}"); total += len(x[:60])
    if out_a:
        s.append("  (之后的消息:)")
        for x in out_a: s.append(f"  - {x[:60]}"); total += len(x[:60])
    return "\n".join(s[:1 + max_n * 2])[:max_chars]

def is_residue(t):
    """#41 修复:只丢「整条几乎全是残渣」的。中文主体 + 小拼音尾渣 → **保留整条**
    (最大保留用户最终输入;尾渣重建失败就带渣展示,不丢真话)。"""
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True
    # 原③条(中文+尾渣 ≤25字 整条丢)误杀真消息(#41 '我用你seedance余额跑yi x'):
    # 收窄为 汉字≤2 才丢('你fa shao' 这类几乎全渣);汉字≥3 = 真消息主体,保留。
    if (re.search(r'[一-鿿]\s*[a-z]{1,3}(?: [a-z]{1,3})+$', c) and len(c) <= 25
            and sum(1 for ch in c if '一' <= ch <= '鿿') <= 2): return True
    return False
def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"

# ===== Phase 1: 重建(14b disambig) =====
print("=== Phase1: 加载 14b 做 IME 重建 ===", flush=True)
m14, tok14 = load("mlx-community/Qwen3-14B-4bit")
def disambig(p):
    if p.get('mode') != 'disambig': return None
    top = p['top']; alt = [w for w in p['words'] if w != top]
    user = ("用户在聊天 app 里用拼音打字,输入法默认上屏了一个词,但可能选错同音字。结合上下文判断默认对不对:"
            "对就保留,只在明显选错(同音字不合语境)时才换。\n"
            f"上下文(当前句已确定的前文 + app + 最近对话):\n{p['context'][:400]}\n"
            f"拼音「{p['py']}」默认上屏=「{top}」。其他同音候选: {' / '.join(alt[:6])}\n"
            "输出这里最合理的那个词(默认合理就输出默认那个)。只输出一个词,别的不要。\n"
            "⚠️ 若所有候选放进语境都不通顺(没打完的拼音/词库里没有的词),只输出 NONE——宁可保留拼音原样也不要选个错词。")
    pr = tok14.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = re.sub(r'<think>.*?</think>', '', generate(m14, tok14, prompt=pr, max_tokens=24, verbose=False), flags=re.S).strip()
        if re.search(r'\bNONE\b', out.upper()): return 'NONE'   # 逃生门:留残渣给口3
        mm = re.search(r'[一-鿿]+', out); return mm.group(0) if mm else None
    except Exception:
        return None

def referee(text, snip, keys, mode='self'):
    """Phase1.75 审核员(用户设计:审核而非丢弃)。**只有 PASS/打回 权,无写权**——
    打回时给的 hint 只是指路,采纳前仍须逐字过击键验证(写权永远在确定性链路)。"""
    mode_note = {"self": "OCR片段锚定到了记录本身的位置,可信度高",
                 "prev": "OCR片段是上一条消息之后的屏幕区域,可能混入界面元素/他人消息,仅当看到与记录明显矛盾的同义内容才 REJECT",
                 "before": "OCR片段来自发送前的帧,内容可能还没渲染,弱证据"}.get(mode, "")
    long_note = "(记录较长,OCR片段只覆盖开头——开头一致即可 PASS)" if len(text) > 60 and snip else ""
    user = ("你是写作采集的审核员。判断「记录」是否真实可信(用户真的发送/写下的文字)。\n"
            f"记录:{text[:200]}\n"
            f"屏幕OCR片段({mode_note}){long_note}:{snip[:300] if snip else '(无帧证据)'}\n"
            f"击键串(用户物理按键,数字是IME选字):{keys[:300] if keys else '(未取到击键段)'}\n"
            "规则:OCR与记录一致,或OCR无证据但击键能支撑记录 → 只输出 PASS;"
            "OCR上明显是别的文字(记录是错字/幻觉/与屏幕矛盾)→ 输出 REJECT|OCR上看到的正确片段;"
            "证据矛盾无法判断 → 输出 UNSURE。只输出一行,不解释。")
    pr = tok14.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        o = re.sub(r'<think>.*?</think>', '', generate(m14, tok14, prompt=pr, max_tokens=64, verbose=False), flags=re.S).strip()
        line = cv((o.splitlines() or [''])[0])
        mm = re.search(r'\b(PASS|REJECT|UNSURE)\b', line.upper())
        verdict = mm.group(1) if mm else 'UNSURE'
        if verdict == 'REJECT':
            parts = re.split(r'[|｜:：]', line, 1)
            return 'REJECT', (parts[1].strip() if len(parts) > 1 else '')
        return verdict, ''
    except Exception:
        return 'UNSURE', ''

_PUNCT = re.compile(r'[\s，,。.!？?！…、:：;；"\'"“”‘’()（）]+')
def norm_t(t): return _PUNCT.sub('', (t or ''))
_CU = [None]
def pyseq(t):
    """文本 → 逐字符编码单元集序列(汉字→拼音集[多音字全收],ASCII→小写字母,标点跳过)。
    用于拼音空间查重:肯下来了 vs 啃下来了 同序列。零硬编码,来自部署词库(ime_schema)。"""
    if _CU[0] is None: _CU[0] = R.SCH.char_units()
    seq = []
    for ch in norm_t(t):
        if ch.isascii(): seq.append(frozenset([ch.lower()]))
        else: seq.append(_CU[0].get(ch, frozenset([ch])))
    return seq
def seq_in(a, b):
    """短序列 a 是否(逐位集合相交)是 b 的连续子串。"""
    if not a or len(a) > len(b): return False
    return any(all(a[j] & b[i + j] for j in range(len(a))) for i in range(len(b) - len(a) + 1))

RAW = {}   # day -> [(app, text, kc, evid, t0, t1)]
DROP = {}  # day -> [(闸口, app, text, evid, t0, t1, 原因)] —— 漏斗每道闸丢弃的全记录(审计)
C3FIX = {}  # day -> [(app, 原文, 修后, via, evid, t0)] —— 口3 修正审计(所有模型/OCR修改可复核)
PROOF = {}  # (evid, text) -> 模型重建的尾巴 —— 凡模型参与选字的尾巴,Phase1.5 强制 OCR 校对(的/得、哟/用一族)
PENDING = {}  # day -> [(app, text, src, evid, t0, 审核理由, OCR片段)] —— 未定区:审核未过,展示不入册(审核而非丢弃)
LEDGER_MODE = os.environ.get('LEDGER_MODE', 'gated')  # gated=B(账本须审核PASS才入册)/ off=A(账本禁用)/ raw=旧行为
for day in DAYS:
    dayrecs = []; drops = []; c3fix = []
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        if not ids: continue
        evs = X.loadev(ids)
        if not evs: continue
        kc = group_kc(ids); ks_full = assemble_keys(ids)
        grp = []
        for ev in evs:
            app = ev['bundle'].split('.')[-1]
            for text, t0, t1, is_send in R.event_sends_with_ts(ev, X):
                kw = R.keys_in_window(con, ev['bundle'], t0, t1)
                # 上下文 = 时间邻域(组内已重建的前几条,条间 gap>5min 截断),不再用旧 staged 全天
                ctx = f"app:{app}\n之前的消息:\n" + ctx_window([(g[4], g[1]) for g in grp], t0 or 0)
                fixed, rinfo = R.reconstruct_message(text, kw, context=ctx, model_fn=disambig)
                # 审计要求:event id + 时间窗 + bundle 随 record 全程传递(Pass4 丢弃标时间;击键账本对账)
                if cv(fixed):
                    grp.append((app, cv(fixed), is_send, ev['id'], t0, t1, ev['bundle']))
                    mt = ''
                    for li in rinfo.get('lines', []):
                        if li.get('reason') == 'rebuilt' and li.get('tail_text'): mt = li['tail_text']
                        elif li.get('reason') == 'residue' and li.get('han'): mt = li['han']
                    if mt: PROOF[(ev['id'], cv(fixed))] = mt   # 机器选的尾(TOP/14B 都算)→ 待校对
        total = sum(len(t) for _, t, *_ in grp)
        if total > 20 and kc < total // 4:                          # 组级击键 gate
            for a, t, s, evid, t0, t1, b in grp:
                drops.append(("组级击键gate", a, t, evid, t0, t1, f"组内容{total}字>击键{kc}×4,疑粘贴/预存"))
            continue
        kst = ks_full.replace("<CR>", "").replace("<BS>", "").strip()
        if kst.startswith("/"):                                     # slash gate
            for a, t, s, evid, t0, t1, b in grp:
                drops.append(("slash gate", a, t, evid, t0, t1, "组击键以/开头(命令输入)"))
            continue
        for app, t, s, evid, t0, t1, b in grp: dayrecs.append((app, t, s, kc, evid, t0, t1, b))
    # dedup_truncated(类4/5a)+ is_residue + 占位符 + 精确去重 —— 每道闸的丢弃都记审计
    drecs = R.dedup_truncated([(t, s, a) for a, t, s, *_ in dayrecs], X.cover)
    keepset = set((t, s, a) for t, s, a in drecs)
    out, seen = [], set()
    for app, t, s, kc, evid, t0, t1, b in dayrecs:
        if (t, s, app) not in keepset:
            drops.append(("dedup_truncated", app, t, evid, t0, t1, "截断态草稿,内容被更长记录覆盖"))
        elif is_residue(t):
            drops.append(("is_residue", app, t, evid, t0, t1, "纯残渣(无中文主体)"))
        elif X.is_ph(t):
            drops.append(("占位符", app, t, evid, t0, t1, "known 占位符"))
        elif t in seen:
            drops.append(("去重", app, t, evid, t0, t1, "同日重复文本"))
        else:
            seen.add(t); out.append((app, t, kc, evid, t0, t1, "ax_cleaned", b))
    # ===== 击键账本恢复(用户铁律:有击键就记录)=====
    # 零 AX 痕迹的 IME 秒发消息(挺不错的/说实话/ElevenLabs):汉字从没进 edit_log,只在击键流里。
    # 对账:全天该 bundle 的 <CR> 段(已消化退格),没被任何已有记录「文本+时间」双重消费的 → 纯击键重建。
    bundles = {} if LEDGER_MODE == 'off' else {b: a for a, t, s, kc, evid, t0, t1, b in dayrecs}
    for b, a in bundles.items():
        recs_b = [(t, t0, t1) for app2, t, s, kc, evid, t0, t1, b2 in dayrecs if b2 == b]
        rows = con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log "
                           "WHERE bundle_id=? AND strftime('%Y-%m-%d',ts_ms/1000,'unixepoch')=? ORDER BY ts_ms",
                           (b, day)).fetchall()
        segs, curseg, dirty = [], [], False
        for ts, c, bs, md in rows:
            if (md & 7) != 0: continue
            if bs:
                # 选字数字后的退格删的是**已上屏汉字**(1BS=1字),按字母弹会产生乱拼音(ninitian→你你天)
                # → 标脏段,整段跳过(宁缺毋错)
                if curseg and curseg[-1][1].isdigit(): dirty = True
                if curseg: curseg.pop()
                continue
            if not c: continue
            if c in ("\n", "\r"):
                if curseg: segs.append((curseg, dirty))
                curseg, dirty = [], False
            else:
                curseg.append((ts, c))
        # 尾段无 <CR> = 未发送,不收(草稿保护)
        for seg, is_dirty in segs:
            if is_dirty: continue
            st0, st1 = seg[0][0], seg[-1][0]
            s = ''.join(c for _, c in seg)
            if len(s) < 4: continue
            # 无选字数字(IME确认)且无≥4字母英文词:不敢解,跳过
            if not any(ch.isdigit() for ch in s) and not re.search(r'[A-Za-z]{4,}', s): continue
            fixed, _ = R.reconstruct_message('', s, model_fn=disambig)
            ft = cv(fixed)
            if len(ft) < 2 or not (R.has_han(ft) or re.search(r'[A-Za-z]{4,}', ft)):
                if len(s) >= 6:                       # 蒸发审计(诊断:guard回退静默吞掉说实话)
                    drops.append(("账本-解码蒸发", a, s[:60], None, st0, st1, "guard回退/解码过短"))
                continue
            # 消费判定(空格+标点归一,诊断:半角','vs全角'，'天然失配):文本被某记录包含 且 时间窗±3s → 已消费
            ftn = norm_t(ft)
            consumed = any(ftn in norm_t(rt) and st0 >= (rt0 or 0) - 3000 and st1 <= (rt1 or 0) + 3000
                           for rt, rt0, rt1 in recs_b)
            if consumed: continue
            if X.is_ph(ft) or is_residue(ft) or ft in seen:
                drops.append(("账本-过滤", a, ft[:60], None, st0, st1, "占位符/残渣/重复")); continue
            seen.add(ft)
            if LEDGER_MODE != 'off':
                out.append((a, ft, len(s), None, st0, st1, "keystroke_recovered", b))
    # ===== Phase1.5 口3:重建不确定的(残渣未清)drop 到此 =====
    # 此时全天消息已就位 → 有**下文**了(两遍式的时序红利)。
    # ① 确定性:OCR 锚定 + 击键 <CR> 段验证(零幻觉);② 还没修上 → 14B 双向语境重试(前文+后文)。
    recs_sorted = sorted(out, key=lambda r: (r[4] or r[5] or 0))
    timeline = [(r[4] or r[5], r[1]) for r in recs_sorted]
    out2 = []
    for i, rec in enumerate(recs_sorted):
        a, t, kc2, evid, t0, t1, src, b = rec
        m = R.LATIN_TAIL.search(t)
        needs = bool(m) and not R._is_eng_tail(m.group().strip())
        if not needs:
            # 干净文本但击键账大额未消费(H/I:尾巴整段没进 AX,文本无残渣)→ 也进口3
            seg0 = C3.keys_segment(b, t1 or t0 or 0)
            letters = len(re.sub(r'[^a-zA-Z]', '', seg0))
            need_est = sum(3 if not ch.isascii() else 1 for ch in cv(t))   # CJK≈3字母/字(拼音)
            needs = letters > need_est + 6
        mt = PROOF.get((evid, t), '')
        if not needs and not mt:
            out2.append(rec); continue
        u = None
        if evid:
            ur = con.execute("SELECT url FROM typing_events WHERE id=:i", {"i": evid}).fetchone()
            u = ur[0] if ur else None
        others = [r2[1] for j, r2 in enumerate(recs_sorted) if j != i and r2[7] == b]
        if needs:
            nt, info = C3.complete_tail(a, t, t1 or t0 or 0, C3.keys_segment(b, t1 or t0 or 0),
                                        url=u, other_texts=others)
            via = "口3-OCR"
        else:   # 机器选字尾 → OCR 校对(渲染事实覆盖模型选字:睡得→睡的)
            nt, info = C3.proofread_tail(a, t, mt, t1 or t0 or 0, C3.keys_segment(b, t1 or t0 or 0),
                                         url=u, other_texts=others)
            via = "口3-校对"
        if nt == t:                                      # OCR 没修上 → 双向语境重试 14B
            ctx2 = f"app:{a}\n邻近消息:\n" + ctx_window(timeline[:i], t0 or 0, after=timeline[i + 1:])
            kw2 = R.keys_in_window(con, b, t0, t1)
            nt, _ = R.reconstruct_message(t, kw2, context=ctx2, model_fn=disambig)
            via = "口3-双向语境"
        if cv(nt) and nt != t:
            c3fix.append((a, t, nt, via, evid, t0))
            out2.append((a, cv(nt), kc2, evid, t0, t1, src + "+c3", b))
        else:
            out2.append(rec)
    # ===== Phase1.75 审核(用户设计:审核而非丢弃,妙不可言版)=====
    # 审核员只有 PASS/打回权;打回 hint 须逐字过击键验证才采纳(写权在确定性链路);
    # 2 轮不过 → 未定区(文档展示,不入成品,绝不静默丢)。
    # 不对称:keystroke_recovered 须 PASS 才入册(B门控,治22条重复污染);ax 路 REJECT 才动(默认信 AX+击键)。
    pend = []; out3 = []
    for i, rec in enumerate(out2):
        a, t, kc2, evid, t0, t1, src_, b = rec
        u = None
        if evid:
            ur = con.execute("SELECT url FROM typing_events WHERE id=:i", {"i": evid}).fetchone()
            u = ur[0] if ur else None
        is_ledger = src_.startswith("keystroke_recovered")
        if LEDGER_MODE == 'raw':                           # raw=旧行为:无审核环(审查修:原先未实现)
            out3.append(rec); continue
        # 账本路(诊断修):referee PASS 对账本是循环论证(记录由击键生成,"击键支撑"恒真)→退出;
        # ① 拼音空间查重(肯/啃同音双胞胎,子串在汉字空间失配)+ 时间窗±10s
        # ② 入册唯一通道 = 确定性渲染全文命中(60s→300s 宽窗);锚不上 → 未定区展示(审核而非丢弃)
        if is_ledger:
            pa = pyseq(t)
            dup = next((r2[1] for r2 in out2 if not r2[6].startswith("keystroke_recovered") and r2[7] == b
                        and (seq_in(pa, pyseq(r2[1])) or seq_in(pyseq(r2[1]), pa))
                        and (t0 or t1 or 0) <= (r2[5] or 0) + 10000
                        and (t1 or t0 or 0) >= (r2[4] or 0) - 10000), None)
            if dup is not None:
                pend.append((a, t, src_, evid, t0, "账本副本(拼音空间重复)", cv(dup)[:80])); continue
            prev = (next((r3[1] for r3 in reversed(out3) if r3[7] == b), None)
                    or next((out2[j][1] for j in range(i - 1, -1, -1) if out2[j][7] == b), None))
            seg = C3.keys_segment(b, t1 or t0 or 0)
            tn0 = norm_t(t)[:60]
            hit = False
            for fw in (60, 300):
                sn, _ts, _md = C3.ocr_snippet(a, u, t, t1 or t0 or 0, prev_text=prev, seg=seg, fwd_s=fw)
                if tn0 and len(tn0) >= 2 and tn0 in re.sub(r'\s', '', sn or ''):
                    hit = True; break
            if hit:
                out3.append(rec)
            else:
                pend.append((a, t, src_, evid, t0, "账本解码未获渲染全文确证", ''))
            continue
        # 审核射程(用户裁定 2026-06-10):**只有 librime/14B 选过字的才走复查 LLM**——
        # 纯 AX 原文(机器没碰过字)= AX+击键双背书,错字风险不存在,免审直接入册
        # (误伤面归零 + referee 调用大降)。判据:PROOF 有模型尾 / 口3 修过(+c3/+rev)。
        machine_touched = bool(PROOF.get((evid, t), '')) or ('+c3' in src_) or ('+rev' in src_)
        if not machine_touched:
            out3.append(rec); continue
        # prev 锚优先用已审核的修后文本(out3),回退 out2(审查修)
        prev = (next((r3[1] for r3 in reversed(out3) if r3[7] == b), None)
                or next((out2[j][1] for j in range(i - 1, -1, -1) if out2[j][7] == b), None))
        seg = C3.keys_segment(b, t1 or t0 or 0)
        snip, _fts, smode = C3.ocr_snippet(a, u, t, t1 or t0 or 0, prev_text=prev, seg=seg)
        snipn = re.sub(r'\s', '', snip or '')
        tn0 = cv(t).replace(' ', '').replace('\n', '')[:60]
        # 确定性快速通道(审查修):渲染与记录逐字一致 → 免 14B 直接过(判定在确定性链路)
        if tn0 and len(tn0) >= 2 and tn0 in snipn:
            out3.append(rec); continue
        # ax 路 + 无任何帧证据:REJECT 不可能成立,免调用直接保留(审查修)
        if not snip and not is_ledger:
            out3.append(rec); continue
        v, hint = referee(t, snip, seg, mode=smode)
        if (v == 'PASS') if is_ledger else (v != 'REJECT'):
            out3.append(rec); continue
        # —— 第 2 轮 ——
        used_snip = snip
        fixed2 = None
        if v == 'REJECT' and hint:
            hn = cv(hint).replace(' ', '')
            # ⚠️critical 修:hint 必须真出现在 OCR 证据里(屏幕渲染锚死),否则审核员=间接写权
            if hn and hn in snipn:
                vt, consumed = C3.verify_tail(hint, seg)   # hint 指路,击键逐字验
                vtn = cv(vt).replace(' ', '')
                others = [r2[1].replace(' ', '').replace('\n', '') for j, r2 in enumerate(out2) if j != i and r2[7] == b]
                t_cmp = cv(t).replace(' ', '').rstrip('，。！？、…,.!? ')   # 标点同口径(审查修)
                han_v = sum(1 for ch in vtn if not ch.isascii())
                if (vtn and len(vtn) >= max(2, int(len(hn) * 0.8))
                        and len(vtn) >= len(t_cmp)                        # 不准变短
                        and consumed >= max(2, 2 * han_v)                 # 消费下限防标点凑数(审查修)
                        and not any(vtn in o for o in others)):           # 等值/包含一律拦,防重复(审查修)
                    fixed2 = vt
        if fixed2 is not None:
            v3, _ = referee(fixed2, snip, seg, mode=smode)               # 复审重修稿
            if (v3 == 'PASS') if is_ledger else (v3 != 'REJECT'):        # 不对称门一致化(审查修)
                c3fix.append((a, t, fixed2, "审核打回重修", evid, t0))
                out3.append((a, cv(fixed2), kc2, evid, t0, t1, src_ + "+rev", b)); continue
        if fixed2 is None:                                 # 第2轮:宽窗重取证复审(账本须PASS,ax须非REJECT)
            snip2, _f2, smode2 = C3.ocr_snippet(a, u, t, t1 or t0 or 0, prev_text=prev, seg=seg, fwd_s=300)
            if snip2 and snip2 != snip:
                used_snip = snip2
                v2, _ = referee(t, snip2, seg, mode=smode2)
                if (v2 == 'PASS') if is_ledger else (v2 != 'REJECT'):
                    out3.append(rec); continue
        clean_snip = re.sub(r'\s+', ' ', used_snip or '').replace('`', chr(180))[:120]   # 文档转义(审查修)
        pend.append((a, t, src_, evid, t0, (('OCR示:' + hint) if hint else v), clean_snip))
    RAW[day] = out3; DROP[day] = drops; C3FIX[day] = list(c3fix); PENDING[day] = pend
    print(f"  {day}: {len(out3)} 条(审核未定 {len(pend)};14b disambig 累计 {R.DISAMBIG_CALLS[0]})", flush=True)
EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval")   # 数据进项目,不用 /tmp
os.makedirs(EVAL, exist_ok=True)
json.dump(RAW, open(os.path.join(EVAL, "v2_rebuilt.json"), "w"), ensure_ascii=False)
del m14, tok14; gc.collect()
print(f"Phase1 完成,14b disambig 共调用 {R.DISAMBIG_CALLS[0]} 次", flush=True)

# ===== Phase 2: Pass4(固定逻辑;LLM 禁用 —— 用户指令:8B 误杀真消息)=====
# 只丢两类:邮箱(.com 结尾)/ 密码(连续 ≥6 个掩码符号 •●* 等)。其余全留。
print("=== Phase2: Pass4 固定逻辑(只滤 .com结尾 + 密码掩码;LLM 禁用)===", flush=True)
PW_MASK = re.compile(r'[•●○◦＊*]{6}')
def pass4_fixed(recs):
    kept, dropped = [], []
    for r in recs:
        t = (r[1] or '').strip()
        if t.lower().endswith('.com'):
            dropped.append((r, "邮箱(.com 结尾)")); continue
        if PW_MASK.search(t):
            dropped.append((r, "密码(连续≥6掩码符号)")); continue
        kept.append(r)
    return kept, dropped
FINAL = {}; DISCARDED = {}
for day in DAYS:
    kept, dropped = pass4_fixed(RAW[day])
    FINAL[day] = kept; DISCARDED[day] = dropped
    print(f"  {day}: {len(RAW[day])} → Pass4 后 {len(kept)}(丢 {len(dropped)})", flush=True)

# ===== 写 Obsidian 文档(含 Pass4 丢弃审计:丢了什么+为什么+event 时间)=====
import datetime
def fmt_ts(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime('%m-%d %H:%M:%S') if ms else '?'
CV = json.load(open(os.path.join(EVAL, "canvas_cloud.json")))
nd = ["# 新 pipeline·成品(阶段0 集成:librime + 14b disambig 重建)\n",
      "**全本地 IME 重建**:event_sends_with_ts(回车检测真发送)+ rebuild(librime 确定性打底 + 14b 同音消歧 + 残渣/击键调和)",
      "+ 组级击键 gate + slash gate + **dedup_truncated**(类4/5a 去截断态)+ is_residue + **8b Pass4**。Canvas=云端。\n",
      "⚠️ 已知小瑕疵(待修):的/得(睡得 vs 睡的)、librime 词库无的 slang(卖个惨)、H/I 截断尾巴、canvas 跨app尾巴。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    out = [(rec[6], rec[1], rec[0]) for rec in FINAL[day]] + [(r["source"], r["text"], r["app"]) for r in CV.get(day, [])]
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(out)}）\n")
    for i, (src, text, app) in enumerate(out, 1): nd.append(rec_md(i, src, kind_of(text), app, text))
    # 口3 修正审计:改了什么、怎么改的(OCR锚定/双向语境)
    cf = C3FIX.get(day, [])
    nd.append(f"\n### 🔧 口3 修正（{len(cf)}）\n")
    if not cf: nd.append("（无）\n")
    for a, old, new, via, evid, t0 in cf:
        nd.append(f"- `[{via}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}`\n  > {old[:120]!r} → **{new[:120]!r}**\n")
    # 未定区:审核未过的展示(用户原则:宁可记录对的,也不拿错的填;不确定的必须看得见)
    pd = PENDING.get(day, [])
    nd.append(f"\n### ⚠️ 未定区(审核未过,展示不入册)({len(pd)})\n")
    if not pd: nd.append("（无）\n")
    for a, t, src_, evid, t0, why, snip in pd:
        nd.append(f"- `[{src_}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}` — {why[:80]}\n  > "
                  + (t or '')[:200].replace('\n', '\n  > ')
                  + (f"\n  OCR证据:`{snip}`\n" if snip else "\n"))
    # 丢弃审计:漏斗每道闸 + Pass4,丢了什么 + 为什么 + event 时间
    dr = DROP.get(day, []); dd = DISCARDED.get(day, [])
    nd.append(f"\n### 🗑️ 丢弃审计（漏斗 {len(dr)} + Pass4 {len(dd)}）\n")
    if not dr and not dd: nd.append("（无）\n")
    for stage, a, t, evid, t0, t1, reason in dr:
        nd.append(f"- `[{stage}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}` — {reason}\n  > {(t or '')[:300]}\n")
    for (a, t, kc, evid, t0, t1, *_), reason in dd:
        nd.append(f"- `[Pass4]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)} → {fmt_ts(t1)}` — {reason or '(模型未给原因)'}\n  > {(t or '')[:300]}\n")
    nd.append("\n---\n")
path = "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-阶段0.md"
open(path, "w").write("\n".join(nd))
print(f"已写 {path}", flush=True)
