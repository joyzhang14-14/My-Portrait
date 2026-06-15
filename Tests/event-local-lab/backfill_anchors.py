#!/usr/bin/env python3
"""一次性回填:把确定性技术锚点拼到现有 digest 尾部(从 OCR 采,不跑模型)。

小模型清洗丢逐字锚点,但 OCR 还在 → 不必重洗 34min,直接回填即可让锚点上云。
幂等:已含 'anchors:' 的 digest 跳过。
  python3 backfill_anchors.py --day 2026-06-07
"""
import argparse
import anchors
import labdb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    args = ap.parse_args()
    con = labdb.connect()
    rows = con.execute("SELECT id, ocr, digest FROM raw_sessions WHERE day=? AND "
                       "digest IS NOT NULL", (args.day,)).fetchall()
    upd = skip = noanc = 0
    with con:
        for r in rows:
            if "\nanchors:" in (r["digest"] or ""):
                skip += 1
                continue
            anc = anchors.harvest(r["ocr"])
            if not anc:
                noanc += 1
                continue
            dig = r["digest"] + "\nanchors: " + ", ".join(anc)
            con.execute("UPDATE raw_sessions SET digest=? WHERE id=?", (dig, r["id"]))
            upd += 1
    print(f"[backfill] {args.day}: 回填 {upd} · 已有锚点跳过 {skip} · 无锚点 {noanc} "
          f"· 共 {len(rows)}")


if __name__ == "__main__":
    main()
