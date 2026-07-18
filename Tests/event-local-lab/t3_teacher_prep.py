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
    ap.add_argument("--per-day", type=int, default=150)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    man = json.load(open(f"/tmp/vision_v4{args.suffix}_{args.day}/v4_manifest.json"))
    con_l = labdb.connect()
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    frames_dir = f"/tmp/vision_frames_v4{args.suffix}_{args.day}"

    # 采样=定向特殊情况+领域多样性+比例分层(用户 2026-07-18:挑不同领域+特殊情况,
    # 强泛化)。选择器全是结构信号(采样用途,非内容判断)。
    import re as _re
    MB = _re.compile(r"([A-Z][\w .&-]{1,24}?)\s+(?:File|Shell)\s+Edit\b")
    MUS = _re.compile(r"\d{1,2}:\d{2}\s*/\s*\d{1,2}:\d{2}|Lossless|[▶⏸♫♪]")

    def bucket(n):
        return 0 if n < 1000 else 1 if n < 3000 else 2 if n < 6000 else 3

    app_freq = collections.Counter(b.get("app") for b in man.values())
    picked, why = [], {}

    def take(k, tag):
        if k not in why:
            why[k] = tag
            picked.append(k)

    for k, b in sorted(man.items(), key=lambda kv: int(kv[0])):
        ocr = b.get("ocr_union") or ""
        mb_apps = {m.group(1).strip() for m in MB.finditer(ocr)}
        app = str(b.get("app") or "")
        if mb_apps and app and all(app.lower() not in a.lower() and a.lower() not in app.lower()
                                   for a in mb_apps):
            take(k, "trap_attr")        # 归属陷阱:菜单栏 app 与归属不一致
        if MUS.search(ocr):
            take(k, "music")            # 音乐证据在屏(bg 触发条件化的正例源)
        if app_freq[b.get("app")] <= 3:
            take(k, "rare_app")         # 稀有 app=领域多样性
        if len(ocr) < 800:
            take(k, "thin_ocr")         # 超薄 OCR(跑飞高危区)
        if (b.get("total_frames") or 0) >= 15:
            take(k, "long_sess")        # 长会话(多帧时间线)
    # 各特殊类封顶,防单类淹没
    cap = max(8, args.per_day // 6)
    cnt = collections.Counter()
    kept = []
    for k in picked:
        if cnt[why[k]] < cap:
            cnt[why[k]] += 1
            kept.append(k)
    picked = kept
    # 剩余配额:比例分层补齐
    strata = collections.defaultdict(list)
    for k, b in sorted(man.items(), key=lambda kv: int(kv[0])):
        if k in why:
            continue
        strata[(b.get("app"), bucket(len(b.get("ocr_union") or "")))].append(k)
    remain = max(0, args.per_day - len(picked))
    total = sum(len(v) for v in strata.values()) or 1
    for s, ks in sorted(strata.items()):
        quota = max(1, round(remain * len(ks) / total))
        step = max(1, len(ks) // quota)
        for k in ks[::step][:quota]:
            take(k, "strata")
    picked = picked + [k for k in why if why[k] == "strata"]
    picked = picked[:args.per_day]
    print("[t3prep] 采样构成:", dict(collections.Counter(why[k] for k in picked)))

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
