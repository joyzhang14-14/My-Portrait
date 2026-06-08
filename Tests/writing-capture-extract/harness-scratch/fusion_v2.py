#!/usr/bin/env python3
"""Fusion v2: PER-ITEM simple prompt (not the overwhelming batch). librime candidates +
light context -> 1.7b picks. Only invoke LLM on items with pinyin residue; clean ones pass through."""
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

def gen(user):
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    out = generate(m, tok, prompt=pr, max_tokens=80, verbose=False)
    return re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip()

def fix_item(text, context):
    runs = re.findall(r'[a-zA-Z]+(?: [a-zA-Z]+)*', text)
    cmap = {r.strip(): cands(r.strip()) for r in runs}
    cmap = {k: v for k, v in cmap.items() if v}          # only runs librime can decode = pinyin residue
    if not cmap: return text                              # no pinyin residue -> pass through unchanged
    cl = "\n".join(f"  {k} → {' '.join(v)}" for k, v in cmap.items())
    p = (f"下面这条聊天消息里有没打完的拼音(残留字母),用候选把它们补成中文。"
         f"其余中文、英文、标点原样保留。结合上下文挑最合适的同音字。只输出补好的完整消息,别的都不要。\n"
         f"上下文(同一对话): {context}\n消息: {text}\n候选:\n{cl}\n补好的消息:")
    return gen(p).split("\n")[0].strip()

# DB content
con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
base = int(datetime.datetime.strptime("2026-06-05","%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
db_records = [r[0] for r in con.execute("SELECT text FROM writing_records WHERE start_ts BETWEEN ? AND ? AND source IN('ax_cleaned','merged')",(base,base+86400000)).fetchall()]
con.close()

files = sorted(glob.glob(os.path.expanduser("~/.portrait/llm_dump/*.json")))
tot=exact=rf_tot=rf_match=0; tdt=0; fusion_all=[]; rows=[]
for f in files:
    d=json.load(open(f)); items=d["items"]; cloud=d["fixes"]
    if not items: continue
    ctx = " / ".join(it["text"] for it in items)[:300]
    t0=time.time()
    for it in items:
        iid,inp=it["id"],it["text"]
        fo = fix_item(inp, ctx)
        cf = cloud.get(iid,{}).get("text", inp)
        fusion_all.append(fo); tot+=1; exact+=(fo==cf)
        if cf != inp:
            rf_tot+=1; rf_match+=(fo==cf); rows.append((inp,cf,fo))
    tdt += time.time()-t0

def best(a,pool): return max((difflib.SequenceMatcher(None,a,b).ratio() for b in pool),default=0)
recall = sum(1 for r in db_records if best(r,fusion_all)>0.85)
print(f"=== 融合 v2(逐条简单 prompt + librime候选,{MODEL.split('/')[-1]})===")
print(f"逐条 vs 云端: {exact}/{tot} = {100*exact/max(tot,1):.0f}%")
print(f"难点(IME解码){rf_match}/{rf_tot} = {100*rf_match/max(rf_tot,1):.0f}%  (旧批量prompt: 1.7b 0%)")
print(f"和库里覆盖: {recall}/{len(db_records)} = {100*recall/max(len(db_records),1):.0f}%")
print(f"耗时 {tdt:.0f}s")
print("难点逐条:")
for inp,cf,fo in rows:
    print(f"  {'OK' if fo==cf else 'XX'} 入{inp[:20]!r} 云{cf[:20]!r} 融合{fo[:20]!r}")
