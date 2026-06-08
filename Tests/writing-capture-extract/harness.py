#!/usr/bin/env python3
"""Local-model eval harness for the writing-capture pipeline.
Reconstructs REAL inputs for Pass1/Pass3/Pass4 from ~/.portrait/portrait.sqlite,
runs candidate Ollama models on the project's REAL prompts, saves outputs for judging."""
import json, os, re, sqlite3, sys, time, urllib.request

DB = os.path.expanduser("~/.portrait/portrait.sqlite")
PROMPTS = "/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Memory/WritingCapturePrompts.swift"
OUT = "/tmp/rime-test/eval/out"; os.makedirs(OUT, exist_ok=True)

def db():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row; return c

def prompt(name):
    src = open(PROMPTS).read()
    m = re.search(r'static let %s = #"""(.*?)"""#' % name, src, re.S)
    return m.group(1).strip()

# ---------- keystroke assembly (mirrors assembleKeystrokeText) ----------
def assemble_keys(keys):
    out = ""
    for k in sorted(keys, key=lambda r: r["ts_ms"]):
        if (k["modifiers"] & 0x07) != 0: continue
        if k["is_backspace"]: out += "<BS>"; continue
        c = k["char"]
        if c: out += "<CR>" if c in ("\n", "\r") else c
    return out[:2000]

def shortcut_of(mods, char):
    m = mods
    if m & 0x08:  # cmd
        return {"v":"paste","x":"cut","c":"copy","z":"undo"}.get((char or "").lower())
    return None

# ---------- Pass 3 input reconstruction ----------
def pass3_sample(rec):
    refs = json.loads(rec["reference_typing_event_ids"] or "[]")
    if not refs: return None
    con = db()
    qs = ",".join("?"*len(refs))
    evs = con.execute(f"SELECT id,text,edit_log,end_value,session_start,started_at,ended_at,total_chars,url FROM typing_events WHERE id IN ({qs}) ORDER BY started_at", refs).fetchall()
    if not evs: return None
    t0 = min(e["started_at"] for e in evs) - 5000
    t1 = max(e["ended_at"] for e in evs) + 5000
    keys = con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",
                       (rec["app"], t0, t1)).fetchall()
    # ax path: NO OCR frames (worker only uses OCR for canvas path). Pulling arbitrary
    # frames by app name pollutes the input with UI chrome -> models transcribe the chrome.
    frames = []
    con.close()
    klog = [{"ts":k["ts_ms"],"char":k["char"],"bs":bool(k["is_backspace"]),
             "mods":("cmd" if k["modifiers"]&0x08 else None),
             "shortcut":shortcut_of(k["modifiers"],k["char"])} for k in keys]
    typing_events = [{"id":e["id"],"text":e["text"],"edit_log":json.loads(e["edit_log"] or "[]"),
                      "end_value":e["end_value"]} for e in evs]
    session = {
        "session_id": refs[0],
        "start_ts": evs[0]["started_at"], "end_ts": evs[-1]["ended_at"],
        "keystroke_text": assemble_keys(keys),
        "keystroke_count": sum(1 for k in keys if (k["modifiers"]&0x07)==0 and not k["is_backspace"]),
        "typing_events": typing_events,
        "keystroke_log": klog,
        "ocr_frames": [{"frame_id":f["id"],"ts":f["timestamp_ms"],"text":(f["full_text"] or "")[:600]} for f in frames],
        "chrome_tokens": [],
    }
    inp = {
        "context_timeline": [{"start_ts":evs[0]["started_at"],"end_ts":evs[-1]["ended_at"],
                              "app":rec["app"],"url":rec["url"],"intent_type":"chat",
                              "summary": rec["context_summary"] or ""}],
        "group_meta": {"app":rec["app"],"url":rec["url"] or "","session_count":1,"user_languages":["zh","en"]},
        "raw_sessions": [session],
    }
    return {"record_id":rec["id"], "input":inp, "ground_truth":rec["text"],
            "input_endvalue": evs[-1]["end_value"], "keystroke_text": session["keystroke_text"],
            "kind":rec["kind"], "source":rec["source"]}

def pick_pass3(n=4):
    con = db()
    rows = con.execute("""SELECT id,app,url,text,reference_typing_event_ids,context_summary,kind,source
        FROM writing_records WHERE source='ax_cleaned' AND reference_typing_event_ids IS NOT NULL
        AND reference_typing_event_ids != '[]' AND length(text)>4
        ORDER BY start_ts DESC LIMIT 400""").fetchall()
    con.close()
    out=[]
    for r in rows:
        refs = json.loads(r["reference_typing_event_ids"] or "[]")
        if len(refs) != 1: continue          # single-event records: clean input<->truth alignment
        if len(r["text"]) < 6: continue
        s = pass3_sample(r)
        if s: out.append(s)
        if len(out)>=n: break
    return out

# ---------- Pass 1 input reconstruction (a real day) ----------
def pick_busy_day():
    con = db()
    # day (UTC) with the most typing_events
    row = con.execute("""SELECT strftime('%Y-%m-%d', started_at/1000, 'unixepoch') d, count(*) n
        FROM typing_events GROUP BY d ORDER BY n DESC LIMIT 1""").fetchone()
    con.close(); return row["d"]

