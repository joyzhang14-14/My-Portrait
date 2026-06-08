#!/usr/bin/env python3
"""AX-clean agent (NEW architecture): light prompt + group by (app,url) + 1-record-per-event
schema + 1.7b local. Phase A = no librime yet (isolate the split+light-prompt effect).
Compares to cloud records. Pass4 per group."""
import json, time, sys, difflib, datetime
import harness as H
from mlx_lm import load, generate
import mlx_constrained as MC

DAY = sys.argv[1] if len(sys.argv) > 1 else "2026-06-05"
m, tok = load("mlx-community/Qwen3-1.7B-4bit")
ted, vs = MC.tokenizer_data(tok, "qwen3-1.7b")

# light AX-clean prompt: ONE event -> ONE message. structurally one record.
AX_PROMPT = """You transcribe ONE chat message a user typed, from accessibility capture.
You get the AX-captured text and the raw keystrokes (pinyin letters for Chinese; <BS>=backspace).
The AX text is usually correct. Your ONLY fixes:
- complete trailing/embedded un-composed pinyin (latin letters where a Chinese character belongs) using the keystrokes;
- drop a placeholder like "Write a message...".
Keep the user's EXACT wording and typos. Do NOT add, rephrase or invent.
If it's not a real user message (empty, a placeholder, pure UI text, an email/login field with no message), set text to "".
Output JSON: {"text": "<clean message or empty>", "kind": "long_form|short_form|other"}"""
AX_SCHEMA = {"type":"object","properties":{"text":{"type":"string"},
    "kind":{"type":"string","enum":["long_form","short_form","other"]}},"required":["text","kind"]}
P4_SCHEMA = {"type":"object","properties":{"kept":{"type":"array","items":{"type":"string"}},
    "discarded":{"type":"array","items":{"type":"object","properties":{"record_id":{"type":"string"},"reason":{"type":"string"}},"required":["record_id","reason"]}}},"required":["kept","discarded"]}

def cgen(user, schema, mx_tok=400):
    pr = tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    proc = MC.json_processor(schema, ted, vs)
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=mx_tok,verbose=False,logits_processors=[proc]); dt=time.time()-t
    try: return json.loads(out), dt
    except: return None, dt

def assemble_keys(keys):
    out=""
    for k in sorted(keys,key=lambda r:r["ts_ms"]):
        if (k["modifiers"]&0x07)!=0: continue
        if k["is_backspace"]: out+="<BS>"; continue
        c=k["char"]
        if c: out+= "<CR>" if c in("\n","\r") else c
    return out[:600]

base=int(datetime.datetime.strptime(DAY,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
con=H.db()
events=con.execute("SELECT id,bundle_id,url,text,end_value,started_at,ended_at FROM typing_events WHERE started_at BETWEEN ? AND ? AND length(text)>1 ORDER BY bundle_id,url,started_at",(base,base+86400000)).fetchall()
cloud=[r["text"] for r in con.execute("SELECT text FROM writing_records WHERE start_ts BETWEEN ? AND ? AND source IN('ax_cleaned','canvas_fusion','merged') ORDER BY start_ts",(base,base+86400000)).fetchall()]
con.close()

# group by (app,url)
groups={}
for e in events: groups.setdefault((e["bundle_id"],e["url"] or ""),[]).append(e)
print(f"day {DAY}: {len(events)}事件 -> {len(groups)}组 | 云端 {len(cloud)}条\n", flush=True)

# Pass3-AX per event (one record each)
t3=0.0; per_group={}
for (app,url),evs in groups.items():
    recs=[]
    for e in evs:
        con=H.db(); keys=con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",(app,e["started_at"]-3000,e["ended_at"]+3000)).fetchall(); con.close()
        user=AX_PROMPT+f'\n\nax_text: {json.dumps(e["text"],ensure_ascii=False)}\nkeystrokes: {json.dumps(assemble_keys(keys),ensure_ascii=False)}'
        d,dt=cgen(user,AX_SCHEMA,300); t3+=dt
        if d and d.get("text","").strip(): recs.append({"text":d["text"],"kind":d.get("kind","short_form")})
    per_group[(app,url)]=recs
local=[r for rs in per_group.values() for r in rs]
print(f"Pass3-AX: {len(events)}事件 -> {len(local)}条(应≈事件数,无过度生成) | {t3:.0f}s ({t3/max(len(events),1):.1f}s/事件)", flush=True)

# Pass4 per group
con=H.db(); rej=[{"text":(r["text"] or "")[:150],"app":r["app"],"kind":r["kind"],"reason":r["reason_text"] or r["reason_category"]} for r in con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 15").fetchall()]; con.close()
t4=0.0; kept=[]
for (app,url),recs in per_group.items():
    if not recs: continue
    rid={f"r{i}":r for i,r in enumerate(recs)}
    payload=[{"record_id":k,"text":v["text"],"kind":v["kind"],"source":"ax_cleaned","app":app,"keystroke_count":5} for k,v in rid.items()]
    p4="\n".join([H.prompt("pass4ContentReview"),"","user_rejected_examples:",json.dumps(rej,ensure_ascii=False),"","records:",json.dumps(payload,ensure_ascii=False)])
    d4,dt=cgen(p4,P4_SCHEMA,800); t4+=dt
    disc=set(x["record_id"] for x in d4.get("discarded",[])) if d4 else set()
    kept+=[v["text"] for k,v in rid.items() if k not in disc]
print(f"Pass4(按组): {len(local)} -> 留 {len(kept)} | {t4:.0f}s", flush=True)

print(f"\n=== AX agent 全量耗时 {DAY}: Pass3 {t3:.0f}s + Pass4 {t4:.0f}s = {t3+t4:.0f}s (+Pass1 切窗 42.6s) ===", flush=True)

# compare to cloud
def best(a,pool): return max((difflib.SequenceMatcher(None,a,b).ratio() for b in pool),default=0)
matched=sum(1 for c in cloud if best(c,kept)>0.6)
print(f"\n=== 跟云端比对 ===\n  云端 {len(cloud)} | 本地留 {len(kept)} | 召回(相似>0.6) {matched}/{len(cloud)} = {100*matched/max(len(cloud),1):.0f}%", flush=True)
print("  逐条最佳匹配(前12):")
for c in cloud[:12]:
    bm=max(kept,key=lambda x:difflib.SequenceMatcher(None,c,x).ratio()) if kept else ""
    print(f"   [{difflib.SequenceMatcher(None,c,bm).ratio():.2f}] 云:{c[:30]!r} 本地:{bm[:30]!r}")
json.dump({"cloud":cloud,"local":kept,"t3":t3,"t4":t4,"recall":matched/max(len(cloud),1)},open(f"{H.OUT}/axagent_{DAY}.json","w"),ensure_ascii=False,indent=1)
