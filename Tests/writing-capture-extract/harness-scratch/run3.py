#!/usr/bin/env python3
"""Pass3 pilot with SCHEMA-forced output (prevents echo/ramble), real prompt, 4 models."""
import json, sys
import harness as H
from llm import call

MODELS = ["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "qwen2.5:14b-instruct"]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
SCHEMA = {"type":"object","properties":{"records":{"type":"array","items":{
    "type":"object","properties":{
        "text":{"type":"string"},"kind":{"type":"string"},
        "source":{"type":"string"},"confidence":{"type":"number"}},
    "required":["text","kind"]}}},"required":["records"]}

def main():
    p = H.prompt("pass3Fusion")
    samples = H.pick_pass3(N)
    json.dump([{"record_id":s["record_id"],"ground_truth":s["ground_truth"],
                "input_endvalue":s.get("input_endvalue",""),"keystroke_text":s.get("keystroke_text",""),
                "kind":s["kind"]} for s in samples],
              open(f"{H.OUT}/pass3_samples.json","w"), ensure_ascii=False, indent=1)
    print(f"Pass3: {len(samples)} samples x {len(MODELS)} models (schema-forced)", flush=True)
    idx=[]
    for s in samples:
        full = p + "\n\nINPUT:\n" + json.dumps(s["input"], ensure_ascii=False)
        for m in MODELS:
            try: out,dt = call(m, full, num_ctx=16384, fmt=SCHEMA)
            except Exception as e: out,dt = f"[ERROR] {e}", -1
            open(f"{H.OUT}/pass3_{s['record_id']}_{m.replace(':','-').replace('/','-')}.txt","w").write(out)
            idx.append({"record_id":s["record_id"],"model":m,"latency":round(dt,1),"out_len":len(out)})
            json.dump(idx, open(f"{H.OUT}/pass3_index.json","w"), ensure_ascii=False, indent=1)
            print(f"  rec {s['record_id']:>5}  {m:<14} {dt:6.1f}s  {len(out)}b", flush=True)
    print("DONE pass3", flush=True)

main()
