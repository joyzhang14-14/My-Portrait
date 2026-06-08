#!/usr/bin/env python3
"""老 vs 新 pipeline【最终成品】对比 —— MLX + JSON约束(发版同环境)。
apples-to-apples:老切分 & 新切分都过同一套本地 pass(AxCleanup=Qwen3-4B / Pass4=Qwen3-1.7B,
都 MLX-4bit + lmfe JSON 约束,真实部署 prompt)。唯一变量=切分。两阶段加载模型省内存。"""
import json, os, re, gc, time
import harness as H
import extract_compare_v2 as M
import mlx_constrained as MC
from mlx_lm import load, generate

con = H.db()
AXCLEAN_PROMPT = H.prompt("axCleanup")
PASS4_PROMPT = H.prompt("pass4ContentReview")
AX_SCHEMA = {"type": "object", "properties": {"fixed": {"type": "array", "items": {"type": "object",
    "properties": {"id": {"type": "string"}, "text": {"type": "string"}, "confidence": {"type": "number"}},
    "required": ["id", "text"]}}}, "required": ["fixed"]}
P4_SCHEMA = {"type": "object", "properties": {
    "kept": {"type": "array", "items": {"type": "string"}},
    "discarded": {"type": "array", "items": {"type": "object", "properties": {
        "record_id": {"type": "string"}, "reason": {"type": "string"}}, "required": ["record_id", "reason"]}}},
    "required": ["kept", "discarded"]}

def assemble_keys(eids):
    rows = []
    for e in eids:
        rows += con.execute("SELECT kl.ts_ms,kl.char,kl.is_backspace,kl.modifiers FROM keystroke_log kl "
                            "JOIN typing_events te ON kl.bundle_id=te.bundle_id "
                            "WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000", (e,)).fetchall()
    out = ""
    for ts, c, bs, mod in sorted(rows, key=lambda r: r[0]):
        if (mod & 0x07) != 0: continue
        if bs: out += "<BS>"; continue
        if c: out += "<CR>" if c in ("\n", "\r") else c
    return out[:700]

def app_url(eids):
    r = con.execute("SELECT bundle_id,url FROM typing_events WHERE id=?", (eids[0],)).fetchone()
    return (r[0] or '', r[1] or '') if r else ('', '')
def fmt(m): return m.replace('\n', ' ⏎ ').strip()

# ---- 收集有变化的会话 ----
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = M.PH
sessions = []
for day in DAYS:
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        evs = M.loadev(ids)
        if not evs: continue
        old_seg = M.oldExtract(evs, PH); new_seg = M.newExtract(evs)
        if set(old_seg) == set(new_seg): continue
        bundle, url = app_url(ids)
        sessions.append(dict(day=day, ids=ids, app=bundle.split('.')[-1], bundle=bundle, url=url,
                             ks=assemble_keys(ids), old_seg=old_seg, new_seg=new_seg))
# 补 #3 类(staged 无记录,对照循环看不到)
for label, lit in [("Google Doc 蓝图随笔", [588, 589, 590]), ("Safari 英文随笔", [674, 675])]:
    evs = M.loadev(lit); b, u = app_url(lit)
    sessions.append(dict(day="(#3恢复)", ids=lit, app=b.split('.')[-1] + " · " + label, bundle=b, url=u,
                         ks=assemble_keys(lit), old_seg=[], new_seg=M.newExtract(evs)))
print(f"有变化会话 {len(sessions)} 个", flush=True)

def run_gen(m, tok, ted, vs, schema, user, mx):
    pr = tok.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = generate(m, tok, prompt=pr, max_tokens=mx, verbose=False, logits_processors=[MC.json_processor(schema, ted, vs)])
        return json.loads(out)
    except Exception:
        return None

# ---- 阶段1: AxCleanup (Qwen3-4B) ----
print("加载 Qwen3-4B 做 AxCleanup…", flush=True)
m4, tok4 = load("mlx-community/Qwen3-4B-4bit"); ted4, vs4 = MC.tokenizer_data(tok4, "qwen3-4b")
def axclean(msgs, ks, bundle, url):
    if not msgs: return []
    items = [{"id": f"r{i}", "text": t, "keystroke": ks} for i, t in enumerate(msgs)]
    user = AXCLEAN_PROMPT + f"\n\napp: {bundle}\nurl: {url}\n\nitems:\n" + json.dumps(items, ensure_ascii=False)
    d = run_gen(m4, tok4, ted4, vs4, AX_SCHEMA, user, 1400)
    fixed = {x["id"]: x.get("text", "") for x in (d or {}).get("fixed", [])}
    res = []
    for i, t in enumerate(msgs):
        ft = re.sub(r'<think>.*?</think>', '', fixed.get(f"r{i}", t), flags=re.S).strip()
        if ft: res.append(ft)
    seen = set(); return [x for x in res if not (x in seen or seen.add(x))]
