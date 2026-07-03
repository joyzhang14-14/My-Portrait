#!/usr/bin/env python3
"""orchestrator —— ingest → 确定性特征 → 按 app-group 逐维度跑 agent → 写 facet。

一 agent 一维度一信息;每维度对**每个 app-group**跑一次 → 维度⑦(按 app/场景/对象
分别分析)由分组天然实现。断点续跑:facets 表已有 (day,group,dim) 行就跳过。

⚠️ 默认 DRY-RUN(不加载 MLX,只打印每个 agent 会看到什么)。真正跑本地模型要
显式 --run(遵守"跑模型前先确认"纪律,并发 event-local-lab 会抢 GPU)。

用法:
  python3 run.py --list                       # 列可用天
  python3 run.py --day 2026-07-02             # dry-run:看特征 + 会喂的 prompt
  python3 run.py --day 2026-07-02 --run       # 真跑本地模型(需确认)
  python3 run.py --days 3 --run --model mlx-community/Qwen3-4B-4bit  # 全用一个模型
  python3 run.py --day 2026-07-02 --dims input_habits,punctuation_layout --run
"""
import argparse
import json
import sys

import dimensions
import engine
import features
import labdb
import source

APP_NAMES = {
    "com.anthropic.claudefordesktop": "Claude",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.google.Chrome": "Chrome",
    "com.apple.Safari": "Safari",
    "com.apple.MobileSMS": "Messages",
    "com.hnc.Discord": "Discord",
    "ru.keepcoder.Telegram": "Telegram",
    "com.microsoft.VSCode": "VS Code",
    "md.obsidian": "Obsidian",
    "com.apple.mail": "Mail",
    "com.tencent.xinWeChat": "WeChat",
    "notion.id": "Notion",
}


def app_name(bundle):
    return APP_NAMES.get(bundle, bundle.split(".")[-1])


def _filter_feats(agg, keys):
    return {k: agg[k] for k in keys if k in agg and agg[k] not in (None, {}, [])}


def build_messages(dim, gk, rows, agg, max_records=18, text_cap=280):
    """给一个 (app-group, 维度) 拼 messages。"""
    label = app_name(gk)
    scenarios = {r["context_summary"] for r in rows if r["context_summary"]}
    scen = " / ".join(list(scenarios)[:3]) if scenarios else "(无场景摘要)"
    feat_line = json.dumps(_filter_feats(agg, dim["feature_keys"]), ensure_ascii=False)

    # 采样文本:结构/语气维度靠文本本身;其余维度也给几条锚定证据。
    samples = []
    for r in rows[:max_records]:
        t = (r["text"] or "").strip().replace("\n", " ")
        if not t:
            continue
        tail = f"…尾[{t[-60:]}]" if len(t) > text_cap else ""
        samples.append(f"- ({r['kind'] or '?'}) {t[:text_cap]}{tail}")
    body = "\n".join(samples) if samples else "(无文本)"

    user = (
        f"CONTEXT: app={label} ({gk})  scenario={scen}  记录数={agg['n_records']}\n"
        f"MEASURED FEATURES (确定性,已算好,直接信): {feat_line}\n"
        f"SAMPLE MESSAGES (用户实际打的字):\n{body}\n\n"
        f"只针对「{dim['name']}」这一个维度作答。"
    )
    return [{"role": "system", "content": dim["system"]},
            {"role": "user", "content": user}]


def resolve_days(args):
    if args.day:
        return [args.day]
    avail = source.available_days()
    if args.days:
        return [d for d, _ in avail[-args.days:]]
    return [d for d, _ in avail]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day")
    ap.add_argument("--days", type=int, help="最近 N 个有数据的天")
    ap.add_argument("--dims", help="逗号分隔维度 key,默认全部")
    ap.add_argument("--model", help="全局覆盖:所有维度都用这个 MLX model id")
    ap.add_argument("--run", action="store_true", help="真加载 MLX 跑(默认 dry-run)")
    ap.add_argument("--force", action="store_true", help="重算(忽略已 ingest/已有 facet)")
    ap.add_argument("--min-group", type=int, default=3, help="组内少于这么多记录就跳过")
    ap.add_argument("--min-ks", type=int, default=40, help="需击键的维度:组内击键少于此跳过")
    ap.add_argument("--list", action="store_true", help="列可用天并退出")
    args = ap.parse_args()

    if args.list:
        for d, c in source.available_days():
            print(f"  {d}  records={c}")
        return

    con = labdb.connect()
    days = resolve_days(args)
    if not days:
        print("没有可处理的天(生产库 writing_records 为空?)"); sys.exit(1)

    # 1) ingest(确定性,只读生产库)
    for d in days:
        n = source.ingest_day(con, d, force=args.force)
        print(f"[ingest] {d}: +{n} records" if n else f"[ingest] {d}: 已在库(跳过)")

    # 2) 选维度
    sel = dimensions.DIMENSIONS
    if args.dims:
        want = set(args.dims.split(","))
        sel = [d for d in sel if d["key"] in want]

    # 3) DRY-RUN:只打印特征 + 每个 group×dim 会喂的 prompt
    if not args.run:
        print("\n===== DRY-RUN(未加载模型)=====")
        for d in days:
            for gk, rows in labdb.groups_for_day(con, d):
                if len(rows) < args.min_group:
                    continue
                agg = features.aggregate(rows)
                print(f"\n### {d}  app={app_name(gk)} ({gk})  记录={agg['n_records']}  击键={agg['ks_total']}")
                print(f"    特征聚合: {json.dumps(agg, ensure_ascii=False)}")
                for dim in sel:
                    if dim["needs_ks"] and agg["ks_total"] < args.min_ks:
                        print(f"    · [{dim['key']}] 跳过(击键 {agg['ks_total']}<{args.min_ks})"); continue
                    msgs = build_messages(dim, gk, rows, agg)
                    print(f"    · [{dim['key']}] prompt_chars={sum(len(m['content']) for m in msgs)}")
        print("\n要真跑本地模型:加 --run(会加载 MLX,请先确认 GPU 空闲)。")
        return

    # 4) 真跑:按模型分组,一模型加载一次,跑它负责的所有 (group,dim)
    models = {}
    for dim in sel:
        mid = args.model or dimensions.TIER_MODELS[dim["tier"]]
        models.setdefault(mid, []).append(dim)

    for mid, dims in models.items():
        engine.load(mid)
        for d in days:
            for gk, rows in labdb.groups_for_day(con, d):
                if len(rows) < args.min_group:
                    continue
                agg = features.aggregate(rows)
                for dim in dims:
                    if labdb.facet_done(con, d, gk, dim["key"]) and not args.force:
                        continue
                    if dim["needs_ks"] and agg["ks_total"] < args.min_ks:
                        continue
                    msgs = build_messages(dim, gk, rows, agg)
                    try:
                        out = engine.call(con, d, dim["key"], msgs, group_key=gk)
                    except Exception as e:            # noqa: BLE001
                        print(f"  [{d}/{app_name(gk)}/{dim['key']}] FAIL {e}"); continue
                    labdb.write_facet(con, d, gk, app_name(gk), dim["key"], out, mid)
                    mark = "✓" if out.get("present") else "·"
                    print(f"  {mark} {d} {app_name(gk):10} {dim['key']:20} "
                          f"{(out.get('label') or '')[:20]}")
    print("\n完成。看结果:python3 report.py")


if __name__ == "__main__":
    main()
