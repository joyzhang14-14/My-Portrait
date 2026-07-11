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
import ax_bearing as AXB          # 承载率判别(canvas_spans);一体化 canvas 判别用
import canvas_librime as CL       # canvas B 解码 + wrap_llm(共享主程序已加载的 14B)
import canvas_route as CR         # 一体化 canvas 构建(build_canvas:B+C 内联,不落 fusion 文件)
from enzh_double_return import double_return_eng, encode_keys   # 双 return 中文IME打英文判别(gmail案)
from mlx_lm import load, generate

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
# DAYS:PORTRAIT_DAYS 覆盖(逗号分隔);='all' → 库中全部有击键记录的天(UTC);默认原四天
_days_env = os.environ.get('PORTRAIT_DAYS')
if _days_env == 'all':
    DAYS = [r[0] for r in con.execute(
        "SELECT DISTINCT strftime('%Y-%m-%d', ts_ms/1000, 'unixepoch') FROM keystroke_log ORDER BY 1")]
elif _days_env:
    DAYS = _days_env.split(',')
else:
    DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
# 按天 decode(2026-07-11 一体化,替代「分两批各带一个 env」):<CUTOFF 旧采集需 librime 解拼音,
# ≥CUTOFF 新采集 AX 直给汉字。PORTRAIT_LIBRIME_DECODE 显式设置=全局强制(gold 复跑);未设=按天自动。
# 每天独立处理 → 单进程按天切 decode 与「分两批各自 env」逐字等价(每天拿到相同 decode 值)。
DECODE_CUTOFF = '2026-06-25'
_DECODE_ENV = os.environ.get('PORTRAIT_LIBRIME_DECODE')
def decode_for(day):
    if _DECODE_ENV is not None: return _DECODE_ENV == '1'
    return day < DECODE_CUTOFF
EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval")   # 数据进项目,不用 /tmp
CACHE = os.path.join(EVAL, 'v2cache')   # 分块可恢复(reaper 防丢):每天 Phase1 落盘,重启跳已算天
FRESH = os.environ.get('PORTRAIT_FRESH') == '1'   # 忽略缓存全重算
def _daycache_path(day): return os.path.join(CACHE, day + '.json')
def _daycache_read(day):
    p = _daycache_path(day)
    if FRESH or not os.path.exists(p): return None
    try:
        d = json.load(open(p)); return d['RAW'], d['DROP'], d['C3FIX'], d['PENDING']
    except Exception: return None
def _daycache_write(day, raw, drop, c3fix, pending):
    os.makedirs(CACHE, exist_ok=True); p = _daycache_path(day)
    json.dump({'RAW': raw, 'DROP': drop, 'C3FIX': c3fix, 'PENDING': pending},
              open(p + '.tmp', 'w'), ensure_ascii=False); os.replace(p + '.tmp', p)
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()

def literal_tail(ev, send_ts):
    """字面数字尾补全(ev1081「全球排32」案,AX 末尾采集丢字里**唯一无歧义**的子集)。
    时间对账:最后一个含汉字的成稿点(commit/submit)之后、发送之前的击键 = AX 漏记的尾巴。
    三道约束缺一不可(逐条都是踩坑踩出来的):
    ① **锚必须含汉字**:AX 会把未解码拼音残渣串也记成 commit(ev522「ji d」),拼音残渣
       commit 当锚会把其后选字数字误当字面尾;锚回退到真汉字后,残渣字母进窗口被②挡。
    ② **submit 也算成稿点**:「了」靠 submit 提交(ev1084),漏认会把「了」选字数字 1 误补。
    ③ **只补 ≥2 位纯数字**:IME 选字一次只按 1 位(1-9),连续 ≥2 位数字不可能是选字,
       必是字面(ev1081「32」)。单个数字尾有选字歧义,宁缺毋错不补;标点尾同理不补
       (实测重复补问号/句界误判)。全范围 250 发送实测:仅 ev1081 命中,零误补。"""
    arr = ev.get('arr') or []
    commit_ts = None
    for e in arr:
        if (e.get('kind') in ('commit', 'submit') and e.get('ts')
                and any('一' <= ch <= '鿿' for ch in cv(e.get('text') or ''))
                and (send_ts is None or e['ts'] <= send_ts)):
            commit_ts = e['ts']
    if commit_ts is None: return ''
    ks = con.execute("SELECT char, is_backspace FROM keystroke_log WHERE bundle_id=:b "
                     "AND (modifiers&7)=0 AND ts_ms > :a AND ts_ms <= :c ORDER BY ts_ms",
                     {"b": ev['bundle'], "a": commit_ts, "c": send_ts or commit_ts}).fetchall()
    buf = []
    for c, bs in ks:
        if bs:
            if buf: buf.pop()
        elif c and c not in ('\r', '\n'):
            buf.append(c)
    s = ''.join(buf).strip()
    return s if s.isdigit() and len(s) >= 2 else ''

# 密码掩码判定(2026-06-12 用户裁定):宽枚举掩码字形 + 私用区(loginwindow 实测 U+F79A)。
# 不用"无字母汉字"一刀切:(> -) 颜文字是真表达;假名/谚文/阿拉伯文等任何语言不当符号。
MASK_CHARS = set('•●○◦∙⋅・⬤⚫⚪🞄＊*※⁕▪▫■□◼◻●')
def is_mask(t, n=4):
    c = cv(t).replace(' ', '')
    return len(c) >= n and all(ch in MASK_CHARS or '\ue000' <= ch <= '\uf8ff' for ch in c)
def is_image_only(t):
    """独立图占位符:文本只由 U+FFFC(cmd+v 粘贴 / 点选的图、贴纸)组成、无文字内容 → 排除。
    用户裁定 2026-06-29:**只动独立图**——不剥真消息里的 \ufffc 前缀(ev647 \ufffc\ufffc全自动化…照旧)、
    也不碰 @提及(AX 拿不到 @名字,先不管)。"""
    c = re.sub(r'\s', '', cv(t))
    return bool(c) and set(c) == {'\ufffc'}
def _retyped(b, t0, t1, txt, floor=0):
    """本条时间窗内有没有用户「自己敲的键」(≥字数)= 是不是又打了一遍。**只管击键**——
    「同事件 submit+endValue」共享同一批击键、这里也会返 True,靠**调用处 `evid` 不等**才拦掉;
    真重发 = 不同事件 且 _retyped;采集副本(无键 re-render)n≈0,丢。用户裁定 2026-06-30。
    floor=首见记录的 t1(2026-07-07 审计修):re-render 副本紧贴原发送(gap≈0),-1000ms 回扫会把
    **原消息末秒的真击键**算到副本头上(买个mac/www 双份入册实证)——重打的键必须晚于首见记录结束,
    窗口起点钳到 floor 之后;真重发(隔秒/分钟再打)键都在自己窗内,不受影响。"""
    n = con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=:b AND ts_ms BETWEEN :a AND :c "
                    "AND is_backspace=0 AND char IS NOT NULL AND (modifiers&7)=0",
                    {"b": b, "a": max((t0 or 0) - 1000, (floor or 0) + 1), "c": (t1 or 0) + 500}).fetchone()[0]
    return n >= max(1, len(cv(txt)))   # ≥1键/字:单字重打(「?」1键)也算真重发;采集副本 n≈0 拦掉

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
def double_return_literal(bundle, t0, t1, residue_text):
    """双 return 英文修复(gmail 案,2026-06-13,用户主导)。中文输入法下打英文 =
    字母 + return(把组合区上屏成字面)+ return(发送)= 双 return;第一个回车只上屏不发送。
    残渣记录的击键窗里若有「拉丁 run + <CR><CR>」且该英文词(去空格小写)== 残渣字母 →
    **直接用击键字面替换**(零 LLM,击键 g-m-a-i-l 就是字面)。只命中 ~residue 且精确匹配
    双 return 的记录 → 天然「不影响其他结果」(纯拼音用选字数字/空格,无双回车,零误抓已验)。
    两路(与 eng_literals_of 同口径):① 双 return(历史 input_source=NULL,靠双回车指纹);
    ② input_source(新采集):拉丁 run 全在 keylayout(英文键盘)= 字面,单回车也认。
    历史数据 input_source=NULL → 路②的 all(keylayout) 恒 False,只走路①,零回归。"""
    letters = re.sub(r'[^a-z]', '', (residue_text or '').lower())
    if len(letters) < 2: return None
    rows = con.execute("SELECT char, is_backspace, input_source FROM keystroke_log WHERE bundle_id=:b "
                       "AND ts_ms BETWEEN :a AND :c AND (modifiers&7)=0 ORDER BY ts_ms",
                       {"b": bundle, "a": (t0 or 0) - 2000, "c": (t1 or 0) + 2000}).fetchall()
    for w in double_return_eng(encode_keys([(c, bs) for c, bs, _ in rows])):  # 路①双 return
        if w.lower() == letters: return w
    buf = []  # 路②:input_source=keylayout 的拉丁 run(单回车也认),run 内全 keylayout 才算字面
    for c, bs, isrc in rows:
        if bs:
            if buf: buf.pop()
        elif c and c.isalpha():
            buf.append((c, bool(isrc and isrc.startswith('com.apple.keylayout'))))
        else:
            if buf and all(kl for _, kl in buf) and ''.join(x for x, _ in buf).lower() == letters:
                return ''.join(x for x, _ in buf)
            buf = []
    if buf and all(kl for _, kl in buf) and ''.join(x for x, _ in buf).lower() == letters:
        return ''.join(x for x, _ in buf)
    return None

