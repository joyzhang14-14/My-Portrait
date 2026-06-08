#!/usr/bin/env python3
"""Resumable local worker: MLX (in-app engine) + checkpointed job queue.
Demonstrates: process N units, hard-crash (power loss), resume the rest.
Work units = real Pass1 time-windows from a real day (June 6).
Usage:
  python3 local_worker.py seed
  python3 local_worker.py process [--crash-after N]
  python3 local_worker.py status
"""
import json, sqlite3, sys, time, os, datetime
import harness as H

JOBDB = "/tmp/rime-test/eval/local_jobs.sqlite"
MODEL = "mlx-community/Qwen3-1.7B-4bit"
WIN_H = 2

def jdb():
    c = sqlite3.connect(JOBDB); c.row_factory = sqlite3.Row
    c.execute("""CREATE TABLE IF NOT EXISTS jobs(
        id INTEGER PRIMARY KEY, kind TEXT, label TEXT, payload TEXT,
        state TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0,
        result TEXT, latency REAL, tps REAL, updated_at INTEGER)""")
    return c

def now(): return int(time.time())

# ---- seed real Pass1 windows from June 6 ----
def window_input(t0, t1):
    con = H.db()
    rows = con.execute("SELECT (started_at/600000)*600000 b,bundle_id,sum(total_chars) c,count(*) n FROM typing_events WHERE started_at BETWEEN ? AND ? GROUP BY b,bundle_id ORDER BY b",(t0,t1)).fetchall()
    typing=[{"ts":r["b"],"app":r["bundle_id"],"chars":r["c"],"events":r["n"]} for r in rows]
    fr=con.execute("SELECT id,timestamp_ms,app_name,browser_url,full_text FROM frames WHERE timestamp_ms BETWEEN ? AND ? AND full_text IS NOT NULL AND length(full_text)>20 ORDER BY timestamp_ms",(t0,t1)).fetchall()
    frames=[];last=0
    for f in fr:
        if f["timestamp_ms"]-last<60000: continue
        last=f["timestamp_ms"]
        frames.append({"frame_id":f["id"],"start_ts":f["timestamp_ms"],"app":f["app_name"],"url":f["browser_url"],"text":(f["full_text"] or "")[:450]})
        if len(frames)>=18: break
    con.close()
    return {"ocr_frames":frames,"typing_summary":typing,"keystroke_activity":[]}

def seed():
    c=jdb()
    if c.execute("SELECT count(*) n FROM jobs").fetchone()["n"]>0:
        print("already seeded"); return
    day="2026-06-06"
    base=int(datetime.datetime.strptime(day,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    n=0
    for h in range(0,24,WIN_H):
        w0=base+h*3600000; w1=w0+WIN_H*3600000
        inp=window_input(w0,w1)
        if not inp["typing_summary"] and not inp["ocr_frames"]: continue
        c.execute("INSERT INTO jobs(kind,label,payload,updated_at) VALUES(?,?,?,?)",
                  ("pass1_window",f"{h:02d}-{h+WIN_H:02d}h",json.dumps(inp,ensure_ascii=False),now()))
        n+=1
    c.commit(); print(f"seeded {n} jobs (real June-6 Pass1 windows)")

# ---- MLX worker ----
_M=None
def run_mlx(payload):
    global _M
    from mlx_lm import load, generate
    if _M is None: _M=load(MODEL)
    m,tok=_M
    p=H.prompt("pass1ContextTimeline").replace("a day's worth","a TIME WINDOW")
    user=("/no_think\n"+p+"\n\nINPUT:\n"+payload+"\n\nOutput ONLY the JSON object.")
    prompt=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False)
    t=time.time()
    out=generate(m,tok,prompt=prompt,max_tokens=1200,verbose=False)
    dt=time.time()-t
    import re
    out=re.sub(r"<think>.*?</think>","",out,flags=re.S).strip()
    ntok=len(tok.encode(out))
    return out, dt, ntok/dt if dt>0 else 0

def process(crash_after=None):
    c=jdb()
    # resume: reset stale 'processing' (left by a crash) back to pending
    stale=c.execute("UPDATE jobs SET state='pending' WHERE state='processing'").rowcount
    if stale: print(f"[resume] reset {stale} stale processing -> pending"); c.commit()
    done_this=0
    while True:
        job=c.execute("SELECT * FROM jobs WHERE state='pending' ORDER BY id LIMIT 1").fetchone()
        if not job: break
        c.execute("UPDATE jobs SET state='processing',attempts=attempts+1,updated_at=? WHERE id=?",(now(),job["id"])); c.commit()
        try:
            out,dt,tps=run_mlx(job["payload"])
            try: nseg=len(json.loads(out).get("timeline",[]))
            except: nseg=-1
            # ATOMIC: write result + mark done in one statement
            c.execute("UPDATE jobs SET state='done',result=?,latency=?,tps=?,updated_at=? WHERE id=?",
                      (out,round(dt,1),round(tps,1),now(),job["id"])); c.commit()
            print(f"  done #{job['id']} {job['label']}  {dt:5.1f}s  {tps:.0f} tok/s  -> {nseg} 段")
            done_this+=1
            if crash_after and done_this>=crash_after:
                print(f"  💥 模拟断电(硬退出,正在跑的下一个 job 留在 processing)"); os._exit(1)
        except Exception as e:
            c.execute("UPDATE jobs SET state='pending',updated_at=? WHERE id=?",(now(),job["id"])); c.commit()
            print(f"  ERR #{job['id']} {e} -> 留 pending 待重试")
    print("队列清空")

def status():
    c=jdb()
    for r in c.execute("SELECT state,count(*) n FROM jobs GROUP BY state").fetchall():
        print(f"  {r['state']:<12} {r['n']}")
    tot=c.execute("SELECT count(*) n FROM jobs").fetchone()["n"]
    done=c.execute("SELECT count(*) n FROM jobs WHERE state='done'").fetchone()["n"]
    print(f"  ---- {done}/{tot} 完成")

if __name__=="__main__":
    cmd=sys.argv[1] if len(sys.argv)>1 else "status"
    if cmd=="seed": seed()
    elif cmd=="process":
        ca=None
        if "--crash-after" in sys.argv: ca=int(sys.argv[sys.argv.index("--crash-after")+1])
        process(ca)
    else: status()
