#!/usr/bin/env python3
"""自查:逐天对照 老 vs 新 成品文档,机械扫描问题。"""
import re, difflib
OB = "/Users/joyzhang14/Desktop/Obsidian/"
def parse(path):
    txt = open(path).read()
    days = {}
    for db in txt.split("\n## ")[1:]:
        day = db.split("\n", 1)[0].strip()
        recs = []
        for blk in re.split(r'\n(?=\*\*\d+\.\*\* )', db):
            mt = re.search(r'\*\*\d+\.\*\* `\[([^\]]+)\]` 📍 `([^`]+)`', blk)
            if not mt: continue
            ql = [ln[2:] if ln.startswith("> ") else ln[1:] for ln in blk.split("\n") if ln.startswith(">")]
            text = "\n".join(ql).strip()
            if text: recs.append((mt.group(1), mt.group(2), text))
        days[day] = recs
    return days
OLD = parse(OB + "Pipeline成品-老pipeline.md")
NEW = parse(OB + "Pipeline成品-新pipeline.md")
def sim(a, b): return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()
def related(a, b): return a in b or b in a or sim(a, b) >= 0.7

print("="*64)
for day in ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']:
    o = OLD.get(day, []); n = NEW.get(day, [])
    ot = [t for _,_,t in o]; nt = [t for _,_,t in n]
    print(f"\n## {day}  老 {len(o)} → 新 {len(n)}")
    # 1) 新里的短碎片(≤5字,非纯标点)
    frag = [t for t in nt if len(t) <= 5 and re.search(r'[一-鿿a-zA-Z]', t)]
    if frag: print(f"  ⚠️短碎片({len(frag)}): {frag}")
    # 2) 残渣
    res = [t for t in nt if re.fullmatch(r'[a-zA-Z0-9 ]{1,12}', t) or (re.search(r'[a-zA-Z ]{3,}$', t) and re.search(r'[一-鿿]', t) and len(t)<=20)]
    if res: print(f"  ⚠️残渣({len(res)}): {res[:8]}")
    # 3) 新里前缀重复(A 是 B 严格前缀)
    pd = [a for i,a in enumerate(nt) if len(a)>=10 and any(j!=i and len(b)>len(a) and b.startswith(a) for j,b in enumerate(nt))]
    if pd: print(f"  ⚠️前缀重复未合({len(pd)}): {[x[:25] for x in pd]}")
    # 4) 老有、新缺(>8字的真消息没对上 → 疑似漏)
    miss = [t for t in ot if len(t)>8 and not any(related(t,x) for x in nt)]
    if miss: print(f"  ⚠️疑似漏采({len(miss)}):")
    for t in miss[:6]: print(f"       老有新无: {t[:46]!r}")
    # 5) canvas
    cvs = [t for k,a,t in n if 'canvas' in k]
    if cvs: print(f"  📄canvas {len(cvs)} 条(头40字): {[t[:40] for t in cvs]}")
