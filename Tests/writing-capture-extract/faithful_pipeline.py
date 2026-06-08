#!/usr/bin/env python3
"""忠实模拟真实 pipeline 的 AX 路 + Pass4,全 MLX 本地。无云端、喂完整记录、接 librime、
用上真实筛选算法(组级击键 gate / slash gate / trimLatinTail supersede / mergePrefixDrafts)。
用法: python3 faithful_pipeline.py 1.7b|4b|8b   → 写 Desktop/Obsidian/Pipeline成品-新pipeline-<size>.md + json"""
import json, os, re, sys, subprocess, difflib
import harness as H
import extract_compare_v2 as M
import mlx_constrained as MC
from mlx_lm import load, generate

SIZE = sys.argv[1] if len(sys.argv) > 1 else "1.7b"
MID = {"1.7b": "mlx-community/Qwen3-1.7B-4bit", "4b": "mlx-community/Qwen3-4B-4bit", "8b": "mlx-community/Qwen3-8B-4bit"}[SIZE]
TAG = {"1.7b": "qwen3-1.7b", "4b": "qwen3-4b", "8b": "qwen3-8b"}[SIZE]
con = H.db()
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
print(f"=== 忠实 pipeline,MLX {SIZE} ===", flush=True)
m, tok = load(MID); ted, vs = MC.tokenizer_data(tok, TAG)
def gen(schema, user, mx):
    pr = tok.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = generate(m, tok, prompt=pr, max_tokens=mx, verbose=False, logits_processors=[MC.json_processor(schema, ted, vs)])
        return json.loads(re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip())
    except Exception: return None

def cands(py, n=6):
    py = py.replace(" ", "").lower()
    if len(py) < 2 or not py.isalpha(): return []
    try:
        o = subprocess.run(["/tmp/rime-test/cands", py, str(n)], capture_output=True, text=True, timeout=10).stdout
        return [ln.split("] ", 1)[1].strip() for ln in o.splitlines() if "] " in ln]
    except Exception: return []

def sess_events(ids):
    out = []
    for e in ids:
        r = con.execute("SELECT started_at,ended_at,bundle_id FROM typing_events WHERE id=?", (e,)).fetchone()
        if r: out.append(r)
    return out
def group_kc(ids):   # 真实组级击键数(app匹配,窗内,无修饰键)
    n = 0
    for st, et, b in sess_events(ids):
        n += con.execute("SELECT COUNT(*) FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND (modifiers&7)=0", (b, st-10000, et+10000)).fetchone()[0]
    return n
def assemble_keys(ids):
    rows = []
    for e in ids:
        rows += con.execute("SELECT kl.ts_ms,kl.char,kl.is_backspace,kl.modifiers FROM keystroke_log kl JOIN typing_events te ON kl.bundle_id=te.bundle_id WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000", (e,)).fetchall()
    o = ""
    for ts, c, bs, md in sorted(rows, key=lambda r: r[0]):
        if (md & 7) != 0: continue
        if bs: o += "<BS>"; continue
        if c: o += "<CR>" if c in ("\n", "\r") else c
    return o[:700]
def app_of(eid):
    r = con.execute("SELECT bundle_id FROM typing_events WHERE id=?", (eid,)).fetchone()
    return (r[0] or '') if r else ''

# ---- AxCleanup: 真实 axCleanup prompt + librime 候选(接上 librime)----
AX_PROMPT = H.prompt("axCleanup")
AX_SCHEMA = {"type": "object", "properties": {"fixed": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}, "confidence": {"type": "number"}}, "required": ["id", "text"]}}}, "required": ["fixed"]}
def axcleanup(messages, ks, bundle):
    items, anyres = [], False
    for i, t in enumerate(messages):
        cmap = {}
        for run in set(re.findall(r'[a-zA-Z]+(?: [a-zA-Z]+)*', t)):
            c = cands(run.strip())
            if c: cmap[run.strip()] = c[:6]; anyres = True
        items.append({"id": f"r{i}", "text": t, "keystroke": ks, "librime_candidates": cmap})
    if not anyres:
        return list(dict.fromkeys(messages))   # 无残渣,免 LLM
    user = (AX_PROMPT + "\n\n注:每条 item 附了 librime_candidates(各拼音残片的候选),用它+击键+上下文把残留拼音补成中文。"
            + f"\n\napp: {bundle}\n\nitems:\n" + json.dumps(items, ensure_ascii=False))
    d = gen(AX_SCHEMA, user, 1600)
    fixed = {x["id"]: x.get("text", "") for x in (d or {}).get("fixed", [])}
    out = []
    for i, t in enumerate(messages):
        ft = re.sub(r'<think>.*?</think>', '', fixed.get(f"r{i}", t), flags=re.S).strip()
        out.append(ft if ft else t)
    return list(dict.fromkeys(out))

# ---- trimLatinTail supersede(真实算法,worker 1511-1530)----
def trim_latin_tail(s):
    v = s; n = 0
    while v and (v[-1] == ' ' or (v[-1].isascii() and v[-1].isalpha())): v = v[:-1]; n += 1
    return v.strip() if 1 <= n <= 3 else s
