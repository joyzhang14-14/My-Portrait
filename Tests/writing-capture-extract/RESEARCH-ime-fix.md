# 写作采集退步(A–N)修复调研报告(2026-06-08)

> 5 条研究线(R1–R5)的汇总。给"定方案→讨论→改"用。证据全部 DB/源码可复现。
> 关联:`PIPELINE-ALGORITHM.md` §12(问题清单)、`~/Desktop/Pipeline问题清单.md`(A–N)。

---

## 🔑 颠覆性发现(R1):老 pipeline 的 IME 重建,靠的是 **sonnet**,不是 librime

最关键的一条,改变整个策略:

- **Swift 生产代码里没有任何 librime/拼音解码逻辑**(`grep -rni rime Sources/` = 0)。
- 老 pipeline 把 IME 尾巴("点睡的""逆天""啥/没看懂""越高越好")补对,**100% 靠 AxCleanup 这步的
  强模型(sonnet)** 读懂"原始击键流"自己脑补汉字。`axCleanup` prompt
  (`WritingCapturePrompts.swift:685-693`)**已经显式写了**"击键比 text 多出干净音节、以选字/空格/回车
  收尾时,把整条缺失尾巴解码成汉字接上去"。
- 老 pipeline **每条 record 都无条件**把完整击键(`assembleKeystrokeText`,含拼音+选字数字+`<CR>`/`<BS>`)
  喂给 AxCleanup LLM——没有任何 gate。

**新 harness 为什么炸(双重原因,gate 是主因)**:
1. **(主因)致命 gate**:`faithful_pipeline.py::axcleanup()` 只在 **text 里 regex 出拉丁残渣**时才调
   LLM(`anyres`);否则直接返回原文。ev523 的 text="我今天早上5"(全汉字,无拉丁)→ gate 不触发 →
   **LLM 根本没被调用** → 尾巴永远补不回。ev596 同理整条丢。**gate 的判据(text 有没有拉丁)和失败
   模式(尾巴只活在击键里、text 看不到拉丁)正交,必然漏。**
2. **(次因)模型弱**:即便调用,MLX 8b < sonnet —— nitian 挑成"你替"(F)、gmail 幻觉成"购买了"(J)。

> **一句话**:老 pipeline = sonnet 的语言能力 + 一个早就写好的补尾 prompt。新 harness 用 gate 把这个
> prompt 的能力屏蔽了,又把模型换成了不够强的本地 8b。

---

## ⚠️ 由此引出的核心张力(要你拍的第一件事)

**铁律是"AX 路全本地 MLX、不连云端"。但老 pipeline 的质量恰恰来自 sonnet(云端)。本地 8b 单靠自己
做不到同等的拼音→汉字重建。**

调研给出的**全本地达标路径**(R2+R3+R4),不是靠"换更强的本地模型",而是靠**把确定性扛起来**:

```
librime(确定性候选,#0 对绝大多数干净拼音都对)
   + keystroke 选字数字(nitian「1」= 用户选了第1个 = 逆天,确定性锁定答案)
   = 重建主力(确定性,不靠模型猜)
本地 MLX 只在「librime #0 不可信(歧义/残缺)」时,在 librime 约束候选集里挑同音字
   + 防幻觉硬 guard(英文不送 librime;无候选支持的新增中文一律回滚)
```

这样本地 8b 从"自由出题"降级成"校对已知答案",F(你替)、J(购买了)都能在**代码层**钉死,
不依赖模型靠谱。**这是让"全本地"真正可行的关键** —— 没有 librime+选字数字这套确定性,
本地小模型自由重建必然出 F/J 这类错。

---

## librime 能力实测(R2,可复现)

`/tmp/rime-test/cands <连写拼音> <n>`:

