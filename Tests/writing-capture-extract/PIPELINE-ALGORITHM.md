# 写作采集 Pipeline 算法 Spec(给 Claude 自己看的备忘）

> **用途**:跨 context 不丢线索。记录①整条 pipeline 怎么跑 ②**当前部署的 Swift(v1)** vs
> **已验证的 harness(v2 + 回车检测)** 的差异 ③还没做的事(把 v2 接进 Swift)。
> 最后更新:2026-06-08。harness 在 `/tmp/rime-test/eval/`,生产代码在
> `Sources/MyPortrait/Memory/WritingCapture*.swift`。

---

## 0. 一句话状态

- **harness(Python)已验证 v2 + 回车检测**:旧 193 → 新 169,清掉 24 条草稿碎片,真发送
  一条不丢,**0 回归**。
- **生产 Swift 还是 v1**(v2 曾接进去又 `git reset --hard` 撤了)。**核心待办 = 把 v2 的
  edit_log 回放 + 回车检测移植进 Swift `unifiedExtract`/`withinEventSends`**。
- **铁律**:AX 路全本地 MLX、不用 Ollama、不偷连云端、喂完整记录、接 librime、用真实筛选算法。
  Canvas 可以用云端(用户认可)。写作采集用小模型不用 sonnet。

---

## 1. 整条 pipeline(Step0 → Pass1 → Pass2 → Pass3 → Pass4)

数据源:`~/.portrait/portrait.sqlite` 的 `typing_events`(AX 输入框快照 + `edit_log`)、
`keystroke_log`(物理击键)、OCR frames。

```
原始 typing_events / keystroke_log / ocr_frames
        │
   Step0  WritingCaptureStep0.preprocess()        ← 按空闲 >5min 切 session,产 rawSessions
        │
   Pass1  WritingCapturePass1Agent                ← OCR+击键 → 上下文时间线(intentType+summary)
        │                                            模型默认 sonnet(应换小模型);≤100 帧采样
        │
   Pass2  WritingCapturePass2Agent                ← 每个 rawSession 判 primary_source = ax | ocr
        │                                            ax: units=[[event_id…]] 一条消息一组;ocr: 走 canvas
        │                                            模型 haiku;失败 fallback 全保留
        │
   Pass3  WritingCapturePass3Agent ─┬─ AX 分支    ← typingTotal>50字:unifiedExtract(确定性)
        │                           │                + AxCleanup LLM 补 IME 拼音残渣 → source=ax_cleaned
        │                           └─ Canvas 分支  ← OCR 逐窗快照 diff 重建文档 → source=canvas_fusion
        │                                            模型默认 sonnet
        │
   Pass4  WritingCapturePass4Agent                ← 逐 (app,url) 组,一次 LLM call 判每条 keep/discard
        │                                            喂完整记录 + user_rejected 例子;并发 5 组
        ▼
   writing_records(入库)
```

模型解析链(`ConfigSchema.swift:212-214`):`resolvedModelLight` → `modelLight` 空则
`resolvedModel` → `model` 空则 provider `defaultModel`(兜底 sonnet)。**写作采集应锁小模型**。

---

## 2. AX 提取核心:当前 Swift(v1) vs 已验证 harness(v2)

这是整件事的关键。两边都在做"从一串 `typing_events` 的 `edit_log` 里还原出用户真正发出的消息",
但算法不同。

### edit_log 条目语义(两边共用)
`{kind, text, ts}`,kind ∈:
- `commit` = 输入法真把字落进去 = **手打**(中文 IME 出汉字 / 英文逐字)。算进击键置信度。
- `delete` = 文本被删(退格 / 发送后清空 / 修剪)。
- `paste` = 剪贴板注入,**零击键,永不算手打**,任何提取都过滤掉。
- `submit` = 回车标记,**不可靠**(回车未必真发出、app 会假清空),两边都**不**拿它当发送依据。

### 2a. 当前部署 Swift v1(`WritingCaptureWorker.swift`)