# AxCleanup 之后、Pass4 之前的确定性去重(对齐真实 pipeline 的 trimLatinTail supersede + mergePrefixDrafts):
# 丢掉「(去掉末尾≤3拉丁残尾后)是同组另一条更长记录的严格前缀」的早期草稿。
def dedup_drafts(records):
    def trim_tail(s):
        v = s; n = 0
        while v and (v[-1] == ' ' or (v[-1].isascii() and v[-1].isalpha())): v = v[:-1]; n += 1
        return v.strip() if 1 <= n <= 3 else s
    keep = []
    for i, a in enumerate(records):
        sa = trim_tail(a).strip()
        if len(sa) >= 2 and any(j != i and len(b) > len(sa) and b.startswith(sa) for j, b in enumerate(records)):
            continue
        keep.append(a)
    seen = set(); return [x for x in keep if not (x in seen or seen.add(x))]

t0 = time.time()
for i, s in enumerate(sessions):
    s['old_clean'] = dedup_drafts(axclean(s['old_seg'], s['ks'], s['bundle'], s['url']))
    s['new_clean'] = dedup_drafts(axclean(s['new_seg'], s['ks'], s['bundle'], s['url']))
    print(f"  ax {i+1}/{len(sessions)} {s['day']} ev{s['ids'][0]}", flush=True)
print(f"AxCleanup 完成 {time.time()-t0:.0f}s", flush=True)
del m4, tok4; gc.collect()

# ---- 阶段2: Pass4 (Qwen3-1.7B) ----
print("加载 Qwen3-1.7B 做 Pass4…", flush=True)
m17, tok17 = load("mlx-community/Qwen3-1.7B-4bit"); ted17, vs17 = MC.tokenizer_data(tok17, "qwen3-1.7b")
def pass4(records):
    if not records: return []
    recs = [{"record_id": f"p{i}", "text": t} for i, t in enumerate(records)]
    user = PASS4_PROMPT + "\n\nrecords:\n" + json.dumps(recs, ensure_ascii=False)
    d = run_gen(m17, tok17, ted17, vs17, P4_SCHEMA, user, 800)
    disc = {x["record_id"] for x in (d or {}).get("discarded", [])}
    return [t for i, t in enumerate(records) if f"p{i}" not in disc]
t0 = time.time()
for i, s in enumerate(sessions):
    s['old_final'] = pass4(s['old_clean'])
    s['new_final'] = pass4(s['new_clean'])
    print(f"  p4 {i+1}/{len(sessions)} {s['day']} ev{s['ids'][0]}: 老{len(s['old_final'])} 新{len(s['new_final'])}", flush=True)
print(f"Pass4 完成 {time.time()-t0:.0f}s", flush=True)

# ---- 生成 md ----
out = ["# 老 pipeline vs 新 pipeline【最终成品】对比(AxCleanup + Pass4 之后)\n",
       "> **MLX + JSON约束(发版同环境)**。apples-to-apples:老切分 & 新切分**都过同一套本地 pass**",
       "> —— AxCleanup=Qwen3-4B-4bit(真prompt,击键补拼音) / Pass4=Qwen3-1.7B-4bit(真prompt keep-discard),**唯一变量=切分**。",
       "> ⚠️ 两边都本地小模型,**老这列会和你之前看的线上 staged 略有出入**(残渣清不干净=模型差异,非切分);",
       "> 重点看**切分带来的结构差异**(长消息回来没、事件内多发送、占位符/碎片)。\n", "---\n"]
for s in sessions:
    out.append(f"### [{s['day']}] `{s['app']}` · ev{s['ids'][0]}…\n")
    out.append("**老切分 → 成品:**")
    out += [f"- {fmt(m)}" for m in s['old_final']] or ["- *(无)*"]
    if not s['old_final']: out.append("- *(无 / #3 线上整组丢)*")
    out.append("\n**新切分 → 成品:**")
    out += [f"- {fmt(m)}" for m in s['new_final']] or ["- *(无)*"]
    out.append("\n---\n")
path = os.path.expanduser("~/Desktop/Pipeline最终成品对比-老vs新.md")
open(path, "w").write("\n".join(out))
print(f"\n已生成: {path}  ({len(sessions)} 会话)", flush=True)
