#!/usr/bin/env python3
"""Gemma 4 vision vs Qwen3-4B OCR-text 的 A/B(clean 阶段)。

问题:OCR→文本 引入 chrome 污染/错字。试 Gemma 4 多模态直接看截图能否
从根上绕开。混合方案的可行性验证 —— 不是全替 OCR。

流程(断点续跑,结果落 lab.db vision_ab 表 + Obsidian md):
  选 session(乱码/chrome 重 + 干净对照)→ 每 session 取代表帧 →
  ffmpeg 从 MP4 按 offset 抽 JPG → A: Gemma4 vision 看图出 digest
  vs B: 现有 Qwen3-4B OCR-text digest → 记录 5 指标。

⚠️ 跑模型,占内存+GPU。跑前确认 faithful_v2 停。

  python3 vision_ab.py --day 2026-06-07 --n-garbled 25 --n-clean 15
"""
import argparse, json, os, subprocess, sqlite3, time
import labdb, chrome, source

GEMMA = "mlx-community/gemma-4-12B-it-4bit"
PORTRAIT = os.path.expanduser("~/.portrait")
TMP = "/tmp/vision_ab_frames"

AB_SCHEMA = """
CREATE TABLE IF NOT EXISTS vision_ab(
  session_id INTEGER PRIMARY KEY, day TEXT, app TEXT, bucket TEXT,
  frame_jpg TEXT, ocr_digest TEXT, vision_digest TEXT,
  vision_latency_ms INTEGER, vision_json_ok INTEGER, peak_note TEXT, ts_ms INTEGER);
"""


def pick_frame(con_p, session_row):
    """取 session 成员帧的中间一个,查 portrait.sqlite 拿 chunk+offset,
    ffmpeg 从 MP4 抽 JPG。返回 jpg 路径或 None。"""
    fids = json.loads(session_row["frame_ids"])
    fid = fids[len(fids) // 2]
    r = con_p.execute(
        "SELECT vc.file_path, f.offset_ms FROM frames f "
        "JOIN video_chunks vc ON f.video_chunk_id=vc.id WHERE f.id=?", (fid,)).fetchone()
    if not r or not r[0]:
        return None
    mp4 = os.path.join(PORTRAIT, r[0])
    if not os.path.exists(mp4):
        return None
    os.makedirs(TMP, exist_ok=True)
    out = os.path.join(TMP, f"s{session_row['id']}.jpg")
    ss = max(0, (r[1] or 0) / 1000.0)
    cp = subprocess.run(
        ["ffmpeg", "-y", "-ss", str(ss), "-i", mp4, "-frames:v", "1",
         "-q:v", "2", out], capture_output=True)
    return out if (cp.returncode == 0 and os.path.exists(out)) else None


def vision_digest(model, processor, jpg, app):
    """Gemma 4 看图 → digest。lean prompt(<500 tok 避 mlx-vlm bug#242)。"""
    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template
    prompt = (f"This is a screenshot of a macOS screen (foreground app: {app}). "
              "Describe what the user is actually DOING. Ignore UI chrome "
              "(menu bars, clocks, sidebars, buttons). If a media app is "
              "foreground but real content is code/terminal/docs, the activity "
              "is that work, not the music. Reply ONLY JSON: "
              '{"doing":"<1-2 sentences>","keywords":["3-6 terms"]}')
    formatted = apply_chat_template(processor, model.config, prompt, num_images=1)
    t0 = time.time()
    out = generate(model, processor, formatted, [jpg], max_tokens=200,
                   temperature=0.1, verbose=False)
    txt = out if isinstance(out, str) else getattr(out, "text", str(out))
    return txt, int((time.time() - t0) * 1000)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-07")
    ap.add_argument("--n-garbled", type=int, default=25)
    ap.add_argument("--n-clean", type=int, default=15)
    ap.add_argument("--model", default=GEMMA)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if not args.force and subprocess.run(["pgrep", "-f", "faithful_v2.py"],
                                         capture_output=True).stdout.strip():
        print("⛔ faithful_v2 在跑,等停或 --force"); return

    con = labdb.connect()
    con.executescript(AB_SCHEMA)
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    con_p.row_factory = sqlite3.Row

    rows = con.execute(
        "SELECT * FROM raw_sessions WHERE day=? AND digest IS NOT NULL "
        "AND status IN ('completed','pending') ORDER BY start_ms", (args.day,)).fetchall()
    # 乱码/chrome 重 = bg_media 或 strip 前后差异大;干净 = 其余
    garbled, clean = [], []
    for r in rows:
        is_g = r["bg_media"] or (r["ocr"] and
               len(chrome.strip_chrome(r["ocr"])) < len(r["ocr"]) * 0.7)
        (garbled if is_g else clean).append(r)
    sel = garbled[:args.n_garbled] + clean[:args.n_clean]
    done = {x[0] for x in con.execute("SELECT session_id FROM vision_ab").fetchall()}
    sel = [r for r in sel if r["id"] not in done]
    print(f"[ab] {args.day}: {len(garbled)} garbled / {len(clean)} clean 池, "
          f"本次跑 {len(sel)}(已完成 {len(done)})")
    if not sel:
        print("全部已跑 → 生成报告"); report(con, args.day); return

    from mlx_vlm import load
    print(f"[ab] loading {args.model} …")
    model, processor = load(args.model)

    for r in sel:
        bucket = "garbled" if (r["bg_media"] or
                 len(chrome.strip_chrome(r["ocr"])) < len(r["ocr"]) * 0.7) else "clean"
        jpg = pick_frame(con_p, r)
        if not jpg:
            print(f"  ✗ #{r['id']} 抽帧失败,跳过"); continue
        try:
            vtxt, lat = vision_digest(model, processor, jpg, r["app"])
            try:
                import engine
                vj = engine.parse_json(vtxt, "object"); ok = 1
                vdig = f"{vj.get('doing','')}\nkeywords: {', '.join(vj.get('keywords',[]))}"
            except Exception:
                ok = 0; vdig = vtxt[:400]
            with con:
                con.execute(
                    "INSERT OR REPLACE INTO vision_ab(session_id,day,app,bucket,"
                    "frame_jpg,ocr_digest,vision_digest,vision_latency_ms,"
                    "vision_json_ok,ts_ms) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (r["id"], args.day, r["app"], bucket, jpg, r["digest"],
                     vdig, lat, ok, labdb.now_ms()))
            print(f"  ✓ #{r['id']} [{bucket}] {lat}ms json={ok} | {vdig[:55]}")
        except KeyboardInterrupt:
            print("\n[stop] 中断,重跑续"); break
        except Exception as e:
            print(f"  ✗ #{r['id']} ERROR {e}")
    report(con, args.day)


