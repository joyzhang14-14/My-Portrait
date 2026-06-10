#!/usr/bin/env python3
"""离线 OCR 对证(用户指令:不重跑 LLM,拿现有产出直接撞 OCR)。
输入:eval/v2_rebuilt.json(det 跑的 8 元组);筛 ≤20 字纯 AX 记录(幻影/碎片域)。
规则同 Phase1.75 det/screen_only:一致/无证言→通过;OCR 真身矛盾→标记(只筛不替换)。"""
import json, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rebuild as R
import ocr3 as C3

cv = R.cv
_PUNCT = re.compile(r'[\s，,。.!？?！…、:：;；"\'"“”‘’()（）]+')
def norm_t(t): return _PUNCT.sub('', (t or ''))

d = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval", "v2_rebuilt.json")))
rows = []
for day, recs in d.items():
    for j, r in enumerate(recs):
        a, t, kc, evid, t0, t1, src, b = r
        if len(cv(t)) > 20 or '+c3' in src or '+rev' in src or '+det' in src:
            continue
        prev = next((recs[k][1] for k in range(j - 1, -1, -1) if recs[k][7] == b), None)
        seg = C3.keys_segment(b, t1 or t0 or 0)
        snip, _ts, mode = C3.ocr_snippet(a, None, t, t1 or t0 or 0, prev_text=prev, seg=seg)
        tn = norm_t(t)
        snipn = norm_t(snip)   # 两侧同口径去标点(逗号挡匹配误报)
        if not snip:
            rows.append((day, a, evid, t, "无证言(无帧)", "")); continue
        if tn[:60] in snipn:
            rows.append((day, a, evid, t, "✓渲染一致", "")); continue
        vt, consumed = C3.verify_tail(snip, seg)
        vtn = norm_t(vt)
        han_v = sum(1 for ch in vtn if not ch.isascii())
        if not vtn or consumed < max(2, han_v) or vtn == tn:
            rows.append((day, a, evid, t, "无可证言/击键一致", "")); continue
        rows.append((day, a, evid, t, "⚠️矛盾", f"渲染真身≈{vtn[:24]} | snip:{re.sub(chr(92)+'s+',' ',snip)[:60]}"))

ok = sum(1 for r in rows if r[4].startswith("✓"))
noev = sum(1 for r in rows if "无" in r[4])
bad = [r for r in rows if r[4] == "⚠️矛盾"]
print(f"筛查 {len(rows)} 条 AX 短消息:渲染一致 {ok} / 无证言 {noev} / ⚠️矛盾 {len(bad)}")
for day, a, evid, t, _, det in bad:
    print(f"  [{day}] {a} ev{evid}: {t!r}\n      {det}")
json.dump([list(r) for r in rows], open("eval/screen_audit.json", "w"), ensure_ascii=False)
