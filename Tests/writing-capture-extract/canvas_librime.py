#!/usr/bin/env python3
"""bucket B:短 canvas 输入的 librime 重建(新文件,复用 rebuild,不改它)。

承载率判 0承载(canvas)且击键数 ≤ BUCKET_KEYS(短)→ 这里。AX 拿不到内容,但短输入的击键流
干净(没鼠标跳改)→ 用 keys_in_window + rebuild.reconstruct(临时开 DECODE_LIBRIME)解拼音→汉字。
长文(C)走 OCR/canvas_merge,不来这——librime 全量解长英文=乱码(实测「他和us米利唐如熬夜蛤丝…」)。

与 AX 路共存:rebuild.DECODE_LIBRIME 是模块全局(AX 路默认关,防误判)。这里**运行时**临时置 True
再还原(不碰 rebuild.py 源码),所以两条路同进程不冲突。

⚠️ librime 同音错字风险(打的字→大的子)→ 输出**留给口3 OCR 校验**(口3 要 14B,本文件不跑模型,
只出确定性 TOP 解码 model_fn=None)。英文字面(ok/wtf)reconstruct 的 _is_eng_tail 会自然保留不解。
"""
import os, sys, time, re, json
from difflib import SequenceMatcher
import rebuild as R          # 复用 reconstruct/keys_in_window,不改 rebuild.py
import ax_bearing as B       # 复用 canvas_spans(承载率判别)
import canvas_local as CL    # 复用 frame_lines(OCR 词→行)


def _decode_segment(seg):
    """seg=char 列表(已消化退格)→ 文本。逐 run 装配:拼音→librime TOP;英文→字面(保大小写);
    标点/空格/字面数字→原样保留(reconstruct 那条会丢标点+丢纯英文,故 bucket B 自己装)。"""
    out, buf = [], ""
    def flush(pick=None):
        nonlocal buf
        if not buf:
            return
        kind, _ = R.classify(buf, pick)           # cands/lattice 内部自带 .lower(),buf 可留原大小写
        if kind == 'chinese':
            han, _ = R.decode_run(buf, model_fn=None)
            out.append(han or buf)                # 解不出 → 留拼音残渣(宁缺毋错)
        else:
            out.append(buf)                       # english/incomplete → 字面(The/ok 保原样)
        buf = ""
    for ch in seg:
        if ch.isalpha():
            buf += ch
        elif ch.isdigit() and buf and 1 <= int(ch) <= 9:
            flush(int(ch) - 1)                    # 选字数字 = 拼音收尾上屏
        elif ch.isprintable():
            flush(); out.append(ch)               # 标点/空格/字面数字:先收尾,再原样保留(逗号!)
        # else:控制键(ESC/US 等)= 非文字,丢(同 real_key correctness)
    flush()
    return ''.join(out)


def decode_span(con, bundle, t0, t1):
    """一个短 canvas 会话的击键 → librime 确定性重建(TOP,不跑模型)。"""
    kw = R.keys_in_window(con, bundle, t0, t1)
    prev = R.DECODE_LIBRIME
    R.DECODE_LIBRIME = True   # bucket B 这条路开 decode;AX 路保持关
    try:
        lines = [_decode_segment(seg) for seg in R.split_cr(kw)]
    finally:
        R.DECODE_LIBRIME = prev
    return '\n'.join(l for l in lines if l)


def _walk_letters(kw):
    """keys_in_window 原文(含 <BS>/<CR>/选字数字)→ 退格感知字母序列。
    组内 BS 删字母;**紧跟选字上屏后的 BS 删该组末音节**(选字后 1BS=1汉字,音节↔字,lattice 切分
    ——IMEStateMachine 地雷的窄版,只服务 ax_verify 全对齐;ev3338 的 shi1<BS>=打了「是」又删)。"""
    groups, buf = [], []   # groups: [ [letters...], committed ]
    for t in R._toks(kw or ''):
        if t == '<BS>':
            if buf: buf.pop()
            elif groups and groups[-1][1]:
                g = groups[-1][0]
                _, syls = R.lattice(''.join(g))
                cut = len(syls[-1][0]) if syls else len(g)
                del g[len(g) - cut:]
                if not g: groups.pop()
            elif groups:
                g = groups[-1][0]
                if g: g.pop()
                if not g: groups.pop()
        elif t.isalpha():
            buf.append(t.lower())
        elif t.isdigit() and buf and '1' <= t <= '9':
            groups.append([buf, True]); buf = []
        else:                                # <CR>/标点/空格:组收尾(未选字)
            if buf: groups.append([buf, False]); buf = []
    if buf: groups.append([buf, False])
    return ''.join(c for g, _ in groups for c in g)