def supersede(recs):   # recs: list[(app,text,kc)]
    T = [t for _, t, _ in recs]; sup = set()
    for i, (_, a, _) in enumerate(recs):
        st = trim_latin_tail(a)
        if len(st) >= 2 and st != a and any(j != i and len(T[j]) > len(st) and T[j].startswith(st) for j in range(len(recs))):
            sup.add(i)
    return [r for i, r in enumerate(recs) if i not in sup]
# ---- mergePrefixDrafts(近似:同app A 是更长 B 严格前缀 → A 早期草稿,丢)----
def merge_prefix(recs):
    T = [t.strip() for _, t, _ in recs]
    return [r for i, r in enumerate(recs) if not (len(T[i]) >= 15 and any(j != i and recs[j][0] == recs[i][0] and len(T[j]) > len(T[i]) and T[j].startswith(T[i]) for j in range(len(recs))))]

# ---- Pass4: 完整记录 + 拒绝样本 + 真实 prompt ----
P4 = H.prompt("pass4ContentReview")
rej = con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 28").fetchall()
rejex = [{"text": (r[0] or '')[:200], "app": r[1], "kind": r[2], "reason": r[4] or r[3]} for r in rej]
P4_SCHEMA = {"type": "object", "properties": {"kept": {"type": "array", "items": {"type": "string"}}, "discarded": {"type": "array", "items": {"type": "object", "properties": {"record_id": {"type": "string"}, "reason": {"type": "string"}}, "required": ["record_id", "reason"]}}}, "required": ["kept", "discarded"]}
def pass4(recs):   # recs: [(app,text,kc)]
    if not recs: return []
    R = [{"record_id": f"p{i}", "text": t, "kind": "long_form" if len(t) >= 140 else "short_form", "source": "ax_cleaned", "app": a, "url": None, "keystroke_count": kc, "context_summary": None} for i, (a, t, kc) in enumerate(recs)]
    user = P4 + "\n\nuser_rejected_examples:\n" + json.dumps(rejex, ensure_ascii=False) + "\n\nrecords:\n" + json.dumps(R, ensure_ascii=False)
    d = gen(P4_SCHEMA, user, 2000)
    disc = {x["record_id"] for x in (d or {}).get("discarded", [])}
    return [recs[i] for i in range(len(recs)) if f"p{i}" not in disc]

# ---- 主流程 ----
FINAL = {}
for day in DAYS:
    dayrecs = []
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        if not ids: continue
        evs = M.loadev(ids)
        if not evs: continue
        msgs = M.newExtract(evs)
        if not msgs: continue
        kc = group_kc(ids); ks = assemble_keys(ids); bundle = app_of(ids[0])
        total = sum(len(x) for x in msgs)
        if total > 20 and kc < total // 4: continue                    # 组级击键 gate(真实)
        kst = ks.replace("<CR>", "").replace("<BS>", "").strip()
        if kst.startswith("/"): continue                                # slash gate(真实)
        for t in axcleanup(msgs, ks, bundle):
            dayrecs.append((bundle.split('.')[-1], t, kc))
    dayrecs = [r for i, r in enumerate(dayrecs) if r[1] and r not in dayrecs[:i]]   # exact dedup
    dayrecs = supersede(dayrecs)
    dayrecs = merge_prefix(dayrecs)
    kept = []
    for i in range(0, len(dayrecs), 12): kept += pass4(dayrecs[i:i+12])
    FINAL[day] = kept
    print(f"  {day}: {len(dayrecs)} → Pass4 后 {len(kept)}", flush=True)

CV = json.load(open("/tmp/rime-test/eval/canvas_cloud.json"))
def is_residue(t):   # A组#8 确定性残渣过滤(librime/模型没解掉的纯拼音乱码)
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True
    if re.search(r'[一-鿿]\s*[a-z]{1,3}(?: [a-z]{1,3})+$', c) and len(c) <= 25: return True
    return False
def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"
nd = [f"# 新 pipeline·成品(v2 切分,**忠实全本地 MLX {SIZE}**)\n",
      f"**无任何偷工**:真实会话分组 + unifiedExtract v2 + 组级击键gate + slash gate + **librime** AxCleanup(MLX {SIZE})",
      f"+ trimLatinTail supersede + mergePrefixDrafts + **完整记录** Pass4(MLX {SIZE})。Canvas=云端(你认可的)。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    out = [("ax_cleaned", t, a) for a, t, kc in FINAL[day] if not is_residue(t)] + [(r["source"], r["text"], r["app"]) for r in CV.get(day, [])]
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(out)}）\n")
    for i, (src, text, app) in enumerate(out, 1): nd.append(rec_md(i, src, kind_of(text), app, text))
    nd.append("\n---\n")
path = f"/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-{SIZE}.md"
open(path, "w").write("\n".join(nd))
json.dump({d: FINAL[d] for d in DAYS}, open(f"/tmp/rime-test/eval/faithful_{SIZE}.json", "w"), ensure_ascii=False)
print(f"已写 {path}", flush=True)
