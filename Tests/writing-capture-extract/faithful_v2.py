#!/usr/bin/env python3
"""⚠️ failed 版本(2026-06,用户标记)—— 本地 14B disambig + 8B Pass4 的 IME 重建尝试,**待用户定点修**。
已知 bug(文件内注释也有):的/得助词、librime 词库无的 slang(如"卖个惨")、H/I 截断尾巴、canvas 跨app尾巴;
且**依赖旧 writing_records_staged 做分组**。用户在评估它、逐点修;改方向由用户决断。
librime 已搬进项目 rime/(不再用 /tmp)。生产当前仍是云端 haiku 老 pipeline。

阶段0 集成全量重跑:
event_sends_with_ts(真发送+is_send) → rebuild 重建(librime + 14b disambig + 残渣调和)
→ 组级击键 gate / slash gate → dedup_truncated(类4/5a) → is_residue → 8b Pass4 → 合云端 canvas
→ 写 Obsidian 对照文档。两阶段加载省内存:14b 重建 → 卸载 → 8b Pass4。"""
import json, os, re, sqlite3, gc
import harness as H
import rebuild as R
import extract_compare_v2 as X
import mlx_constrained as MC
from mlx_lm import load, generate

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()

# ---- helpers ----
def sess_events(ids):
    out = []
    for e in ids:
        r = con.execute("SELECT started_at,ended_at,bundle_id FROM typing_events WHERE id=?", (e,)).fetchone()
        if r: out.append(r)
    return out
def group_kc(ids):
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
def convo_ctx(ev):
    r = con.execute("SELECT bundle_id FROM typing_events WHERE id=?", (ev['id'],)).fetchone()
    if not r: return ""
    bundle = r[0]; app = bundle.split('.')[-1]
    day = con.execute("SELECT date_utc FROM writing_records_staged WHERE reference_typing_event_ids LIKE ? LIMIT 1", (f"%{ev['id']}%",)).fetchone()
    rows = []
    if day:
        rows = [x[0] for x in con.execute("SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts", (day[0], "%" + app + "%")).fetchall()]
    return f"app:{app}\n最近对话:\n" + "\n".join(f"  - {t[:40]}" for t in rows[:24])

def is_residue(t):
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9]{1,4}', c): return True
    if re.fullmatch(r'[a-z]{1,4}( [a-z]{1,5}){1,}', c): return True
    if re.search(r'[一-鿿]\s*[a-z]{1,3}(?: [a-z]{1,3})+$', c) and len(c) <= 25: return True
    return False
def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def rec_md(n, src, kind, app, text): return f"**{n}.** `[{src}/{kind}]` 📍 `{app}`\n\n> " + text.replace("\n", "\n> ") + "\n"

# ===== Phase 1: 重建(14b disambig) =====
print("=== Phase1: 加载 14b 做 IME 重建 ===", flush=True)
m14, tok14 = load("mlx-community/Qwen3-14B-4bit")
def disambig(p):
    if p.get('mode') != 'disambig': return None
    top = p['top']; alt = [w for w in p['words'] if w != top]
    user = ("用户在聊天 app 里用拼音打字,输入法默认上屏了一个词,但可能选错同音字。结合上下文判断默认对不对:"
            "对就保留,只在明显选错(同音字不合语境)时才换。\n"
            f"上下文(当前句已确定的前文 + app + 最近对话):\n{p['context'][:400]}\n"
            f"拼音「{p['py']}」默认上屏=「{top}」。其他同音候选: {' / '.join(alt[:6])}\n"
            "输出这里最合理的那个词(默认合理就输出默认那个)。只输出一个词,别的不要。")
    pr = tok14.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = re.sub(r'<think>.*?</think>', '', generate(m14, tok14, prompt=pr, max_tokens=24, verbose=False), flags=re.S).strip()
        mm = re.search(r'[一-鿿]+', out); return mm.group(0) if mm else None
    except Exception:
        return None

RAW = {}   # day -> [(app, text, is_send, kc)]
for day in DAYS:
    dayrecs = []
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        if not ids: continue
        evs = X.loadev(ids)
        if not evs: continue
        kc = group_kc(ids); ks_full = assemble_keys(ids)
        grp = []
        for ev in evs:
            ctx = convo_ctx(ev); app = ev['bundle'].split('.')[-1]
            for text, t0, t1, is_send in R.event_sends_with_ts(ev, X):
                kw = R.keys_in_window(con, ev['bundle'], t0, t1)
                fixed, _ = R.reconstruct_message(text, kw, context=ctx, model_fn=disambig)
                if cv(fixed): grp.append((app, cv(fixed), is_send))
        total = sum(len(t) for _, t, _ in grp)
        if total > 20 and kc < total // 4: continue                 # 组级击键 gate
        kst = ks_full.replace("<CR>", "").replace("<BS>", "").strip()
        if kst.startswith("/"): continue                            # slash gate
        for app, t, s in grp: dayrecs.append((app, t, s, kc))
    # dedup_truncated(类4/5a)+ is_residue + 精确去重
    drecs = R.dedup_truncated([(t, s, a) for a, t, s, _ in dayrecs], X.cover)
    keepset = set((t, s, a) for t, s, a in drecs)
    out, seen = [], set()
    for app, t, s, kc in dayrecs:
        if (t, s, app) in keepset and not is_residue(t) and t not in seen:
            seen.add(t); out.append((app, t, kc))
    RAW[day] = out
    print(f"  {day}: {len(out)} 条(14b disambig 调用累计 {R.DISAMBIG_CALLS[0]})", flush=True)
