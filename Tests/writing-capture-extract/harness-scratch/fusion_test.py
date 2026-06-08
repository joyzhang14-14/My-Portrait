#!/usr/bin/env python3
"""Fusion re-test (full day 06-05, real dumped inputs):
librime gives candidates for each pinyin residue -> local 1.7b picks by context.
Compare to cloud fixes (per-item) AND to the DB writing_records (库里内容)."""
import json, time, glob, re, subprocess, sqlite3, os, datetime, difflib, sys
import harness as H
from mlx_lm import load, generate
import mlx_constrained as MC

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-1.7B-4bit"
m, tok = load(MODEL)
ted, vs = MC.tokenizer_data(tok, MODEL.split("/")[-1])
SCHEMA = {"type":"object","properties":{"fixed":{"type":"array","items":{"type":"object","properties":{
    "id":{"type":"string"},"text":{"type":"string"}},"required":["id","text"]}}},"required":["fixed"]}
PROMPT = """You reconstruct chat messages where some Chinese was typed but left as un-composed PINYIN letters.
For each item: `text` is what was captured (Chinese + maybe pinyin letters). `cands` gives, per pinyin fragment, a pinyin engine's top Chinese candidates — the correct character is USUALLY among them; pick the one that fits the meaning and the surrounding conversation. Replace each pinyin fragment with the chosen Chinese. KEEP existing Chinese and the user's exact wording — do NOT add or invent extra content. If a latin part is real English (a name/word/code), keep it as English.
Output JSON {"fixed":[{"id":"..","text":"final message"}]}."""

def cands(py, n=8):
    py = py.replace(" ", "").lower()
    if len(py) < 2 or not py.isalpha(): return []
    try:
        o = subprocess.run(["/tmp/rime-test/cands", py, str(n)], capture_output=True, text=True, timeout=10).stdout
        return [ln.split("] ", 1)[1].strip() for ln in o.splitlines() if "] " in ln]
    except Exception: return []

def cgen(user):
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    proc = MC.json_processor(SCHEMA, ted, vs)
    t=time.time(); out=generate(m,tok,prompt=pr,max_tokens=1500,verbose=False,logits_processors=[proc]); dt=time.time()-t
    try: return json.loads(out), dt
    except: return None, dt

# DB content (库里) for 06-05
con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
base = int(datetime.datetime.strptime("2026-06-05","%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
db_records = [r[0] for r in con.execute("SELECT text FROM writing_records WHERE start_ts BETWEEN ? AND ? AND source IN('ax_cleaned','merged')",(base,base+86400000)).fetchall()]
con.close()

files = sorted(glob.glob(os.path.expanduser("~/.portrait/llm_dump/*.json")))
tot=exact=rf_tot=rf_match=0; tdt=0; fusion_all=[]; rows=[]
for f in files:
    d=json.load(open(f)); items=d["items"]; cloud=d["fixes"]
    if not items: continue
    aug=[]
    for it in items:
        cmap={}
        for run in set(re.findall(r'[a-zA-Z]+(?: [a-zA-Z]+)*', it["text"])):
            c=cands(run.strip())
            if c: cmap[run.strip()]=c[:6]
        aug.append({"id":it["id"],"text":it["text"],"cands":cmap})
    user=PROMPT+f'\n\nconversation (same chat, for context):\n{json.dumps([it["text"] for it in items],ensure_ascii=False)}\n\nitems:\n'+json.dumps(aug,ensure_ascii=False)
    res,dt=cgen(user); tdt+=dt
    lf={x["id"]:x.get("text","") for x in (res or {}).get("fixed",[])}
    for it in items:
        iid,inp=it["id"],it["text"]
        cf=cloud.get(iid,{}).get("text",inp)
        fo=lf.get(iid,inp)
        fusion_all.append(fo); tot+=1; exact+=(fo==cf)
        if cf!=inp:
            rf_tot+=1; rf_match+=(fo==cf); rows.append((inp,cf,fo))

# 和库里 writing_records 对照(set-level recall)
def best(a,pool): return max((difflib.SequenceMatcher(None,a,b).ratio() for b in pool),default=0)
recall=sum(1 for r in db_records if best(r,fusion_all)>0.85)
print(f"=== 融合重测 06-05(librime候选 + 1.7b上下文挑,真实输入)===")
print(f"逐条 vs 云端: 完全一致 {exact}/{tot} = {100*exact/max(tot,1):.0f}%")
print(f"难点(IME解码)子集: {rf_match}/{rf_tot} = {100*rf_match/max(rf_tot,1):.0f}%  (对比: 纯1.7b 0% / librime单独 31%)")
print(f"和库里 writing_records 对照: {len(db_records)}条库里记录, 被融合覆盖(相似>0.85) {recall}/{len(db_records)} = {100*recall/max(len(db_records),1):.0f}%")
print(f"耗时 {tdt:.0f}s / {len(files)}组")
print(f"\n难点逐条(入→云端→融合):")
for inp,cf,fo in rows:
    print(f"  {'OK' if fo==cf else 'XX'} 入{inp[:22]!r} 云{cf[:22]!r} 融合{fo[:22]!r}")
json.dump({"exact":exact,"tot":tot,"rf_match":rf_match,"rf_tot":rf_tot,"recall":recall,"db":len(db_records),"rows":rows,"sec":tdt},
          open(f"{H.OUT}/fusion_result.json","w"),ensure_ascii=False,indent=1)
