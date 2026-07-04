#!/usr/bin/env python3
"""模型 A/B —— 同一批真实数据,多个 MLX 模型在同几个维度上并排比产出。

仿 event-local-lab/vision_models_ab.py。目的:实证「难维度(中文句法/语气)上
8B 够不够、14B 提升多少、30B 天花板差多远」,好按 16GB 约束定档。

**不污染主 facets 表** —— 结果只进内存 + 写 reports/ab_<day>.md + ab_<day>.json。
一次只驻留一个模型(engine.load 会先 unload 旧的),按小→大顺序跑,大模型即使
OOM 也不影响已拿到的小模型结果。

用法:
  python3 models_ab.py --day 2026-06-05 --models 4B,8B,14B,30B \
      --dims message_structure,tone,input_habits
"""
import argparse
import json
import os
import time

import dimensions
import engine
import features
import labdb
import run as runmod
import source

ALIASES = {
    "1.7B": "mlx-community/Qwen3-1.7B-4bit",
    "4B": "mlx-community/Qwen3-4B-4bit",
    "8B": "mlx-community/Qwen3-8B-4bit",
    "14B": "mlx-community/Qwen3-14B-4bit",
    "30B": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--models", default="4B,8B,14B",
                    help="逗号分隔别名或完整 id(小→大顺序跑)")
    ap.add_argument("--dims", default="message_structure,tone,input_habits")
    ap.add_argument("--min-group", type=int, default=3)
    ap.add_argument("--min-ks", type=int, default=40)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    day = args.day
    models = [ALIASES.get(m, m) for m in args.models.split(",")]
    dims = [dimensions.DIM_BY_KEY[k] for k in args.dims.split(",")
            if k in dimensions.DIM_BY_KEY]

    con = labdb.connect()
    n = source.ingest_day(con, day)
    print(f"[ingest] {day}: {'+'+str(n) if n else '已在库'} records")

    groups = [(gk, rows) for gk, rows in labdb.groups_for_day(con, day)
              if len(rows) >= args.min_group]
    print(f"[groups] {len(groups)} 个 app-group ≥{args.min_group} 条")
    aggs = {gk: features.aggregate(rows) for gk, rows in groups}

    # results[(gk, dim_key)][model] = {out, ms}
    results = {}
    for mid in models:
        short = next((k for k, v in ALIASES.items() if v == mid), mid.split("/")[-1])
        print(f"\n===== 模型 {short}  ({mid}) =====")
        try:
            engine.load(mid)
        except Exception as e:                        # noqa: BLE001
            print(f"  加载失败(内存不足?)跳过:{e}")
            continue
        for gk, rows in groups:
            agg = aggs[gk]
            for dim in dims:
                if dim["needs_ks"] and agg["ks_total"] < args.min_ks:
                    continue
                msgs = runmod.build_messages(dim, gk, rows, agg)
                t0 = time.time()
                try:
                    out = engine.call(con, day, f"ab:{dim['key']}", msgs, group_key=gk)
                except Exception as e:                 # noqa: BLE001
                    out = {"present": None, "error": str(e)[:200]}
                ms = int((time.time() - t0) * 1000)
                results.setdefault((gk, dim["key"]), {})[short] = {"out": out, "ms": ms}
                mark = "✓" if (out or {}).get("present") else "·"
                print(f"  {mark} {runmod.app_name(gk):10} {dim['key']:18} "
                      f"{ms:5}ms  {(out.get('label') or out.get('error') or '')[:24]}")
        engine.unload()

    # ---- 渲染 markdown ----
    order = [next((k for k, v in ALIASES.items() if v == m), m.split("/")[-1])
             for m in models]
    md = [f"# 模型 A/B · {day}\n",
          f"模型(小→大):{' · '.join(order)}\n",
          "维度:" + ", ".join(d["key"] for d in dims) + "\n"]
    for (gk, dk), by_model in sorted(results.items()):
        md.append(f"\n## {runmod.app_name(gk)} `{gk}` — 维度 **{dk}**\n")
        md.append("| 模型 | present | label | conf | ms |")
        md.append("|---|---|---|---|---|")
        for short in order:
            r = by_model.get(short)
            if not r:
                continue
            o = r["out"] or {}
            md.append(f"| {short} | {o.get('present')} | {o.get('label') or o.get('error') or ''} "
                      f"| {o.get('confidence') or ''} | {r['ms']} |")
        md.append("")
        for short in order:
            r = by_model.get(short)
            if not r:
                continue
            o = r["out"] or {}
            pat = o.get("pattern") or ""
            ev = "；".join((o.get("evidence") or [])[:3])
            md.append(f"- **{short}**: {pat}" + (f"\n  - 证据: {ev}" if ev else ""))
    md_text = "\n".join(md)

    out_md = args.out or os.path.join("reports", f"ab_{day}.md")
    os.makedirs(os.path.dirname(out_md) or ".", exist_ok=True)
    open(out_md, "w", encoding="utf-8").write(md_text)
    json.dump({f"{gk}|{dk}": v for (gk, dk), v in results.items()},
              open(out_md.replace(".md", ".json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"\n写出 {out_md}")


if __name__ == "__main__":
    main()