json.dump(RAW, open("/tmp/rime-test/eval/v2_rebuilt.json", "w"), ensure_ascii=False)
del m14, tok14; gc.collect()
print(f"Phase1 完成,14b disambig 共调用 {R.DISAMBIG_CALLS[0]} 次", flush=True)

# ===== Phase 2: Pass4(8b) =====
print("=== Phase2: 加载 8b 做 Pass4 ===", flush=True)
m8, tok8 = load("mlx-community/Qwen3-8B-4bit"); ted, vs = MC.tokenizer_data(tok8, "qwen3-8b")
def gen(schema, user, mx):
    pr = tok8.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = generate(m8, tok8, prompt=pr, max_tokens=mx, verbose=False, logits_processors=[MC.json_processor(schema, ted, vs)])
        return json.loads(re.sub(r'<think>.*?</think>', '', out, flags=re.S).strip())
    except Exception: return None
P4 = H.prompt("pass4ContentReview")
rej = con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 28").fetchall()
rejex = [{"text": (r[0] or '')[:200], "app": r[1], "kind": r[2], "reason": r[4] or r[3]} for r in rej]
P4_SCHEMA = {"type": "object", "properties": {"kept": {"type": "array", "items": {"type": "string"}}, "discarded": {"type": "array", "items": {"type": "object", "properties": {"record_id": {"type": "string"}, "reason": {"type": "string"}}, "required": ["record_id", "reason"]}}}, "required": ["kept", "discarded"]}
def pass4(recs):
    if not recs: return []
    Rr = [{"record_id": f"p{i}", "text": t, "kind": kind_of(t), "source": "ax_cleaned", "app": a, "url": None, "keystroke_count": kc, "context_summary": None} for i, (a, t, kc) in enumerate(recs)]
    user = P4 + "\n\nuser_rejected_examples:\n" + json.dumps(rejex, ensure_ascii=False) + "\n\nrecords:\n" + json.dumps(Rr, ensure_ascii=False)
    d = gen(P4_SCHEMA, user, 2000)
    disc = {x["record_id"] for x in (d or {}).get("discarded", [])}
    return [recs[i] for i in range(len(recs)) if f"p{i}" not in disc]
FINAL = {}
for day in DAYS:
    recs = RAW[day]; kept = []
    for i in range(0, len(recs), 12): kept += pass4(recs[i:i+12])
    FINAL[day] = kept
    print(f"  {day}: {len(recs)} → Pass4 后 {len(kept)}", flush=True)

# ===== 写 Obsidian 文档 =====
CV = json.load(open("/tmp/rime-test/eval/canvas_cloud.json"))
nd = ["# 新 pipeline·成品(阶段0 集成:librime + 14b disambig 重建)\n",
      "**全本地 IME 重建**:event_sends_with_ts(回车检测真发送)+ rebuild(librime 确定性打底 + 14b 同音消歧 + 残渣/击键调和)",
      "+ 组级击键 gate + slash gate + **dedup_truncated**(类4/5a 去截断态)+ is_residue + **8b Pass4**。Canvas=云端。\n",
      "⚠️ 已知小瑕疵(待修):的/得(睡得 vs 睡的)、librime 词库无的 slang(卖个惨)、H/I 截断尾巴、canvas 跨app尾巴。\n",
      f"天数:{', '.join(DAYS)}\n", "---\n"]
for day in DAYS:
    out = [("ax_cleaned", t, a) for a, t, kc in FINAL[day]] + [(r["source"], r["text"], r["app"]) for r in CV.get(day, [])]
    nd.append(f"## {day}\n"); nd.append(f"### 🆕 新 pipeline·成品（{len(out)}）\n")
    for i, (src, text, app) in enumerate(out, 1): nd.append(rec_md(i, src, kind_of(text), app, text))
    nd.append("\n---\n")
path = "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-阶段0.md"
open(path, "w").write("\n".join(nd))
print(f"已写 {path}", flush=True)