def eng_literals_of(bundle, t0, t1):
    """事件击键窗里「英文字面」拉丁 run 集合(小写去空格),传给 reconstruct guard 防过度解码
    (em→恶魔,2026-06-16 用户裁定)。两路并集,保历史又解未来:
      ① 双 return(历史数据 input_source=NULL):拉丁 run + <CR><CR> = 中文输入法打的英文字面;
      ② input_source(新采集):拉丁 run 击键全在 keylayout(英文键盘)= 字面;
         inputmethod(拼音 IME)下不收 → ni/wo 等2字母拼音照常解码。"""
    rows = con.execute("SELECT char, is_backspace, input_source FROM keystroke_log WHERE bundle_id=:b "
                       "AND ts_ms BETWEEN :a AND :c AND (modifiers&7)=0 ORDER BY ts_ms",
                       {"b": bundle, "a": (t0 or 0) - 2000, "c": (t1 or 0) + 2000}).fetchall()
    lits = set()
    for w in double_return_eng(encode_keys([(c, bs) for c, bs, _ in rows])):  # 路①
        lits.add(w.lower())
    buf = []  # 路②:[(char, 是否keylayout)],run 内全 keylayout 才算字面
    def flush():
        if buf and all(kl for _, kl in buf): lits.add(''.join(c for c, _ in buf).lower())
        buf.clear()
    for c, bs, isrc in rows:
        if bs:
            if buf: buf.pop()
        elif c and c.isalpha():
            buf.append((c, bool(isrc and isrc.startswith('com.apple.keylayout'))))
        else:
            flush()
    flush()
    return lits

def is_slash_command(t):
    """Discord 斜杠命令(/play /s /stop + 自动补全 UI '/cmd … +N more')不是消息(v22,类5)。
    只命中首段=/字母(命令形态);文件路径 /Users/… 首段含 / 分隔不 fullmatch,天然不中。"""
    s = cv(t).lstrip()
    if not s.startswith('/'): return False
    head = (s.split() or [''])[0]
    return bool(re.fullmatch(r'/[a-zA-Z]{1,20}', head)) and (
        len(cv(s)) <= 30 or 'more' in s or '\n' in (t or '') or 'url' in s.lower())

def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"

