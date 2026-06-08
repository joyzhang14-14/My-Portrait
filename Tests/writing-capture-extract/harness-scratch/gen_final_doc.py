#!/usr/bin/env python3
"""老 vs 新 pipeline【最终成品】(AxCleanup + Pass4 之后)对比 → 桌面 md。
老成品 = 库里 staged(线上,真实);新成品 = 新切分(v2)→ AxCleanup(qwen3:4b,真prompt,击键补拼音)
→ 去重 → Pass4(qwen3:1.7b,真prompt keep/discard)。只跑有变化的会话。
caveat: 新的两个 pass 用本地小模型,老 staged 当时可能云端,残渣处理会有模型差异。"""
import json, os, sys, re, difflib
import harness as H
import extract_compare_v2 as M
from llm import call

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
        for k in con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log kl "
                              "JOIN typing_events te ON kl.bundle_id=te.bundle_id "
                              "WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000", (e,)).fetchall():
            rows.append(k)
    out = ""
    for ts, c, bs, mod in sorted(rows, key=lambda r: r[0]):
        if (mod & 0x07) != 0: continue
        if bs: out += "<BS>"; continue
        if c: out += "<CR>" if c in ("\n", "\r") else c
    return out[:700]

def axcleanup(msgs, ks, app, url):
    if not msgs: return []
    items = [{"id": f"r{i}", "text": t, "keystroke": ks} for i, t in enumerate(msgs)]
    user = (AXCLEAN_PROMPT + f"\n\napp: {app}\nurl: {url}\n\nitems:\n"
            + json.dumps(items, ensure_ascii=False))
    try:
        out, _ = call("qwen3:4b", user, num_ctx=8192, fmt=AX_SCHEMA)
        fixed = {x["id"]: x.get("text", "") for x in json.loads(out).get("fixed", [])}
    except Exception:
        fixed = {}
    res = []
    for i, t in enumerate(msgs):
        ft = fixed.get(f"r{i}", t)
        ft = re.sub(r'<think>.*?</think>', '', ft, flags=re.S).strip()
        if ft: res.append(ft)
    # 去重保序
    seen = set(); return [x for x in res if not (x in seen or seen.add(x))]

def pass4(records):   # records: list of text; 返回 kept 文本
    if not records: return []
    recs = [{"record_id": f"p{i}", "text": t} for i, t in enumerate(records)]
    user = PASS4_PROMPT + "\n\nrecords:\n" + json.dumps(recs, ensure_ascii=False)
    try:
        out, _ = call("qwen3:1.7b", user, num_ctx=12288, fmt=P4_SCHEMA)
        d = json.loads(out)
        disc = {x["record_id"] for x in d.get("discarded", [])}
    except Exception:
        disc = set()
    return [t for i, t in enumerate(records) if f"p{i}" not in disc]

def app_url(eids):
    r = con.execute("SELECT bundle_id,url FROM typing_events WHERE id=?", (eids[0],)).fetchone()
    return (r[0] or '', r[1] or '') if r else ('', '')

def fmt(m): return m.replace('\n', ' ⏎ ').strip()

DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = M.PH
ONE = len(sys.argv) > 1 and sys.argv[1] == "one"

out = ["# 老 pipeline vs 新 pipeline【最终成品】对比(过完 AxCleanup + Pass4)\n",
       "> **apples-to-apples**:老切分 vs 新切分,**两边都用同一套本地 pass 重跑**",
       "> (AxCleanup=qwen3:4b 真prompt击键补拼音 / Pass4=qwen3:1.7b 真prompt keep-discard),**唯一变量=切分**。",
       "> ⚠️ 因为两边都用本地小模型,**老这列会和你之前看的线上 staged 略有出入**(残渣清不干净=模型差异,不是切分);",
       "> 重点看**切分带来的结构差异**(长消息有没有回来、事件内多发送、占位符/碎片)。\n", "---\n"]

processed = 0
for day in DAYS:
    sess_rows = con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall()
    for (refs,) in sess_rows:
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        evs = M.loadev(ids)
        if not evs: continue
        old_seg = M.oldExtract(evs, PH); new_seg = M.newExtract(evs)
        # 只处理切分有变化的
        if set(old_seg) == set(new_seg): continue
        bundle, url = app_url(ids); app = bundle.split('.')[-1]
        ks = assemble_keys(ids)
        # apples-to-apples:老/新切分都过同一套本地 pass
        old_final = pass4(axcleanup(old_seg, ks, bundle, url))
        new_final = pass4(axcleanup(new_seg, ks, bundle, url))
        out.append(f"### [{day}] `{app}` · ev{ids[0]}…\n")
        out.append("**老切分 → 成品:**")
        for m in old_final: out.append(f"- {fmt(m)}")
        if not old_final: out.append("- *(无)*")
        out.append("\n**新切分 → 成品:**")
        for m in new_final: out.append(f"- {fmt(m)}")
        if not new_final: out.append("- *(无)*")
        out.append("\n---\n")
        processed += 1
        print(f"  {day} ev{ids[0]}: 老{len(old_final)} → 新{len(new_final)}", flush=True)
        if ONE: break
    if ONE and processed: break

path = os.path.expanduser("~/Desktop/Pipeline最终成品对比-老vs新.md")
open(path, "w").write("\n".join(out))
print(f"\n已生成: {path}  (处理 {processed} 个会话)")