def pass1_sample(day=None):
    day = day or pick_busy_day()
    con = db()
    import datetime
    t0 = int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    t1 = t0 + 86400000
    # typing_summary aggregated to per-(10min, app) buckets so a full day fits a small ctx
    rows = con.execute("""SELECT (started_at/600000)*600000 b, bundle_id, sum(total_chars) c, count(*) n
        FROM typing_events WHERE started_at BETWEEN ? AND ? GROUP BY b,bundle_id ORDER BY b""",(t0,t1)).fetchall()
    typing_summary = [{"ts":r["b"],"app":r["bundle_id"],"chars":r["c"],"events":r["n"]} for r in rows]
    # frames anchored near typing activity, ~1 per 90s bucket, capped
    fr = con.execute("""SELECT id,timestamp_ms,app_name,browser_url,full_text FROM frames
        WHERE timestamp_ms BETWEEN ? AND ? AND full_text IS NOT NULL AND length(full_text)>20
        ORDER BY timestamp_ms""",(t0,t1)).fetchall()
    frames=[]; last=0
    for f in fr:
        if f["timestamp_ms"]-last < 90000: continue
        last=f["timestamp_ms"]
        frames.append({"frame_id":f["id"],"start_ts":f["timestamp_ms"],"end_ts":f["timestamp_ms"]+1000,
                       "app":f["app_name"],"url":f["browser_url"],"text":(f["full_text"] or "")[:400]})
        if len(frames)>=35: break
    ks = con.execute("""SELECT (ts_ms/600000)*600000 m, bundle_id, count(*) c FROM keystroke_log
        WHERE ts_ms BETWEEN ? AND ? GROUP BY m,bundle_id ORDER BY m""",(t0,t1)).fetchall()
    keystroke_activity=[{"ts_bucket":k["m"],"app":k["bundle_id"],"count":k["c"]} for k in ks]
    con.close()
    return {"day":day,"input":{"ocr_frames":frames,"typing_summary":typing_summary,"keystroke_activity":keystroke_activity}}

# ---------- Pass 4 input reconstruction (kept vs discarded classification) ----------
def _kc_for_window(app, t0, t1):
    con=db(); n=con.execute("SELECT count(*) c FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND (modifiers&7)=0 AND is_backspace=0",(app,t0,t1)).fetchone()["c"]; con.close(); return n

def pass4_batch(n_keep=5, n_drop=5):
    con=db()
    kept = con.execute("""SELECT id,app,url,text,kind,source,context_summary,reference_typing_event_ids,start_ts,end_ts
        FROM writing_records WHERE source IN ('ax_cleaned','canvas_fusion','merged') AND length(text)>3
        ORDER BY start_ts DESC LIMIT ?""",(n_keep,)).fetchall()
    drop = con.execute("""SELECT id,reason,preview,kind,session_ids FROM writing_records_discarded
        WHERE preview IS NOT NULL AND length(preview)>2 ORDER BY created_at DESC LIMIT ?""",(n_drop,)).fetchall()
    rej = con.execute("SELECT text,app,kind,reason_category,reason_text FROM writing_records_user_rejected LIMIT 28").fetchall()
    con.close()
    recs=[]; truth={}
    for i,r in enumerate(kept):
        kc = _kc_for_window(r["app"], r["start_ts"]-10000, r["end_ts"]+10000)
        rid=f"k{i}"
        recs.append({"record_id":rid,"text":r["text"],"kind":r["kind"],"source":r["source"],
                     "app":r["app"],"url":r["url"],"keystroke_count":kc,"context_summary":r["context_summary"]})
        truth[rid]="keep"
    for i,d in enumerate(drop):
        rid=f"d{i}"
        recs.append({"record_id":rid,"text":d["preview"],"kind":d["kind"] or "short_form","source":"ax_cleaned",
                     "app":"com.unknown","url":None,"keystroke_count":0,"context_summary":None})
        truth[rid]="discard"
    rejex=[{"text":(x["text"] or "")[:200],"app":x["app"],"kind":x["kind"],
            "reason":x["reason_text"] or x["reason_category"]} for x in rej]
    # interleave so order doesn't leak labels
    import itertools
    order=[x for pair in itertools.zip_longest(recs[:n_keep],recs[n_keep:]) for x in pair if x]
    return {"records":order,"user_rejected":rejex,"truth":truth}

if __name__ == "__main__":
    if sys.argv[1:] == ["smoke3"]:
        s = pick_pass3(1)[0]
        print("record_id:", s["record_id"], "| ground_truth:", s["ground_truth"][:60])
        print("keystroke_text:", s["input"]["raw_sessions"][0]["keystroke_text"][:120])
        print("n typing_events:", len(s["input"]["raw_sessions"][0]["typing_events"]))
        print("n keystroke_log:", len(s["input"]["raw_sessions"][0]["keystroke_log"]))
        print("input json bytes:", len(json.dumps(s["input"], ensure_ascii=False)))
