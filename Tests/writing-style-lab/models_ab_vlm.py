#!/usr/bin/env python3
"""VLM 档 A/B —— 专测 Qwen3.5(多模态,走 mlx_vlm 而非 mlx_lm)在难维度上的表现。

复用同一套 build_messages / features / 维度定义,产出可直接跟 mlx_lm 档
(models_ab.py 的 4B/8B/14B/30B)并排比。重点:语气维度 8B 判不准调侃,看
最新多语言模型(Qwen3.5,201 语言)能不能救回。

纯文本任务:num_images=0,image=None。enable_thinking=False(调研:CoT 伤讽刺
+ 徒增延迟),并兜底剥 <think>…</think>。

用法:
  python3 models_ab_vlm.py --day 2026-06-05 \
      --model mlx-community/Qwen3.5-27B-4bit \
      --dims tone,message_structure,input_habits
"""
import argparse
import json
import os
import re
import time

import dimensions
import engine          # 复用 parse_json / repair
import features
import labdb
import run as runmod
import source

_THINK = re.compile(r"<think>.*?</think>", re.S)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--model", default="mlx-community/Qwen3.5-27B-4bit")
    ap.add_argument("--dims", default="tone,message_structure,input_habits")
    ap.add_argument("--min-group", type=int, default=3)
    ap.add_argument("--min-ks", type=int, default=40)
    ap.add_argument("--max-tokens", type=int, default=640)
    args = ap.parse_args()

    day, MODEL = args.day, args.model
    short = MODEL.split("/")[-1]
    dims = [dimensions.DIM_BY_KEY[k] for k in args.dims.split(",")
            if k in dimensions.DIM_BY_KEY]

    con = labdb.connect()
    source.ingest_day(con, day)
    groups = [(gk, rows) for gk, rows in labdb.groups_for_day(con, day)
              if len(rows) >= args.min_group]
    aggs = {gk: features.aggregate(rows) for gk, rows in groups}
    print(f"[groups] {len(groups)} 个;维度 {[d['key'] for d in dims]}")

    # ---- 加载 VLM ----
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    try:
        from mlx_vlm.utils import load_config
        config = load_config(MODEL)
    except Exception:
        config = None
    print(f"[vlm] loading {MODEL} …")
    t0 = time.time()
    model, processor = load(MODEL)
    if config is None:
        config = getattr(model, "config", None)
    print(f"[vlm] loaded in {time.time()-t0:.1f}s")

    def vlm_json(messages, max_tokens):
        formatted = apply_chat_template(
            processor, config, messages,
            add_generation_prompt=True, num_images=0, enable_thinking=False)
        res = generate(model, processor, formatted, image=None,
                       max_tokens=max_tokens, temperature=0.2, verbose=False)
        raw = getattr(res, "text", None) or str(res)
        raw = _THINK.sub("", raw)
        return raw

    results = {}
    first = True
    for gk, rows in groups:
        agg = aggs[gk]
        for dim in dims:
            if dim["needs_ks"] and agg["ks_total"] < args.min_ks:
                continue
            msgs = runmod.build_messages(dim, gk, rows, agg)
            t1 = time.time()
            try:
                raw = vlm_json(msgs, args.max_tokens)
                if first:
                    print("\n----- 首个原始输出(眼验) -----\n" + raw[:600] + "\n-----\n")
                    first = False
                out = engine.parse_json(raw, "object")
            except Exception as e:                    # noqa: BLE001
                out = {"present": None, "error": str(e)[:200]}
            ms = int((time.time() - t1) * 1000)
            results[(gk, dim["key"])] = {"out": out, "ms": ms}
            mark = "✓" if (out or {}).get("present") else "·"
            print(f"  {mark} {runmod.app_name(gk):10} {dim['key']:18} {ms:6}ms  "
                  f"{(out.get('label') or out.get('error') or '')[:30]}")

    # ---- 落盘 ----
    md = [f"# VLM A/B · {day} · {short}\n"]
    for (gk, dk), r in sorted(results.items()):
        o = r["out"] or {}
        md.append(f"\n## {runmod.app_name(gk)} — {dk}")
        md.append(f"- present={o.get('present')} conf={o.get('confidence')} label={o.get('label')} ({r['ms']}ms)")
        if o.get("pattern"):
            md.append(f"- pattern: {o['pattern']}")
        if o.get("evidence"):
            md.append(f"- 证据: {'；'.join(o.get('evidence', [])[:3])}")
        if o.get("error"):
            md.append(f"- ERROR: {o['error']}")
    out_md = os.path.join("reports", f"ab_vlm_{day}_{short}.md")
    os.makedirs("reports", exist_ok=True)
    open(out_md, "w", encoding="utf-8").write("\n".join(md))
    json.dump({f"{gk}|{dk}": v for (gk, dk), v in results.items()},
              open(out_md.replace(".md", ".json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"\n写出 {out_md}")


if __name__ == "__main__":
    main()
