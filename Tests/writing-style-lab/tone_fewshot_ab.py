#!/usr/bin/env python3
"""tone prompt A/B —— 同一个小模型,旧 prompt(v1)vs 加 few-shot 的 v2,看能不能
把"客观中立"的误判纠成正确的"轻松调侃"。

痛点(实测):8B 把 Discord 上「逆天/取长补短啊/那你问Claude啊」这种调侃判成
"客观中立" —— 它把**技术话题**当成了**中立语气**。v2 用 few-shot 教它:话题≠语气,
要看口吻标记(网络俚语/语气词/短促吐槽/自嘲)。调研:few-shot 胜堆参数。

用法:  python3 tone_fewshot_ab.py --day 2026-06-05 --models 8B,4B
"""
import argparse
import time

import dimensions
import engine
import features
import labdb
import run as runmod
import source

ALIASES = {"4B": "mlx-community/Qwen3-4B-4bit", "8B": "mlx-community/Qwen3-8B-4bit",
           "14B": "mlx-community/Qwen3-14B-4bit",
           "30B": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"}

TONE_V2_BODY = """
You analyze ONE aspect of the user's writing in ONE app/context: TONE / AFFECT (语气·态度)
— the emotional/attitudinal lean, NOT the topic and NOT sentence structure.

⚠️ 核心铁律:**话题 ≠ 语气**。内容是技术/严肃话题,**不代表**语气就是"客观中立"。
判语气只看**口吻标记**:
  - 网络俚语 / 夸张词(逆天、笑死、绝了、离谱、yyds)→ 轻松/调侃
  - 语气词、口语尾巴(啊、呗、嘛、哈、呗、啦)→ 随意/亲近
  - 短促吐槽、自嘲、玩笑、反问 → 轻松调侃 / 戏谑
  - 平实完整句 + 求解/分析措辞、无俚语无情绪 → 认真 / 理性
  - 冷嘲、"意料之中"式无奈 → 愤世嫉俗
不要因为"在聊技术"就默认判"中立/客观"—— 那几乎总是漏判。真正中立要**通篇无任何
口吻标记**才成立。

轴(选最贴的):愤世嫉俗↔真诚 · 轻松调侃↔严肃 · 攻击直冲↔温和委婉 · 冷淡疏离↔亲近热情。

FEW-SHOT(照这个映射来判):
① 消息:「逆天」「笑死 这也行」「那你问Claude啊」「取长补短啊」
   → {"present":true,"label":"轻松调侃","pattern":"用网络俚语和短促吐槽表达,语气随意带戏谑,即便在聊技术","evidence":["逆天","笑死 这也行","那你问Claude啊"],"confidence":"high"}
② 消息:「这个 pipeline 用了 4 层 LLM 过滤,你觉得有什么可以优化的?」「AX 抓输入有时效性问题」
   → {"present":true,"label":"认真求解","pattern":"聚焦问题、措辞平实、主动求评估,无俚语无情绪","evidence":["你觉得有什么可以优化的?","AX 抓输入有时效性问题"],"confidence":"high"}
③ 消息:「又崩了,意料之中」「能用就行,别指望它」
   → {"present":true,"label":"愤世嫉俗","pattern":"以无奈/看淡的口吻吐槽,预期悲观","evidence":["又崩了,意料之中","别指望它"],"confidence":"medium"}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-05")
    ap.add_argument("--models", default="8B,4B")
    ap.add_argument("--min-group", type=int, default=3)
    args = ap.parse_args()

    tone_v1 = dimensions.DIM_BY_KEY["tone"]
    tone_v2 = {**tone_v1, "system": TONE_V2_BODY.strip() + "\n" + dimensions.OUTPUT_CONTRACT}

    con = labdb.connect()
    source.ingest_day(con, args.day)
    groups = [(gk, rows) for gk, rows in labdb.groups_for_day(con, args.day)
              if len(rows) >= args.min_group]
    aggs = {gk: features.aggregate(rows) for gk, rows in groups}

    rows_out = []
    for m in args.models.split(","):
        mid = ALIASES.get(m, m)
        engine.load(mid)
        for gk, grows in groups:
            agg = aggs[gk]
            for tag, dim in [("v1", tone_v1), ("v2", tone_v2)]:
                msgs = runmod.build_messages(dim, gk, grows, agg)
                t0 = time.time()
                try:
                    out = engine.call(con, args.day, f"tone_{tag}", msgs, group_key=gk)
                except Exception as e:                # noqa: BLE001
                    out = {"present": None, "label": f"ERR {str(e)[:60]}"}
                ms = int((time.time() - t0) * 1000)
                rows_out.append((m, runmod.app_name(gk), tag, out, ms))
        engine.unload()

    # ---- 并排打印 ----
    print("\n" + "=" * 78)
    print(f"{'模型':5} {'场景':9} {'ver':4} {'label':16} {'conf':7} {'ms':>6}")
    print("-" * 78)
    for m, app, tag, out, ms in rows_out:
        o = out or {}
        print(f"{m:5} {app:9} {tag:4} {(o.get('label') or '')[:16]:16} "
              f"{(o.get('confidence') or ''):7} {ms:6}")
    print("=" * 78)
    print("\n证据/pattern 细节:")
    for m, app, tag, out, ms in rows_out:
        o = out or {}
        ev = "；".join((o.get("evidence") or [])[:3])
        print(f"\n[{m} {app} {tag}] {o.get('label')}\n  {o.get('pattern','')}\n  证据: {ev}")


if __name__ == "__main__":
    main()
