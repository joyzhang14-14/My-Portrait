# GOLD v2 · 新宇宙(v4b doing)· 2026-07-03

> 213 条 exactly-once 裁决复审(workflow wti1b6gsc,4分片+judge)。
> 规则准确率 82.4% (168/204 可判 = win_correct 142 + both_belong 26; 总213条中 unjudgeable 9, wron...

## 36 条裁反案例(=EO规则回归集;全部同一签名:loser标题关键词在doing逐字命中而winner零钩子)

- s86: cron按钮UI修复(TimelineSidebar)+说话人训练,真家='Retrain speaker profiles and fix UI',winner(VAD/转录)零钩子
- s91: speaker retraining+UI hit-test/Light模式修复,真家='Retrain speaker profiles and fix UI',无VAD/Silero内容
- s100: enrollByRecording/enrollByFile重训+ConnectionsView UI修复=loser原词,真家='Retrain speaker profiles and fix UI',VAD/silero零出现
- s103: UI divider改动+声音训练素材,真家='Retrain speaker profiles and fix UI',无VAD/转录
- s104: 两票连环裁反(idx31/32),音频训练/说话人识别+Divider UI,真家='Retrain speaker profiles and fix UI',VAD与Git两个winner均无钩子
- s111: fix(theme-light) divider修复,与s103同一工作,真家=Retrain+fix UI簇,winner(VAD)内容为零
- s124: writing-capture-researcher+'你得抓住mei'找回,纯采集内容,真家=writing-capture事件,VAD零关联
- s127: OCR移植+AxCleanup留存+scheduler=采集管线内容,真家=writing-capture/AX-OCR事件,无VAD/转录模型
- s140: 显式commit a7507ab fix(writing-capture),纯采集调试,真家=writing-capture事件
- s143: mega段,核心=placeholder采集修复(另含UI perf+AudioError第三事件),真家='Fix placeholder text misclassification',winner(VAD/模型)为零
- s180: LazyVStack→List布局卡顿修复,真家='Fix layout lag in My-Portrait',doing无placeholder内容
- s187: UI渲染性能LazyVStack→List,真家='Fix layout lag in My-Portrait',placeholder无踪影
- s188: 通篇LazyVStack→List布局卡顿,真家='Fix layout lag in My-Portrait',winner(placeholder)零出现
- s192: List刷新/布局卡顿(确认UI非DB)+长会议re-id,真家='Fix layout lag in My-Portrait'
- s239: LLM误判回退deterministic+ensureOcrPrepped/isAxBroken,真家=AX/OCR routing事件,ASR配置仅次要一句
- s245: AX/OCR安全边界/canvas输出验证,真家=AX/OCR routing事件,无speaker separation/FluidAudio内容
- s360: OCR移植+colorHex UI修复,真家='Port OCR and fix UI',winner(音频/记忆设置)仅endpoint配置沾边
- s416: IME尾丢/拼音恢复/击键日志,真家='Debug CJK input',winner(权限/系统工具)无钩子
- s425: 两票均错裁给'Debug CJK input'但doing零CJK内容;AMFI boot-arg/SIP应归权限事件,d987191 power mode部分应归power mode事件
- s428: 加Balanced/Auto电源档并commit d987191(4文件43行),真家='Implement power mode and Auto Live indicator',winner是skip-permissions杂烩
- s434: Balanced电源模式/PowerProfileState实时显示,真家=power mode事件,权限flag只是命令载体
- s435: 输入法漏采/多语言/攒数据微调,真家='Debug CJK input',winner(power mode)无钩子
- s625: revert ebfead8 boundary-send(194 errors),真家='边界消息提取'事件,无unified model内容
- s665: OCR移植+MemoriesView颜色渲染,与loser成员s667几乎同文,应归loser簇
- s770: screenpipe图标hit area/TimelineSidebar+设置UI修复,真家=sidebar UI簇,全篇零OCR
- s814: sidebar可折叠RECENTS+chevron toggle(f7a0cf0),真家=foldable RECENTS/sidebar UI事件,winner('got 0s'音频)零钩子(doing原文已复核确认)
- s820: 两票裁反(idx155/157),内容=00b07be writing-capture重构+f7a0cf0侧边栏折叠,真家='Refactor writing-capture pipeline and UI'
- s823: doing显式含SidebarIconButton+frame(minHeight:24),真家=sidebar UI事件,winner(logo/模型加载)零出现
- s853: field-state timeline+Codex模型列表gpt-5.x展开修复(=loser核心),无RECENTS fold实质内容,应归loser
- s871: VoiceTrainer start()状态检查致卡死修复,真家='Fix VoiceTrainer state and retry logic',winner仅泛UI沾边无OCR
- s874: VoiceTrainer stuck .failure+reset()前置+commit 694e4eb,真家='Fix VoiceTrainer state and retry logic'(doing原文已复核确认)
- s878: VoiceTrainer card stuck guard(.idle)+reset()修复694e4eb,loser标题精确命中,真家='Fix VoiceTrainer state and retry logic'
- s1119: 内容即foldable RECENTS,真家=foldable RECENTS事件,winner(00b07be field-state重构)零出现;此票导致s1119最终归属链整体走错

## 修法(判决)
- EO 加『不对称证据否决』子句:loser标题词逐字命中 + winner零字面钩子 → 改判loser(预计82.4%→90%+)
- 阈值不动(掉分是裁决逻辑非阈值)

## 其他判决要点
- v7b=新基线,老宇宙对照淘汰;残渣0/84、重生成11%、锚点零造假
- ⚠️ rescue塌缩bug:bucket18五事件sids解析失败→整桶塌成1个WeChat事件,s1177期末报告事件丢失(模型判断是对的,解析/rescue丢的)
- P_MERGE2六项:因果链✓/人名✓(带瑕疵)/引语✗(item提取稀疏66帧12项)/末part✗(s72 revert仍蒸发)/garble条件✓/幻觉✓——两个✗都在item提取层
- 人名中文原字禁罗马化(何成→He Cheng检索失败);大事件(n≥8)摘要按成员分要点
- kw裸百分比token是连接词隐患(79/337含'80%'类,来自bypass的_PCT_RX)
