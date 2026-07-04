#!/usr/bin/env python3
"""验证三件事(一次跑完):
  (a) tone 改英文指令后 8B 仍判对"轻松调侃"(无回归)
  (b) message_structure few-shot 能在明含特定句式的合成句上判出具体类别
      (真实 06-05 数据多为追加式,合成句才测得出"能不能识别"这件事)
  (c) JSON 修复后 4B 的 input_habits 不再崩

用法: python3 verify_v2.py
"""
import dimensions
import engine
import features
import labdb
import run as runmod
import source

DAY = "2026-06-05"
Q8 = "mlx-community/Qwen3-8B-4bit"
Q4 = "mlx-community/Qwen3-4B-4bit"

SYNTH = {
    "宾语前置组": ["这个我知道", "作业我写完了", "那个我早删了", "饭我吃过了"],
    "连动组": ["去买菜做饭", "拿去用", "起来看看", "过来帮个忙"],
    "倒装组": ["走吧我们", "冷死了今天", "先睡了我", "真好看这个"],
    "平铺追加组": ["嗯", "好的", "知道了", "收到", "行"],
}


def synth_msg(dim, name, texts):
    user = (f"CONTEXT: app=Test scenario=聊天 记录数={len(texts)}\n"
            f"MEASURED FEATURES: {{}}\n"
            f"SAMPLE MESSAGES:\n" + "\n".join(f"- {t}" for t in texts) +
            f"\n\n只针对「{dim['name']}」这一个维度作答。")
    return [{"role": "system", "content": dim["system"]},
            {"role": "user", "content": user}]


def main():
    con = labdb.connect()
    source.ingest_day(con, DAY)
    groups = [(gk, rows) for gk, rows in labdb.groups_for_day(con, DAY)
              if len(rows) >= 3]
    aggs = {gk: features.aggregate(rows) for gk, rows in groups}
    ms = dimensions.DIM_BY_KEY["message_structure"]
    tone = dimensions.DIM_BY_KEY["tone"]
    ih = dimensions.DIM_BY_KEY["input_habits"]

    print("========== (b) message_structure 合成句能否识别具体类别(8B)==========")
    engine.load(Q8)
    for name, texts in SYNTH.items():
        out = engine.call(con, DAY, "synth_ms", synth_msg(ms, name, texts), group_key=name)
        print(f"  {name:8} 期望≈{name[:-1]:5} → 判为【{out.get('label')}】 ({out.get('confidence')})")

    print("\n========== (a) tone 英文版·真实数据(应:Discord=调侃, Claude=认真)==========")
    for gk, rows in groups:
        out = engine.call(con, DAY, "verify_tone", runmod.build_messages(tone, gk, rows, aggs[gk]), group_key=gk)
        print(f"  {runmod.app_name(gk):9} → 【{out.get('label')}】 {(out.get('pattern') or '')[:36]}")

    print("\n     message_structure 英文版·真实数据(看是否比笼统'追加式'更准):")
    for gk, rows in groups:
        out = engine.call(con, DAY, "verify_ms", runmod.build_messages(ms, gk, rows, aggs[gk]), group_key=gk)
        print(f"  {runmod.app_name(gk):9} → present={out.get('present')} 【{out.get('label')}】")
    engine.unload()

    print("\n========== (c) 4B input_habits JSON 修复验证(之前崩,现应成功)==========")
    engine.load(Q4)
    ok = 0
    for gk, rows in groups:
        agg = aggs[gk]
        if agg["ks_total"] < 40:
            continue
        out = engine.call(con, DAY, "verify_ih_4b", runmod.build_messages(ih, gk, rows, agg), group_key=gk)
        good = out.get("present") is not None and not (out.get("label") or "").startswith("ab:")
        ok += good
        print(f"  {runmod.app_name(gk):9} → present={out.get('present')} 【{out.get('label')}】 {'✓解析成功' if good else '✗仍失败'}")
    engine.unload()
    print(f"\n  4B input_habits: {ok} 个成功解析(修复前是 0)")


if __name__ == "__main__":
    main()