def report(con, day):
    out = f"/Users/joyzhang14/Desktop/Obsidian/event pipeline local/vision-AB-{day}.md"
    rows = con.execute("SELECT * FROM vision_ab WHERE day=? ORDER BY bucket,session_id",
                       (day,)).fetchall()
    n = len(rows)
    if not n:
        print("无 A/B 数据"); return
    json_ok = sum(r["vision_json_ok"] for r in rows)
    avg_lat = sum(r["vision_latency_ms"] for r in rows) / n
    L = [f"# Vision A/B · Gemma4-12B vision vs Qwen3-4B OCR · {day}", "",
         f"样本 {n} · vision JSON 有效率 {json_ok}/{n} · 平均延迟 {avg_lat/1000:.1f}s/帧", "",
         "对照口径:同一 session,**左=Qwen3-4B 看 OCR 文本**,**右=Gemma4-12B 看截图**。",
         "重点看 garbled 桶:vision 能否救回 OCR 弄坏/被 chrome 污染的内容。", ""]
    for bucket in ("garbled", "clean"):
        bk = [r for r in rows if r["bucket"] == bucket]
        L.append(f"\n## {bucket}({len(bk)})")
        for r in bk:
            L.append(f"\n### #{r['session_id']} · {r['app']} · {r['vision_latency_ms']}ms")
            L.append(f"- **OCR(Qwen3-4B)**: {(r['ocr_digest'] or '').splitlines()[0][:200]}")
            L.append(f"- **Vision(Gemma4)**: {(r['vision_digest'] or '').splitlines()[0][:200]}")
    open(out, "w").write("\n".join(L) + "\n")
    print(f"[report] {out}  (n={n}, json_ok={json_ok}/{n}, avg {avg_lat/1000:.1f}s)")


if __name__ == "__main__":
    main()
