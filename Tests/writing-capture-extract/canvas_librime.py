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
import os, sys, time
import rebuild as R          # 复用 reconstruct/keys_in_window,不改 rebuild.py
import ax_bearing as B       # 复用 canvas_spans(承载率判别)


def decode_span(con, bundle, t0, t1):
    """一个短 canvas 会话的击键 → librime 确定性重建(TOP,不跑模型)。"""
    kw = R.keys_in_window(con, bundle, t0, t1)
    prev = R.DECODE_LIBRIME
    R.DECODE_LIBRIME = True   # bucket B 这条路开 decode;AX 路保持关
    try:
        text, _ = R.reconstruct_message('', kw, model_fn=None)
    finally:
        R.DECODE_LIBRIME = prev
    return text


def bucket_b(con, t0, t1):
    """承载率 0承载 且短(B 桶)的会话,逐个 librime 重建。返回 spans + 'decoded'。"""
    out = []
    for sp in B.canvas_spans(con, t0, t1):
        if sp['bucket'] != 'B':
            continue              # 长文(C)走 OCR,不在这
        out.append({**sp, 'decoded': decode_span(con, sp['bundle'], sp['t0'], sp['t1'])})
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
