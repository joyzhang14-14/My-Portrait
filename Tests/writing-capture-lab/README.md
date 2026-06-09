# 写作采集 · 本地化改进实验室

按 `~/Desktop/写作采集/算法-改进版.md`(v5 执行规范)分阶段实现的**可信、可复现本地实验室**。
Python(SwiftPM 不扫此目录,不影响 Swift 构建)。改生产 Swift 需先经用户批准(规范执行规则 6)。

## 跑测试
```bash
cd Tests/writing-capture-lab
python3 test_evidence.py    # 阶段零
python3 test_signals.py     # 阶段一(读 gitignore 的 send_signals.json;先跑 extract_fixtures.py 重生)
python3 test_fixtures.py    # 阶段二(完全离线,读已提交的脱敏 cases.json);失败返回非零退出码
python3 test_placeholder.py # 阶段三(占位符规则 §4 + #44/#45);失败返回非零退出码
python3 test_verifier.py    # 阶段四(确定性 patch 验证器 §5;纯算法无模型);失败返回非零退出码
python3 test_trigger.py     # 阶段五(#40 触发判定/回退/击键去重 §6;确定性);失败返回非零退出码
python3 test_stage6.py      # 阶段六(Pass4 状态机 + Canvas 约束 §7;确定性);失败返回非零退出码
# 重生 fixture(需活库):python3 extract_fixtures.py(阶段一原始信号) / python3 export_fixtures.py(阶段二脱敏)
```

## 阶段进度(以 `算法-改进版.md` 的复选框为权威)
- **阶段零(数据契约)**:`evidence.py` + `test_evidence.py`。✅
- **阶段一(发送证据状态机)**:`signals.py`(三分判据)+ `extract_fixtures.py` + `test_signals.py`。✅
- **阶段二(固定脱敏 fixture)**:`fixtures_lib.py`(脱敏+结构校验+读取器)+ `signals_raw.py`(纯函数提取)
  + `export_fixtures.py` + `test_fixtures.py` + `fixtures/cases.json`(26 个脱敏 fixture,可入 git)。✅
  - 已导出:7 labeled / 12 草稿负样本 / 2 短真消息 / 2 粘贴 / 2 占位符 / 1 高频。
  - **延后阶段四**(LLM/重建依赖真数据,脱敏会破坏语义):`#41`(IME 尾巴重建)、`#42`(gmail→购买了 反幻觉)、
    AI 回复负样本。见规范"阻塞与决策"。
- **阶段三(占位符规则 §4 + #44/#45)**:`placeholder.py`(known 配置/匹配 + §4.2 决策表 + learned 审计-only)
  + `test_placeholder.py`。✅
  - #44/#45 修复:占位符靠「是占位符串 + 无物理击键」判 app 注入(**不分 commit/paste**,堵 commit 注入泄漏);
    占位符整体删或整体留,**绝不剥前缀造「他说X」**。known 占位符受「有击键 + 有发送证据」例外保护。
  - #41/#42(IME 重建/反幻觉)→ 延后阶段四(用户已确认)。
- **阶段四(确定性 patch 验证器 §5)**:`patch.py`(schema+解析)+ `verifier.py`(九条规则 + 多 patch 冲突/倒序应用
  + 骨架哈希二次确认 + completeness 独立计算)+ `test_verifier.py`。✅(**纯算法、零模型**)
  - 核心铁律:模型只提局部 patch、**不信模型自报**;每个 replacement 字符可追溯到击键(英文顺序)/拼音候选(中文)/
    commit(标点),否则拒整个 patch。verification_passed ≠ completeness。反幻觉=rule6 拒 CJK 非候选。
  - **#41/#42 端到端重建 harness 已跑通**:`recon.py`(`rime_cands.py` librime + Qwen3-1.7B-4bit MLX +
    验证器)+ `rime/`(项目内置 librime)。真实成果:
    - **#42 gmail**:`g mai l → gmail`(模型判英文,购买了**未出现**);rule6b 反幻觉=中文须 commit 背书
    - **#41 海报**:`介绍的haibao → 介绍的海报`(commit-match 确定性优先,免模型同音字幻觉)
    - 验证器额外拦住模型同音字错误(海豹 vs 海报):未提交 → rule6b 拒,宁缺毋错
  - 环境:`mlx-lm`+`Qwen3-1.7B-4bit` 本机已有(零安装);`librime` homebrew + 雾凇词库(rime/ice gitignore)
- **阶段五(#40 整条重建 §6)**:`trigger.py`(触发判定 + 回退 + 击键去重)+ `test_trigger.py`
  + recon.py 的 `reconstruct_40`。✅
  - **仅明确数据不一致触发**(AX漏已提交中文/拼音残渣/跨事件互补/逐段无法对齐),**长度只进风险分不单独触发**。
  - 所有重建走阶段四验证器;无法安全应用 → **回退 captured 标 partial/unrecoverable,绝不伪装 complete**(宁缺毋错)。
  - 跑通:`介绍的haibao→介绍的海报`(complete)/ `记录xyz→记录xyz`(重建失败回退 partial)。零云端。
- **阶段六(Pass4 状态机 + Canvas 约束 §7)**:`pass4.py`(按 (app,url) 分组 + 每条输入恰好覆盖一次校验 +
  四状态)+ `canvas.py`(Canvas 约束)+ `test_stage6.py`。✅
  - Pass4:accepted→最终 / rejected→discarded / 调用·解析·覆盖失败→**review_failed 留 staged 不删(绝不默认全留)**
    / partial·draft·unknown·unrecoverable→not_applicable。每条输入恰好一个状态。
  - Canvas(唯一允许云端路径):跨 app 合池只做候选发现 / 新增需帧演进+击键+文档身份 / 不用最长 OCR 补尾 /
    不绕过 Canvas 专用 Pass4 / 同一 EvidenceResult 契约。

## ✅ v5 规范六阶段(零~六)全部完成,7 套测试全离线绿
零数据契约 / 一发送三分判据 / 二脱敏fixture / 三占位符+#44/#45 / 四确定性验证器 / 五#40触发回退 / 六Pass4+Canvas。
\#41/#42 重建 harness(librime+Qwen3-1.7B MLX+验证器)端到端跑通。**全程 Python 实验室,未碰生产 Swift**
(Swift 迁移是后续独立阶段,需用户批准)。

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
