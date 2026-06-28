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


def make_llm(model='mlx-community/Qwen3-14B-4bit'):
    """惰性加载本地 LLM(MLX 14B,非 sonnet),返回 prompt->text 的 callable。
    **GPU 占用时别调 make_llm**(会 OOM)。导入本模块不加载模型。"""
    from mlx_lm import load, generate
    m, tok = load(model)
    def llm(prompt):
        # enable_thinking=False:Qwen3 思考模式会吃光 token 只输出 <think>,关掉直接出答案
        text = tok.apply_chat_template([{"role": "user", "content": prompt}],
                                       add_generation_prompt=True, enable_thinking=False)
        out = generate(m, tok, prompt=text, max_tokens=80, verbose=False)
        return re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
    return llm


def ocr_correct_llm(con, sp, librime_text, llm=None):
    """LLM 判别 canvas 短输入的最终干净内容:给 librime 候选 + OCR 锚定行,本地 LLM 输出最终内容
    (用 OCR 纠同音错字、去掉中途打了又删/界面噪声)。
    llm=None(默认,GPU 占用/不跑模型)或无 OCR 证据 → 回退 librime(残渣/错字可见,宁缺毋错)。"""
    lib = re.sub(r'\s', '', librime_text)
    if not lib:
        return librime_text
    last = _session_end(con, sp['bundle'], sp['t0'])
    ev = _ocr_evidence(con, sp['bundle'], sp['t0'], last, lib)
    if not ev or llm is None:
        return librime_text
    prompt = (f"任务:还原用户在文档里写的最终内容。\n"
              f"【屏幕真值·以此为准】OCR 实际拍到的文字行(就是用户屏幕上真实显示的,含界面噪声):\n  {' / '.join(ev)}\n"
              f"【参考·可能有错】拼音击键解码(同音字常解错,且可能含打了又删的字):{librime_text}\n"
              f"规则:① 内容**以 OCR 屏幕真值为准**——OCR 里的汉字优先于击键候选(如击键'泥土'但 OCR 是'逆天',取'逆天')。"
              f"② 只保留 OCR 里**真实存在**的用户文字,丢掉界面噪声(菜单/按钮/无关行)和击键候选里 OCR 没有的字(=打了又删)。\n"
              f"只输出还原后的最终文字本身,不要解释、不要引号。")
    out = llm(prompt)
    return out or librime_text


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
