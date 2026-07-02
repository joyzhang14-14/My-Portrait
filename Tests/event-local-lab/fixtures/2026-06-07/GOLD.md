# GOLD 资产索引 · 2026-06-07 冻结日

> 人工/sonnet 逐条核过的判例资产。**改动管线必须对这些重放;翻盘≠自动否决,翻盘→人工复核(软门)。**
> ⚠️ 本日是 93 分位极端重编码日(57 天中位编码浓度 0.55 vs 本日 0.86),单日 gold 不足以守护换日分布
> ——日型样本在 `../daytypes/`,acceptance 门必须四日型一起看。

## 1. 42 例 dup 裁决 gold(exactly-once 验收)

出处:`analysis/structure_forensics.json` → forensics[1](F2)。43 个双分配 session、14 个事件对,
逐条内容裁决(33 强判例+9 弱判例+1 双不沾 s366)。

- 组合规则(壳优先→锚点决定门 max≥0.06 且比率≥1.1→末现后备)= 38/42 一致,强判例 33/33。
- ⚠️ 阈值是 pre-R6(冻结 idf)标定的绝对值;idf 重标后须改 rank/分位数并重放本 gold。
- 最大对:(E50 permission-bypasses, E53 IME tail-loss)×15 → 15 段全部属 E53。

## 2. 13 例 rescue 归置 gold(覆盖兜底验收)

出处:`analysis/structure_forensics.json` → forensics[0](F1)。29 段未覆盖(gpt41 29/29 全覆盖):

- 桶内有事件的 13 段 Tier1 模拟:9-10 段与 gpt 安置主题一致、0 垃圾。锁定判例:
  s630/s820/s936→writing-capture 重构线;s633→MemoriesView;s646→跨桶 recording templates(gpt 同);
  s425→Balanced power;s254→playlist/听歌;s665→OCR 移植。
- 整桶蒸发 16 段=[桶11×10, 桶20×6];s1080 该独立成事件(gpt 同款 'Deleted a Claude chat thread')。

## 3. 实锤C:perm24 六时间团块(时间项/拆分验收,blob 对齐应=1.00)

```
blob1 2.16-2.70h: 212,239,277
blob2 3.21-3.46h: 388,397,411,416,422,431
blob3 3.76-4.11h: 516
blob4 5.91-6.29h: 937,966,977,988,1000,1014,1018
blob5 6.70-6.75h: 1079,1085,1091
blob6 8.16-8.29h: 1189,1190,1193,1198   ← 双拼输入法集成,应归 librime/输入法线
```

时间区间数据:`sessions_time.json`(key→app/parts/start_ms/end_ms;当日 0 点=1780790400000)。

## 4. 禁合对(误合回归,永久)

- **s868**(代码重构 commit 'refactor(writing-capture): extract unified model...',WritingCapturePrompts.swift)
  必须独立/归重构线,**禁止**并入 'Extract and clean sent messages from JSON'。
- **s599**(ChatGPT→Codex 账号关联,Apple ID privaterelay,ToS)必须独立,**禁止**埋进 'Research AI tools'。
  （v4_anchormerge 两处误合实锤,版本对照翻盘依据;出处 `analysis/version_compare.json`)

## 5. 壳事件裁决

- E75(单例壳,s1116)该删;E42{756,1058}/E88{1169,1170,1172} 是**多成员壳=正确的更精子事件,该赢**
  (v5 两全版删 E42/E88 属"删反了但覆盖无害")。出处 F2。

## 6. 关键指标基线(2026-06-07)

| 版本                    | 事件   | 覆盖        | dup    | mega≥20 | B³F1 vs gpt41 |
| ----------------------- | ------ | ----------- | ------ | ------- | ------------- |
| v1_raw225               | 225    | 287/337     | 82     | 2       | 0.286         |
| v2_fixes90              | 90     | 308/337     | 43     | 2       | 0.402         |
| v3_globalmerge          | 41     | 308/337     | 36     | 4       | 0.402         |
| v4_anchormerge86        | 86     | 308/337     | 38     | 2       | 0.404         |
| **v5 bestofboth(胜出)** | **88** | **308/337** | **38** | **2**   | **0.403**     |
| gpt-5.4(参照)           | 41     | 334/337     | 0      | —       | —             |

数据:`cmp/*.json`;分桶复现基线:α0.7/τ0.30/cap30 → 24 桶(时间项/降权落地后桶数会变,
acceptance 期望值按版本更新,**"24桶"不是永久断言**)。

## 7. 质量 gold 摘录(出处 `analysis/quality_audit.json`)

- 残渣基线:skip-permissions 在 doing 132/337;本地摘要 20/88 命中 vs gpt 0/41(下游可修天花板)。
- 王昱在 s432/s1115/s1180 doing 有 3 处,摘要必须可检索(S2 场景)。
- 锚点互换病例:local#3/#4(ScreenCaptureKit↔MemorySettingsView)= 合并后未重生成摘要。
- 上游:doing 保真 ~47%;raw_sessions.ocr 有 2000 字符入库截断(593/1200 恰=2000,待修)。