| 输入 | librime #0 | 正确 | 结论 |
|---|---|---|---|
| `nitian` | **逆天** ✅ | 逆天 | 干净:#0 即对。F 的"你替"是模型挑了 #3,**librime 没错** |
| `buxing` | **不行** ✅ | 不行 | 干净(#1/#2 是 emoji,需 `emoji=False` 过滤) |
| `tedian` | **特点** ✅ | 特点 | 干净。K 的"te dian"残渣本应被这步消化 |
| `sha`/`meikandong`(分段) | **啥**/**没看懂** ✅ | — | 干净(必须**按 Enter 分段**,整串会串消息) |
| `yuegaoyuehao` | **越高越好** ✅ | — | 干净 |
| `dianshuide`(整串) | 点水的 ❌ | 点睡的 | **整串 #0 错**,要按用户分段 `dian`+`shuide`(后者选字数字定位"睡的") |
| `henbux`(残缺) | 很不幸 ❌ | 很不喜欢 | **残缺猜错,正确答案不在候选里 → 绝不能取 #0**(L 类,宁缺毋错) |
| `gmail`(英文) | 购买了 ❌ | (英文) | **英文被当拼音硬解 = J 的幻觉根因 → 送 librime 前必须拦英文** |

**能力边界**:① 完整单消息标准拼音 #0 几乎总对;② 必须用击键流**按 Enter 分段**(rime 整串分词会串句);
③ 残缺拼音会被强行补成别的词 → 必须识别并兜底;④ 英文会被硬解成汉字 → 送前必须拦。

---

## 各类修复方案

### 类 1/3(IME 重建,主旋律 —— A/B/E/H/I/K/M/N)
1. **砍掉 gate**:AxCleanup 每条 record 无条件喂击键(照老 Swift `WritingCaptureWorker.swift:1483`)。
2. **确定性重建优先**:从击键解析"拼音+选字数字",`cands(拼音)[数字-1]` 直接定字(R4 的 `parse_pinyin_picks`)。
   选字数字 1-indexed 已实测(nitian「1」=`[0]`=逆天)。
3. **按 Enter 分段**再解(避免整串串句);只补 edit_log 缺失/截断的段。
4. **残缺兜底**:末音节不完整(henbux)→ 删尾巴 or 保留原拼音,**绝不取 #0 硬写**。

### 类 2(挑错/幻觉,最危险 —— F/J)
1. **选字优先**:有选字数字就**确定性定字**,不让模型从候选里自由挑(根治 F 你替)。
2. **每条只喂自己那段击键**(现在把整 event 击键喂每条,干扰判断)。
3. **英文判定**(任一即英文,绝不送 librime):①击键里该拉丁后无选字数字、直接上屏;
   ②`cands(词)[0]==词本身`(rime 把真英文词放 #0:attention/coding/notebook/gemini);③切不出合法拼音。
   gmail 被信号①兜住(`g e<BS>mail<CR>` 无选字数字)。
4. **绝不脑补 硬 guard**(代码层,模型说了不算):模型输出做字符级 diff,**新增的中文若追溯不到
   librime 候选/确定性重建 → 判幻觉、回滚为原拉丁**(钉死 gmail→购买了);确定性已定的段 → 覆盖模型(钉死你替)。

### 类 4(乱 event 重复/截断态泄漏 —— G)
- 根因:`newExtract` 边界用 `related(下个 session_start, cur)` 判接龙,但下个 session_start 是 IME
  拼音尾巴(`他ma`),字面对不上 → 截断态"他骂你你也不会"逃成独立消息,和完整版重复。
- 修:emit cur 前,先看它是不是后面某条的"截断前缀"(**剥掉两边末尾拉丁/拼音残尾**再比前缀)→ 命中丢截断态。
  落点 = 扩 `supersede`,补一条"纯前缀 + 来自 endValue 且无回车背书(`sent=False`)"的 supersede。

### 类 5a(长文增量没合并 —— C)
- 根因:`mergePrefixDrafts`/`merge_prefix` 用**字面 `startswith`**;Notes 中段改字(ev606 vs ev607 在第
  46 字分叉)→ 字面前缀链断 → 截断快照逃逸。
- 修:把"字面 hasPrefix"换成"**最长公共前缀占比 ≥60%** 且 o 更长更晚" → 吞掉中段改字的增量草稿。
  保留现有"发送过的不丢"护栏(增量草稿无 send-clear,安全)。

### 类 5b(canvas 重建丢尾 —— D)
- 根因(两条,和窗口切分无关):① 这篇随笔**跨 app 写**(Safari 起草→Notes 续写),canvas 按 app 切成两个
  group 各自重建,Safari 那条天然缺尾(它的帧就没拍到续作);② Notes 那条带尾的 body 在 merge 时因为同屏
  混了两篇 Notes,尾巴被 LLM 归错文档。
- 修:① **治本**——canvas group 不只按 app 切,同一篇文档(标题/正文大量重叠)跨 app 合池再 fanout;
  ② **治标先上**——`run()` 合并出 body 后,拿本 group 所有 OCR 帧 full_text 做"尾巴校验":以 body 末尾
  N 字为锚,某帧锚点后还有续文就 append(纯确定性,只从已采集帧捞,不发明)。

### 类 6(新老共性,可能无解 —— L)
- `hen bu x` 用户没打完(只到 henbuxi),librime 也猜错(很不幸)。**优先级最低**,目标只是"别幻觉"
  (删残缺尾巴 or 保留原样),不追求补全。

---

## librime 嵌 Swift(R3):可行、低风险

- `/tmp/rime-test/cands` 已用 homebrew librime(1.17)跑通,纯 `RimeApi` headless 会话——**不抢焦点、
  不走 IMK**,跟输入法系统无关,符合"离屏"。
- 集成 = 标准"C 库 + bridging header + bundle 资源"活,仿已有 `MyPortraitObjC` 模式;
  **不用改 entitlements**(`disable-library-validation` 已为 MLX 开)。
- 体积:dylib ~4MB(librime + 7 个依赖);词库 `rime_ice.table.bin` **57MB**(gzip 25MB)+ lua/ 884KB(必带)。
  **建议词库 download-on-demand**(首次启用从 Release 拉到 `~/.portrait/rime/`,不进安装包)。
- 首次部署 ~8.2s(后台线程跑一次,产物缓存);之后常驻单 session、单后台串行队列复用。
- 双轨构建:C shim + `rime_api.h` 进 `Sources/MyPortraitObjC/`(SwiftPM 自动收);`project.yml` 加 link
  flags + dylib bundle 脚本,**改完跑 `xcodegen generate`**。
- 替代方案(纯查表 / 纯 MLX 生成)都不如 librime:前者等于重造 librime 的 1/10、后者就是 F/J 的幻觉源。
  **结论:librime 出候选集 + 整句 TOP,MLX 在候选内消歧,职责不变,只是从 subprocess 搬进进程内。**

---

## 建议的实施顺序(待你拍)

**阶段 0(先在 harness 验,不碰 Swift)**:按 R2/R4 改 `faithful_pipeline.py::axcleanup()`——砍 gate +
确定性重建(选字数字)+ 英文拦截 + 防幻觉 guard + 按 Enter 分段。用 A–N 做回归:F/J/类1/3 应全好,
0 幻觉。同时按 R5 改 `extract_compare_v2.py` 的 supersede/merge(类 4/5a)。**全部 harness 验过 0 回归。**

**阶段 1(canvas)**:R5b 治标(OCR 帧尾巴校验)先上,治本(跨 app 合池)排后。

**阶段 2(移植 Swift)**:harness 验完,把 ① 砍 gate + 确定性重建 + 防幻觉 guard ② supersede/merge 改
③ librime 接进 Swift(R3)移植进生产。守"先测好再接"+ `xcodegen generate` + 提醒 Xcode 重开。

---

## 待你拍的关键决策
1. **全本地路线确认**:走"librime + 选字数字确定性重建 + MLX 仅消歧 + 防幻觉 guard"(全本地,工程量大些),
   而不是"AxCleanup 退回 sonnet/云端"(违背铁律但最省事)?调研推荐前者,且证明了它能达标。
2. **librime 词库**:download-on-demand(安装包小,首用要联网拉 25MB)还是直接打进 .app(+57MB)?
3. **实施顺序**:按上面阶段 0→1→2,还是你有别的优先级(比如先只修最危险的 J 幻觉)?