| 组件 | 行号 | 规则 |
|---|---|---|
| `unifiedExtract()` | 1306-1327 | 状态机:`cur` 跨事件草稿累加;`withinEventSends` 抓事件内发送;`isResetState` 判边界;next-event sessionStart 复位 → 提交 cur |
| `isResetState()` | 1259-1263 | 空/全空白/全零宽 `{200B,200C,200D,FEFF}` / 在占位符集合里 → true |
| `collectPlaceholders()` | 1268-1285 | run 级:某 endValue 被单条 commit/**或** paste 整块出现、且全 run **≥3 次** → 占位符 |
| `withinEventSends()` | 1288-1303 | delete 块两侧紧挨 marker(空/占位符)、≥2 可见字 → 事件内发送 |
| `mergePrefixDrafts()` | 1334-1363 | 同 (app,url):无真发送(`isSendClear`)且文本是更长后续记录的严格前缀 → 丢(陈旧草稿) |
| `isSendClear()` | 1145-1156 | endValue 空 **且** edit_log 有「删掉非自己 commit 的累积文本 ≥2 字」→ 真发送清空 |
| `bestGroupText()` | 1165-1191 | 取组内最完整文本:endValue > edit_log 最长 commit/delete > 最后有效 endValue > "" |
| `extractSentMessages()` | 1208-1248 | 旧算法,已被 unifiedExtract 部分取代 |
| `axConfidence()` | 1368-1384 | `commit字 /(commit字+delete字)` → 映射 [0.80,0.99] |

**⚠️ v1 关键缺陷(grep 确认)**:`WritingCaptureWorker.swift` 提取路径(1306-1537)里**没有
任何 keystroke_log 查询 / 回车键 / `\r`/`\n` 检测**。`keystroke_log` 只在 152、500 行注释里
提到(黑名单层,不在提取逻辑)。**delete 清空输入框就被当发送,不管有没有真按回车** →
这就是草稿碎片(打了又退格删的)被误记的根因(问题 #1/#8)。

### 2b. 已验证 harness v2(`extract_compare_v2.py` `newExtract`)

edit_log **回放**,比 v1 更准。流程(行 113-147):

```python
for k, e in enumerate(evs):
    cs = cstream(arr)              # 所有 commit 文本拼起来(手打流)
    endv = cv(e['endv']); endEmpty = emptyZW(e['endv'])
    ph = phMarkers(arr)           # 本事件占位符(paste-only ∩ delete,≥6字,含真字符)
    # ① submit:≥2字直接 emit(冲掉不相关的 cur)
    # ② 事件内发送 withinSends(arr, endEmpty, ph, returns) ← 含回车检测,见 §3
    # ③ endValue 边界:
    injected = cover(endv,cs)<0.2 and not (ssv and related(endv,ssv))  # 没 commit 背书 & 非从 ss 演进 = 注入
    resting  = endv in delset or endv in ph or endv in RUNPH           # 静止占位符
    if not injected and not resting: cur = endv      # 演进中的草稿,继续累加
    elif cur: emit(cur); cur=None
    # ④ 跨事件:下个 ss 空或与 cur 不 related → 提交 cur
```

辅助函数:
- `phMarkers`(69-79):占位符 = **paste 注入**(不是 commit)∩ 被 delete、≥6字、含 `[A-Za-z一-鿿]`。
  **只认 paste 不认 commit** —— 否则把"打了又删的普通词(sonnet/fang dao)"误当占位符,
  连累紧挨的中途删除被误判成发送。
- `RUNPH`/`runPlaceholders`(83-93):全 run paste **≥5 次**、长 6-40、含真字符 = 静态占位符
  (抓 `Write a message…` 这种不逐事件删的)。
- `emptyBox`(94-95):`EMPTY_OK={200B,200C,200D,FEFF,0A,0D,09,20}`,**不含 `\xa0`(00A0)**——
  Spiffy 拿 `\xa0` 当真占位符,不能算"空框"。
- `cstream`/`cover`/`sim`/`related`:`cover`=LCS 覆盖率(endv 多少字能在 commit 流里对上,
  <0.2=注入);`related`=`sim≥0.5 或 互为前缀`。

**v2 验证**:`extract_compare_v2.py` 全量对 4 天(05-27/28/29、06-05),旧 193 / 新 169,
占位符泄漏 0,真回归 0(3 条已知误标 = 粘贴的 `先读文档…`/`他说文档说…` + emoji 串,不算)。

---

## 3. ⭐ 回车检测(最新已验证的根治法,2026-06-08)

**问题**:事件内一段文本被 delete 清空,是**真发送了**(该记)还是**打了又退格删的草稿**(该丢)?
`删老`/`你跳过`/`每次都`/`然后`/`Spiffy` 这些碎片就是后者。

**干净信号** = 这条 delete 前 ~1.8s 窗内 `keystroke_log` 有没有**回车键**(`char IN ('\n','\r')`):
- 真发送:按 Enter 清空框 → delete 前必有回车(实测 `OCR合成`/`Canvas`/`那我就不知道`/`我的`
  回车=1,留对)。
- 草稿:退格一路删空 → 无回车、只有 backspace(实测 `删老`/`你跳过`/`每次都` 回车=0、退格=3,丢对)。

**实现**(`extract_compare_v2.py`):
```python
# loadev:每个 event 多取 bundle_id/started_at/ended_at,查窗内回车键时间戳
rets = con.execute(
    "SELECT ts_ms FROM keystroke_log WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? AND char IN (?, ?)",
    (bundle, started-2000, ended+2000, "\n", "\r")).fetchall()

# withinSends 加 sent() 闸:
def sent(ts):  # 前 1.8s 到后 0.2s 有回车 = 真发送
    return ts is not None and any(ts-1800 <= rt <= ts+200 for rt in returns)
...
    if not sent(e.get('ts')): continue   # 没回车 = 草稿,不当发送
```

**效果**:清掉 24 条草稿碎片、真发送一条不丢、0 新增回归。`我的`(2 字真发送)靠回车留住——
纯长度阈值 / 纯击键阈值都会误杀它,**只有回车信号能保短真发送**。确定性、不靠模型。

---

## 4. 真实筛选算法(harness `faithful_pipeline.py` 已接,对齐 Swift)

按顺序作用在提取出的消息上:

1. **组级击键 gate**(Swift 1461-1463 / py 127):`if totalLen>20 and kc < totalLen//4: skip`。
   `kc` = `keystroke_log` 中 `(modifiers&7)==0`、app 匹配、窗 [start-10s,end+10s] 的击键数。
   长文但击键 <1/4 字数 = 粘贴/OCR/AI,丢。
2. **slash gate**(Swift 1465-1469 / py 129):击键文本(去 `<CR>`/`<BS>`)以 `/` 开头 → 斜杠命令,丢。
3. **AxCleanup**(librime + 本地模型 fusion,§5):补 IME 拼音残渣。
4. **trimLatinTail supersede**(Swift 1511-1530 / py `supersede`):A 去掉末尾 1-3 个 latin/空格后
   ≥2 字、且是更长 B 的前缀 → A 是中途态,丢。
5. **mergePrefixDrafts**(Swift 1334-1363 / py `merge_prefix`):同 app,A(≥15 字)是更长 B 的
   严格前缀 → A 是早期草稿,丢。
6. **is_residue**(A 组 #8,确定性残渣过滤,py 141-147):三条正则
   - `[a-zA-Z0-9]{1,4}` 纯短拉丁/数字(`w1`/`oc`)
   - `[a-z]{1,4}( [a-z]{1,5})+` 空格分隔拼音碎片(`p s`/`ji d`)
   - `[一-鿿]\s*[a-z]{1,3}( [a-z]{1,3})+$` 且 ≤25 字:中文+末尾空格分隔拼音(`hen bu x`)
   - **必须保留连写英文词**(`XPC`/`gemini`/`bug`/`notebookLM`)——早期 bug 是把这些误删了。

---

## 5. AxCleanup:librime + 本地模型 fusion(全本地)

补 IME 没落定的拼音残渣(`…什么dian` → `…什么店`)。**不许用云端**。

- **librime 桥**:`/tmp/rime-test/cands <拼音> <n>`,把连写整拼音解成候选
  (`tedian→特点`,`jiushishuo→就是说`,`henbuxihuan→很不喜欢`)。解不了缩写(`jiu s s`)和残缺(`hen bu x`)。
- **fusion**:每条消息里的 latin run 抽出来过 librime → 候选连同击键 + 上下文喂本地 MLX,
  模型挑同音字。`AX_SCHEMA = {fixed:[{id,text,confidence}]}`。无残渣则免 LLM 原样过。
- **模型**:AxCleanup 用 **MLX 4B**(1.7b 太弱,同音字挑不对;实测 librime+4b ≈ 88% 对齐库里)。

---

## 6. Pass4 记录格式 + 模型结论

### 记录结构 `WritingCapturePass4InputRecord`(`WritingCapturePass4Agent.swift:11-37`)
```
recordId: String          // "g<组>_r<记录>"
text: String
kind: String              // long_form(≥140字) | short_form | other
source: String            // ax_cleaned | canvas_fusion | merged
app: String               // bundle_id
url: String?
keystrokeCount: Int        // 真实物理击键(≥0=用户打的)
contextSummary: String?    // Pass1 场景摘要(≤100字)
keystrokeText: String?     // 仅 canvas_fusion:原始击键
```
`keystrokeCount` 算法(`Pass4Builders.swift:55-65`):`keystroke_log` 中 `bundleId==app` 且
`ts ∈ [startTs-10s, endTs+10s]` 且 `(modifiers&0x07)==0`(排除 cmd/opt/ctrl)的条数。
并发:逐 (app,url) 组,一组一次 LLM call(组内全部记录一起喂),`concurrency:5`。

### Pass4 模型结论(**喂完整记录前提下**)
- **Ollama 1.7b 完美**(完整记录 + user_rejected 例子,正确丢 `然后`/`删老`/`w1`,留真消息)。
- **MLX 1.7b/4b 不稳**(1.7b 全留;4b 过丢、把 `可以试试` 也丢了)。
- **MLX 8b 最好**(真消息 7/7 全留,但仍会留个别碎片 → 靠 §3 回车检测在**提取阶段**先清掉,
  Pass4 就看不到碎片了)。
- 用户立场:量化差异很小,**根因是没喂完整记录**;完整记录下 MLX/Ollama 都该行。
  → AX 路**只用 MLX**(铁律),Pass4 用 8b。

prompt key:`pass4ContentReview`(`WritingCapturePrompts.swift:457-530`),canvas 组用
`pass4CanvasSupport`(537-574)。其它:`pass1ContextTimeline`(15-106)、`pass2Segment`
(721-785)、`pass3Fusion`(110-453)、`axCleanup`(674-719)。

---

## 7. Canvas 重建(可以用云端,用户认可)

OCR 逐版本快照 diff → window-fanout(切小窗并发 subagent)重建文档。本地 14b 质量不行
(20+ 处删改控不住幻觉),**用云端 Claude**。产出 `source=canvas_fusion`。已重建 3 篇存
`/tmp/rime-test/eval/canvas_cloud.json`(05-28 Safari 残篇、05-29 Safari "Why I'm Building
a Copy of Myself"、05-29 Notes "Natural Monopoly Analysis")。

---

## 8. 八个已知问题 + 状态

| # | 名称 | 根因 | 状态 |
|---|---|---|---|
| 1 | 草稿全删没后续 | delete 清空当发送,不验是否真发出 | **✅ §3 回车检测根治** |
| 2 | 原地编辑跳变切分 | 占位符当边界,中途切碎 | ⏳ 待修(分段/合并,与 #3/#5 同根) |
| 3 | merged 长消息整类漏 | 新 pipeline 该合的没合,丢内容 | ⏳ 待修(结构性) |
| 4 | 粘贴误当手打 | 没在**文本段级**验 commit 背书 | ✅ 手打铁律 + §2 commit 验证 |
| 5 | 占位符泄漏 + 碎片 | Claude 输入框闪占位符,当消息末尾切 | 🟡 部分(回车清草稿;占位符剔除/IME 边界/合并待修) |
| 6 | 跨午夜重复 | day-run 按 UTC 切日,机器 TZ UTC-4 | ✅ backlog 连续游标解决(day-run 跨午夜别单跑) |
| 7 | IME 尾巴丢字 | 回车竞速,AX 读框时字已被清 | 🟡 部分(submitRaceBurst 2/5/9/14/20ms 重读;librime 兜底未接 Swift) |
| 8 | 生拼音残留 | 中途快照/退格草稿(内容在 keystroke_log,非 librime 失败) | ✅ §3 回车检测 + §4 is_residue |

问题清单原文在记忆 `project_handtyped_only_rule` / `project_ime_capture_limit` /
`project_pipeline_baseline`(`~/Desktop/Pipeline问题清单.md` agent 没找到,以记忆为准)。

---

## 9. 铁律 / 绝不做(必须长期遵守)

- **手打铁律**:只记 commit(键盘)背书的内容,粘贴一律不记,不管原文从哪来。判"是不是手打",
  不追"真来源 app"。信号 = edit_log `commit` vs `paste`/`delete`,**判在文本段级**
  (数时间窗击键会被 23min merge 骗;一个 event 混 paste+commit,门要落段级)。
- **AX 路**:全本地 **MLX only**,**不用 Ollama**,**不偷连云端**,**喂完整记录**(text/kind/
  source/app/url/真 keystroke_count/context_summary/user_rejected/真 prompt),**接 librime**,
  **用真实筛选算法**(§4)。
- **Canvas** 可用云端(用户认可)。
- **写作采集用小模型**,不用 sonnet;sonnet 锁 200K(用户拒绝开 1M credits,别尝试 1M)。
- **方法学避坑**:① 数时间窗击键 → 被 merge 骗;② end_value/submit 匹配 → Discord 发送清空、
  真消息也变 delete/空,误伤;③ 单看来源 event commit 量 → 英文(0.1-0.5)和粘贴(0)阈值贴太近、脆。
  结构问题(分段/合并)比阈值更值得修。

---

## 10. 文件地图

**harness(Python,`/tmp/rime-test/eval/`)**
- `extract_compare_v2.py` —— v2 `newExtract` + 回车检测 + 全量对照(旧 vs 新,0 回归校验)
- `faithful_pipeline.py` —— 忠实全 MLX pipeline(`1.7b|4b|8b`):v2 + gate + librime AxCleanup +
  supersede + merge + Pass4 + is_residue → 写 `Pipeline成品-新pipeline-<size>.md` + `faithful_<size>.json`
- `gen_raw.py` —— v2 原始切分 per day(带击键)→ `raw_msgs.json`
- `gen_local_fusion.py` —— librime+4b AxCleanup → Pass4 → 合云端 canvas → 最终文档
- `canvas_cloud.json` —— 3 篇云端重建 canvas
- `/tmp/rime-test/cands` —— librime 解码二进制(`cands <拼音> <n>`)

**生产 Swift(`Sources/MyPortrait/Memory/`)**
- `WritingCaptureWorker.swift` —— Step0 调度 + **unifiedExtract v1**(待移植 v2)+ 筛选 gate
- `WritingCapturePass1Agent` / `Pass2Agent` / `Pass3Agent` / `Pass4Agent` —— 四个 pass
- `WritingCaptureAxCleanupAgent` —— AxCleanup
- `WritingCaptureCanvasAgent` —— canvas 重建
- `WritingCapturePass4Builders.swift` —— Pass4 记录构造 + keystrokeCount
- `WritingCapturePrompts.swift` —— 全部 prompt 文本
- `WritingCaptureStep0`(独立模块）—— session 切分

**存档(git)**:`Tests/writing-capture-extract/`(本文件 + harness 脚本快照 + README)。

---

## 11. ⭐ 待办(下一步要做的事)

1. ~~harness 验回车检测 0 回归 + 碎片清零~~ ✅ 已验(旧 193→新 169,24 碎片清掉,0 回归)。
2. **跑 faithful_pipeline 8b**(回车修 + is_residue)→ 出最终干净文档,确认 5 条残留草稿碎片清光。
   (正在后台跑,看 `/tmp/rime-test/eval/faithful_8b_rerun.log`)
3. **把 v2 + 回车检测移植进 Swift**(harness 验完才动,守"先测好再接"):
   - `unifiedExtract` 换成 edit_log 回放(cover/related 边界、injected/resting 判定)
   - `phMarkers`(paste-only)、`RUNPH`(≥5)、`emptyBox`(排除 `\xa0`)
   - `withinEventSends` 加**回车检测**:查 `keystroke_log` 窗内 `\n`/`\r`,无回车的事件内发送候选丢掉
   - 移植后必须 `swift build` 通过 + `xcodegen generate`(新增文件的话)+ 提醒用户 Xcode 重开
4. **剩余结构性问题** #2/#3/#5:分段/合并 —— 占位符剔除、IME 闪动不当边界、演进消息合并。
5. #7 IME 尾巴:把 librime 兜底接进 Swift(目前只 submitRaceBurst,克隆输入法已放弃,内嵌 librime 待接)。

---

## 12. ⚠️ 老 vs 新逐条对照发现的退步(2026-06-08,A–K)

用户拿老 pipeline 产出逐条对照新 8b,发现 **11 处新 pipeline 比老 pipeline 差**(详见
`~/Desktop/Pipeline问题清单.md`)。**之前"新 pipeline 更全"只在「碎片」维度成立;一旦涉及
IME 输入的中文消息,老 pipeline 明显更全更准**——老的有 keystroke_log + librime 尾巴重建,
新 harness 弱化/没接。归 5 类:

| 类 | 病症 | 案例 | 根因 | 修复 |
|---|---|---|---|---|
| **1 IME 尾巴丢失** | 汉字没进 edit_log,截断/整条丢 | 我今天早上5(点睡的丢)/啥/没看懂/就问(特定的人丢)/大多数人都很喜欢(Google的生态丢) | Return race:拼音秒选字秒发送,350ms debounce 没快照到汉字;keystroke_log **有**原始击键可恢复 | 接 keystroke_log + librime 重建 |
| **2 重建挑错/幻觉** | 逆天→你替;**gmail→购买了** | F/J | AxCleanup 模型挑错候选(librime #0=逆天却挑#3)/ 英文当拼音**硬造** | 击键选字序号优先;无高分候选**绝不脑补**;英文不送 librime |
| **3 残渣泄漏** | te dian(特点)/yo(用)/你fa shao 当记录留 | E/K | 该重建没重建,is_residue 又拦不住("dian"4字母、单组拼音逃过正则) | 治本=重建,别靠 is_residue 正则补 |
| **4 乱 event 重复/误切** | 他骂你…截断版+完整版都留 | G(ev1128) | 多消息连发边界 + endValue 截断态都当记录 | 按发送边界干净切;前缀/截断态合并取最长 |
| **5 长文/canvas 截断** | OCR优化长文拆+截;My Portrait 随笔停"it can…" | C/D | 增量长文没合并取最长;canvas 重建漏尾窗(OCR 帧里**有**尾巴) | 同输入框连续 event 合并取最终;canvas 覆盖到最后一帧 |

**最高优先级 = 把 IME 重建补回来(类 1/2/3)**,且重建**宁可保守(不全)也绝不幻觉**
(类 2 的 J:gmail→购买了 最危险 —— 往记忆里塞用户没说的话)。这条直接抬升 §11 待办里
"librime 兜底接进 Swift" 的优先级:它不是可选优化,是**新 pipeline 上线前必须补的能力**。

**关键证据(都已验证,DB 可复现)**:
- 尾巴在 keystroke_log:ev523 `dian1shuide1\r`(点睡的)、ev596 `sha1meikandong1`(啥/没看懂)。
- librime 数据没错:`nitian` 候选 #0=逆天(模型却挑了 #3 你替)。
- canvas 尾巴在 OCR 帧:`it can also be my first entrepreneurial project…`(重建却停在 it can…)。
- 老 pipeline 全部正确重建:staged #3256/#3285/#3286/#3143/#3153 等。