def _keys_walk_text(keys_letters, text):
    """span 击键字母序列能否**完整走完** text:每个汉字消费其单元全拼或任意非空前缀(简拼),
    ASCII 字母逐字符对应,标点/空格/单元表外字符(全角标点/￼)跳过;**双向走完**(键耗尽∧文走尽)
    才算命中——全对齐防模糊替换引入新错字。记忆化 DP,span≤120 键有界。"""
    cu = R.SCH.char_units()
    tl = [c for c in (text or '').lower() if not c.isspace()]
    n, m = len(keys_letters), len(tl)
    if not n or not m: return False
    memo = {}
    def walk(i, j):
        key = (i, j)
        if key in memo: return memo[key]
        if j == m: r = (i == n)
        else:
            ch = tl[j]
            if ch.isascii():
                if ch.isalpha():
                    r = i < n and keys_letters[i] == ch and walk(i + 1, j + 1)
                else:
                    r = walk(i, j + 1)            # 标点/数字跳过(键侧已剥选字数字)
            elif ch in cu:
                r = False
                for u in cu[ch]:
                    for L in range(len(u), 0, -1):   # 全拼→简拼前缀
                        if keys_letters[i:i + L] == u[:L] and walk(i + L, j + 1):
                            r = True; break
                    if r: break
            else:
                r = walk(i, j + 1)                # 全角标点/￼/emoji:单元表外,跳过
        memo[key] = r; return r
    return walk(0, 0)


def _keys_cover_text(keys_letters, text):
    """text 的拼音能否作为**子序列**在 keys_letters 里按序找到(键可跳过多余字母=打了又删的内容)。
    用于 gate ocr_correct 的 14B 输出——同音纠错(拼音一致)和删字(键多于文)都放行,但凭空替换成
    击键不支持的屏幕文字(网页/AI/通知)拒。**每个汉字必须消费其某单元的全拼**(不用简拼声母!简拼
    单字母匹配会让错字幻觉借声母蒙混:portraitzhongde 能蒙混"破人体热爱体重的" po-r-t-r-ai-t-zhong-de)。
    ASCII 字母逐字符,标点/表外跳过。记忆化 DP。"""
    cu = R.SCH.char_units()
    tl = [c for c in (text or '').lower() if not c.isspace()]
    n, m = len(keys_letters), len(tl)
    if not m: return True
    if not n: return False
    memo = {}
    def walk(i, j):                       # i=键位(可从此往后跳),j=文位
        if j == m: return True
        key = (i, j)
        if key in memo: return memo[key]
        ch = tl[j]; r = False
        if ch.isascii():
            if ch.isalpha():
                for k in range(i, n):     # 允许跳过多余键(删掉的内容)
                    if keys_letters[k] == ch and walk(k + 1, j + 1): r = True; break
            else:
                r = walk(i, j + 1)         # 标点跳过(文侧)
        elif ch in cu:
            for k in range(i, n):         # 跳过多余键找该字全拼的起点
                for u in cu[ch]:
                    if keys_letters[k:k + len(u)] == u and walk(k + len(u), j + 1): r = True; break
                if r: break
        else:
            r = walk(i, j + 1)
        memo[key] = r; return r
    return walk(0, 0)


