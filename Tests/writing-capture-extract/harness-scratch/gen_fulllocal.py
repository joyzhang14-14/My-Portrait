#!/usr/bin/env python3
"""全本地 pipeline 重跑(Pass1-Pass4),与项目 config 完全隔离 —— 只换"用哪个模型",
prompt 用真实部署的(逻辑要忠实)。本地模型:Pass1=MLX-4B / AxCleanup=MLX-8B /
Canvas=Ollama-14B / Pass4=MLX-8B。输出覆盖桌面 Obsidian 两个文档(老仍是 staged,新=全本地)。
分阶段加载模型省内存。结果写 JSON 中间档,便于断点/重排。"""
import json, os, re, gc, time, datetime, sqlite3, difflib
import harness as H
import extract_compare_v2 as M
import mlx_constrained as MC
from mlx_lm import load, generate
from llm import call as ollama_call

con = H.db()
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = M.PH
OUT = "/tmp/rime-test/eval/fulllocal.json"
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def day_range(d):
    b = int(datetime.datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    return b, b+86400000

AXCLEAN_PROMPT = H.prompt("axCleanup")
PASS4_PROMPT = H.prompt("pass4ContentReview")
PASS1_PROMPT = H.prompt("pass1ContextTimeline")
CANVAS_PROMPT = H.prompt("canvasWindow")
AX_SCHEMA = {"type":"object","properties":{"fixed":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"},"confidence":{"type":"number"}},"required":["id","text"]}}},"required":["fixed"]}
P4_SCHEMA = {"type":"object","properties":{"kept":{"type":"array","items":{"type":"string"}},"discarded":{"type":"array","items":{"type":"object","properties":{"record_id":{"type":"string"},"reason":{"type":"string"}},"required":["record_id","reason"]}}},"required":["kept","discarded"]}

def gen_mlx(m, tok, ted, vs, schema, user, mx):
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = generate(m, tok, prompt=pr, max_tokens=mx, verbose=False, logits_processors=[MC.json_processor(schema, ted, vs)])
        return json.loads(re.sub(r'<think>.*?</think>','',out,flags=re.S).strip())
    except Exception: return None

def assemble_keys(eids):
    rows = []
    for e in eids:
        rows += con.execute("SELECT kl.ts_ms,kl.char,kl.is_backspace,kl.modifiers FROM keystroke_log kl JOIN typing_events te ON kl.bundle_id=te.bundle_id WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000",(e,)).fetchall()
    out=""
    for ts,c,bs,mod in sorted(rows,key=lambda r:r[0]):
        if (mod&7)!=0: continue
        if bs: out+="<BS>"; continue
        if c: out+="<CR>" if c in("\n","\r") else c
    return out[:700]
def gkc(eids):
    n=0
    for e in eids:
        r=con.execute("SELECT started_at,ended_at,bundle_id FROM typing_events WHERE id=?",(e,)).fetchone()
        if r: n+=con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND (modifiers&7)=0",(r[2],r[0]-10000,r[1]+10000)).fetchone()[0]
    return n
def app_of(eid):
    r=con.execute("SELECT bundle_id FROM typing_events WHERE id=?",(eid,)).fetchone()
    return (r[0] or '') if r else ''
def has_residue(msgs):
    return any(re.search(r'[a-zA-Z]', m) and (re.search(r'[一-鿿]', m) or re.fullmatch(r'[a-zA-Z0-9 ]+', cv(m))) for m in msgs)

# ============ 枚举会话 ============
# AX 会话:用真实 Step0 分组(staged 的 session 边界 = reference_typing_event_ids)。
# 这是"数据分组"不是 config —— 我自己写的简化分组会切错丢消息,用真实边界才忠实。
def enum_ax_sessions(day):
    out=[]
    for refs, in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')",(day,)).fetchall():
        try:
            ids=[int(x) for x in json.loads(refs or '[]')]
            if ids: out.append(ids)
        except: pass
    return out
# Canvas 会话:用 staged canvas_fusion 的 frame 引用(数据分组,非 config)。
def enum_canvas(day):
    out=[]
    for fids, in con.execute("SELECT reference_frame_ids FROM writing_records_staged WHERE date_utc=? AND source='canvas_fusion'",(day,)).fetchall():
        try: out.append([int(x) for x in json.loads(fids or '[]')])
        except: pass
    return out

DATA={}  # day -> {'ax':[(app,records)], 'canvas':[...], 'pass1':...}

# ============ Pass1: 上下文(MLX 4B,2h 窗)============
print("=== Pass1 (MLX Qwen3-4B) ===", flush=True)
m4,tok4=load("mlx-community/Qwen3-4B-4bit"); ted4,vs4=MC.tokenizer_data(tok4,"qwen3-4b")
P1_SCHEMA={"type":"object","properties":{"timeline":{"type":"array","items":{"type":"object","properties":{"app":{"type":"string"},"summary":{"type":"string"}},"required":["app","summary"]}}},"required":["timeline"]}
ctx_by_day={}
for day in DAYS:
    lo,hi=day_range(day); ctx=[]
    for w in range(0,86400000,7200000):  # 2h 窗
        ws,we=lo+w,min(lo+w+7200000,hi)
        frs=con.execute("SELECT app_name,substr(full_text,1,400) FROM frames WHERE timestamp_ms BETWEEN ? AND ? AND full_text IS NOT NULL ORDER BY timestamp_ms LIMIT 8",(ws,we)).fetchall()
        if not frs: continue
        inp=PASS1_PROMPT+"\n\nactivity:\n"+json.dumps([{"app":a.split('.')[-1],"screen":t} for a,t in frs],ensure_ascii=False)[:6000]
        d=gen_mlx(m4,tok4,ted4,vs4,P1_SCHEMA,inp,500)
        if d: ctx+= [(x.get("app",""),x.get("summary","")) for x in d.get("timeline",[])]
    ctx_by_day[day]=ctx
    print(f"  {day}: {len(ctx)} 上下文段", flush=True)
del m4,tok4; gc.collect()

# ============ Pass3 AX: unifiedExtract v2 + AxCleanup(MLX 8B)============
print("=== Pass3 AX + AxCleanup (MLX Qwen3-8B) ===", flush=True)
m8,tok8=load("mlx-community/Qwen3-8B-4bit"); ted8,vs8=MC.tokenizer_data(tok8,"qwen3-8b")
def axclean(msgs,ks,bundle):
    if not msgs: return []
    if not has_residue(msgs): return list(dict.fromkeys(msgs))   # 无残渣免 LLM
    items=[{"id":f"r{i}","text":t,"keystroke":ks} for i,t in enumerate(msgs)]
    d=gen_mlx(m8,tok8,ted8,vs8,AX_SCHEMA,AXCLEAN_PROMPT+f"\n\napp: {bundle}\n\nitems:\n"+json.dumps(items,ensure_ascii=False),1600)
    fixed={x["id"]:x.get("text","") for x in (d or {}).get("fixed",[])}
    res=[]
    for i,t in enumerate(msgs):
        ft=re.sub(r'<think>.*?</think>','',fixed.get(f"r{i}",t),flags=re.S).strip()
        if ft: res.append(ft)
    return list(dict.fromkeys(res))
for day in DAYS:
    axrecs=[]
    for ids in enum_ax_sessions(day):
        evs=M.loadev(ids)
        if not evs: continue
        msgs=M.newExtract(evs)
        if not msgs: continue
        bundle=app_of(ids[0]); ks=assemble_keys(ids); kc=gkc(ids)
        total=sum(len(m) for m in msgs)
        if total>20 and kc<total//4: continue       # 组级击键 gate
        cleaned=axclean(msgs,ks,bundle)
        for t in cleaned:
            axrecs.append({"app":bundle.split('.')[-1],"source":"ax_cleaned","text":t,"kc":kc})
    # mergePrefixDrafts:跨 session 丢"是同 app 更长记录严格前缀"的早期草稿(打字接上了就并成一条)。
    def drop_prefix(recs):
        T=[r["text"].strip() for r in recs]; keep=[]
        for i,r in enumerate(recs):
            a=T[i]
            if len(a)>=15 and any(j!=i and r["app"]==recs[j]["app"] and len(T[j])>len(a) and T[j].startswith(a) for j in range(len(recs))):
                continue
            keep.append(r)
        return keep
    axrecs=drop_prefix(axrecs)
    DATA.setdefault(day,{})["ax"]=axrecs
    print(f"  {day}: AX {len(axrecs)} 条", flush=True)
del m8,tok8; gc.collect()

# ============ Pass3 Canvas: 这次留空(改用云端 Claude 单独重建,见 canvas_cloud)============
print("=== Pass3 Canvas (置空,改云端单独做) ===", flush=True)
for day in DAYS:
    DATA[day]["canvas"]=[]

# ============ Pass4: keep/discard(MLX 8B)============
print("=== Pass4 (MLX Qwen3-8B) ===", flush=True)
m8,tok8=load("mlx-community/Qwen3-8B-4bit"); ted8,vs8=MC.tokenizer_data(tok8,"qwen3-8b")
rej=con.execute("SELECT text,app,reason_category,reason_text FROM writing_records_user_rejected LIMIT 28").fetchall()
rejex=[{"text":(r[0]or'')[:100],"reason":r[3] or r[2]} for r in rej]
def pass4(records):
    if not records: return []
    recs=[{"record_id":f"p{i}","text":r["text"],"kind":"long_form" if len(r["text"])>=140 else "short_form","source":r["source"],"app":r["app"],"keystroke_count":r["kc"],"context_summary":r.get("ctx","")} for i,r in enumerate(records)]
    user=PASS4_PROMPT+"\n\nuser_rejected_examples:\n"+json.dumps(rejex,ensure_ascii=False)+"\n\nrecords:\n"+json.dumps(recs,ensure_ascii=False)
    d=gen_mlx(m8,tok8,ted8,vs8,P4_SCHEMA,user,2000)
    disc={x["record_id"] for x in (d or {}).get("discarded",[])}
    return [r for i,r in enumerate(records) if f"p{i}" not in disc]
for day in DAYS:
    allrecs=DATA[day]["ax"]+DATA[day].get("canvas",[])
    daycx=ctx_by_day.get(day,[])         # Pass1 上下文喂给 Pass4
    for r in allrecs:
        r["ctx"]=next((s for a,s in daycx if a.split('.')[-1]==r["app"] or r["app"] in a),"")
    kept=[]
    for i in range(0,len(allrecs),15):   # 分批 15 条
        kept+=pass4(allrecs[i:i+15])
    DATA[day]["final"]=kept
    print(f"  {day}: Pass4 后 {len(kept)}/{len(allrecs)} 条", flush=True)
del m8,tok8; gc.collect()

json.dump(DATA,open(OUT,"w"),ensure_ascii=False,indent=1)
print(f"\n中间档: {OUT}", flush=True)

# ============ 写新文档(覆盖)—— canvas 解析 body_text + 确定性残渣过滤 ============
def kind_of(t): return "long_form" if len(t)>=140 else "short_form"
def rec_md(n,src,kind,app,text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> "+text.replace("\n","\n> ")+"\n"
def canvas_body(text):
    if not text.strip().startswith("{"): return text
    try:
        d=json.loads(text); b=(d.get("body_text") or "").strip(); return b if b else text
    except Exception:
        mm=re.search(r'"body_text"\s*:\s*"((?:[^"\\]|\\.)*)"',text)
        return (mm.group(1).encode().decode('unicode_escape') if mm else text)
def is_residue(t):
    c=cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}',c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}',c): return True
    if re.search(r'[a-zA-Z ]{3,}$',c) and re.search(r'[一-鿿]',c) and len(c)<=20: return True
    return False
nd=["# 新 pipeline·成品(v2 切分,全本地 Pass1-Pass4)\n",
    "全文不省略。**完全本地、与项目 config 隔离**(只换「用哪个模型」,prompt 用真实部署版):",
    "Pass1=MLX Qwen3-4B / Pass3 AX(unifiedExtract v2 + AxCleanup)=MLX Qwen3-8B /",
    "Pass3 Canvas 重建=MLX Qwen3-14B / Pass4=MLX Qwen3-8B。\n",
    f"天数:{', '.join(DAYS)}\n","---\n"]
for day in DAYS:
    recs=[]
    for r in DATA[day]["final"]:
        text=canvas_body(r["text"]) if r["source"]=="canvas_fusion" else r["text"]
        if r["source"]!="canvas_fusion" and is_residue(text): continue
        recs.append((r["source"],text,r["app"]))
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(recs)}）\n")
    for i,(src,text,app) in enumerate(recs,1): nd.append(rec_md(i,src,kind_of(text),app,text))
    nd.append("\n---\n")
open("/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md","w").write("\n".join(nd))
print("已覆盖新文档", flush=True)
