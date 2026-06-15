#!/usr/bin/env python3
"""Phase B:多层 OCR 清洗的 LLM 层 —— 原始 OCR(≤2000 字) → 活动 digest。

本地 token 免费才养得起这一层:云端 pipeline 为省钱把 OCR 砍到 600 字直接
喂聚类;这里先用**小模型**(默认 Qwen3-4B)把 2000 字噪音 OCR 凝成 ~300 字
"用户在干什么"的 digest,下游 14B 的 decide/describe/summarize 全部吃
digest —— 信号密度反超云端,prompt 反而更小。

  python3 clean_day.py --day 2026-06-07 [--model mlx-community/Qwen3-4B-4bit]
                       [--limit 5] [--force]

checkpoint:digest 列,每 session 独立事务;纯噪音 → skipped_noise。
Ctrl-C 安全,重跑续。⚠️ 跑之前先跟用户确认。
"""
import argparse
import sys

import labdb, redact, anchors
from run_day import ensure_ingested, other_lab_running

CLEAN_MODEL = "mlx-community/Qwen3-4B-4bit"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default=CLEAN_MODEL)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if not args.force and other_lab_running():
        print("⛔ faithful_v2.py 还在跑。等它停,或 --force。")
        sys.exit(1)

    con = labdb.connect()
    ensure_ingested(con, args.day)
    todo = labdb.sessions_needing_clean(con, args.day)
    if args.limit:
        todo = todo[:args.limit]
    if not todo:
        print("没有待清洗的 session(全部已有 digest 或被 skip)。")
        return
    print(f"[clean] {args.day}: {len(todo)} session(s),model={args.model}")

    import engine
    import prompts
    engine.load(args.model)

    done = noise = 0
    for s in todo:
        try:
            out = engine.call(con, args.day, "clean", prompts.clean(s),
                              session_id=s["id"], max_tokens=250)
            doing = (out.get("doing") or "").strip()
            if not doing:
                labdb.mark_noise(con, s["id"])
                noise += 1
                print(f"  ∅ #{s['id']} {s['app'][:20]:20s} → 纯噪音,skip")
                continue
            kw = ", ".join(out.get("keywords") or [])
            # hybrid 脱敏闸:digest 上云前掩码残留 PII(原文不出本地,digest 才上云)
            dig, hits = redact.redact(f"{doing}\nkeywords: {kw}")
            if hits:
                print(f"    [redact] #{s['id']} 掩码 {hits}")
            # 确定性锚点采集:小模型抽象摘要会丢逐字锚点(commit/文件/ID),
            # 正则从 OCR 直接采集**非敏感**技术锚点拼到尾部(在 redact 之后,不掩码锚点)
            anc = anchors.harvest(s["ocr"])
            if anc:
                dig += "\nanchors: " + ", ".join(anc)
            labdb.set_digest(con, s["id"], dig)
            done += 1
            print(f"  ✓ #{s['id']} {s['app'][:20]:20s} → {doing[:60]}")
        except KeyboardInterrupt:
            print(f"\n[stop] 手动中断。已清洗 {done},重跑同命令续。")
            return
        except Exception as e:                          # noqa: BLE001
            labdb.fail_session(con, s["id"], e)
            print(f"  ✗ #{s['id']} → ERROR {e}(保持待清洗,重跑会再试)")

    print(f"[done] cleaned {done}, noise {noise} → 下一步 run_day.py --day {args.day}")


if __name__ == "__main__":
    main()
