#!/usr/bin/env python3
"""Multi-day windowed Pass1 on the SMALLEST model qwen3:1.7b WITH schema constraint
(Ollama format=json — constraint is engine-agnostic; transfers to MLX+mlx-swift-structured).
Tests cross-day consistency of the smallest model on the hardest pass."""
import json, time, datetime, sys
import harness as H
from llm import call

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3:1.7b"
DAYS = ["2026-05-25","2026-05-30","2026-06-01","2026-06-05","2026-06-06"]
WIN_H = 2
SCHEMA = {"type":"object","properties":{"timeline":{"type":"array","items":{
    "type":"object","properties":{
        "start_ts":{"type":"integer"},"end_ts":{"type":"integer"},"app":{"type":"string"},
        "url":{"type":["string","null"]},
        "intent_type":{"type":"string","enum":["writing","search","reading","command","chat","other"]},
        "summary":{"type":"string"}},
    "required":["start_ts","end_ts","app","intent_type","summary"]}}},"required":["timeline"]}
PROMPT = H.prompt("pass1ContextTimeline").replace("a day's worth","a TIME WINDOW")

def window_input(t0,t1):
    con=H.db()
    rows=con.execute("SELECT (started_at/600000)*600000 b,bundle_id,sum(total_chars) c,count(*) n FROM typing_events WHERE started_at BETWEEN ? AND ? GROUP BY b,bundle_id ORDER BY b",(t0,t1)).fetchall()
    typing=[{"ts":r["b"],"app":r["bundle_id"],"chars":r["c"],"events":r["n"]} for r in rows]
    fr=con.execute("SELECT id,timestamp_ms,app_name,browser_url,full_text FROM frames WHERE timestamp_ms BETWEEN ? AND ? AND full_text IS NOT NULL AND length(full_text)>20 ORDER BY timestamp_ms",(t0,t1)).fetchall()
    frames=[];last=0
    for f in fr:
        if f["timestamp_ms"]-last<60000: continue
        last=f["timestamp_ms"]
        frames.append({"frame_id":f["id"],"start_ts":f["timestamp_ms"],"app":f["app_name"],"url":f["browser_url"],"text":(f["full_text"] or "")[:450]})
        if len(frames)>=16: break
    con.close()
    return {"ocr_frames":frames,"typing_summary":typing,"keystroke_activity":[]}

def merge(tl):
    out=[]
    for s in sorted(tl,key=lambda x:x.get("start_ts",0)):
        if out and out[-1]["app"]==s["app"] and out[-1]["intent_type"]==s["intent_type"] and s["start_ts"]-out[-1]["end_ts"]<600000:
            out[-1]["end_ts"]=s["end_ts"]
        else: out.append(dict(s))
    return out

print(f"model {MODEL} (schema-constrained) | {len(DAYS)} days\n", flush=True)
allday={}; G={"win":0,"valid":0,"t":0}
for day in DAYS:
    base=int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    seg=[]; nw=0; nv=0; dt=0
    for h in range(0,24,WIN_H):
        inp=window_input(base+h*3600000, base+(h+WIN_H)*3600000)
        if not inp["typing_summary"] and not inp["ocr_frames"]: continue
        full=PROMPT+"\n\nINPUT:\n"+json.dumps(inp,ensure_ascii=False)
        try:
            out,t=call(MODEL,full,num_ctx=8192,fmt=SCHEMA); dt+=t; nw+=1
            s=json.loads(out).get("timeline",[]); nv+=1; seg+=s
        except Exception as e: nw+=1; print(f"   {day} {h:02d}h ERR {e}",flush=True)
    m=merge(seg)
    allday[day]={"windows":nw,"valid":nv,"raw":len(seg),"merged":len(m),"sec":round(dt),"timeline":m}
    G["win"]+=nw; G["valid"]+=nv; G["t"]+=dt
    print(f"{day}: {nw}窗 合法{nv}/{nw} | {len(seg)}段->合并{len(m)} | {dt:.0f}s",flush=True)
print(f"\n总: {G['valid']}/{G['win']} 合法 = {100*G['valid']/max(G['win'],1):.0f}% | {G['t']:.0f}s",flush=True)
json.dump(allday, open(f"{H.OUT}/pass1w_multi_ollama.json","w"), ensure_ascii=False, indent=1)
