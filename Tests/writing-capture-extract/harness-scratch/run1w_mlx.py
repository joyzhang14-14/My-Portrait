#!/usr/bin/env python3
"""RELEASE-CONFIG multi-day windowed Pass1:
   MLX engine (mlx_lm) + JSON-schema constraint (lmfe, = mlx-swift-structured) + smallest Qwen3-1.7B-4bit.
   Records PER-DAY processing time (key input for the resumable queue)."""
import json, time, datetime, sys
import harness as H
from mlx_lm import load, generate
import mlx_constrained as MC

MODEL = "mlx-community/Qwen3-1.7B-4bit"
DAYS = ["2026-05-25","2026-05-30","2026-06-01","2026-06-05","2026-06-06"]
WIN_H = 2
SCHEMA = {"type":"object","properties":{"timeline":{"type":"array","items":{"type":"object","properties":{
    "start_ts":{"type":"integer"},"end_ts":{"type":"integer"},"app":{"type":"string"},
    "intent_type":{"type":"string","enum":["writing","search","reading","command","chat","other"]},
    "summary":{"type":"string"}},"required":["start_ts","end_ts","app","intent_type","summary"]}}},"required":["timeline"]}
PROMPT = H.prompt("pass1ContextTimeline").replace("a day's worth","a TIME WINDOW")

m, tok = load(MODEL)
ted, vs = MC.tokenizer_data(tok, "qwen3-1.7b")

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
    user=PROMPT+"\n\nINPUT:\n"+payload+"\n\nOutput ONLY the JSON object."
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    proc=MC.json_processor(SCHEMA,ted,vs)   # fresh enforcer per window
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=1800,verbose=False,logits_processors=[proc]); dt=time.time()-t
    try: seg=json.loads(out).get("timeline",[]); ok=True
    except: seg=[]; ok=False
    return ok,seg,dt

print(f"RELEASE CONFIG: MLX {MODEL.split('/')[-1]} + JSON约束 | {len(DAYS)} days\n", flush=True)
per_day={}; G={"win":0,"valid":0,"t":0.0}
for day in DAYS:
    base=int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    nw=0; nv=0; dt=0.0; nseg=0
    for h in range(0,24,WIN_H):
        inp=window_input(base+h*3600000, base+(h+WIN_H)*3600000)
        if not inp["typing_summary"] and not inp["ocr_frames"]: continue
        ok,seg,t=gen(json.dumps(inp,ensure_ascii=False)); nw+=1; nv+=1 if ok else 0; dt+=t; nseg+=len(seg)
    per_day[day]={"windows":nw,"valid_json":nv,"segments":nseg,"sec":round(dt,1)}
    G["win"]+=nw; G["valid"]+=nv; G["t"]+=dt
    print(f"⏱  {day}: {nw}窗 | 合法{nv}/{nw} | {nseg}段 | 处理耗时 {dt:.1f}s ({dt/max(nw,1):.1f}s/窗)", flush=True)
    json.dump(per_day, open(f"{H.OUT}/pass1_mlx_perday.json","w"), ensure_ascii=False, indent=1)
avg=G["t"]/len(DAYS)
print(f"\n总: {G['valid']}/{G['win']} 合法JSON | 5天共 {G['t']:.0f}s | 平均 {avg:.0f}s/天", flush=True)
print(f"=> 一次开机若有 30 分钟空闲,可处理约 {int(1800/max(avg,1))} 天的积压", flush=True)
