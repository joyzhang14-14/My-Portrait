# writing-style-lab —— 写作风格提炼 · 本地 MLX 实验室

把云端风格提炼(生产 `WritingStyleDistiller`,现跑 sonnet)换成**本地 MLX + Qwen3**,
架构改成**一 agent 一维度一信息**。仿照 `event-local-lab` / `writing-capture-extract`。

## 核心设计:确定性打底 + 小模型只命名

审查(桌面《写作风格提炼pipeline·审查与优化方案》)结论:多数风格信号能用**纯 Python
确定性算法**从原始 `keystroke_log` / 终稿文本 / `edit_log` 里量出来。所以这里把"判断"
下沉到 `features.py`,LLM 只做"给量好的信号起个名 / 确认",这正是本地小模型(1.7B–14B)
能稳的活。

```
生产库(只读)          本实验室(lab.db)                    产出
~/.portrait/          ┌─ source.py  按 app+时间窗 join      facets 表
 portrait.sqlite  ──▶ │  keystroke_log(不用坏的回链)   ──▶ 一 (app-group × 维度) 一行
 writing_records      ├─ features.py 确定性特征(零 LLM)      + report.py 渲染 md
 keystroke_log        └─ run.py 逐 app-group 逐维度跑 agent
```

## 六个维度(agent),各吃各的信号

| 维度                             | 吃什么信号(确定性)                                                | 模型档   | LLM 干啥     |
| -------------------------------- | ----------------------------------------------------------------- | -------- | ------------ |
| ① 消息结构(倒装/反问/宾前/连动…) | 终稿文本 + 结构轻提示                                             | big 14B  | 中文语序判断 |
| ② 语气(愤世/轻松/攻击↔温和)      | 终稿文本                                                          | big 14B  | 情感基调判断 |
| ③ 输入习惯(输入法/句中切换/速度) | keystroke_log:input_source 分布/切换数/键间 gap/拉丁 run/选词数字 | small 4B | 只命名       |
| ④ 修改习惯(批量vs实时纠错)       | edit_log:一次成稿率/删改比/连删爆发                               | mid 8B   | 归类         |
| ⑤ 标点排版(句号语用/盘古/切分)   | 终稿:句尾分布/盘古空格比;发送数                                   | small 4B | 只命名       |
| ⑥ 写作习惯(流线/流式/跳跃)       | 节奏:成稿率/删改/停顿/速度                                        | mid 8B   | 归类         |

**维度⑦「按 app/场景/对象分别分析」不是单独 agent** —— 每个维度都**对每个 app-group
跑一次**,facet 天然带上下文。app 是硬分组键;场景来自 `context_summary`。
⚠️ **收件人/对象身份现在采集层根本没采**(`typing_events` v13/14 删了 window_title/
thread_id),本实验室无法凭空造,需另做采集层改动(见审查文档 P2)。

## 用法

```bash
cd Tests/writing-style-lab
python3 run.py --list                     # 看哪些天有数据
python3 run.py --day 2026-07-02           # DRY-RUN:算特征 + 打印每个 agent 会看到啥(不加载模型)
python3 run.py --day 2026-07-02 --run     # 真跑本地 MLX(⚠️ 会加载模型,先确认 GPU 空闲)
python3 report.py --day 2026-07-02        # 看产出
```

- 默认 **dry-run**,不碰模型。真跑要显式 `--run`(纪律:并发 event-local-lab 会抢 GPU,先确认)。
- `--model mlx-community/Qwen3-4B-4bit` 把所有维度压到一个模型(省显存/快)。
- `--dims input_habits,punctuation_layout` 只跑指定维度。
- `--force` 重算;断点续跑:已有 `(day,group,dim)` facet 自动跳过。

## 模型

`dimensions.py:TIER_MODELS` 定档(small=Qwen3-4B / mid=8B / big=14B)。机器上已下载:
1.7B/4B/8B/14B/30B-A3B/**Qwen3.5-27B**。想用更新的(如 Qwen3.6):
`huggingface-cli download mlx-community/<id>` 后用 `--model` 指过去即可。

## v1 已知局限(对应审查文档,待后续)

- **句首补词 / 跳跃型**需要光标位置(`pos`)—— 上游 `TextDiff.sandwich` 算了又扔,v1 无。
- **收件人维度**信号采集层缺失(见上)。
- **讽刺/反讽**需要对话上下文(对方消息),v1 未接 OCR frames。
- `pangu_ratio` 在 OCR 重建文本(`source=canvas_fusion`)上不可信 —— prompt 已提示按 source 谨慎。
- 老击键行 `input_source=NULL`(v41 前),输入法特征只对新数据可靠。
