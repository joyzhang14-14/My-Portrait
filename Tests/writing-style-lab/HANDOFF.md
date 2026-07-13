# 写作风格提炼 本地化实验室 · 交接文档

> 目标:把 `writing_style` 提炼链路(生产 `WritingStyleDistiller`,**现跑云端 sonnet**)
> 换成 **MLX + 本地小 Qwen3**,架构改成**一 agent 一维度一信息**。Python 实验线,
> **生产 Swift 零改动**。仿照 `Tests/event-local-lab` / `Tests/writing-capture-extract`。
>
> **结论先行(已实证):16GB 全本地成立。** 8B + few-shot 就够,不用 14B/30B/云端。

## 背景与约束(用户定的)

- 动机:**隐私** —— 提炼要读用户真实打的每一句话,不该发云端。
- 推理形态:**MLX**(最终打包进 app),**不是 ollama**。实验线用 `mlx_lm`。
- ⚠️ **16GB 硬约束**:用户 dev 机 24GB M5,但**朋友也用 16GB**,产品要落到 16GB Mac。
  且 MyPortrait app 本身在跑(采集/OCR/ASR/DB)吃内存 → **留给提炼模型只 ~5–7GB**。
- **一 agent 一维度一信息**:一个维度一个 agent,各吃各的窄信号,可分模型档。
- **prompt 规范**:**指令用英文**,**few-shot 例子可中文/任意语言**。
- 实验**留在 Python**,不在 Swift 里试。
- ⚠️ **每次跑模型前必须先和用户确认**(event-local-lab 常占 GPU,撞上会换页)。

### 用户要的 6+1 个维度(第一性需求)

| #   | 维度         | 内容                                                  |
| --- | ------------ | ----------------------------------------------------- |
| ①   | 消息结构     | 倒装 / 反问 / 追加式 / 后置补说 / 宾语前置 / 连动结构 |
| ②   | 语气         | 愤世嫉俗 / 轻松愉快 / 攻击↔温和 / 冷淡↔亲近           |
| ③   | 输入习惯     | 输入法类型 / **一段话中途切输入法** / 打字速度        |
| ④   | 修改习惯     | 打完在句首补 please / 批量纠错 vs 实时纠错            |
| ⑤   | 标点排版     | 句号的语用学 / 盘古之白 / 消息切分                    |
| ⑥   | 写作习惯     | 流线型 / 流式型 / 跳跃型                              |
| ⑦   | **⭐最重要** | **按不同 app / 场景 / 对象分别分析**                  |

## 核心架构:确定性打底,小模型只"命名"

审查结论:多数风格信号能用**纯 Python 确定性算法**量出来。所以把"判断"下沉到
`features.py`,LLM 只做"给量好的信号起个名/确认" —— 这正是本地小模型能稳的活。

```
生产库(只读)                 lab.db(可续跑)                        产出
~/.portrait/portrait.sqlite
  writing_records ─┐
  keystroke_log  ──┼─→ source.py:按 app + 时间窗 [start_ts,end_ts] join 击键
                   │     ⚠️ 不用 reference_keystroke_range —— 实测多为 '{}'
                   │
                   └─→ features.py(零 LLM,确定性):
                         · 击键流 → 输入法分布/句中切换/键间 gap/拼音 run/选词数字键
                         · 终稿   → 句尾分布 / 盘古之白比 / 结构轻提示
                         · edit_log → 一次成稿率 / 删改比 / 连删爆发
                                          ↓
                       run.py:按 app-group 分组 → 逐维度跑 agent
                       (维度⑦由"每维度对每 group 各跑一次"天然实现)
                                          ↓
                       facets 表(day × group × dim)→ report.py

event-local-lab/lab.db(只读)  ← event_context.py 确定性 join(时间窗+app)
  raw_sessions.window ──→ scope(对象/场景:"@何成"=私聊 / "#皇片|头尖尖"=频道)
  vision_items        ──→ 屏幕证据(Server/Channel/User/在看什么)
  events / v4_events  ──→ 当天事件标题(场景轴)
                                          ↓
                       scoped_run.py:按 (app × scope) 分组 → 真·按对象分析
```

**铁律**:对象**只从 window/thread 标签推**,**绝不从消息内容猜**(否则"提到张三"
会被误当成"写给张三")。

## 文件

