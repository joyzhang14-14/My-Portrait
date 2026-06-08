#!/usr/bin/env python3
"""从 fulllocal.json 重排最终文档:① canvas 记录解析 JSON 取 body_text ② 保守残渣过滤
③ 重写新文档。不重跑模型。"""
import json, re, os
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
# 保守残渣:纯拉丁/数字 ≤4(w/oc/55/in)、空格分隔的拼音碎片(p s/ji d/ming t)、中文+末尾≥3拉丁残尾。
# 不碰连写英文词(notebookLM/gmail)。
def is_residue(t):
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True            # 拼音碎片 p s / ji d / ming t
    if re.search(r'[a-zA-Z ]{3,}$', c) and re.search(r'[一-鿿]', c) and len(c) <= 20: return True
    return False
def canvas_body(text):
    if not text.strip().startswith("{"): return text
    try:
        d = json.loads(text)
        b = (d.get("body_text") or "").strip()
        return b if b else text
    except Exception:
        m = re.search(r'"body_text"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
        return (m.group(1).encode().decode('unicode_escape') if m else text)

DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
D = json.load(open("/tmp/rime-test/eval/fulllocal.json"))
def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"

nd = ["# 新 pipeline·成品(v2 切分,全本地 Pass1-Pass4)\n",
      "全文不省略。**完全本地、与项目 config 隔离**(只换「用哪个模型」,prompt 用真实部署版):",
      "Pass1=MLX Qwen3-4B / Pass3 AX(unifiedExtract v2 + AxCleanup)=MLX Qwen3-8B /",
      "Pass3 Canvas 重建=MLX Qwen3-14B / Pass4=MLX Qwen3-8B。残渣用确定性规则补清(A组#8,LLM Pass4 兜不住)。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    recs = []
    for r in D[day]["final"]:
        text = canvas_body(r["text"]) if r["source"] == "canvas_fusion" else r["text"]
        if r["source"] != "canvas_fusion" and is_residue(text): continue
        recs.append((r["source"], text, r["app"]))
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(recs)}）\n")
    for i, (src, text, app) in enumerate(recs, 1):
        nd.append(rec_md(i, src, kind_of(text), app, text))
    nd.append("\n---\n")
open("/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md", "w").write("\n".join(nd))
print("已重排最终文档")
for day in DAYS:
    n = sum(1 for r in D[day]["final"] if r["source"] == "canvas_fusion" or not is_residue(canvas_body(r["text"]) if False else r["text"]))
print("各天计数见文档")
