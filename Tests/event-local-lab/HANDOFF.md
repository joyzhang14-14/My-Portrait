# Event Processor 本地化实验室 · 交接文档

> 目标:验证 **MLX + Qwen3-14B-4bit(本地)** 能否替代云端大模型跑 event
> processor(聚类 + impact),质量对齐云端。Python 实验线,**生产 Swift 零改动**。
> 仿照 `Tests/writing-capture-extract` 的实验室模式。

## 背景与约束(用户定的)

- 动机:**隐私** —— event processor 是唯一把屏幕 OCR 原文发云端的 pipeline。
- 推理形态:**MLX**(最终打包进 app,不依赖 ollama)。实验线用 `mlx_lm`。
- 可以慢,但要**断点续跑**:每处理一簇 raw data → event 先写库 →
  写库成功才把对应 raw data 标 completed。一点一点吃当天,不一次性全量。
- 质量:先看 v1 跑得怎么样,再定细化指标(暂无硬指标)。
- ⚠️ **每次跑模型前必须先和用户确认**(writing-capture 实验 faithful_v2.py
  常在占机器,14B 常驻 ~8GB,24GB 总内存,撞上会换页)。

## v1 架构:检索代替全量注意力,窄决策代替大聚类

云端 EventBuilder 一口吃全天(全部 session + carry + top-20 历史)做一次性
聚类 —— 14B 接不住。v1 拆成 14B 永远只看小 prompt 的流式版:

```
portrait.sqlite(只读) frames(day)
→ source.py:Tier-1 规则 merge(app+window+5min 间隙)→ sessions → 入 lab.db(pending)
   OCR cap 2000 字(云端 600)—— 本地 token 免费,多读屏
→ clean_day.py(Phase B,多层 OCR 清洗的 LLM 层,小模型默认 Qwen3-4B):
   [LLM·clean] 原始 OCR → digest{doing, keywords};纯噪音 → skipped_noise
   checkpoint = digest 列,每 session 独立事务;下游全部吃 digest
→ run_day.py 主循环(Phase C,14B),每 session 一个事务:
   1. retrieve.py  候选检索(无 LLM):当天 open events 词法打分 top-K
   2. [LLM·decide]  session 卡片 + ≤K 个候选卡片 → 单选 {"join": id} 或 {"new": true}
   3. [LLM·describe] 仅 NEW:写 title/summary/type/facets/tags(小 JSON)
   4. 同事务:events 写库 + session 标 completed     ← 断点恢复粒度
→ finalize_day.py(当天 sessions 全 completed 后):
   a. [LLM·summarize] 每事件由全部成员重写最终摘要(单事件小 prompt)
   b. [LLM·merge]     检索出的相似 open 事件对 → 二选一"应合并?"
   c. [LLM·join]      每事件检索 top-K 历史事件(读 ~/.portrait/events/*.md
                      frontmatter,只读)→ 逐个二选一"同一持续活动?"
→ inspect_day.py:markdown 报告,与生产 events/<day>/ 并排对照
```

“合并/全量搜索”的回答:**检索(词法 Jaccard/IDF)负责全局视野,LLM 只做
候选间的窄判断**。检索召回错了 LLM 救不了 —— 所以 finalize 有 merge 兜底
(漏 join 造成的重复事件在终态再并)。

## 文件

| 文件              | 职责                                                        |
| ----------------- | ----------------------------------------------------------- |
| `labdb.py`        | lab.db schema + 事务式 checkpoint 助手                      |
| `source.py`       | 只读取 frames / Tier-1 merge / 历史事件 frontmatter 加载    |
| `retrieve.py`     | 无 LLM 候选检索(token Jaccard + IDF 加权)                   |
| `engine.py`       | mlx_lm 包装:加载、生成、JSON 抽取/修复/重试、llm_calls 落库 |
| `prompts.py`      | decide / describe / summarize / merge / join 五个小 prompt  |
| `run_day.py`      | 主循环 CLI(断点续跑入口)                                    |
| `finalize_day.py` | 终态三步(summarize/merge/join)                              |
| `inspect_day.py`  | 产出报告:lab 事件 vs 生产 events/<day>/                     |

## 用法(每一步跑之前先问用户!)

```bash
cd Tests/event-local-lab
python3 clean_day.py --day 2026-06-07                # Phase B:OCR→digest(4B)
python3 run_day.py --day 2026-06-07                  # Phase C:聚类(14B),断点续跑
python3 run_day.py --day 2026-06-07 --limit 5        # 烟雾测试:只处理 5 个 session
python3 finalize_day.py --day 2026-06-07
python3 inspect_day.py --day 2026-06-07              # reports/2026-06-07.md
```

模型默认 `mlx-community/Qwen3-14B-4bit`(已在 HF 缓存,无需下载);
`--model` 可换 8B/4B 做梯度对比。

## 状态

- [x] v1 脚手架(本文档 + 全部代码)—— 未跑过任何模型
- [x] v1.1 多层清洗:clean_day.py(用户提议:时间换质量,数字越洗越准)
      ⚠️ 改了 OCR cap(600→2000),已 ingest 的天要 --reingest 才吃到新 cap
- [ ] 烟雾测试(--limit 5,等用户确认 + faithful_v2.py 停)
- [ ] 整天跑通 + inspect 对照
- [ ] 质量结论 → 决定细化指标 / 改架构 / 换模型档位
- [ ] (远期)移植 Swift + MLX 打包进 app —— 处理逻辑那时再改
