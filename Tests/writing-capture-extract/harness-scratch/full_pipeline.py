#!/usr/bin/env python3
"""FULL pipeline on one real day, RELEASE CONFIG (MLX 1.7b + JSON constraint),
then compare local output vs the cloud-produced writing_records already in the DB.
Pass3 (transcribe each typing_event) -> Pass4 (keep/discard) -> compare to cloud records."""
import json, time, sys, difflib, datetime
import harness as H
from mlx_lm import load, generate
import mlx_constrained as MC

DAY = sys.argv[1] if len(sys.argv) > 1 else "2026-06-05"
m, tok = load("mlx-community/Qwen3-1.7B-4bit")
ted, vs = MC.tokenizer_data(tok, "qwen3-1.7b")

P3_SCHEMA={"type":"object","properties":{"records":{"type":"array","items":{"type":"object","properties":{
    "text":{"type":"string"},"kind":{"type":"string","enum":["long_form","short_form","other"]}},
    "required":["text","kind"]}}},"required":["records"]}
P4_SCHEMA={"type":"object","properties":{"kept":{"type":"array","items":{"type":"string"}},
    "discarded":{"type":"array","items":{"type":"object","properties":{"record_id":{"type":"string"},"reason":{"type":"string"}},"required":["record_id","reason"]}}},
    "required":["kept","discarded"]}

def cgen(user, schema, max_tokens=1200):
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    proc=MC.json_processor(schema,ted,vs)
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=max_tokens,verbose=False,logits_processors=[proc]); dt=time.time()-t
    try: return json.loads(out), dt
    except: return None, dt

def assemble_keys(keys):
    out=""
    for k in sorted(keys,key=lambda r:r["ts_ms"]):
        if (k["modifiers"]&0x07)!=0: continue
        if k["is_backspace"]: out+="<BS>"; continue
        c=k["char"]
        if c: out+= "<CR>" if c in("\n","\r") else c
    return out[:1500]

# ---- day bounds + events ----
base=int(datetime.datetime.strptime(DAY,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
con=H.db()
events=con.execute("SELECT id,bundle_id,url,text,edit_log,end_value,started_at,ended_at FROM typing_events WHERE started_at BETWEEN ? AND ? AND length(text)>1 ORDER BY started_at",(base,base+86400000)).fetchall()
cloud=[r["text"] for r in con.execute("SELECT text FROM writing_records WHERE start_ts BETWEEN ? AND ? AND source IN('ax_cleaned','canvas_fusion','merged') ORDER BY start_ts",(base,base+86400000)).fetchall()]
con.close()
print(f"day {DAY}: {len(events)} 打字事件 -> Pass3 转写 | 云端记录 {len(cloud)} 条\n", flush=True)

# ---- Pass3: transcribe each event ----
p3prompt=H.prompt("pass3Fusion")
local=[]; t3=0.0
for e in events:
    con=H.db()
    keys=con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",(e["bundle_id"],e["started_at"]-3000,e["ended_at"]+3000)).fetchall()
    con.close()
    sess={"session_id":e["id"],"start_ts":e["started_at"],"end_ts":e["ended_at"],
          "keystroke_text":assemble_keys(keys),"keystroke_count":sum(1 for k in keys if (k["modifiers"]&0x07)==0 and not k["is_backspace"]),
          "typing_events":[{"id":e["id"],"text":e["text"],"end_value":e["end_value"],"edit_log":json.loads(e["edit_log"] or "[]")}],
          "keystroke_log":[],"ocr_frames":[],"chrome_tokens":[]}
    inp={"context_timeline":[],"group_meta":{"app":e["bundle_id"],"url":e["url"] or "","session_count":1,"user_languages":["zh","en"]},"raw_sessions":[sess]}
    user=p3prompt+"\n\nINPUT:\n"+json.dumps(inp,ensure_ascii=False)+"\n\nOutput ONLY the JSON object."
    d,dt=cgen(user,P3_SCHEMA,900); t3+=dt
    if d:
        for r in d.get("records",[]):
            if r.get("text","").strip(): local.append({"text":r["text"],"kind":r.get("kind","short_form")})
print(f"Pass3: {len(events)}事件 -> {len(local)} 条本地记录 | {t3:.0f}s", flush=True)

# ---- Pass4: keep/discard ----
con=H.db(); rej=[{"text":(r["text"] or "")[:150],"app":r["app"],"kind":r["kind"],"reason":r["reason_text"] or r["reason_category"]} for r in con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 20").fetchall()]; con.close()
recs=[{"record_id":f"r{i}","text":x["text"],"kind":x["kind"],"source":"ax_cleaned","app":"","url":None,"keystroke_count":5,"context_summary":None} for i,x in enumerate(local)]
p4user="\n".join([H.prompt("pass4ContentReview"),"","user_rejected_examples:",json.dumps(rej,ensure_ascii=False),"","records:",json.dumps(recs,ensure_ascii=False)])
d4,t4=cgen(p4user,P4_SCHEMA,1500)
disc=set(x["record_id"] for x in d4.get("discarded",[])) if d4 else set()
kept=[r for r in recs if r["record_id"] not in disc]
print(f"Pass4: {len(local)} -> 留 {len(kept)} 丢 {len(disc)} | {t4:.0f}s", flush=True)

# ---- Pass1 time (reuse earlier measured) ----
P1=42.6 if DAY=="2026-06-05" else None
total=t3+t4+(P1 or 0)
print(f"\n=== 全量每天耗时 {DAY} ===")
print(f"  Pass1(切窗): {P1}s | Pass3(转写): {t3:.0f}s | Pass4(过滤): {t4:.0f}s | 合计 ~{total:.0f}s", flush=True)

# ---- compare local kept vs cloud records ----
def best(a,pool): return max((difflib.SequenceMatcher(None,a,b).ratio() for b in pool), default=0)
kept_txt=[H.cleanVisible(r["text"]) if hasattr(H,'cleanVisible') else r["text"] for r in kept]
cloud_c=[c for c in cloud]
matched=sum(1 for c in cloud_c if best(c,kept_txt)>0.6)
print(f"\n=== 跟云端入库内容比对 ===")
print(f"  云端 {len(cloud_c)} 条 | 本地留下 {len(kept_txt)} 条")
print(f"  云端被本地覆盖(相似>0.6): {matched}/{len(cloud_c)} = {100*matched/max(len(cloud_c),1):.0f}% (召回)")
print("\n  云端 vs 本地最佳匹配(抽样):")
for c in cloud_c[:10]:
    bm=max(kept_txt,key=lambda x:difflib.SequenceMatcher(None,c,x).ratio()) if kept_txt else ""
    r=difflib.SequenceMatcher(None,c,bm).ratio()
    print(f"   [{r:.2f}] 云: {c[:32]!r}  本地: {bm[:32]!r}")
json.dump({"day":DAY,"t3":t3,"t4":t4,"p1":P1,"cloud":cloud_c,"local_kept":kept_txt,"recall":matched/max(len(cloud_c),1)},
          open(f"{H.OUT}/full_{DAY}.json","w"),ensure_ascii=False,indent=1)
