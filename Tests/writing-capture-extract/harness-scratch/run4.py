#!/usr/bin/env python3
"""Pass4 eval: keep-vs-discard classification on real kept + real discarded records, 4 models."""
import json
import harness as H
from llm import call

MODELS = ["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "qwen2.5:14b-instruct"]
SCHEMA = {"type":"object","properties":{
    "kept":{"type":"array","items":{"type":"string"}},
    "discarded":{"type":"array","items":{"type":"object","properties":{
        "record_id":{"type":"string"},"reason":{"type":"string"},"preview":{"type":"string"}},
        "required":["record_id","reason"]}}},
    "required":["kept","discarded"]}

def build_prompt(b):
    lines = [H.prompt("pass4ContentReview"), ""]
    if b["user_rejected"]:
        lines += ["user_rejected_examples:", json.dumps(b["user_rejected"], ensure_ascii=False), ""]
    lines += ["records:", json.dumps([{k:v for k,v in r.items()} for r in b["records"]], ensure_ascii=False)]
    return "\n".join(lines)

def main():
    b = H.pass4_batch(10,10)
    truth = b["truth"]
    prompt = build_prompt(b)
    json.dump(b, open(f"{H.OUT}/pass4_batch.json","w"), ensure_ascii=False, indent=1)
    print(f"Pass4: {len(b['records'])} records (5 keep / 5 discard) x {len(MODELS)} models", flush=True)
    print(f"prompt ~{len(prompt)//3} tokens\n", flush=True)
    results=[]
    for m in MODELS:
        try:
            out,dt = call(m, prompt, num_ctx=12288, fmt=SCHEMA)
            d = json.loads(out)
            disc = set(x["record_id"] for x in d.get("discarded",[]))
            # predicted: in disc -> discard, else keep
            correct=sum(1 for rid,lab in truth.items() if (("discard" if rid in disc else "keep")==lab))
            # confusion
            kept_wrong=[rid for rid,lab in truth.items() if lab=="keep" and rid in disc]   # false discard (BAD: drops user content)
            drop_miss=[rid for rid,lab in truth.items() if lab=="discard" and rid not in disc] # missed junk
            acc=correct/len(truth)
            print(f"=== {m:<14} {dt:6.1f}s  acc {correct}/{len(truth)}={acc:.0%}  误删用户{len(kept_wrong)} 漏滤垃圾{len(drop_miss)} ===", flush=True)
            results.append({"model":m,"latency":round(dt,1),"acc":acc,"false_discard":kept_wrong,"missed_junk":drop_miss})
        except Exception as e:
            print(f"=== {m:<14} ERROR {e} ===", flush=True)
            results.append({"model":m,"error":str(e)})
        json.dump(results, open(f"{H.OUT}/pass4_results.json","w"), ensure_ascii=False, indent=1)
    print("\nDONE pass4", flush=True)

main()