| 文件                 | 职责                                                                    |
| -------------------- | ----------------------------------------------------------------------- |
| `engine.py`          | mlx_lm 包装:load/unload、生成、JSON 抽取+**修复**+重试、llm_calls 落库  |
| `labdb.py`           | lab.db schema(records/facets/llm_calls)+ 可续跑 checkpoint              |
| `source.py`          | 只读生产库;按 app+时间窗 join keystroke_log;算特征入库                  |
| `features.py`        | ⭐**确定性特征骨架**(零 LLM):输入法/节奏/盘古/句尾/删改                 |
| `dimensions.py`      | 6 维度定义 = 6 个 agent(窄信号 + 英文 prompt + few-shot + 模型档)       |
| `run.py`             | orchestrator:按 app-group 逐维度跑(**默认 dry-run,`--run` 才加载模型**) |
| `report.py`          | facets → markdown                                                       |
| `det_test.py`        | 确定性层单测(特征 + JSON 修复),零模型,随便跑                            |
| `models_ab.py`       | 多模型 A/B(mlx_lm 档:4B/8B/14B/30B)                                     |
| `models_ab_vlm.py`   | VLM 档 A/B(Qwen3.5,走 mlx_vlm)                                          |
| `tone_fewshot_ab.py` | tone prompt v1 vs v2 A/B                                                |
| `verify_v2.py`       | 三合一验证:tone 英文版无回归 / ms 合成句 / JSON 修复                    |
| `event_context.py`   | ⭐join event-local-lab → scope(对象/场景)+ vision 证据 + 事件           |
| `scoped_run.py`      | 按 (app × scope) 分组跑维度 —— **维度⑦的落地形态**                      |

## 实测结论(比跑分可信,推翻纸面)

### 模型选型:8B 是甜点,越大/越新 ≠ 越好

2026-06-05 真实中文聊天数据(Discord 20 条 + Claude 3 条),难维度对比:

| 模型             | 可靠性     | 速度         | 中文句法 | 语气        | 16GB       | 判定           |
| ---------------- | ---------- | ------------ | -------- | ----------- | ---------- | -------------- |
| Qwen3-4B         | 5/6        | 最快 2–5s    | ✓        | 蒙对        | ✓ 2.3GB    | 易维度可用     |
| **Qwen3-8B**     | **6/6**    | 4–6s         | ✓        | 需 few-shot | ✓ 5GB      | ⭐**部署默认** |
| Qwen3-14B        | **3/6 崩** | **慢 5–18s** | 半漏     | ✗           | 顶格 7.8GB | ❌**淘汰**     |
| Qwen3-30B-A3B    | 6/6        | 热 2–4s      | ✓最好    | ✓最佳       | ✗ 16GB     | 天花板,不部署  |
| Qwen3.5-27B(VLM) | 4/6 漏判   | **7–35s**    | **全漏** | 漏一半      | ✗          | ❌**淘汰**     |

- **14B 两头不讨好**:dense 14B 全参激活,比 MoE 的 30B-A3B(只激活 3.3B)**还慢**。
- **Qwen3.5(201 语言、最新)没换来更好的中文分析**:反而更保守、漏判更多、VLM 多背一层。
- MoE **不省内存**(30B 全量常驻)——"3.3B 激活"≠ 内存小。

### 关键发现:提质靠 prompt(few-shot),不靠堆参数

| 问题                                                       | 修法                                                        | 结果                                                                      |
| ---------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| 8B 把调侃聊天判成"客观中立"(**混淆了技术话题 ≠ 中立语气**) | tone prompt 加 "TOPIC ≠ TONE" 铁律 + 3 个 few-shot          | **8B 从"客观中立"→"轻松调侃",追平 30B,零回归**                            |
| 所有模型对句法只吐笼统"追加式"                             | message_structure 加 4 个具体 few-shot(宾前/连动/倒装/追加) | 合成句实测 8B **认出倒装/宾语前置/连动**(high);真实闲聊仍**诚实**判追加式 |
| 4B/14B 的 `input_habits` 崩 JSON                           | `engine._insert_missing_commas`(补 evidence 数组缺逗号)     | 4B **0/2 → 2/2**                                                          |

⚠️ **JSON 修复顺序是坑**:`_insert_missing_commas` **必须在 `repair` 之前**跑 ——
`repair` 的裸引号前瞻会把相邻两个字符串**误并成一个**。

### 维度⑦(按对象分析):靠 event-local-lab 补齐

生产侧本来做不了(见下"生产缺口"),但 event-lab 的 `raw_sessions.window` 有完整窗口标题。
06-05 实测 **24/24 全匹配**,同一个 Discord 里**私聊和频道被干净分开**:

```
Discord × #皇片 | 头尖尖    19 条   ← 频道
Discord × @何成              1 条   ← 私聊对象
Claude  × Claude             3 条
Safari  × Withdraw Acceptance 1 条
```

## ⚠️ 三个"零重叠"坑(踩了三次,记牢)

| 信号                                 | 有数据的天                            | writing_records 的天 | 后果                                                                     |
| ------------------------------------ | ------------------------------------- | -------------------- | ------------------------------------------------------------------------ |
| `keystroke_log.input_source`(输入法) | 06-13 → 07-03                         | 05-24 → **06-05**    | **零重叠** → 输入法只能靠节奏启发式(`ime_inferred`:选词数字键+latin run) |
| `vision_items`(视觉)                 | 05-10 / 06-07 / 06-20 / 06-26 / 06-30 | 同上                 | **零重叠** → 06-05 需补跑 vision(已起过,见状态)                          |
| `events` / `v4_events`               | 06-07                                 | 同上                 | **零重叠** → 事件轴暂缺                                                  |

