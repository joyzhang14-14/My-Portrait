# 写作采集 · 本地化改进实验室

按 `~/Desktop/写作采集/算法-改进版.md`(v5 执行规范)分阶段实现的**可信、可复现本地实验室**。
Python(SwiftPM 不扫此目录,不影响 Swift 构建)。改生产 Swift 需先经用户批准(规范执行规则 6)。

## 跑测试
```bash
cd Tests/writing-capture-lab
python3 test_evidence.py   # 阶段零
python3 extract_fixtures.py  # 阶段一:从活库重生 fixtures/send_signals.json(gitignore,未脱敏)
python3 test_signals.py    # 阶段一(读冻结 fixture);失败返回非零退出码
```

## 阶段进度(以 `算法-改进版.md` 的复选框为权威)
- **阶段零(数据契约)**:`evidence.py` + `test_evidence.py`。✅
- **阶段一(发送证据状态机)**:`signals.py`(三分判据)+ `extract_fixtures.py` + `test_signals.py`。✅
- 阶段二(固定 fixture)→ 三(占位符+#41-45)→ 四(patch+验证器)→ 五(#40)→ 六(Pass4/Canvas)。待做。

## 阶段一 · 发送证据三分判据(2026-06 对抗工作流校准)
真正判据 = **清空机制**(不是占位符 reset——草稿退光后框也出占位符):
- **有回车(纯回车 md==0,宽窗容忍~2.7s滞后)** → `confirmed_sent`
- **无回车 + 尾部连续退格 ≥ 内容长(整条退光)** → `confirmed_draft`
- **无回车 + clean 一次性清空(内容未被退格抹,凭空消失)+ 占位符/空框 reset + 击键背书** → `probable_sent`
  （IME 回车竞速吞掉 ~8% 真发送的回车键,clean_clear 把它们与"退格抹光的草稿"分开）

**承重墙验证**:17-agent 对抗工作流跑 461 条 OCR 确认真发送,92% 有纯回车,~8% 因 IME 回车竞速无回车
(硬反例 ev907/ev423/ev790,全 clean 一次性清空)。8 例 head-to-head 坐实判据。详见
`~/Desktop/写作采集/算法-改进版.md` §2.3 / 阻塞与决策。

**全量人群审计**(claudefordesktop 297 条框清空,诊断用非提交测试):状态机在证据明确的 case 上与
OCR 真值一致;~10 条分歧由 **OCR 预言机噪声**主导(对话区漏抓 / 子串撞车 / OCR 盲),非状态机误收
—— 4 条"OCR草稿→confirmed_sent"全是纯回车跟完整消息(真发送,OCR 假阴性);5 条 clean_clear 无回车
本就不确定故判 probable。无一条被证实的真误收。

**已知局限**(留待后续):Cmd+A 全选删(1 退格删长内容)、鼠标点发送、app 弃稿 —— clean_clear 兜底
可能把这类误判 probable_sent;OCR 预言机对 OCR 盲内容(小写/标点/滚动)不可靠。

**fixture 隐私**:`fixtures/send_signals.json` 未脱敏(含真实草稿/消息),gitignore,由
`extract_fixtures.py` 从活库重生。脱敏可提交版在阶段二。

## 阶段零① 数据结构定位(记录,供以后移植 Swift 时改)
**当前没有任何 completeness / delivery / pass4_status 字段**,以下结构以后需加(动 Swift 前先问用户):

| 位置 | 结构 | 现有字段 |
|---|---|---|
| `Sources/MyPortrait/Memory/WritingCapturePass3Agent.swift:11` | `WritingCaptureRecord` | text, editLog, kind, source, confidence, contextSummary, app, url, startTs, endTs, refs… |
| `Sources/MyPortrait/Memory/WritingCapturePass4Agent.swift:11` | `WritingCapturePass4InputRecord` | recordId, text, kind, source, app, url, keystrokeCount, contextSummary, keystrokeText |
| `Sources/MyPortrait/Memory/WritingCaptureStore.swift:454` | `writing_records_staged` 表 | date_utc, start_ts, end_ts, app, url, text, edit_log, confidence, context_summary, source, kind, refs… |

**本地实验室现状**:旧 harness(`Tests/writing-capture-extract/`)记录是裸 tuple `(app,text,kc)`,无状态结构 ——
本实验室用 `evidence.py` 的 `EvidenceResult` 作为唯一记录契约。

**以后移植 Swift 需改的文件**(待用户批准):`WritingCaptureRecord`(加 EvidenceResult 字段)、
`WritingCaptureStore`(staged 表迁移加列)、`WritingCapturePass4Agent`(pass4_status)。
**根目录 README 无需同步**(纯内部实验室,无对外行为变化)。
