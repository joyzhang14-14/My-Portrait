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

## v2(章节化)—— 解决单 session 孤证

用户用真实案例定位 v1 根因:云端强在**整天上下文交叉印证**(打错字
"胰腺癌"被当真实搜索;录 daily show 做转译测试被当看球)。v2 决策单元
从 session 换成章节:

```
clean(同 v1)
→ outline_day.py(Phase B2,14B):滑窗 ~40 digest/窗 + 上一窗章节接力
   → 全天划成叙事章节;LLM 漏归的 session 兜进最近章(镜像 coverGaps)
   checkpoint = chapters 表,断点续从未覆盖 session 接
→ eventize_day.py(Phase C v2):significance gate(单 session <2min 折叠)
   → 每章一次 describe_chapter(带前后章上下文)→ 事件;事务=章级
→ finalize_day.py(同 v1):merge 兜底(章节数 ~30,O(n²) 无压力)+ 历史 join
```

v1 的 run_day.py 保留可跑(对照用)。同一天切换 v1/v2 要 --reingest 重置。

## 用法(每一步跑之前先问用户!)

```bash
cd Tests/event-local-lab
python3 clean_day.py --day 2026-06-07                # Phase B:OCR→digest(4B)
# —— v2 主线 ——
python3 outline_day.py --day 2026-06-07              # B2:digest→章节(14B)
python3 eventize_day.py --day 2026-06-07             # C:章节→事件(14B)
# —— v1 对照线 ——
python3 run_day.py --day 2026-06-07                  # per-session 聚类(14B)
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
- [x] 烟雾测试 + 整天跑通(06-07,2026-06-11):1126 sessions 全 completed,
      **6 类 LLM 调用 9775 次零失败**;decide 258 事件 → merge 并 109 →
      终态 149(新 44 + 老事件复现 105);云端同日 28 个新事件。
      文档:~/Desktop/Obsidian/本地14B事件产出-2026-06-07.md + 云端事件产出-….md
      ⚠️ 已知问题:① merge 兜底 O(n²) 烧 6823 调用/123min(decide join 率
      不够狠是上游因)→ 下版改 top-K 邻居;② 产出粒度仍比云端碎(149 vs 28),
      decide/merge prompt 要更激进;③ describe 语言混杂(英文为主夹中文)。
- [x] v2 章节化搭建(outline/eventize,2026-06-12)—— 未跑
- [ ] v2 烟雾测试(--limit-windows 2 → eventize --limit 3,等用户确认)
- [x] v2 整天跑通(06-07,2026-06-12):149→46 events(云端28);两个孤证案例
      (胰腺癌打错字/daily show转译测试)**都修复**,但摆向过粗:10 个事件
      ≥40 sessions,最大139。根因=outline 滑窗 continue_last 雪球。
      未跑 finalize merge(会加剧过粗,污染粒度评估)。
      文档:~/Desktop/Obsidian/event pipeline local/(v1/v2/云端三方)
- [x] v3 实现(2026-06-13,未跑模型)—— 6 项,针对 "spotify 82-session" 失败:
      #1 chrome.py 确定性剥菜单栏/时钟/喇叭/默认标签(source.finish_session,
         无条件剥+灾难安全网;test_chrome.py 真实样本验证)⭐最高杠杆
      #2 bg_media 标记(媒体app+空window+dev信号;labdb 加列)
      #3 outline 章节软上限 60(continue/leftover 到顶不再堆,防雪球;
         ⚠️ 会过切真长活动,靠 finalize merge 合回——用户已接受 tradeoff)
      #4 clean prompt 加背景app+chrome标签否定规则(4B 靠列举)
      #5 outline prompt 加 [bg] 标记+反mega-chapter+meta-activity
      #6 eventize 末尾确定性兜底:标题点了媒体app但占比<10%且非媒体主导→改名
      废弃:frames.focused(全=1没用)、app重标(脆)、600cap(违设计)
- [ ] v3 跑 06-07 对照 v2/云端(等用户确认 + faithful 停;先 --reingest 吃 chrome 剥离)
- [ ] 现实预期:sonnet 的隐式消歧/全局连贯/未见chrome泛化 本地够不到,规则近似
- [ ] (远期)移植 Swift + MLX 打包进 app —— 处理逻辑那时再改
      ⚠️ 移植时 join 路径要做全产出语义(用户点名):不建新文件,给老事件
      merge:recordOccurrence(+1,per-day 去重)+ 追加 memberFrameIds +
      清 distilledInto(事件复活,重新进 distill 视野),标题/摘要冻结。
      实验室只读生产数据,只在报告里按此口径分区(occ_ev),不真写。