**根因**:writing capture 的 worker 默认 `off`,用户只手动跑到 06-05;而 input_source /
vision 都是之后才有的。**要拿干净信号,得先把写作采集在新数据上补跑出 writing_records。**

### 其他硬事实(生产侧,已核过源码)

- `keystroke_log.char` 对 CJK 存的是**拼音字母 + 选词数字键**,**拿不到合成汉字**
  (CGEvent 限制,`KeystrokeCharLogger.swift:15-18`)。
- `writing_records.reference_keystroke_range` 实测**多为 `{}`** → 别用它 join,用 app+时间窗。
- **生产缺口(见审查文档 P2)**:① 收件人身份在 `typing_events` v13/v14 迁移里被**物理删掉**
  (window*title/thread_id);② 光标位置被 `TextDiff.sandwich`(`TypingRecordWriter.swift:221`)
  \*\*算出来又用 `*` 丢弃\*\* —— 免费就能留住,是"句首补 please"和"跳跃型"的唯一信号。

## 用法(跑模型前先问用户!)

```bash
cd Tests/writing-style-lab
python3 det_test.py                                   # 确定性单测,零模型,随便跑
python3 run.py --list                                 # 看哪些天有数据
python3 run.py --day 2026-06-05                       # DRY-RUN:算特征+打印prompt(不加载模型)
python3 run.py --day 2026-06-05 --run                 # ⚠️ 真跑本地 MLX
python3 report.py --day 2026-06-05                    # 看产出

# —— 实验/对照线 ——
python3 models_ab.py --day 2026-06-05 --models 4B,8B,14B,30B --dims tone,message_structure
python3 tone_fewshot_ab.py --day 2026-06-05 --models 8B,4B    # prompt v1 vs v2
python3 verify_v2.py                                          # 三合一验证
python3 scoped_run.py --day 2026-06-05 --dims tone,message_structure --model 8B  # 按对象分析
```

- 默认 **dry-run**,不碰模型。`--force` 重算;断点续跑:已有 `(day,group,dim)` facet 自动跳过。
- 模型档在 `dimensions.py:TIER_MODELS`(small=4B / mid=8B / big=14B)。
  **实测 14B 该淘汰,难维度已改用 mid(8B)。**

## 状态

- [x] 脚手架 + 确定性骨架(`54282be`)—— 6 维度 agent、可续跑 lab.db、只读生产库
- [x] 确定性层单测 + 修 2 个真 bug(`1aef650`):盘古比分母、句尾分类(以字收尾=none 非 other)
- [x] 选型调研(6 路 web agent,带来源)→ `~/Desktop/Obsidian/写作风格提炼·本地模型选型调研.md`
      ⚠️ **初版把 30B-A3B 当首选是错的**(没做 16GB 内存把关),已按 16GB 修正
- [x] 5 模型 A/B + tone few-shot 固化(`d8fb8f0`)
- [x] message_structure few-shot + prompt 转英文 + 修 JSON 缺逗号(`0fa0b76`)
- [x] 接 event-lab 实现按对象/场景分组(`d676e86`),06-05 join 24/24
- [~] **06-05 补跑 vision** —— 起过(Qwen3-VL-8B,350 会话/603 帧),
  **用户要重构 vision 系统,已主动停**;lab.db 里留了 **37 行半截产物**,
  ⚠️ 重构后记得 `DELETE FROM vision_items WHERE day='2026-06-05'` 再重跑
- [ ] vision 重构完 → 重跑 06-05 vision → `scoped_run.py` 出**按对象**的风格分析
      (接口依赖:`vision_items` 的 `day` / `session_key`(能 join raw_sessions)/ `items`(JSON 数组)
      三个字段语义不变的话,writing-style 侧零改动)
- [ ] **gold 评测集** —— 调研发现:**中文讽刺/语用/句法业界没有任何 benchmark**,
      "到底多准"只能在自己数据上标(CIRON 式,几十条)。这是把"看着对"变成"可度量"的关键
- [ ] 扩大验证:现在只测了 06-05 两个 app,要跑更多天/更多 app(微信/浏览器/终端)
- [ ] 其余 4 维度(input/editing/punctuation/writing_mode)还没过同样的 few-shot 精修
      (靠确定性喂、已经不错,优先级低)
- [ ] (可选升级)**约束解码** —— MLX 可上 JSON-schema 语法约束,结构有效性≈100%,
      比 `engine.repair` 更彻底。**要引 `outlines` 依赖,需用户点头**
- [ ] (远期)移植进 Swift 生产 distiller —— 把验证过的 prompt/分档搬过去

## 参考文档

- `~/Desktop/Obsidian/写作风格提炼pipeline·审查与优化方案.md` —— 7 维度 × 差距 × **27 条修复**
  × 对抗验证(confirmed 12 / revise 15 / reject 0;newDep 0)
- `~/Desktop/Obsidian/写作风格提炼·本地模型选型调研.md` —— 选型(已按 16GB 修正)
- 相关铁律:`SarcasmBench` 实证 **CoT 伤讽刺** → 难维度用 **Instruct + few-shot,别开 Thinking**
