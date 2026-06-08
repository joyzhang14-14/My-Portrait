#!/usr/bin/env python3
"""Fusion v3: decompose to the TINY task 1.7b proved it can do.
For each pinyin residue run: LLM picks ONE word among librime candidates (the working diagnostic
format). CODE substitutes it back into the message. LLM never assembles — its job is trivial."""
import json, time, glob, re, subprocess, sqlite3, os, datetime, difflib, sys
from mlx_lm import load, generate

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-1.7B-4bit"
m, tok = load(MODEL)

def cands(py, n=6):
    py = py.replace(" ", "").lower()
    if len(py) < 2 or not py.isalpha(): return []
    try:
        o = subprocess.run(["/tmp/rime-test/cands", py, str(n)], capture_output=True, text=True, timeout=10).stdout
        return [ln.split("] ", 1)[1].strip() for ln in o.splitlines() if "] " in ln]
    except Exception: return []

def gen(user, mx=12):
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    return re.sub(r'<think>.*?</think>', '', generate(m,tok,prompt=pr,max_tokens=mx,verbose=False), flags=re.S).strip()

def pick(run, cs, message, context):
    # the WORKING diagnostic format: give candidates, ask for ONE word only
    p = (f"拼音 '{run}' 在这句话里应该是哪个中文词?候选: {' '.join(cs)}。"
         f"结合句子和对话意思挑一个,只输出那一个中文词,不要候选列表、不要解释、不要符号。\n"
         f"对话: {context[:160]}\n句子: {message}\n答案:")
    o = gen(p).split("\n")[0].strip()
    for c in cs:                       # prefer an exact candidate the model named
        if c and c in o: return c
    return re.sub(r'[^一-鿿]', '', o)[:8] or cs[0]   # else strip to hanzi

def fix_item(text, context):
    out = text
    for run in re.findall(r'[a-zA-Z]+(?: [a-zA-Z]+)*', text):
        cs = cands(run.strip())
        if not cs: continue            # English / abbrev librime can't decode -> leave as-is
        out = out.replace(run, pick(run.strip(), cs, text, context), 1)
    return out

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
base = int(datetime.datetime.strptime("2026-06-05","%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
db_records = [r[0] for r in con.execute("SELECT text FROM writing_records WHERE start_ts BETWEEN ? AND ? AND source IN('ax_cleaned','merged')",(base,base+86400000)).fetchall()]
con.close()

files = sorted(glob.glob(os.path.expanduser("~/.portrait/llm_dump/*.json")))
tot=exact=rf_tot=rf_match=0; tdt=0; fusion_all=[]; rows=[]
for f in files:
    d=json.load(open(f)); items=d["items"]; cloud=d["fixes"]
    if not items: continue
    ctx=" / ".join(it["text"] for it in items)
    t0=time.time()
    for it in items:
        iid,inp=it["id"],it["text"]
        fo=fix_item(inp,ctx); cf=cloud.get(iid,{}).get("text",inp)
        fusion_all.append(fo); tot+=1; exact+=(fo==cf)
        if cf!=inp:
            rf_tot+=1; rf_match+=(fo==cf); rows.append((inp,cf,fo))
    tdt+=time.time()-t0
def best(a,p): return max((difflib.SequenceMatcher(None,a,b).ratio() for b in p),default=0)
recall=sum(1 for r in db_records if best(r,fusion_all)>0.85)
print(f"=== 融合 v3(逐残留只挑一词 + 代码组装,{MODEL.split('/')[-1]})===")
print(f"逐条 vs 云端: {exact}/{tot} = {100*exact/max(tot,1):.0f}%")
print(f"难点(IME解码){rf_match}/{rf_tot} = {100*rf_match/max(rf_tot,1):.0f}%  (1.7b 旧版 0% / librime单独 31%)")
print(f"和库里覆盖: {recall}/{len(db_records)} = {100*recall/max(len(db_records),1):.0f}%")
print(f"耗时 {tdt:.0f}s")
print("难点逐条:")
for inp,cf,fo in rows: print(f"  {'OK' if fo==cf else 'XX'} 入{inp[:18]!r} 云{cf[:18]!r} 融合{fo[:18]!r}")
