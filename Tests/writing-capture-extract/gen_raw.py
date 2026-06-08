#!/usr/bin/env python3
"""生成 v2 原始切分(真实分组)per day,带每会话击键文本(供云端解残渣拼音)。→ raw_msgs.json"""
import json, sqlite3, os
import extract_compare_v2 as M
con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
def assemble_keys(eids):
    rows=[]
    for e in eids:
        rows+=con.execute("SELECT kl.ts_ms,kl.char,kl.is_backspace,kl.modifiers FROM keystroke_log kl JOIN typing_events te ON kl.bundle_id=te.bundle_id WHERE te.id=? AND kl.ts_ms BETWEEN te.started_at-2000 AND te.ended_at+2000",(e,)).fetchall()
    out=""
    for ts,c,bs,mod in sorted(rows,key=lambda r:r[0]):
        if (mod&7)!=0: continue
        if bs: out+="<BS>"; continue
        if c: out+="<CR>" if c in("\n","\r") else c
    return out[:600]
def app_of(eid):
    r=con.execute("SELECT bundle_id FROM typing_events WHERE id=?",(eid,)).fetchone()
    return (r[0] or '').split('.')[-1] if r else '?'
out={}
for day in DAYS:
    sess=[]
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')",(day,)).fetchall():
        try: ids=[int(x) for x in json.loads(refs or '[]')]
        except: ids=[]
        if not ids: continue
        evs=M.loadev(ids)
        if not evs: continue
        msgs=M.newExtract(evs)
        if not msgs: continue
        sess.append({"app":app_of(ids[0]),"keystroke":assemble_keys(ids),"messages":msgs})
    out[day]=sess
    print(f"{day}: {len(sess)} 会话, {sum(len(s['messages']) for s in sess)} 条原始切分")
json.dump(out,open("/tmp/rime-test/eval/raw_msgs.json","w"),ensure_ascii=False,indent=1)
print("已存 raw_msgs.json")
