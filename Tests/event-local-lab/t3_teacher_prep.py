"""t3 教师数据扩量 —— 备料(确定性部分,零 LLM)。

三连败根因=教师数据 559 条/5 天不够(handoff §37)。本脚本为新教师日备料:
  ①分层抽样(app × OCR 长度桶,确定性,不挑内容);
  ②每会话打一个证据包:帧图路径(多图=已证的归属杠杆)+全帧 OCR+裸 app 名+窗口清单;
  ③包供 sonnet+opus workflow 标注(sonnet 逐条产,opus 裁决——用户模型规矩)。

四个历史缺陷的规避进任务书(prep 只备料,规则文本在 workflow prompt 里):
  D1 题头只给裸 app 名零提示;D2 归属以实际内容为准;D3 social 禁天气/桌面;
  D4 锚点自然停不设 cap;bg=触发条件化(屏上有硬证据才写,禁关系性解释,歌词丢弃)。

用法: python t3_teacher_prep.py --day 2026-05-15 [--per-day 110] --out DIR
"""
import argparse
import collections
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import labdb  # noqa: E402
import source  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--suffix", default="b")
    ap.add_argument("--per-day", type=int, default=110)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    man = json.load(open(f"/tmp/vision_v4{args.suffix}_{args.day}/v4_manifest.json"))
    con_l = labdb.connect()
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    frames_dir = f"/tmp/vision_frames_v4{args.suffix}_{args.day}"

    # 分层:app × OCR 长度桶,层内按 key 序等距取(确定性)
    def bucket(n):
        return 0 if n < 1000 else 1 if n < 3000 else 2 if n < 6000 else 3

    strata = collections.defaultdict(list)
    for k, b in sorted(man.items(), key=lambda kv: int(kv[0])):
        strata[(b.get("app"), bucket(len(b.get("ocr_union") or "")))].append(k)
    total = sum(len(v) for v in strata.values())
    picked = []
    for s, ks in sorted(strata.items()):
        quota = max(1, round(args.per_day * len(ks) / total))
        step = max(1, len(ks) // quota)
        picked += ks[::step][:quota]
    picked = picked[:args.per_day]

    os.makedirs(args.out, exist_ok=True)
    for k in picked:
        b = man[k]
        fids = []
        for pid in b["parts"]:
            r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=:id",
                              {"id": pid}).fetchone()
            if r:
                fids += json.loads(r[0])
        ocr = []
        for fid in fids:
            row = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=:id",
                                {"id": fid}).fetchone()
            if row and row[0]:
                ocr.append(row[0])
        span = con_p.execute(
            f"SELECT MIN(timestamp_ms), MAX(timestamp_ms) FROM frames "
            f"WHERE id IN ({','.join('?' * len(fids))})", fids).fetchone() if fids else None
        inv = con_p.execute(
            "SELECT DISTINCT app_name, COALESCE(window_name,'') FROM frames "
            "WHERE timestamp_ms BETWEEN ? AND ? AND app_name IS NOT NULL AND app_name != ''",
            (span[0] - 900_000, span[1])).fetchall() if span and span[0] else []
        jpgs = [os.path.join(frames_dir, fn) for _, fn in b["frames"]]
        json.dump({"day": args.day, "key": k, "app": b.get("app"),
                   "frames": jpgs, "ocr_full": "\n".join(ocr)[:20000],
                   "window_inventory": [f"{a} | {w}" for a, w in inv]},
                  open(os.path.join(args.out, f"{args.day}_s{k}.json"), "w"),
                  ensure_ascii=False)
    print(f"[t3prep] {args.day}: 抽 {len(picked)}/{len(man)} → {args.out}")


main()