# ===== Phase 1: 重建(14b disambig) =====
# 14B 消费者:AX 路 disambig(仅 decode 天经 decode_run 调)+ referee(仅 REVIEW_MODE!=det)+
# 一体化 canvas(B 的 OCR 纠错 + C 的 canvas_merge)。三者都不需要 → 跳过加载省 8G 显存,不抢 GPU。
# 精细化:已缓存的天不需模型;canvas 有固定源(PORTRAIT_CANVAS)或已缓存也不需 → 恢复跑不白加载。
CANVAS_SRC = os.environ.get('PORTRAIT_CANVAS')       # 显式=用固定源(gold 复跑固定 essay);未设=内联一体化构建
CANVAS_INLINE = not CANVAS_SRC
REVIEW_MODE_ENV = os.environ.get('REVIEW_MODE', 'det')
_CANVAS_CACHE = os.path.join(CACHE, '_canvas.json')
def _has_canvas():
    for day in DAYS:
        (t0,) = con.execute("SELECT strftime('%s', :d)*1000", {"d": day}).fetchone()
        (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day')*1000", {"d": day}).fetchone()
        if AXB.canvas_spans(con, int(t0), int(t1)): return True
    return False
_pending_days = DAYS if FRESH else [d for d in DAYS if not os.path.exists(_daycache_path(d))]
_canvas_cached = (not FRESH) and (bool(CANVAS_SRC) or os.path.exists(_CANVAS_CACHE))
NEED_MODEL = (bool(_pending_days) and (any(decode_for(d) for d in _pending_days) or REVIEW_MODE_ENV != 'det')) \
    or (CANVAS_INLINE and not _canvas_cached and _has_canvas())
if NEED_MODEL:
    print("=== Phase1: 加载 14b(AX 重建 + 一体化 canvas 共享同一模型)===", flush=True)
    m14, tok14 = load("mlx-community/Qwen3-14B-4bit")
else:
    print("=== Phase1: 无 decode 天/无 canvas 需模型 且 REVIEW_MODE=det → 跳过加载 14b ===", flush=True)
    m14 = tok14 = None
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

# 渐进 IME 草稿态折叠(2026-06-29):未发送草稿逐字打的进度态(zhe y/这样d/这样的dui ma/这样的对吗?)
# 跨拼音↔汉字态对不上,seq_in 也治不了(逐字符 ascii vs 逐音节 / 简拼声母 d vs 全拼 de)。
# 故拍平成**字母串**比前缀(简拼天然免疫:zheyangd 是 zheyangde… 的前缀;也免口3时序——
# 这样的dui ma 与 这样的对吗 拼音相同,拼音空间里压根不分先后口3)。
def _py_letters(text, cap=512):
    """text → 所有可能的拼音/字面平铺串(小写;标点空格跳过;汉字按多音字展开;短文本枚举)。
    多音字爆炸(>cap)返回 None(交由上层当不匹配,宁缺毋错)。"""
    if _CU[0] is None: _CU[0] = R.SCH.char_units()
    cu = _CU[0]
    res = ['']
    for ch in norm_t(text).lower():
        if ch.isascii():
            res = [r + ch for r in res]
        else:
            res = [r + u for r in res for u in (cu.get(ch) or (ch,))]
        if len(res) > cap: return None
    return [r for r in res if r]

def _py_prefix(a_text, b_text):
    """a 的拼音平铺是否为 b 的拼音平铺**前缀**(多音字回溯 + 简拼/混合态免疫;空 a 返 False)。"""
    if _CU[0] is None: _CU[0] = R.SCH.char_units()
    cu = _CU[0]
    bt = norm_t(b_text).lower()
    cand = _py_letters(a_text)
    if not cand: return False
    def walk(i, s):
        if not s: return True               # a 字母全消费 = 前缀成立(不要求 b 走完)
        if i >= len(bt): return False        # b 走完但 a 还有 → 不是前缀
        ch = bt[i]
        if ch.isascii():
            return s.startswith(ch) and walk(i + 1, s[1:])
        for u in cu.get(ch, (ch,)):
            if s.startswith(u):
                if walk(i + 1, s[len(u):]): return True
            elif u.startswith(s):            # 简拼:s 是该音节前缀(a 末段)→ a 整体已是前缀
                return True
        return False
    return any(walk(0, af) for af in cand)

def _completeness(text, ts):
    """草稿「完整度」排序键:(拼音字母总长, 汉字数, 时刻)。
    拼音字母长=内容量同口径(这样的dui ma 与 这样的对吗 同为14,不被拼音残渣的字符数骗);
    平局取汉字多者(更解码)、再取更晚者(更接近最终输入)。"""
    cand = _py_letters(text)
    plen = max((len(c) for c in cand), default=0) if cand else len(norm_t(text))  # 长文多音字爆炸 cand=None → 字数兜底
    han = sum(1 for c in norm_t(text) if not c.isascii())
    return (plen, han, ts or 0)

RAW = {}   # day -> [(app, text, kc, evid, t0, t1)]
DROP = {}  # day -> [(闸口, app, text, evid, t0, t1, 原因)] —— 漏斗每道闸丢弃的全记录(审计)
C3FIX = {}  # day -> [(app, 原文, 修后, via, evid, t0)] —— 口3 修正审计(所有模型/OCR修改可复核)
PROOF = {}  # (evid, text) -> 模型重建的尾巴 —— 凡模型参与选字的尾巴,Phase1.5 强制 OCR 校对(的/得、哟/用一族)
PENDING = {}  # day -> [(app, text, src, evid, t0, 审核理由, OCR片段)] —— 未定区:审核未过,展示不入册(审核而非丢弃)
REVIEW_MODE = os.environ.get('REVIEW_MODE', 'det')  # det=确定性OCR对证(2026-06-14用户裁定默认,明显优于llm) / llm=referee复查(已退役,可env切回对照)
LEDGER_MODE = os.environ.get('LEDGER_MODE', 'narrow')  # 2026-06-12 用户裁定开窄账本(之类的案:零AX痕迹纯击键消息):
# narrow=窄射程(双回车包夹+选字数字+无脏退格+秒发≤10s)+入册唯一通道渲染确证,确证不过进丢弃审计不刷未定区;
# off=2026-06-10 A裁定(全量账本~50%垃圾已废除);gated/raw 留档可切。
# 击键只做 AX 修复辅助;gated/raw 代码留档可切
SLASH_GATE = os.environ.get('PORTRAIT_SLASH_GATE', '1') == '1'  # 斜杠命令过滤(全局开关,2026-06-30:app无关,前端可关)
KC_GATE = os.environ.get('PORTRAIT_KC_GATE', '1') == '1'        # 组级击键gate(kc比例判粘贴);关=改用直接 paste 信号(粘贴政策)判粘贴
for day in DAYS:
    cached = _daycache_read(day)
    if cached is not None:
        RAW[day], DROP[day], C3FIX[day], PENDING[day] = cached
        print(f"  {day}: 缓存命中,跳过 Phase1({len(RAW[day])} 条)", flush=True); continue
    R.DECODE_LIBRIME = decode_for(day)   # 按天切 decode(旧采集 librime 解拼音 / 新采集 AX 直给汉字)
    dayrecs = []; drops = []; c3fix = []
    # 自家分组(2026-06-12:staged 表被外部清空,遗留依赖被迫了断——本来就是移植前必做项):
    # 同 bundle + 时间链(下一事件 started_at 距上一事件 ended_at ≤10min 连桶)。
    # 桶只服务组级击键gate/slash gate/组级commit流取证,对边界容错高;已知案例逐一推演无害
    # (612-618 与 622-633 gap 22min 正确分桶;1142/1143 并桶不影响幻影/折叠判定——皆 DB 直查)。
    day_groups = []
    for (b_,) in con.execute("SELECT DISTINCT bundle_id FROM typing_events "
                             "WHERE strftime('%Y-%m-%d',started_at/1000,'unixepoch')=:d ORDER BY bundle_id", {"d": day}).fetchall():
        evrows = con.execute("SELECT id, started_at, ended_at FROM typing_events "
                             "WHERE bundle_id=:b AND strftime('%Y-%m-%d',started_at/1000,'unixepoch')=:d "
                             "ORDER BY started_at", {"b": b_, "d": day}).fetchall()
        cur, last_end = [], None
        for eid, st_, en_ in evrows:
            if cur and last_end is not None and (st_ or 0) - last_end > 10 * 60 * 1000:
                day_groups.append(cur); cur = []
            cur.append(eid); last_end = max(last_end or 0, en_ or st_ or 0)
        if cur: day_groups.append(cur)
    for ids in day_groups:
        evs = X.loadev(ids)
        if not evs: continue
        kc = group_kc(ids); ks_full = assemble_keys(ids)
        grp_cs = ''.join(X.cstream(e['arr']) for e in evs)   # 组级commit流:发送清空快照跨事件手打取证(#40)
        sends_raw = []
        for ev in evs:
            for text, t0, t1, is_send in R.event_sends_with_ts(ev, X, group_cs=grp_cs):
                sends_raw.append([ev, text, t0, t1, is_send])
        # 回车背书升格(ev1174 jeff chang案,用户证实网页Gemini真发送):endValue短草稿(≤20字,L7射程)
        # 条件A:事件收尾紧跟裸回车(晚于末笔编辑150ms+;IME确认回车必伴随commit,天然排除)。
        # 条件B(yo案 ev1133,2026-06-11,用户证实真发送):AX时间不可信(迟到的'y' commit比物理
        # 发送晚4.4s,把ended_at拖后,真回车反而在窗外)→ 纯击键判据:事件击键span内**最后一个
        # 回车是终态**(其后无任何键)且**紧邻其前是选字数字**(≤2s;数字选字已清空组合区,
        # 该回车不可能是IME确认,只能是发送)。只收窄到L7射程:长文endValue升格会让同消息
        # 过期中间态以真发送身份入册(ev1152/1153实测),不做。降级环在后,可否决误升。
        for sr in sends_raw:
            ev, text, t0, t1, s = sr
            if s or len(cv(text)) > 20: continue
            last_ts = max((e['ts'] for e in ev['arr'] if e.get('ts')), default=t0 or 0)
            cr = con.execute("SELECT 1 FROM keystroke_log WHERE bundle_id=:b AND char IN (char(10),char(13)) "
                             "AND is_backspace=0 AND (modifiers&7)=0 AND ts_ms BETWEEN :a AND :c AND ts_ms >= :d LIMIT 1",
                             {"b": ev['bundle'], "a": (t1 or 0) - 1000, "c": (t1 or 0) + 2500, "d": last_ts + 150}).fetchone()
            if not cr:
                ks = con.execute("SELECT ts_ms, char, is_backspace FROM keystroke_log WHERE bundle_id=:b "
                                 "AND (modifiers&7)=0 AND ts_ms BETWEEN :a AND :c ORDER BY ts_ms",
                                 {"b": ev['bundle'], "a": (t0 or 0) - 2000,
                                  "c": (ev.get('ended_at') or t1 or 0) + 2500}).fetchall()
                ks = [(kts, kc, kbs) for kts, kc, kbs in ks if kbs or kc]
                if (len(ks) >= 2 and not ks[-1][2] and ks[-1][1] in ('\r', '\n')
                        and not ks[-2][2] and (ks[-2][1] or '').isdigit()
                        and ks[-1][0] - ks[-2][0] <= 2000):
                    cr = True
            # 框清空否决(2026-06-29,这样的对吗?案):升格只认回车击键,会误升**表单内逐字 IME 态**
            # ——textarea 里回车是换行不是发送,每段 endValue 都带 \n 被全升成发送(zhe y/这样d/
            # 这样的dui ma/这样的对吗?)。真发送后框清空、同 element 不再延续;故查同 element_hash 60s 内
            # 后续事件 value 是否**拼音延续**本段(_py_prefix 治 d/的 字符串对不上)→ 延续=框没清=非真发送,
            # 不升格(保持 ~draft,交渐进草稿态折叠归并)。jeff chang 等真发送框会清、value 不延续 → 照常升格。
            if cr:
                nxt = con.execute(
                    "SELECT t2.end_value FROM typing_events t1 JOIN typing_events t2 "
                    "ON t2.element_hash = t1.element_hash AND t2.element_hash IS NOT NULL "
                    "WHERE t1.id=:i AND t2.id != t1.id "
                    "AND t2.started_at > t1.ended_at AND t2.started_at <= t1.ended_at + 60000",
                    {"i": ev['id']}).fetchall()
                if any(w and _py_prefix(cv(text), cv(w)) for (w,) in nxt):
                    cr = False   # 框没清(value 延续)= 误升,否决
            if cr: sr[4] = True
        # 幻影发送降级(案 vos/vcd ev616=假submit / 关SIP ev1148=假delete快照):"发送"后框内容仍在——
        # 同bundle 60s内后续事件(DB直查,不受staged分组限制)endValue 原样延续该文本为前缀、
        # 且其 commit 流没重打过(cover<0.5,非重发)→ 框从没清过 = AX事件切分/重渲染幻影,
        # 非真发送,降级草稿(dedup 会归并进真终稿)。submit 不豁免(ev616实证假submit存在;
        # 真submit如ev633靠证人测试天然安全:真发送清空框,后续事件不可能原样延续未重打)。
        # 前缀<10字不动(保护"好的"类短消息真发送);不用同事件endv相等判(真发送事件常恰好
        # 收在发送瞬间,endv来不及清,会误杀)。
        for sr in sends_raw:
            ev, text, t0, t1, s = sr
            if not s: continue
            pre = cv(R.LATIN_TAIL.sub('', text)).replace('\n', '')
            if len(pre) < 10: continue
            wits = con.execute("SELECT end_value, edit_log FROM typing_events WHERE bundle_id=:b "
                               "AND started_at > :a AND started_at <= :a2 ORDER BY started_at",
                               {"b": ev['bundle'], "a": t1 or 0, "a2": (t1 or 0) + 60000}).fetchall()
            for w_endv, w_el in wits:
                e2v = cv(w_endv).replace('\n', '')
                try: w_arr = json.loads(w_el or '[]')
                except: w_arr = []
                if e2v.startswith(pre) and X.cover(pre, X.cstream(w_arr)) < 0.5:
                    sr[4] = False; break
        grp = []
        for ev, text, t0, t1, is_send in sends_raw:
            app = ev['bundle'].split('.')[-1]
            kw = R.keys_in_window(con, ev['bundle'], t0, t1)
            engl = eng_literals_of(ev['bundle'], t0, t1)   # 英文字面 run(双return/input_source)防过度解码
            # 上下文 = 时间邻域(组内已重建的前几条,条间 gap>5min 截断),不再用旧 staged 全天
            ctx = f"app:{app}\n之前的消息:\n" + ctx_window([(g[4], g[1]) for g in grp], t0 or 0)
            fixed, rinfo = R.reconstruct_message(text, kw, context=ctx, model_fn=disambig, eng_literals=engl)
            # 审计要求:event id + 时间窗 + bundle 随 record 全程传递(Pass4 丢弃标时间;击键账本对账)
            if cv(fixed):
                fx = cv(fixed)
                lt = literal_tail(ev, t1)                 # 字面数字/标点尾补全(全球排32案)
                if lt and not fx.endswith(lt): fx += lt
                grp.append((app, fx, is_send, ev['id'], t0, t1, ev['bundle']))
                mt = ''
                for li in rinfo.get('lines', []):
                    if li.get('reason') == 'rebuilt' and li.get('tail_text'): mt = li['tail_text']
                    elif li.get('reason') == 'residue' and li.get('han'): mt = li['han']
                if mt: PROOF[(ev['id'], fx)] = mt   # 机器选的尾(TOP/14B 都算)→ 待校对
        total = sum(len(t) for _, t, *_ in grp)
        if KC_GATE and total > 20 and kc < total // 4:              # 组级击键 gate(KC_GATE 关=改用直接 paste 信号)
            # 逐条复检(XPC案,2026-06-12:自家分组并桶后大粘贴拖累手打小消息整桶连坐)——
            # gate 触发只定性"桶内有非手打",去留逐条判:条文本对桶 commit 流 cover≥0.5(手打)留。
            kept_g = []
            for a, t, s, evid, t0, t1, b in grp:
                ok = len(cv(t)) <= 20 or X.cover(cv(t), grp_cs) >= 0.5
                if not ok and len(cv(t)) <= 120:
                    # 击键fallback(header案ev664,2026-06-12):IME整句上屏被AX记成paste,commit流
                    # 只剩'header'6字cover=0.29冤杀;击键流拼音完整 → 简拼下界闸(字母≥汉字+ascii)背书
                    letters_t = len(re.sub(r'[^a-zA-Z]', '', R.keys_in_window(con, b, t0, t1)))
                    need_t = sum(1 for ch in cv(t) if not ch.isascii()) + len(re.sub(r'[^a-zA-Z]', '', cv(t)))
                    ok = letters_t >= need_t
                if ok:
                    kept_g.append((a, t, s, evid, t0, t1, b))
                elif len(cv(t)) <= 120:
                    drops.append(("组级击键gate", a, t, evid, t0, t1, f"组内容{total}字>击键{kc}×4,条cover<0.5,疑粘贴/预存"))
                # >120字的大块非手打(Xcode/Obsidian预存文档):静默忽略,不刷审计(用户指令 2026-06-12,仿v14)
            grp = kept_g
            if not grp: continue
        kst = ks_full.replace("<CR>", "").replace("<BS>", "").strip()
        if SLASH_GATE and kst.startswith("/"):                      # slash gate(全局开关)
            for a, t, s, evid, t0, t1, b in grp:
                drops.append(("slash gate", a, t, evid, t0, t1, "组击键以/开头(命令输入)"))
            continue
        for app, t, s, evid, t0, t1, b in grp: dayrecs.append((app, t, s, kc, evid, t0, t1, b))
    # dedup_truncated(类4/5a)+ is_residue + 占位符 + 精确去重 —— 每道闸的丢弃都记审计
    # 传发送时刻 ts 进 dedup:等长条款限 5min 窗(2026-07-07 审计修,stage1/stage2 误杀案)
    drecs = R.dedup_truncated([(t, s, a, (t1 or t0 or 0)) for a, t, s, kc, evid, t0, t1, b in dayrecs], X.cover)
    keepset = set((t, s, a) for t, s, a, _ts in drecs)
    out, seen = [], {}   # seen: 文本 → (首条 evid, 首条 t1)(判真重发 vs 采集副本;t1 给 _retyped 当击键下界)
    for app, t, s, kc, evid, t0, t1, b in dayrecs:
        if (t, s, app) not in keepset:
            drops.append(("dedup_truncated", app, t, evid, t0, t1, "截断态草稿,内容被更长记录覆盖"))
        elif X.is_ph(t):
            drops.append(("占位符", app, t, evid, t0, t1, "known 占位符"))
        elif is_image_only(t):
            drops.append(("独立图", app, "(图片/贴纸)", evid, t0, t1, "独立图占位符 U+FFFC,无文字内容"))
        elif is_mask(t):
            # 用户裁定 2026-06-12:≥4掩码字符 → 数据层直接丢(loginwindow实测PUA U+F79A)。
            # 宽枚举掩码集+PUA范围;不用"无字母汉字"一刀切(会误杀(> -)颜文字;假名/谚文/
            # 阿拉伯文也不能当符号——语言判据一律用Unicode属性,不限死码点)
            drops.append(("密码掩码", app, "(内容已过滤)", evid, t0, t1, "掩码字符≥4(密码框)"))
        elif SLASH_GATE and is_slash_command(t):
            drops.append(("slash命令", app, t, evid, t0, t1, "斜杠命令/补全UI(非消息)"))
        elif t in seen and not (evid != seen[t][0] and _retyped(b, t0, t1, t, floor=seen[t][1])):
            # 同文本:同事件副本(submit+endValue)或无新击键的 re-render → 丢;
            # 不同事件且用户又敲了一遍 → 真重发,落到 else 保留(最大保留)。
            # floor=首见 t1:副本窗不回扫进原消息的击键(买个mac/www 双份案,2026-07-07)
            drops.append(("去重", app, t, evid, t0, t1, "同事件/无重打的采集副本"))
        else:
            # 残渣不丢改标记(用户裁定 2026-06-11:ok/okay/oki 是语气表达,先标记入册);
            # 顺带清旧账 L1:残渣保留后自动进口3,有 OCR 找回真身的机会(记得案当年死在丢弃)
            seen[t] = (evid, t1)
            # 单字草稿 = delete 孤儿残渣(rebuild 已按事件内结构判别,只有本事件无 commit/产出的孤儿才到这里)
            # → 标 ~residue 进未定区;is_send=True 的单字发送(6/额/哈)不标,是真消息。
            lone_char = (not s) and len(cv(t)) == 1
            src = "ax_cleaned" + ("" if s else "~draft") + ("~residue" if (is_residue(t) or lone_char) else "")
            out.append((app, t, kc, evid, t0, t1, src, b))
    # 残渣副本去重(jeff chang 案,2026-06-11):~residue 的字母串与 ±10s 同bundle 邻条的
    # 拼音平铺全等(多音字按词库全集回溯)→ 过期预上屏快照,真身胜,丢给审计。
    # ev1173 'jeff chang shi shei'(IME 还没上屏的 AX 泄漏)vs ev1174 'jeff chang 是谁?'(上屏后)。
    def _py_flat_eq(letters, text2):
        if _CU[0] is None: _CU[0] = R.SCH.char_units()
        cu = _CU[0]
        tgt = [c for c in norm_t(text2).lower() if c.isalnum() or not c.isascii()]
        def walk(i, s):
            if i == len(tgt): return s == ''
            ch = tgt[i]
            if ch.isascii():
                return s.startswith(ch) and walk(i + 1, s[1:])
            for u in cu.get(ch, ()):
                if s.startswith(u) and walk(i + 1, s[len(u):]): return True
            return False
        return bool(letters) and walk(0, letters)
    out_f = []
    for rec in out:
        a_, t_, kc_, evid_, t0_, t1_, src0, b_ = rec
        if '~residue' in src0:
            # 双 return 英文(gmail 案,2026-06-13):残渣击键窗有「拉丁 run+<CR><CR>」且英文词
            # ==残渣字母 → 字面替换(零 LLM)。只命中 ~residue 精确匹配的记录,不影响其他;
            # 改后记 C3FIX 审计可追溯。命中即定稿,跳过下游残渣副本去重/草稿折叠。
            eng = double_return_literal(b_, t0_, t1_, t_)
            if eng:
                c3fix.append((a_, t_, eng, "双return英文", evid_, t0_))
                out_f.append((a_, eng, kc_, evid_, t0_, t1_, src0.replace('~residue', ''), b_))
                continue
            letters = re.sub(r'[^a-z]', '', t_.lower())
            twin = None
            if len(letters) >= 4:
                twin = next((r2 for r2 in out if r2 is not rec and r2[7] == b_ and '~residue' not in r2[6]
                             and abs((r2[4] or r2[5] or 0) - (t0_ or t1_ or 0)) <= 10000
                             and _py_flat_eq(letters, r2[1])), None)
            if twin is not None:
                drops.append(("残渣副本", a_, t_, evid_, t0_, t1_, f"拼音与真身重复:{cv(twin[1])[:30]}")); continue
        # 中间态草稿折叠(ev1143 那个输入法我hen bu x 案,2026-06-11):~draft 与同bundle
        # 15min内后续真发送共享长前缀(≥max(10,草稿norm一半))→ 同一消息的中间快照
        # (中段被用户删改,cover<0.8 漏过 dedup_truncated),按最终输入原则折叠,丢审计。
        if '~draft' in src0:
            tn0 = norm_t(t_)
            need = max(10, len(tn0) // 2)
            if len(tn0) >= 10:
                fin = next((r2 for r2 in out if r2 is not rec and r2[7] == b_ and '~draft' not in r2[6]
                            and (r2[5] or r2[4] or 0) >= (t1_ or t0_ or 0) - 1000
                            and (r2[5] or r2[4] or 0) - (t1_ or t0_ or 0) <= 15 * 60 * 1000
                            and norm_t(r2[1])[:need] == tn0[:need]), None)
                if fin is not None:
                    drops.append(("中间态草稿", a_, t_, evid_, t0_, t1_,
                                  f"与后续真发送共享前缀(中段被改写):{cv(fin[1])[:30]}")); continue
            # 删除证据折叠(2026-07-10 用户指认「我有一个app目前,是专门记录」案:ev876 明明记着
            # delete'，是专门记录',却因共享前缀 9<10 差 1 字不折——编辑历史是硬证据,长度只是启发式):
            # 草稿 D=P+S,后续非草稿记录以 P 开头(P≥4),S 的删除在两者之间的 edit_log 里**原文有案**
            # (单条 delete 文本包含 norm(S),不拼碎片防散字符巧合)→ 同一次写作的中间态,折叠。
            fin2 = None
            for r2 in out:
                if r2 is rec or r2[7] != b_ or '~draft' in r2[6]: continue
                rt = (r2[5] or r2[4] or 0)
                if not ((t1_ or t0_ or 0) - 1000 <= rt <= (t1_ or t0_ or 0) + 15 * 60 * 1000): continue
                rn = norm_t(r2[1])
                k = 0
                while k < min(len(tn0), len(rn)) and tn0[k] == rn[k]: k += 1
                if k < 4 or k >= len(tn0): continue   # 前缀太短没意义;D 是纯前缀归 dedup_truncated 管
                S = tn0[k:]
                if len(S) < 2: continue
                for (elog2,) in con.execute(
                        "SELECT edit_log FROM typing_events WHERE bundle_id=:b AND started_at>=:a AND started_at<=:c",
                        {"b": b_, "a": (t0_ or t1_ or 0) - 1000, "c": rt + 1000}):
                    try: arr2 = json.loads(elog2 or '[]')
                    except Exception: continue
                    # 收紧:删除文本 norm **以 S 结尾**(删的就是 A 相对 B 多出的尾),非 S 作中间子串
                    # (防两条真独立近消息共享前缀+A尾恰是某无关删除的中段子串→误折;宁缺毋错)
                    if any(x.get('kind') == 'delete' and norm_t(x.get('text') or '').endswith(S) for x in arr2):
                        fin2 = r2; break
                if fin2 is not None: break
            if fin2 is not None:
                drops.append(("中间态草稿", a_, t_, evid_, t0_, t1_,
                              f"删除证据折叠(S的删除edit_log有案):{cv(fin2[1])[:30]}")); continue
        # 渐进 IME 草稿态折叠(2026-06-29:6/26 Safari 表单逐字打「这样的对吗?」漏的那族):
        # 上面的块只折叠进**真发送**;未发送草稿的逐字进度态(zhe y/这样d/这样的dui ma/这样的对吗?)
        # 全是 ~draft,无真发送可锚 → 这里折叠进**更完整的同 bundle 草稿**。跨拼音↔汉字态用 _py_prefix
        # (字母前缀,简拼免疫),完整度按拼音字母长(免被拼音残渣字符数骗、免口3时序)。
        if '~draft' in src0:
            rk = _completeness(t_, t1_ or t0_)
            sup = next((r2 for r2 in out if r2 is not rec and r2[7] == b_
                        and abs((r2[5] or r2[4] or 0) - (t1_ or t0_ or 0)) <= 15 * 60 * 1000
                        and _completeness(r2[1], r2[5] or r2[4]) > rk
                        and _py_prefix(t_, r2[1])), None)
            if sup is not None:
                # 审计 reason 嵌 survivor 预览前先遮蔽邮箱(survivor 可能是邮箱前缀态的最终态,
                # P0「全文档」会扫到——同 8cdfb42 教训:审计内容遇敏感一律遮蔽,先 scrub 再截断)
                prev = re.sub(r'\S+@\S+\.\w+', '⟨邮箱已遮蔽⟩', cv(sup[1]))[:30]
                drops.append(("渐进草稿态", a_, t_, evid_, t0_, t1_,
                              f"未发送草稿前缀态,折叠进更完整态:{prev}")); continue
        out_f.append(rec)
    out = out_f
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
            # 窄账本(之类的案):秒发形态(段时长≤10s,zhileid1=1.2s)——打太快AX没跟上才是
            # 这族消息的本质;长段是当年垃圾主源。双回车包夹/选字/无脏退格已由上方条件保证。
            if LEDGER_MODE == 'narrow' and st1 - st0 > 10000: continue
            fixed, _ = R.reconstruct_message('', s, model_fn=disambig)
            ft = cv(fixed)
            if len(ft) < 2 or not (R.has_han(ft) or re.search(r'[A-Za-z]{4,}', ft)):
                if len(s) >= 6:                       # 蒸发审计(诊断:guard回退静默吞掉说实话)
                    drops.append(("账本-解码蒸发", a, s[:60], None, st0, st1, "guard回退/解码过短"))
                continue
            # 消费判定(空格+标点归一,诊断:半角','vs全角'，'天然失配):文本被某记录包含 且 时间窗±3s → 已消费
            # 发送清空(ChatGPT等网页)的AX记录时间戳在发送那刻,打字早它几十秒 → 长段(≥6字,
            # 巧合被包含几无可能)起点回看放宽到60s,接住被它涵盖的击键碎片免重复(2026-06-16 hermes案)
            ftn = norm_t(ft)
            back = 60000 if len(ftn) >= 6 else 3000
            consumed = any(ftn in norm_t(rt) and st0 >= (rt0 or 0) - back and st1 <= (rt1 or 0) + 3000
                           for rt, rt0, rt1 in recs_b)
            if consumed: continue
            if X.is_ph(ft) or is_residue(ft) or ft in seen:
                drops.append(("账本-过滤", a, ft[:60], None, st0, st1, "占位符/残渣/重复")); continue
            # 质量门(用户指令 2026-06-12:'增加pass/给pass'类Notes碎片不应出现):汉字主体≥3
            # ('之类的'/'还可以'=3✓);不足=半截碎片,静默掉(渲染确证过了也不入,宁缺勿碎)
            if LEDGER_MODE == 'narrow' and sum(1 for ch in ft if not ch.isascii()) < 3:
                continue
            seen[ft] = (None, None)
            if LEDGER_MODE != 'off':
                out.append((a, ft, len(s), None, st0, st1, "keystroke_recovered", b))
    # ===== Phase1.5 口3:重建不确定的(残渣未清)drop 到此 =====
    # 此时全天消息已就位 → 有**下文**了(两遍式的时序红利)。
    # ① 确定性:OCR 锚定 + 击键 <CR> 段验证(零幻觉);② 还没修上 → 14B 双向语境重试(前文+后文)。
    # 按发送时刻 t1 排(2026-07-07 审计修,原按 t0=开始打字):交错发送(A 先开打后发、B 后开打先发)
    # 时 t0 序会让 prev 锚锚到「发送晚于本条、尚未上屏」的消息 → 前条锚 OCR 找不存在的文本;
    # 展示层同族 bug 已按 t1 修过(bovhltmkf),口3 内部跟齐。timeline 语境时间同步换 t1。
    recs_sorted = sorted(out, key=lambda r: (r[5] or r[4] or 0))
    timeline = [(r[5] or r[4], r[1]) for r in recs_sorted]
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
            # 简拼下界闸(A12特定的人/我的意思案,2026-06-12 用户截图实证):原闸按全拼3字母/字
            # 高估需求,简拼用户(w=我,d=的)真尾巴(yisi1/特定的人)永远到不了线。下界=每汉字
            # 至少1键+ascii字面1键;净剩≥4 → 给口3机会(锚定+击键验证+护栏把关,误入仅耗时)。
            han_n = sum(1 for ch in cv(t) if not ch.isascii())
            asc_n = len(re.sub(r'[^a-zA-Z]', '', cv(t)))
            needs = letters - han_n - asc_n >= 4
        if not needs and not mt:
            out2.append(rec); continue
        u = None
        if evid:
            ur = con.execute("SELECT url FROM typing_events WHERE id=:i", {"i": evid}).fetchone()
            u = ur[0] if ur else None
        others = [r2[1] for j, r2 in enumerate(recs_sorted) if j != i and r2[7] == b]
        if needs:
            prev_t = next((r2[1] for r2 in reversed(recs_sorted[:i]) if r2[7] == b), None)
            nt, info = C3.complete_tail(a, t, t1 or t0 or 0, C3.keys_segment(b, t1 or t0 or 0),
                                        url=u, other_texts=others, prev_text=prev_t)
            via = "口3-OCR"
        else:   # 机器选字尾 → OCR 校对(渲染事实覆盖模型选字:睡得→睡的)
            nt, info = C3.proofread_tail(a, t, mt, t1 or t0 or 0, C3.keys_segment(b, t1 or t0 or 0),
                                         url=u, other_texts=others)
            via = "口3-校对"
        if nt == t:                                      # OCR 没修上 → 双向语境重试 14B
            ctx2 = f"app:{a}\n邻近消息:\n" + ctx_window(timeline[:i], t0 or 0, after=timeline[i + 1:])
            kw2 = R.keys_in_window(con, b, t0, t1)
            # eng_literals 与主 reconstruct(line 299)对称:防双向语境第二次过度解码(em→恶魔,2026-06-16)
            nt, _ = R.reconstruct_message(t, kw2, context=ctx2, model_fn=disambig,
                                          eng_literals=eng_literals_of(b, t0, t1))
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
    racing_kill = set()   # 竞速尾巴归并:被账本全版顶替的 AX 截断版下标(每天还能pei ni liao t 案)
    for i, rec in enumerate(out2):
        a, t, kc2, evid, t0, t1, src_, b = rec
        if i in racing_kill:
            drops.append(("竞速归并", a, t, evid, t0, t1, "AX末尾回车竞速截断,同消息账本全版已入册"))
            continue
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
                if LEDGER_MODE == 'narrow':   # 窄账本:副本/未确证进丢弃审计不刷未定区(92条噪音教训)
                    drops.append(("账本-副本", a, t, None, t0, t1, f"拼音空间与已有记录重复:{cv(dup)[:30]}"))
                else:
                    pend.append((a, t, src_, evid, t0, "账本副本(拼音空间重复)", cv(dup)[:80]))
                continue
            # 竞速尾巴归并(每天还能pei ni liao t 案,2026-07-10 用户指认):AX 末尾回车竞速把 IME
            # 未转完的组合区记成文本(汉字前缀+拉丁残尾),账本从击键恢复出全熟版——同一条消息两副本。
            # seq_in 接不住(汉字单元 'pei' 对散字母 p,e,i 集合不相交),用 _py_prefix 字母级行走。
            # 签名收窄防误伤:非账本近邻(±10s 同 bundle)必须**带拉丁残尾(≥2字母)**才进射程
            # (「你好/你好吗」真实连发无拉丁尾,不碰);方向=账本全版过下方渲染确证才顶替(铁律:
            # 账本入册唯一通道);确证不过 → 竞速版原样留(残渣可见 > 丢)。
            rtwin = None
            for j, r2 in enumerate(out2):
                if r2 is rec or r2[6].startswith("keystroke_recovered") or r2[7] != b: continue
                if abs((r2[5] or r2[4] or 0) - (t1 or t0 or 0)) > 10000: continue
                mtail = re.search(r'[A-Za-z][A-Za-z ]*$', cv(r2[1]))
                if not mtail or len(re.sub(r'[^A-Za-z]', '', mtail.group())) < 2: continue
                if _py_prefix(r2[1], t):
                    rtwin = j; break
            prev = (next((r3[1] for r3 in reversed(out3) if r3[7] == b), None)
                    or next((out2[j][1] for j in range(i - 1, -1, -1) if out2[j][7] == b), None))
            seg = C3.keys_segment(b, t1 or t0 or 0)
            tn0 = norm_t(t)[-60:]   # 尾60对证(用户裁定:长文尾部恒可见/头部滚出窗;错也多在尾)
            hit = False
            for fw in (60, 300):
                sn, _ts, _md = C3.ocr_snippet(a, u, t, t1 or t0 or 0, prev_text=prev, seg=seg, fwd_s=fw)
                if tn0 and len(tn0) >= 2 and tn0 in norm_t(sn):
                    hit = True; break
            if hit:
                if rtwin is not None:
                    if rtwin > i:
                        racing_kill.add(rtwin)   # 竞速版还没处理到 → 前瞻跳过(排序后账本常在前)
                    else:
                        xr = out2[rtwin]         # 竞速版已入 out3 → 按 evid+t0+bundle 摘(**非文本**:
                        # AX 竞速残版=汉前缀+拉丁尾=residue,常走口3/det 改字,out3 里文本已变,文本相等会失配漏摘→重复)
                        out3[:] = [r3 for r3 in out3 if not (r3[3] == xr[3] and r3[4] == xr[4] and r3[7] == xr[7])]
                        drops.append(("竞速归并", xr[0], xr[1], xr[3], xr[4], xr[5], "AX末尾回车竞速截断,同消息账本全版已入册"))
                out3.append(rec)
            elif LEDGER_MODE == 'narrow':
                drops.append(("账本-未确证", a, t, None, t0, t1, "渲染确证未过(窄账本:不入未定区)"))
            else:
                pend.append((a, t, src_, evid, t0, "账本解码未获渲染全文确证", ''))
            continue
        # 审核射程(用户裁定 2026-06-10):**只有 librime/14B 选过字的才走复查 LLM**——
        # 纯 AX 原文(机器没碰过字)= AX+击键双背书,错字风险不存在,免审直接入册
        # (误伤面归零 + referee 调用大降)。判据:PROOF 有模型尾 / 口3 修过(+c3/+rev)。
        machine_touched = bool(PROOF.get((evid, t), '')) or ('+c3' in src_) or ('+rev' in src_)
        # 用户指令(2026-06-10):det 零LLM零幻觉 → AX 纯原文的**短消息**(≤20字,幻影/碎片域)
        # 也对证筛一遍;但纯 AX 只筛不替换(AX+击键双背书,OCR 矛盾→未定区展示,不动字)。
        screen_only = (not machine_touched) and len(cv(t)) <= 20 and REVIEW_MODE == 'det'
        if not machine_touched and not screen_only:
            out3.append(rec); continue
        # prev 锚优先用已审核的修后文本(out3),回退 out2(审查修)
        prev = (next((r3[1] for r3 in reversed(out3) if r3[7] == b), None)
                or next((out2[j][1] for j in range(i - 1, -1, -1) if out2[j][7] == b), None))
        seg = C3.keys_segment(b, t1 or t0 or 0)
        snip, _fts, smode = C3.ocr_snippet(a, u, t, t1 or t0 or 0, prev_text=prev, seg=seg)
        snipn = norm_t(snip)   # 两侧同口径(标点归一,离线对证实测:逗号挡匹配致误报)
        tn0 = norm_t(t)[-60:]  # 尾60+同口径归一(用户裁定:尾部恒可见且错多在尾;头60会放过尾错)
        # 确定性快速通道(审查修):渲染与记录逐字一致 → 免 14B 直接过(判定在确定性链路)
        if tn0 and len(tn0) >= 2 and tn0 in snipn:
            out3.append(rec); continue
        # ax 路 + 无任何帧证据:REJECT 不可能成立,免调用直接保留(审查修)
        if not snip and not is_ledger:
            if '~draft' in src_ and len(cv(t)) <= 20:      # L7:短草稿连帧都没有 → 未定区
                pend.append((a, t, src_, evid, t0, "短草稿快照无帧证据(零回车背书)", '')); continue
            out3.append(rec); continue
        if REVIEW_MODE == 'det':
            # ===== 确定性对证器(用户提议:复查=拿OCR对证,固定程序替代LLM)=====
            # 规则:OCR无可证言→保留;击键滑窗搜索出渲染真身(verify_tail内建同音/前缀松弛)
            # 与记录不同且过护栏→替换(渲染+击键双背书);矛盾且护栏不过→未定区展示。
            tn = norm_t(t)
            vt, consumed = C3.verify_tail(snip, seg)
            vtn = norm_t(vt)
            han_v = sum(1 for ch in vtn if not ch.isascii())
            if not vtn or consumed < max(2, han_v) or vtn == tn:
                # L7(2026-06-10):零回车草稿快照(~draft)且短(≤20字)且 OCR 无渲染确证 → 未定区
                # (打了一半放弃的输入框残留,如'苹果某些';有渲染=真写过,照常保留)
                if '~draft' in src_ and len(cv(t)) <= 20 and vtn != tn and tn[-60:] not in snipn:
                    pend.append((a, t, src_, evid, t0, "短草稿快照无渲染确证(零回车背书)",
                                 re.sub(r'\s+', ' ', snip or '')[:120])); continue
                out3.append(rec); continue                 # OCR 无证言/一致 → 信 librime+击键
            others = [norm_t(r2[1]) for j, r2 in enumerate(out2) if j != i and r2[7] == b]
            t_cmp = tn.rstrip('，,。.!？?！…、 ')
            if screen_only:
                # 纯 AX 短消息:只筛不替换。OCR 真身与记录矛盾 → 未定区展示(幻影/碎片筛查)
                pend.append((a, t, src_, evid, t0, "AX短消息对证矛盾(渲染=" + vtn[:20] + ")",
                             re.sub(r'\s+', ' ', snip)[:120]))
                continue
            if (len(vtn) >= len(t_cmp) and not any(vtn in o for o in others)):
                c3fix.append((a, t, vt, "确定性对证替换", evid, t0))
                out3.append((a, cv(vt), kc2, evid, t0, t1, src_ + "+det", b)); continue
            pend.append((a, t, src_, evid, t0, "OCR对证矛盾(渲染真身=" + vtn[:20] + ")", re.sub(r'\s+', ' ', snip)[:120]))
            continue
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
    _daycache_write(day, out3, drops, list(c3fix), pend)   # 落盘,reaper 杀了重启跳过本天
    print(f"  {day}: {len(out3)} 条(审核未定 {len(pend)};14b disambig 累计 {R.DISAMBIG_CALLS[0]})", flush=True)
os.makedirs(EVAL, exist_ok=True)
json.dump(RAW, open(os.path.join(EVAL, "v2_rebuilt.json"), "w"), ensure_ascii=False)
# ===== Phase 1.6:一体化 canvas(B/C 内联,共享上面已加载的 14B,不落 fusion 中间文件)=====
# 承载率判别 canvas_spans → B 短档 librime+OCR纠错+ax_verify;C 长档 canvas_merge。CV_INLINE 结构
# 同 canvas_route_fusion.json;显式 PORTRAIT_CANVAS(gold 用固定 essay 源)→ 不内联,下方 output 读固定源。
creport, cnoanchor = [], []
if CANVAS_INLINE:
    if not FRESH and os.path.exists(_CANVAS_CACHE):
        _cc = json.load(open(_CANVAS_CACHE))
        CV_INLINE = _cc['CV']; creport = _cc['creport']; cnoanchor = _cc['cnoanchor']
        print("canvas: 缓存命中,跳过重建", flush=True)
    else:
        _llm = CL.wrap_llm(m14, tok14) if m14 is not None else None   # 共享主程序 14B,不重复加载
        CV_INLINE, creport, cnoanchor = CR.build_canvas(con, DAYS, _llm)
        os.makedirs(CACHE, exist_ok=True)
        json.dump({'CV': CV_INLINE, 'creport': creport, 'cnoanchor': cnoanchor},
                  open(_CANVAS_CACHE + '.tmp', 'w'), ensure_ascii=False); os.replace(_CANVAS_CACHE + '.tmp', _CANVAS_CACHE)
    _nb = sum(1 for v in CV_INLINE.values() for x in v if x['source'].startswith('canvas_B'))
    _ncc = sum(1 for v in CV_INLINE.values() for x in v if x['source'] == 'canvas_C')
    print(f"canvas 一体化 · B {_nb} 段 · C {_ncc} 篇 · 无锚点 C {len(cnoanchor)}", flush=True)
else:
    CV_INLINE = {}
del m14, tok14; gc.collect()
print(f"Phase1 完成,14b disambig 共调用 {R.DISAMBIG_CALLS[0]} 次", flush=True)

# ===== Phase 2: Pass4(固定逻辑;LLM 禁用 —— 用户指令:8B 误杀真消息)=====
# 只丢两类:邮箱(.com 结尾)/ 密码(连续 ≥6 个掩码符号 •●* 等)。其余全留。
print("=== Phase2: Pass4 固定逻辑(只滤 .com结尾 + 密码掩码;LLM 禁用)===", flush=True)
PW_MASK = re.compile(r'[•●○◦＊*]{6}')
# URL 整条匹配(ev563 教训:search('://')连坐'正文含github链接'的302字真消息——
# 该丢的是'整条就是URL'的地址栏草稿,链接作为正文一部分保留)
URL_FULL = re.compile(r'(https?://\S+|localhost:\d\S*|[\w.-]+\.(com|org|net|io|ai|dev|cn|me|co|app|us|edu)(/\S*)?)', re.I)
EMAIL_PAT = re.compile(r'\S+@\S+\.\w+')   # 邮箱=PII,任意位置即扔(用户裁定;zzhang@…k12.nc.us)
EMAIL_FILTER = os.environ.get('PORTRAIT_EMAIL_FILTER', '1') == '1'   # 邮箱过滤开关(2026-07-11 用户:前端可关)
# 手机号/号码闸(2026-07-11 审核 Fix C,13910653410 案=WiFi登录表单被采):**整段就是号码**才丢
# (数字/空格/-/()/+ 组成 且 ≥10 位真数字——手机号10-11位;≥10 排掉8位日期 2026-07-11 误杀)。
# 含文字的正文里带个号码不连坐(与 URL/邮箱 canvas 同口径,最大保留)。
PHONE_FULL = re.compile(r'[\d\s\-()+]{7,}')
def is_phone(t):
    t = (t or '').strip()
    return bool(PHONE_FULL.fullmatch(t)) and len(re.sub(r'\D', '', t)) >= 10
def pass4_fixed(recs):
    kept, dropped = [], []
    for r in recs:
        t = (r[1] or '').strip()
        if t.lower().endswith('.com') or URL_FULL.fullmatch(t) or (EMAIL_FILTER and EMAIL_PAT.search(t)):
            dropped.append((r, "网址/邮箱")); continue
        if is_phone(t):
            dropped.append((r, "号码(整段≥7位数字,PII)")); continue
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
# canvas 源(2026-07-11 一体化):默认用上方内联构建的 CV_INLINE(不落 fusion 中间文件);
# PORTRAIT_CANVAS 显式指定固定源(gold 复跑固定 essay)则读之。
if CANVAS_SRC and os.path.exists(CANVAS_SRC):
    CV = json.load(open(CANVAS_SRC))
else:
    CV = CV_INLINE
_totp = sum(len(FINAL[d]) for d in DAYS)
_cbn = sum(1 for v in CV.values() for x in v if x['source'].startswith('canvas_B'))
_ccn = sum(1 for v in CV.values() for x in v if x['source'] == 'canvas_C')
nd = ["# 生产接入前 · 最终审核大跑 v2(一体化 pipeline · 全量真实数据)\n",
      "> **一体化主程序** `faithful_v2.py`(一条命令跑完):承载率判别 → 承载段 AX 重建"
      "(typing_events+keystroke_log) + 0承载段 canvas(B librime+OCR纠错+ax_verify / C canvas_merge)"
      " → 统一 Pass4 → 本文档。canvas 内联构建(不落 fusion 中间文件),与 AX 路共享同一 14B。零人工干预。\n",
      "## 组成(真实生产流程)\n",
      "- **AX 路**:`event_sends_with_ts`(回车检测真发送)+ rebuild(librime 确定性打底 + 14b 同音消歧 + "
      "残渣/击键调和)+ 组级击键 gate + slash gate + dedup_truncated + is_residue + 注入闸/竞速归并/删除证据折叠。",
      "- **canvas 路**:`ax_bearing.canvas_spans` 承载率切 0承载会话 → B 短档(≤120键)librime 解码 + 14B OCR "
      "纠错 + ax_verify;C 长档(>120键)canvas_merge 按文档 OCR 层级归并。A 闸剔 AX 已收的头碎片。",
      "- **按天 decode**:<2026-06-25 librime 解拼音(旧采集)、≥6/25 AX 直给汉字(新采集);单进程按天自动切。",
      "- **Pass4**:只滤 网址/邮箱(`PORTRAIT_EMAIL_FILTER` 可关)+ 密码掩码;canvas 段同过 Pass4(整段=PII 才丢)。\n",
      f"## 总量:成品 **{_totp}** 条(canvas_B {_cbn} + canvas_C {_ccn} + AX 其余)· 天数 {len(DAYS)}"
      f"({DAYS[0]}..{DAYS[-1]})\n"]
if creport or cnoanchor:
    nd.append("## canvas 明细\n")
    for a, did, app, nf, nc in creport:
        nd.append(f"- `[C {a}]` {app} · `{did[:16]}` · {nf}帧 → {nc}字")
    for n in cnoanchor:
        nd.append(f"- `[C-DROP]` {n.get('day', '?')} {n['app']} · {n.get('nkeys', 0)}键 · {n['reason']}")
nd.append("\n---\n")
def _canvas_frag(t):
    """canvas_B 碎片判别(2026-07-11 审核 Fix A):canvas_B 无「发送」背书,单字/短碎片/纯符号极可能是
    解码残渣。AX 路对残渣会打 ~residue→未定区,canvas_B 产出**旁路了此闸**直接进成品(审核确认的
    魔/测/w/spot/==/。。等大批碎片)。→ 判碎片,路由未定区(残渣可见>丢)。canvas_C essay 长文不走此判。"""
    c = cv(t).strip()
    if len(c) <= 1: return True                                     # 单字/单符号
    if is_residue(t): return True                                   # AX 同款(ascii≤4 / ascii run / 中文≤2+尾渣)
    if not re.search(r'[一-鿿]|[a-zA-Z]{2,}', c): return True        # 纯符号/纯数字碎片(== / 。。 / 11 / -)
    han = sum(1 for ch in c if '一' <= ch <= '鿿')
    if han == 0 and len(re.sub(r'[^a-zA-Z]', '', c)) <= 4: return True   # 短纯英文碎片(spot/sour/mymy/alen)
    return False
for day in DAYS:
    # 按发送时刻(t1=回车那刻)排序,匹配 Discord/IM 时间线——用户对着 app 按时间逐条核对。
    # 修前按 t0(开始打字)排:边打边想的长消息会顶到前面错位(ev461「那比如说你就很重要」
    # 打字 12:28:58、发送 12:31:24,中间先发了「那你真出生」「重要是相对的」,t0 排把它顶到第2位)。
    # 纯展示层重排,不影响重建/去重/口3。canvas(整篇 essay 重建)非聊天流,仍附末尾。
    day_final = sorted(FINAL[day], key=lambda r: (r[5] or r[4] or 0))
    # canvas 段过 Pass4 同款闸(2026-07-10 用户裁定「canvas也进pass4」:riqujoyzhang14@gmail.com
    # 案——canvas 直通拼接曾旁路邮箱/掩码/URL 禁令;拼接污染不拆,成品级有问题整条丢)。
    cvday = []
    for r in CV.get(day, []):
        t_ = (r["text"] or '').strip()
        # canvas(2026-07-11 用户裁定):**整段就是**邮箱/URL=PII → 丢;邮箱+其他内容(长文正文引用)→ 保留
        # (与 AX 路"任意位置即扔"分叉:canvas 是拼接长文,一个邮箱不该连坐整篇 essay)。fullmatch 语义。
        if URL_FULL.fullmatch(t_) or (EMAIL_FILTER and EMAIL_PAT.fullmatch(t_)):
            DISCARDED[day].append(((r["app"], r["text"], None, None, None, None, r["source"], None), "纯网址/邮箱(canvas)")); continue
        if is_phone(t_):   # 号码 PII(Fix C):整段就是号码 → 丢(canvas 表单字段也采到)
            DISCARDED[day].append(((r["app"], "(内容已过滤)", None, None, None, None, r["source"], None), "号码PII(canvas)")); continue
        if PW_MASK.search(t_) or is_mask(t_):
            DISCARDED[day].append(((r["app"], "(内容已过滤)", None, None, None, None, r["source"], None), "密码掩码(canvas)")); continue
        # canvas_B 碎片/残渣 → 未定区(Fix A:补 AX 路 ~residue→未定区 的旁路;canvas_C essay 不判碎片)
        if r["source"].startswith("canvas_B") and _canvas_frag(t_):
            PENDING.setdefault(day, []).append((r["app"], r["text"], r["source"], None, None, "canvas_B碎片/残渣(无发送背书)", ""))
            continue
        cvday.append(r)
    out = [(rec[6], rec[1], rec[0]) for rec in day_final] + [(r["source"], r["text"], r["app"]) for r in cvday]
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(out)}）\n")
    for i, (src, text, app) in enumerate(out, 1): nd.append(rec_md(i, src, kind_of(text), app, text))
    # 口3 修正审计:改了什么、怎么改的(OCR锚定/双向语境)
    cf = C3FIX.get(day, [])
    nd.append(f"\n### 🔧 口3 修正（{len(cf)}）\n")
    if not cf: nd.append("（无）\n")
    for a, old, new, via, evid, t0 in cf:
        nd.append(f"- `[{via}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}`\n  > {old[:120]!r} → **{new[:120]!r}**\n")
    # 未定区:审核未过的展示(用户原则:宁可记录对的,也不拿错的填;不确定的必须看得见)
    # 敏感过滤(用户指令 2026-06-12:密码/网址过滤没做是半成品):密码掩码/.com 在未定区
    # 与审计同样不展示(密码内容任何文档都不该出现),静默掉
    def sensitive(t_):
        t_ = (t_ or '').strip()
        # 展示层:掩码≥3/纯符号≥4(PUA如loginwindow U+F79A 也覆盖)/@邮箱/.com 同滤
        return (is_mask(t_, n=3) or t_.lower().endswith('.com')
                or bool(re.search(r'\S+@\S+\.\w+', t_)))
    pd = [r for r in PENDING.get(day, []) if not sensitive(r[1])]
    nd.append(f"\n### ⚠️ 未定区(审核未过,展示不入册)({len(pd)})\n")
    if not pd: nd.append("（无）\n")
    for a, t, src_, evid, t0, why, snip in pd:
        nd.append(f"- `[{src_}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}` — {why[:80]}\n  > "
                  + (t or '')[:200].replace('\n', '\n  > ')
                  + (f"\n  OCR证据:`{snip}`\n" if snip else "\n"))
    # 丢弃审计:漏斗每道闸 + Pass4,丢了什么 + 为什么 + event 时间
    dr = [r for r in DROP.get(day, []) if not sensitive(r[2])]; dd = DISCARDED.get(day, [])
    nd.append(f"\n### 🗑️ 丢弃审计（漏斗 {len(dr)} + Pass4 {len(dd)}）\n")
    if not dr and not dd: nd.append("（无）\n")
    for stage, a, t, evid, t0, t1, reason in dr:
        nd.append(f"- `[{stage}]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)}` — {reason}\n  > {(t or '')[:300]}\n")
    for (a, t, kc, evid, t0, t1, *_), reason in dd:
        # Pass4 丢的就是邮箱/密码——审计只留理由行,内容一律遮蔽(joyzhang_14@163.com 实锤泄漏)
        nd.append(f"- `[Pass4]` 📍 `{a}` · ev{evid} · `{fmt_ts(t0)} → {fmt_ts(t1)}` — {reason or '(模型未给原因)'}\n  > (内容已过滤)\n")
    nd.append("\n---\n")
path = os.environ.get('PORTRAIT_OUT',
                      "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-阶段0.md")
open(path, "w").write("\n".join(nd))
print(f"已写 {path}", flush=True)
