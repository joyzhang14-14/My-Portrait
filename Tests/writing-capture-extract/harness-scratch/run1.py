#!/usr/bin/env python3
"""Pass1 eval: day-timeline on real busy days, 4 models, schema-forced."""
import json
import harness as H
from llm import call

MODELS = ["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "qwen2.5:14b-instruct"]
SCHEMA = {"type":"object","properties":{"timeline":{"type":"array","items":{
    "type":"object","properties":{
        "start_ts":{"type":"integer"},"end_ts":{"type":"integer"},
        "app":{"type":"string"},"url":{"type":["string","null"]},
        "intent_type":{"type":"string","enum":["writing","search","reading","command","chat","other"]},
        "summary":{"type":"string"}},
    "required":["start_ts","end_ts","app","intent_type","summary"]}}},"required":["timeline"]}

def top_days(n=2):
    con=H.db()
    rows=con.execute("""SELECT strftime('%Y-%m-%d',started_at/1000,'unixepoch') d, count(*) n
        FROM typing_events GROUP BY d ORDER BY n DESC LIMIT ?""",(n,)).fetchall()
    con.close(); return [r["d"] for r in rows]

def main():
    p=H.prompt("pass1ContextTimeline")
    idx=[]
    for day in top_days(2):
        s=H.pass1_sample(day)
        full=p+"\n\nINPUT:\n"+json.dumps(s["input"],ensure_ascii=False)
        json.dump(s,open(f"{H.OUT}/pass1_{day}_input.json","w"),ensure_ascii=False,indent=1)
        print(f"Pass1 {day}: ~{len(full)//3} tok x {len(MODELS)} models",flush=True)
        for m in MODELS:
            try: out,dt=call(m,full,num_ctx=12288,fmt=SCHEMA)
            except Exception as e: out,dt=f"[ERROR] {e}",-1
            open(f"{H.OUT}/pass1_{day}_{m.replace(':','-').replace('/','-')}.txt","w").write(out)
            n=0
            try: n=len(json.loads(out).get("timeline",[]))
            except: pass
            idx.append({"day":day,"model":m,"latency":round(dt,1),"segments":n})
            json.dump(idx,open(f"{H.OUT}/pass1_index.json","w"),ensure_ascii=False,indent=1)
            print(f"  {day} {m:<14} {dt:6.1f}s  {n} segments",flush=True)
    print("DONE pass1",flush=True)

main()
