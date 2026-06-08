#!/usr/bin/env python3
"""Multi-day windowed Pass1 on MLX 4b — test cross-day consistency."""
import json, time, re, datetime, sys
import harness as H
from mlx_lm import load, generate

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-4B-4bit"
DAYS = ["2026-05-25","2026-05-30","2026-06-01","2026-06-05","2026-06-06"]
WIN_H = 2
_M = load(MODEL)
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

def gen(payload):
    m,tok=_M
    user=PROMPT+"\n\nINPUT:\n"+payload+"\n\nOutput ONLY the JSON object."
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=2560,verbose=False); dt=time.time()-t
    out=re.sub(r"<think>.*?</think>","",out,flags=re.S).strip(); out=re.sub(r"^<think>\s*","",out).strip()
    try: seg=json.loads(out).get("timeline",[]); ok=True
    except: seg=[]; ok=False
    return ok,seg,dt,out

def merge(tl):
    out=[]
    for s in sorted(tl,key=lambda x:x.get("start_ts",0)):
        if out and out[-1]["app"]==s["app"] and out[-1]["intent_type"]==s["intent_type"] and s["start_ts"]-out[-1]["end_ts"]<600000:
            out[-1]["end_ts"]=s["end_ts"]
        else: out.append(dict(s))
    return out

print(f"model {MODEL.split('/')[-1]} | {len(DAYS)} days\n", flush=True)
grand={"win":0,"valid":0,"t":0}
allday={}
for day in DAYS:
    base=int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    seg=[]; nw=0; nv=0; dt_sum=0
    for h in range(0,24,WIN_H):
        inp=window_input(base+h*3600000, base+(h+WIN_H)*3600000)
        if not inp["typing_summary"] and not inp["ocr_frames"]: continue
        ok,s,dt,out=gen(json.dumps(inp,ensure_ascii=False))
        nw+=1; dt_sum+=dt; nv+=1 if ok else 0; seg+=s
    merged=merge(seg)
    allday[day]={"windows":nw,"valid":nv,"raw_seg":len(seg),"merged":len(merged),"sec":round(dt_sum),"timeline":merged}
    grand["win"]+=nw; grand["valid"]+=nv; grand["t"]+=dt_sum
    print(f"{day}: {nw}窗 合法{nv}/{nw} | {len(seg)}段->合并{len(merged)} | {dt_sum:.0f}s", flush=True)
print(f"\n总: {grand['valid']}/{grand['win']} 窗合法JSON = {100*grand['valid']/max(grand['win'],1):.0f}% | {grand['t']:.0f}s", flush=True)
json.dump(allday, open(f"{H.OUT}/pass1w_multi.json","w"), ensure_ascii=False, indent=1)
