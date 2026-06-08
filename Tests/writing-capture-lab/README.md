# 写作采集 · 本地化改进实验室

按 `~/Desktop/写作采集/算法-改进版.md`(v5 执行规范)分阶段实现的**可信、可复现本地实验室**。
Python(SwiftPM 不扫此目录,不影响 Swift 构建)。改生产 Swift 需先经用户批准(规范执行规则 6)。

## 跑测试
```bash
cd Tests/writing-capture-lab && python3 test_evidence.py   # 阶段零,失败返回非零退出码
```

## 阶段进度(以 `算法-改进版.md` 的复选框为权威)
- **阶段零(数据契约)**:`evidence.py`(EvidenceResult/AuthorEvidence + 状态固定下游行为)+ `test_evidence.py`。✅
- 阶段一(发送证据状态机)→ 二(固定 fixture)→ 三(占位符+#41-45)→ 四(patch+验证器)→ 五(#40)→ 六(Pass4/Canvas)。待做。

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
