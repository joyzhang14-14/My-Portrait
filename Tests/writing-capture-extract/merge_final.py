#!/usr/bin/env python3
"""合并:AX(fulllocal.json,真实分组+本地8b)+ 云端 canvas(canvas_cloud.json)→ 最终新文档。"""
import json, re
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def is_residue(t):
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True                       # 纯短拉丁/数字 w/oc/55
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True            # 纯拼音碎片 p s/ji d
    # 末尾【空格分隔的拼音碎片】(hen bu x / jiu s s)= 残渣;连写英文词(XPC/gemini/bug)保留。
    if re.search(r'[一-鿿]\s*[a-z]{1,3}(?: [a-z]{1,3})+$', c) and len(c) <= 25: return True
    return False
def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"

DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
AX = json.load(open("/tmp/rime-test/eval/fulllocal.json"))
CV = json.load(open("/tmp/rime-test/eval/canvas_cloud.json"))

nd = ["# 新 pipeline·成品(v2 切分,全本地 AX + 云端 Canvas)\n",
      "**AX 路**(占大头)= 真实会话分组 + unifiedExtract v2 → 本地 AxCleanup(MLX Qwen3-8B)→ 本地 Pass4(MLX Qwen3-8B);",
      "**Canvas 重建** = 云端 Claude(本地 14b 质量不行)。残渣用确定性规则补清。prompt 用真实部署版。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    recs = []
    for r in AX[day]["final"]:
        if r["source"] == "canvas_fusion": continue   # AX run 里 canvas 已置空,忽略
        if is_residue(r["text"]): continue
        recs.append((r["source"], r["text"], r["app"]))
    for r in CV.get(day, []):
        recs.append((r["source"], r["text"], r["app"]))
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(recs)}）\n")
    for i, (src, text, app) in enumerate(recs, 1):
        nd.append(rec_md(i, src, kind_of(text), app, text))
    nd.append("\n---\n")
open("/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md", "w").write("\n".join(nd))
print("已合并写入最终文档")

# 自查:之前丢的消息找回来了吗
txt = open("/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md").read()
print("\n=== 之前丢的消息复查 ===")
for kw in ['都是swift', '基本上我问', '你得抓住每个', 'The guidelines were not', '昨天今天修了一下', 'Natural Monopoly', 'Zhuoyi Zhang']:
    print(f"  {kw!r}: {'✓在' if kw in txt else '✗仍无'}")