def ax_verify(con, sp, decoded):
    """AX 验证 keystroke(2026-07-10 用户裁定,十七块政策案):canvas_B 的 librime 解码是猜,
    但附近 AX 事件里常躺着输入法的**真实产出**(如 ev3338 的 delete'这种情况正常吗?在选课界面',
    end_value 空所以 A闸认不了)。span 击键与某 AX 文本拼音空间**全对齐** → 用 AX 文本顶替解码
    (真值>猜;简拼 qk→情况 免疫)。对不齐 → 保留 librime(dag1zhey1d 案:AX 只有'ok',真内容留)。
    候选=同 bundle [t0-60s,t1+60s] 事件的 commit/delete/submit/end_value 实质非占位文本。
    键流用 _walk_letters(退格感知:选字后 BS 删末音节)——sp['typed'] 不消化退格,ev3338 的
    shi1<BS>(打「是」又删)会留孤魂 shi 卡死全对齐。"""
    letters = _walk_letters(R.keys_in_window(con, sp['bundle'], sp['t0'], sp['t1']))
    if len(letters) < 4:
        return decoded
    cands_ax = []
    for endv, elog in con.execute(
            "SELECT end_value, edit_log FROM typing_events WHERE bundle_id=:b AND ended_at>=:a AND started_at<=:c",
            {"b": sp['bundle'], "a": sp['t0'] - 60000, "c": sp['t1'] + 60000}):
        try: entries = json.loads(elog or '[]')
        except Exception: entries = []
        for x in entries:
            if x.get('kind') in ('commit', 'delete', 'submit'):
                cands_ax.append(x.get('text') or '')
        cands_ax.append(endv or '')
    seen = set()
    for raw in cands_ax:
        t = B.strip_zw(raw).replace('￼', '').strip()
        if len(t) < 2 or t in seen: continue
        seen.add(t)
        if any(p in t for p in B._PH_SNIPPETS): continue
        if _keys_walk_text(letters, t):
            if t != decoded:
                print(f"  [B axv] {sp['bundle'].rsplit('.',1)[-1]} {decoded[:20]!r} → {t[:30]!r}")
            return t
    return decoded


def bucket_b(con, t0, t1):
    """承载率 0承载 且短(B 桶)的会话,逐个 librime 重建。返回 spans + 'decoded'。"""
    out = []
    for sp in B.canvas_spans(con, t0, t1):
        if sp['bucket'] != 'B':
            continue              # 长文(C)走 OCR,不在这
        out.append({**sp, 'decoded': decode_span(con, sp['bundle'], sp['t0'], sp['t1'])})
    return out


# ============ LLM 判别 canvas 最终内容(2026-06-28 用户裁定:确定性算法被「删除事件没记录」
# 卡死——选择删/鼠标删 keystroke_log 抓不到,最终态不可确定性重建。改用本地 LLM 判别) ============

def _anchor_len(lib, line):
    """librime 候选与 OCR 行的最长公共子串(用 librime 打对的字锚,简拼免疫);≥2含中文 或 ≥3 才算。"""
    m = SequenceMatcher(None, lib, line, autojunk=False).find_longest_match(0, len(lib), 0, len(line))
    sub = lib[m.a:m.a + m.size]
    if m.size >= 2 and any('一' <= c <= '鿿' for c in sub):
        return m.size
    return m.size if m.size >= 3 else 0


def _session_end(con, bundle, t0):
    """span 起点所属的「文档编辑 session」末键 ts(同 bundle 连续击键,gap<5min 算断)。
    canvas 编辑被承载率 burst 切碎,OCR 证据要按整个 session 收集。"""
    last = t0
    for (t,) in con.execute("SELECT ts_ms FROM keystroke_log WHERE bundle_id=:b AND ts_ms>=:a ORDER BY ts_ms",
                            {"b": bundle, "a": t0}):
        if t - last > 5 * 60 * 1000:
            break
        last = t
    return last


def _ocr_evidence(con, bundle, t0, last, lib):
    """跨 session 帧收集与 librime 候选锚定的 OCR 行(去重)。**不按 browser_url 过滤**——
    实测干净帧的 browser_url 常是 NULL,过滤会把真值滤掉;改 app_name + 时间窗。
    app_name 从 bundle 末段映射(com.google.Chrome→Chrome→帧 'Google Chrome')。"""
    app_pat = '%' + bundle.rsplit('.', 1)[-1] + '%'
    rows = con.execute("SELECT ocr_words_json FROM frames WHERE app_name LIKE :p AND ocr_words_json IS NOT NULL "
                       "AND timestamp_ms BETWEEN :a AND :b", {"p": app_pat, "a": t0 - 30000, "b": last + 90000}).fetchall()
    lines = set()
    for (wj,) in rows:
        try:
            words = json.loads(wj)
        except Exception:
            continue
        for (y, x, t, n) in CL.frame_lines(words):
            if _anchor_len(lib, re.sub(r'\s', '', t)) > 0:
                lines.add(t.strip())
    return sorted(lines)


def wrap_llm(m, tok):
    """把已加载的 MLX (model, tok) 包成 prompt->text 的 callable。faithful_v2 一体化时复用主程序
    已加载的同一 14B(不重复加载);.model/.tok 暴露供 C 档 canvas_merge 共享同一 model。"""
    from mlx_lm import generate
    def llm(prompt):
        # enable_thinking=False:Qwen3 思考模式会吃光 token 只输出 <think>,关掉直接出答案
        text = tok.apply_chat_template([{"role": "user", "content": prompt}],
                                       add_generation_prompt=True, enable_thinking=False)
        out = generate(m, tok, prompt=text, max_tokens=80, verbose=False)
        return re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
    llm.model = m; llm.tok = tok
    return llm


