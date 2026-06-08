#!/usr/bin/env python3
"""Faithful AX-cleanup test: replay the REAL dumped inputs (unifiedExtract-segmented messages)
through local 1.7b with the REAL axCleanup prompt, compare to cloud's fixes (same inputs)."""
import json, time, glob
import harness as H
from mlx_lm import load, generate
import mlx_constrained as MC

m, tok = load("mlx-community/Qwen3-1.7B-4bit")
ted, vs = MC.tokenizer_data(tok, "qwen3-1.7b")
AX = H.prompt("axCleanup")
SCHEMA = {"type":"object","properties":{"fixed":{"type":"array","items":{"type":"object","properties":{
    "id":{"type":"string"},"text":{"type":"string"},"confidence":{"type":"number"}},
    "required":["id","text"]}}},"required":["fixed"]}

def cgen(user):
    pr = tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    proc = MC.json_processor(SCHEMA, ted, vs)
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=1500,verbose=False,logits_processors=[proc]); dt=time.time()-t
    try: return json.loads(out), dt
    except: return None, dt

files = sorted(glob.glob("/Users/joyzhang14/.portrait/llm_dump/*.json"))
tot=exact=rf_tot=rf_match=0; tdt=0; rows=[]
for f in files:
    d=json.load(open(f)); items=d["items"]; cloud=d["fixes"]
    if not items: continue
    user=AX+"\n\nitems:\n"+json.dumps(items,ensure_ascii=False)
    res,dt=cgen(user); tdt+=dt
    lf={x["id"]:x.get("text","") for x in (res or {}).get("fixed",[])}
    for it in items:
        iid,inp=it["id"],it["text"]
        cf=cloud.get(iid,{}).get("text",inp)   # 云端的最终文本
        lo=lf.get(iid,inp)                       # 本地的最终文本
        tot+=1
        if lo==cf: exact+=1
        if cf!=inp:                              # 云端真改过的(IME残留/补字)= 难点
            rf_tot+=1; rf_match+= (lo==cf)
            rows.append((inp,cf,lo,it.get("keystroke","")))
print(f"=== 忠实 AX-cleanup 复跑(本地 Qwen3-1.7B + 约束 vs 云端,同一真实输入)===")
print(f"总 items: {tot} | 本地==云端: {exact}/{tot} = {100*exact/max(tot,1):.0f}%")
print(f"云端真改过的(难点子集): {rf_tot} | 本地也改成一样: {rf_match}/{rf_tot} = {100*rf_match/max(rf_tot,1):.0f}%")
print(f"耗时: {tdt:.0f}s / {len(files)} 组")
print(f"\n云端真改过的逐条(看本地差在哪):")
for inp,cf,lo,ks in rows[:18]:
    print(f"  {'OK' if lo==cf else 'XX'} 入{inp[:26]!r} 云{cf[:26]!r} 本地{lo[:26]!r} ks{ks[:22]!r}")
json.dump({"total":tot,"exact":exact,"realfix":rf_tot,"realfix_match":rf_match,"rows":rows,"sec":tdt},
          open(f"{H.OUT}/full_ax_result.json","w"),ensure_ascii=False,indent=1)
