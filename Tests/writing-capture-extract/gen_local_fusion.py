#!/usr/bin/env python3
"""全本地 AX 清洗:v2 切分(raw_msgs.json)→ librime+4B fusion AxCleanup(像之前那次)→
8B Pass4 → dedup → 合并云端 canvas → 最终文档。无云端参与 AX。"""
import json, os, re, gc, subprocess, difflib
import harness as H
import mlx_constrained as MC
from mlx_lm import load, generate

RAW = json.load(open("/tmp/rime-test/eval/raw_msgs.json"))
CV = json.load(open("/tmp/rime-test/eval/canvas_cloud.json"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()

def cands(py, n=6):
    py = py.replace(" ", "").lower()
    if len(py) < 2 or not py.isalpha(): return []
    try:
        o = subprocess.run(["/tmp/rime-test/cands", py, str(n)], capture_output=True, text=True, timeout=10).stdout
        return [ln.split("] ", 1)[1].strip() for ln in o.splitlines() if "] " in ln]
    except Exception: return []

# ===== 阶段1: librime + 4B fusion AxCleanup =====
print("=== AxCleanup: librime + MLX Qwen3-4B fusion ===", flush=True)
m4, tok4 = load("mlx-community/Qwen3-4B-4bit")
def gen4(prompt, mx=120):
    pr = tok4.apply_chat_template([{"role":"user","content":prompt}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    out = generate(m4, tok4, prompt=pr, max_tokens=mx, verbose=False)
    return re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()
def fix_item(text, ks, context):
    runs = re.findall(r'[a-zA-Z]+(?: [a-zA-Z]+)*', text)
    cmap = {r.strip(): cands(r.strip()) for r in runs}
    cmap = {k: v for k, v in cmap.items() if v}        # 仅 librime 能解的 = 拼音残渣
    if not cmap: return text                            # 无残渣,原样过
    cl = "\n".join(f"  {k} → {' '.join(v[:6])}" for k, v in cmap.items())
    p = ("下面这条消息里有没打完的拼音(残留字母),用候选把它们补成中文。其余中文/英文/标点原样保留。"
         "结合上下文和原始击键挑最合适的同音字。只输出补好的完整消息,别的都不要。\n"
         f"上下文: {context[:200]}\n原始击键(拼音): {ks[:150]}\n消息: {text}\n候选:\n{cl}\n补好的消息:")
    o = gen4(p).split("\n")[0].strip()
    return o if o and len(o) >= len(text)//2 else text
for day in DAYS:
    for s in RAW[day]:
        ctx = " / ".join(s["messages"])[:300]
        s["cleaned"] = list(dict.fromkeys(fix_item(m, s["keystroke"], ctx) for m in s["messages"]))
    print(f"  {day}: 清洗完", flush=True)
del m4, tok4; gc.collect()

# 中间档:存清洗后的(供断点)
json.dump({d:[{"app":s["app"],"cleaned":s["cleaned"],"keystroke":s["keystroke"]} for s in RAW[d]] for d in DAYS},
          open("/tmp/rime-test/eval/cleaned.json","w"), ensure_ascii=False)

# ===== 阶段2: Pass4 (Ollama 1.7b + 完整字段记录,像 run4.py 那次 100%)=====
print("=== Pass4: Ollama qwen3:1.7b(完整记录)===", flush=True)
from llm import call as ollama_call
P4 = H.prompt("pass4ContentReview")
con = H.db()
rej = con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 28").fetchall()
rejex = [{"text":(r[0] or '')[:200],"app":r[1],"kind":r[2],"reason":r[4] or r[3]} for r in rej]
P4_SCHEMA = {"type":"object","properties":{"kept":{"type":"array","items":{"type":"string"}},"discarded":{"type":"array","items":{"type":"object","properties":{"record_id":{"type":"string"},"reason":{"type":"string"},"preview":{"type":"string"}},"required":["record_id","reason"]}}},"required":["kept","discarded"]}
def kc_of(ks): return len(ks.replace("<BS>","").replace("<CR>",""))   # 击键数(近似,>0=真打的)
def pass4(records):    # records: [(app,text,kc,ctx)]
    if not records: return []
    recs = [{"record_id":f"p{i}","text":t,"kind":"long_form" if len(t)>=140 else "short_form","source":"ax_cleaned","app":a,"url":None,"keystroke_count":kc,"context_summary":ctx} for i,(a,t,kc,ctx) in enumerate(records)]
    user = P4+"\n\nuser_rejected_examples:\n"+json.dumps(rejex,ensure_ascii=False)+"\n\nrecords:\n"+json.dumps(recs,ensure_ascii=False)
    try:
        out,_ = ollama_call("qwen3:1.7b", user, num_ctx=16384, fmt=P4_SCHEMA)
        disc = {x["record_id"] for x in json.loads(out).get("discarded",[])}
    except Exception: disc = set()
    return [records[i] for i in range(len(records)) if f"p{i}" not in disc]
FINAL = {}
for day in DAYS:
    recs = []
    for s in RAW[day]:
        kc = kc_of(s["keystroke"]); ctx = (" / ".join(s["messages"])[:120] or None)
        for t in s["cleaned"]:
            recs.append((s["app"], t, kc, ctx))
    # dedup 前缀草稿(同app A是更长B前缀→丢A)
    T = [t for _,t,_,_ in recs]
    recs = [r for i,r in enumerate(recs) if not (len(T[i].strip())>=15 and any(j!=i and recs[j][0]==r[0] and len(T[j].strip())>len(T[i].strip()) and T[j].strip().startswith(T[i].strip()) for j in range(len(recs))))]
    kept = []
    for i in range(0, len(recs), 12): kept += pass4(recs[i:i+12])
    FINAL[day] = [(a,t,kc) for a,t,kc,_ in kept]
    print(f"  {day}: Pass4 后 {len(kept)}/{len(recs)}", flush=True)
ollama_call.__class__  # noop
import os as _os; _os.system("ollama stop qwen3:1.7b 2>/dev/null")

# ===== 写文档(AX + 云端 canvas)=====
def is_residue(t):
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True
    if re.search(r'[一-鿿]\s*[a-z]{1,3}(?: [a-z]{1,3})+$', c) and len(c) <= 25: return True
    return False
def kind_of(t): return "long_form" if len(t)>=140 else "short_form"
def rec_md(n,src,kind,app,text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> "+text.replace("\n","\n> ")+"\n"
nd = ["# 新 pipeline·成品(v2 切分,全本地)\n",
      "**AX 路全本地**:真实分组 + unifiedExtract v2 → **librime + MLX Qwen3-4B** fusion 解拼音残渣 → MLX Qwen3-8B Pass4 → 去重。",
      "**Canvas** = 云端 Claude(本地 14b 质量不行)。\n", f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    out = []
    for a, t, kc in FINAL[day]:
        if is_residue(t): continue
        out.append(("ax_cleaned", t, a))
    for r in CV.get(day, []):
        out.append((r["source"], r["text"], r["app"]))
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(out)}）\n")
    for i,(src,text,app) in enumerate(out,1): nd.append(rec_md(i,src,kind_of(text),app,text))
    nd.append("\n---\n")
open("/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md","w").write("\n".join(nd))
json.dump(FINAL, open("/tmp/rime-test/eval/final_fusion.json","w"), ensure_ascii=False)
print("已写最终文档", flush=True)
