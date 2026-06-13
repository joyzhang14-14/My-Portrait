#!/usr/bin/env python3
"""补测 garbled 桶 —— vision_ab 主脚本因 06-07 是 v2 数据(无 bg_media、OCR
长拼接 strip 差异不达阈)选出 0 个 garbled。这里直接按"OCR 含菜单栏/时钟
chrome 或媒体 app"挑,这是 vision 路线最关键的验证集(Spotify 那类)。
复用 vision_ab 的 pick_frame/vision_digest/report。断点续。"""
import argparse, json, sqlite3
import labdb, chrome, source, vision_ab


def is_garbled(r):
    o = r["ocr"] or ""
    return (r["app"] in chrome.BG_MEDIA_APPS
            or chrome._MENUBAR.search(o) is not None
            or chrome._CLOCK.search(o) is not None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-07")
    ap.add_argument("--n", type=int, default=25)
    ap.add_argument("--model", default="mlx-community/gemma-4-e4b-it-4bit")
    args = ap.parse_args()
    con = labdb.connect()
    con.executescript(vision_ab.AB_SCHEMA)
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    con_p.row_factory = sqlite3.Row

    rows = con.execute("SELECT * FROM raw_sessions WHERE day=? AND digest IS NOT NULL "
                       "ORDER BY start_ms", (args.day,)).fetchall()
    pool = [r for r in rows if is_garbled(r)]
    done = {x[0] for x in con.execute("SELECT session_id FROM vision_ab").fetchall()}
    sel = [r for r in pool if r["id"] not in done][:args.n]
    print(f"[garbled] 池 {len(pool)},本次跑 {len(sel)}")
    if not sel:
        vision_ab.report(con, args.day); return

    from mlx_vlm import load
    print(f"[garbled] loading {args.model} …")
    model, processor = load(args.model)
    import engine
    for r in sel:
        jpg = vision_ab.pick_frame(con_p, r)
        if not jpg:
            print(f"  ✗ #{r['id']} 抽帧失败"); continue
        try:
            vtxt, lat = vision_ab.vision_digest(model, processor, jpg, r["app"])
            try:
                vj = engine.parse_json(vtxt, "object"); ok = 1
                vdig = f"{vj.get('doing','')}\nkeywords: {', '.join(vj.get('keywords',[]))}"
            except Exception:
                ok = 0; vdig = vtxt[:400]
            with con:
                con.execute("INSERT OR REPLACE INTO vision_ab(session_id,day,app,"
                    "bucket,frame_jpg,ocr_digest,vision_digest,vision_latency_ms,"
                    "vision_json_ok,ts_ms) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (r["id"], args.day, r["app"], "garbled", jpg, r["digest"],
                     vdig, lat, ok, labdb.now_ms()))
            print(f"  ✓ #{r['id']} {r['app'][:16]:16s} {lat}ms json={ok} | {vdig[:50]}")
        except Exception as e:
            print(f"  ✗ #{r['id']} {e}")
    vision_ab.report(con, args.day)


if __name__ == "__main__":
    main()
