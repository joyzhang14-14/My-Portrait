#!/usr/bin/env python3
"""Pass1 WINDOWED (serial): split a real day into time windows, run each on a small model,
concatenate + merge. Tests whether windowing rescues Pass1 for small local models."""
import json, sys, datetime
import harness as H
from llm import call

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3:1.7b"
WIN_H = 2  # window hours
SCHEMA = {"type":"object","properties":{"timeline":{"type":"array","items":{
    "type":"object","properties":{
        "start_ts":{"type":"integer"},"end_ts":{"type":"integer"},"app":{"type":"string"},
        "url":{"type":["string","null"]},
        "intent_type":{"type":"string","enum":["writing","search","reading","command","chat","other"]},
        "summary":{"type":"string"}},
    "required":["start_ts","end_ts","app","intent_type","summary"]}}},"required":["timeline"]}

def window_input(t0, t1):
    con = H.db()
    rows = con.execute("""SELECT (started_at/600000)*600000 b, bundle_id, sum(total_chars) c, count(*) n
        FROM typing_events WHERE started_at BETWEEN ? AND ? GROUP BY b,bundle_id ORDER BY b""",(t0,t1)).fetchall()
    typing=[{"ts":r["b"],"app":r["bundle_id"],"chars":r["c"],"events":r["n"]} for r in rows]
    fr = con.execute("""SELECT id,timestamp_ms,app_name,browser_url,full_text FROM frames
        WHERE timestamp_ms BETWEEN ? AND ? AND full_text IS NOT NULL AND length(full_text)>20
        ORDER BY timestamp_ms""",(t0,t1)).fetchall()
    frames=[]; last=0
    for f in fr:
        if f["timestamp_ms"]-last < 60000: continue
        last=f["timestamp_ms"]
        frames.append({"frame_id":f["id"],"start_ts":f["timestamp_ms"],"app":f["app_name"],
                       "url":f["browser_url"],"text":(f["full_text"] or "")[:450]})
        if len(frames)>=18: break
    ks = con.execute("""SELECT (ts_ms/600000)*600000 m, bundle_id, count(*) c FROM keystroke_log
        WHERE ts_ms BETWEEN ? AND ? GROUP BY m,bundle_id ORDER BY m""",(t0,t1)).fetchall()
    ka=[{"ts_bucket":k["m"],"app":k["bundle_id"],"count":k["c"]} for k in ks]
    con.close()
    return typing, frames, ka

def merge(tl):
    out=[]
    for s in sorted(tl, key=lambda x:x.get("start_ts",0)):
        if out and out[-1]["app"]==s["app"] and out[-1]["intent_type"]==s["intent_type"] \
           and s["start_ts"]-out[-1]["end_ts"] < 600000:
            out[-1]["end_ts"]=s["end_ts"]  # stitch adjacent same (app,intent)
        else: out.append(dict(s))
    return out

def main():
    con=H.db(); day=con.execute("""SELECT strftime('%Y-%m-%d',started_at/1000,'unixepoch') d, count(*) n
        FROM typing_events GROUP BY d ORDER BY n DESC LIMIT 1""").fetchone()["d"]; con.close()
    base=int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    prompt=H.prompt("pass1ContextTimeline").replace(
        "You analyze a day's worth of OCR data",
        "You analyze a TIME WINDOW (part of a day) of OCR data")
    print(f"day {day} | model {MODEL} | {WIN_H}h windows (serial)\n", flush=True)
    all_seg=[]; total_dt=0; nwin=0
    for h in range(0,24,WIN_H):
        w0=base+h*3600000; w1=w0+WIN_H*3600000
        typing,frames,ka=window_input(w0,w1)
        if not typing and not frames: continue
        nwin+=1
        inp={"ocr_frames":frames,"typing_summary":typing,"keystroke_activity":ka}
        full=prompt+"\n\nINPUT:\n"+json.dumps(inp,ensure_ascii=False)
        try:
            out,dt=call(MODEL,full,num_ctx=8192,fmt=SCHEMA); total_dt+=dt
            seg=json.loads(out).get("timeline",[])
        except Exception as e:
            seg=[]; dt=-1; print(f"  win {h:02d}-{h+WIN_H:02d}h ERR {e}",flush=True); continue
        all_seg+=seg
        print(f"  win {h:02d}-{h+WIN_H:02d}h  {dt:5.1f}s  {len(frames)}帧 {len(typing)}打字  -> {len(seg)} 段",flush=True)
    merged=merge(all_seg)
    print(f"\n总计: {nwin} 窗 {total_dt:.0f}s | 原始 {len(all_seg)} 段 -> 合并后 {len(merged)} 段\n")
    print("=== 合并后时间线(看 summary 质量)===")
    for s in merged:
        print(f"  {s['intent_type']:<8} {s.get('app','')[:22]:<22} {s.get('summary','')[:55]}")
    json.dump(merged, open(f"{H.OUT}/pass1w_{MODEL.replace(':','-')}.json","w"), ensure_ascii=False, indent=1)

main()