def make_llm(model='mlx-community/Qwen3-14B-4bit'):
    """惰性加载本地 LLM(MLX 14B,非 sonnet),返回 prompt->text 的 callable。
    **GPU 占用时别调 make_llm**(会 OOM)。导入本模块不加载模型。"""
    from mlx_lm import load
    m, tok = load(model)
    return wrap_llm(m, tok)


def ocr_correct_llm(con, sp, librime_text, llm=None):
    """LLM 判别 canvas 短输入的最终干净内容:给 librime 候选 + OCR 锚定行,本地 LLM 输出最终内容
    (用 OCR 纠同音错字、去掉中途打了又删/界面噪声)。
    llm=None(默认,GPU 占用/不跑模型)或无 OCR 证据 → 回退 librime(残渣/错字可见,宁缺毋错)。"""
    lib = re.sub(r'\s', '', librime_text)
    if not lib:
        return librime_text
    # 证据窗收紧到**打字当时**(span 末,非 5min-gap 长 session)——排掉很久之后的自指污染帧
    # (实测干净帧在打字当下 23:18:14,污染帧在 1 小时后我讨论它时)。
    ev = _ocr_evidence(con, sp['bundle'], sp['t0'], sp['t1'], lib)
    if not ev or llm is None:
        return librime_text
    ev_lines = '\n'.join(f"- {e}" for e in ev)
    prompt = (
        "从 OCR 文字行里还原用户在文档里写的那**一句**最终内容,合成成一句、不要照抄列表。\n"
        "OCR 以屏幕为准(汉字优先于击键候选);丢掉界面行(菜单/标签页/按钮)和打了又删的字。\n\n"
        "示例:\n"
        "击键候选:wo de app zhong yu zuo hao le\n"
        "OCR行:\n- 我的app终于做好了\n- 文件 编辑 视图\n- 分享\n"
        "输出:我的app终于做好了\n\n"
        "现在:\n"
        f"击键候选(同音字常错,可能含已删的字):{librime_text}\n"
        f"OCR行:\n{ev_lines}\n"
        "输出:")
    out = llm(prompt)
    if not out:
        return librime_text
    # 收敛(2026-07-11 审核 Fix B):14B 输出必须能被本 span 击键**子序列走通**(_keys_cover_text:
    # 同音纠错/删字放行,但把用户几个击键凭空替换成不相关屏幕文字=网页简介/AI回复/系统通知→拒,
    # 回退 librime)。根治审核确认的「canvas_B 采非手打屏幕文本」(Desmos/魔/Google通知/ChatGPT串)。
    letters = _walk_letters(R.keys_in_window(con, sp['bundle'], sp['t0'], sp['t1']))
    if letters and not _keys_cover_text(letters, out):
        print(f"  [B ocr↯] {sp['bundle'].rsplit('.',1)[-1]} 拒非击键支持的OCR还原 {out[:30]!r}")
        return librime_text
    return out


def _hhmm(ts): return time.strftime('%H:%M:%S', time.gmtime(ts / 1000 - 4 * 3600))


def main():
    import sqlite3
    con = sqlite3.connect(B.DB)
    if len(sys.argv) > 1 and len(sys.argv[1]) == 10 and sys.argv[1][4] == '-':
        d = sys.argv[1]
        (t0,) = con.execute("SELECT strftime('%s', :d) * 1000", {"d": d}).fetchone()
        (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day') * 1000", {"d": d}).fetchone()
    else:
        (tmax,) = con.execute("SELECT max(ts_ms) FROM keystroke_log").fetchone()
        t1 = tmax; t0 = tmax - 24 * 3600 * 1000
    rows = bucket_b(con, t0, t1)
    print(f"bucket B(短 canvas,librime 确定性解)· {len(rows)} 个")
    print(f"{'起':>8} {'app':<14} {'键':>4}  击键原文 → librime 解")
    print("-" * 74)
    for r in rows:
        print(f"{_hhmm(r['t0']):>8} {r['bundle'].rsplit('.',1)[-1]:<14} {r['nkeys']:>4}  "
              f"{r['typed'][:28]} → {r['decoded'][:28]}")


if __name__ == '__main__':
    main()
