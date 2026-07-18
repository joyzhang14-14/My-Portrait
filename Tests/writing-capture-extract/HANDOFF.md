# 写作采集本地化 · 交接文档(压缩版 2026-07-18;完整历史见 git 本文件旧版)

> 给下一个 session(或 compact 后的自己)。**单一恢复入口**。
> 逐版本叙事已压缩;需要某个修复的完整前因后果,`git log --follow HANDOFF.md` 挖旧版。

## 大局

- **生产 Swift 零改动** = 仍是老 pipeline(云端 haiku,`WritingCaptureWorker` unifiedExtract)。本目录全部是 Python 实验线;Python 实验线 ≠ 生产,放手改无接生产顾虑(移植 Swift 必须用户批准)。
- 用户双目标:**最大保留用户最终输入** + **计算最大本地化**。
- 当前状态:**v13 = 当前最佳成品**(`生产接入前审核大跑-v13-2026-07-18.md`,1337 条,gold **44✓/1🟡/0✗**,🟡=B14「123」旧账)——v12 的粘贴治理全量保留 + A20/B11 双✗根治。

## 当前架构(faithful_v2 一体化主程序,一条命令跑全量)

```
自家分组(同bundle+10min时间链连桶,UTC切日;staged 依赖已了断)
→ ax_bearing 承载率判别(逐键±3s内AX有无commit/submit;游戏/包装层skip;A闸_ax_owned去AX已有段)
  ├ 承载 → AX 路:event_sends_with_ts(真发送检测)→ reconstruct(librime确定性+14B disambig+guard)
  │        → OCR锚定(单段+单行才锚)→ 组级击键gate/slash gate → dedup/折叠群 → 口3 → Pass4
  └ 0承载 → canvas 路:B短(≤120键)canvas_librime 逐键解码+ax_verify+ocr_correct_llm
           / C长 canvas_merge(OCR层级归并)→ 过Pass4 → 并入成品(canvas绕过AX下游,脏数据必须在本层清)
→ 跨路由时间去重 → 成品md(⌨击键时间字段)+ 🔧口3修正审计 + 🗑️全闸口丢弃审计 + 未定区
```

- **按天 decode**:`decode_for(day) = day < 2026-06-25`(旧采集 librime 解拼音/新采集 AX 直给汉字);`PORTRAIT_LIBRIME_DECODE` 显式则全局强制。
- **分块可恢复**:每天 Phase1 落 `eval/v2cache/<day>.json`(存重建后 RAW 行)+ `_canvas.json`;重启跳已算天;`PORTRAIT_FRESH=1` 忽略。⚠️**写出层改动可缓存重排生效;重建层改动必须清缓存 GPU 重跑**。
- **14B 条件加载**:decode=0 且 det 且 canvas 已缓存 → 不加载模型。

## 关键文件

| 文件                                  | 职责                                                                            |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `faithful_v2.py`                      | 一体化主程序(**无 main 守卫,import 即跑全 pipeline,勿 import;py_compile 安全**) |
| `rebuild.py`                          | event_sends_with_ts/reconstruct/三道闸/上屏语义/keys_in_window                  |
| `extract_compare_v2.py`               | cstream/injected_texts/cover/占位符 PLH(import 时自跑对照,慢,正常)              |
| `ocr3.py`                             | 口3:complete_tail/proofread_tail/\_whole_residue_ocr/pick_frames 6级降级链      |
| `ocr_anchor.py`                       | OCR 锚定(击键单段→屏幕真值整条替换)                                             |
| `ax_bearing.py`                       | 承载率判别/canvas_spans/skip_canvas/A闸                                         |
| `canvas_librime.py`                   | B桶逐键解码(\_K .ime 三态)+ocr_correct_llm+ax_verify                            |
| `canvas_route.py` / `canvas_c_run.py` | B+C 编排(build_canvas 被 faithful 内联调用)/C 跨天聚合                          |
| `canvas_merge.py` / `canvas_local.py` | C 长文 OCR 层级归并(essay 98%/99%)/确定性行池+timeline                          |
| `ime_schema.py`                       | 零硬编码方案层(音节表/char_units 从 rime 词库提取)                              |
| `compare_gold.py`                     | gold 判分(44 项 + P0 隐私探针,gold 在脚本内)                                    |
| `rime/`                               | 项目内 librime(词库 gitignore,build.sh 重编)                                    |

## 采集层事实(判定逻辑的地基,别再重新考古)

- **2026-06-25 摇读修复**(a0fc280/d79f6d8/1de33de):连发黑洞根治(9/9 全中);**只对新采集生效,历史不回溯**。6/25 前旧数据的漏/黑洞按裁定不追。
- **input_source 自 2026-06-13 才有值**(keylayout=英文键盘/inputmethod=输入法);之前全 NULL。TIS API 必须主线程。
- **canvas(Google Docs 类)AX 原理性无用**:value 只有 ZWSP/`\xa0` 填充,内容 0 承载 → 必须击键/OCR。
- **AX 会缺页**:事件切分间隙漏记手打 commit(ev888);高频时 value-change 被 coalesce;**commit 流不是击键真值的完备投影**。keystroke_log(CGEventTap)独立于 AX,一个键不丢——但也有黑洞时段(B11 案 43min 只 33 键)。
- **用户打字行为**(上屏语义,击键机器的地基):拼音串+选字数字=上屏,退格删的是屏幕字非字母;空格=选1号候选(input_source 背书+真拼音+全小写三道闸才转);回车提交生拼音=双回车;**重度简拼**(`zhaod`=找到/`d`=的);shift+enter=换行;**数字键选字**(末尾单数字≈选字,literal_tail `≥2位` 别放宽,实测≥1 全误补)。
- **候选序 librime ≠ 苹果输入法 = 结构性天花板**(卖个惨/买个参,A10 长期✗):OCR 候选条覆盖 5~7%,拍到才纠,没拍到就算了(用户裁定)。
- 帧归属漂移 Swift 侧 d588339 已治(6/4 起);"内容只在异app帧"是正确标注非 bug,6级降级链兜。
- `browser_url` 又漏又过期(干净帧常 NULL),别当过滤条件;用 app+时间窗+内容锚。

## 现行机制清单(按层;动谁先读谁的注释)

**发送判定(rebuild.event_sends_with_ts)**:占位符/空框夹+回车背书;submit≥1(单字发送合法);send_clear(网页发送清空光杆 delete 豁免);回车背书升格(条件A裸回车150ms/条件B击键终态回车+选字数字≤2s;框清空否决=同element 60s value 拼音延续则不升);幻影发送降级(60s witness endValue 延续+未重打);L7 零回车草稿圈离;单字孤儿定义B(本事件无 commit/产出才算孤儿,标~residue 全留——用户终裁,**别再提撤回**);存量框剥离(非手打存量>30 才剥,小存量整条留)。

**三道闸(粘贴,零内容硬编码)**:闸A ⌘V 检测(paste_pressed,窗=上一同app事件末→本事件末+500,无限时长);闸B 巨块 commit(>30字含换行=粘贴伪装,injected_texts 判 inj,cstream 剔出背书流);闸C 逐行 30 闸(commit_backed):`_backed_mask` 两路背书取并集(commit 流连续块:ASCII≥3/含汉字≥2,双方去空格 ∪ 键流拼音空间:行文本转 char_units 最小读音对 `_key_letters` 字母流 ≥3 块,汉字整读音盖住才算),未背书≤30 留、>30 段级手术 `_cut_spans` 抠段,背书率<0.25 整行丢,多数背书守卫(背书率<0.25 才回落强背书行);≤120 字母下界豁免+包含性判据(ascii 词须真在组键流)。**组级上膛**:组内证据→整组过闸C,但证据打真实时间戳(paste/inj 条目 ts、⌘V 键时刻 paste_pressed_ts)**只向前传**(晚于事件结束的证据不上膛该事件),占位符轮换(Type / for commands 族)不算证据。开关 `PORTRAIT_PASTE_GATE`(默认开)、`PORTRAIT_PASTE_MAX`(默认30,前端旋钮)。

**重建(reconstruct)**:librime 确定性打底+14B disambig(TOP偏置+时间邻域ctx)+guard(新增汉字∈候选/英文字面保留)+逃生门(NONE→残渣给口3);unaligned/no_chinese_run/纯英文行=保守不动;`_is_eng_tail` 逐词判;double_return_literal 两路(双回车+keylayout);eng_literals 防过度解码;pick 解码(旧数据带选字数字的 run 恢复解码,"pick 后紧跟数字=数字串"守卫);literal_tail 只补≥2位数字尾。

**去重/折叠(faithful)**:dedup_truncated(截断态,等长条款限 5min 窗);同日去重真重发 vs 采集副本(`seen` dict+`_retyped` 击键下界 floor=首见 t1);渐进草稿折叠+中间态草稿折叠(`_py_prefix` 字母串前缀,简拼免疫);删除证据折叠(edit_log 单条 delete 原文有案);残渣拼音平铺去重(±10s 同bundle);**跨路由时间去重**(三条件缺一不可:窗口包含≥0.8/拼音空间覆盖≥0.6/最大单块占比≥0.7——连续性判真假重复;留分=(汉字数,长度,路由AX>keystroke>canvas),杀者进审计带"留谁");is_image_only(纯U+FFFC);is_mask(宽枚举+PUA≥4);KC_GATE 组级击键 gate(触发后逐条复检 cover≥0.5 或简拼字母下界)。

**口3(OCR 校对,闸C 之后运行)**:complete_tail/proofread_tail;`_whole_residue_ocr` 两守卫(base 前缀保护+整窗全验);verify_tail 词库全集反查;pick_frames 6级帧降级链+url 同站 LIKE;尾60对证;排序按 t1。⚠️它会捞屏幕文本进成品(145 Queens Quay 案,挂账)。

**OCR 锚定(OA.resolve)**:击键窗=单段完整消息+**记录单行**才锚(多行=内容超出本窗击键,锚定是整条替换会腰斩,机位案)。

**canvas 路**:承载率逐键判(±3s,GAP_KEYS=8 并回空档,modifiers&7=0,isprintable);A闸 `_ax_owned`(B 段落在同bundle 实质 end_value 事件内→归AX,头3s尾0容差,只对 B 桶);B 桶逐键 `.ime` 三态解码(衔接语义:切英文/回车=字面,字母+空格=上屏解码;英文键盘不送 librime;输入法吃的回车不断行;英文键盘数字是字面);ocr_correct_llm 三招(enable_thinking=False/证据窗收紧 span 末/few-shot);ax_verify(击键与 AX 文本拼音空间全对齐→AX 顶替);碎片闸→未定区;OCR-grounding 防凭空造字;英文前缀剥离 gate 到旧采集;C 桶 canvas_merge(essay 98%/99%:历史帧剔除 is_history_frame/终稿仲裁 trim=末25%非历史帧池+半窗容差/尾部终态化两步锚定/delete 行池派生四闸/timeline 从成品派生构造性自洽)。**canvas 成品绕过 AX 下游过滤,脏数据必须在 canvas 层清**;canvas 过 Pass4(用户裁定)。

**Pass4(固定逻辑,LLM 禁用)**:邮箱任何@形态丢(**先抠邮箱再看残余**;必须先确认真有 PII 再谈残余长度,否则"可以/继续"两字真消息被误杀);URL 整条 fullmatch 才丢(正文链接合法);掩码;`PORTRAIT_EMAIL_FILTER`/`PORTRAIT_PHONE_FILTER`/`PORTRAIT_SLASH_GATE`/`PORTRAIT_KC_GATE` 开关。

**击键时间字段**:每条 `⌨ start → end` = ks_span(窗口首击/末击,pad 前2s后300ms,同app钳位);canvas 由 canvas_spans 确定性回填。

## 版本史一行流(细节挖 git 旧版 HANDOFF)

- 06-10~14:审核agent A/B→**det 终裁**(llm 复查退役);v10 尾60对证/快照过组闸/L7;幻影发送+过期快照两修;上屏三修;残渣标记;v17 自家分组+窄账本 27✓;v18 存量剥离;v19 suffix_only/掩码闸;v20 URL整条/掩码PUA;v21 双return接入+REVIEW_MODE 查因(det/llm 路由差异)。
- 06-15~17:url同站+6级降级链+斜杠过滤;em 双路 eng_literals;hermes send_clear;\_whole_residue_ocr 补洞。
- 06-18~24:keystroke 主导架构(连发拆分)→ **sonnet 逐条核翻盘整套回滚**(gold 43✓是假象,82条中间态垃圾;教训=信噪比>gold,ax 路零漏是强基准)。
- 06-25~28:采集层摇读修复;承载率判别+四档路由定型;canvas_librime B 桶+ocr_correct_llm;游戏 skip。
- 06-29~07-07:渐进IME草稿折叠+框清空否决;口3 错字两守卫;单字孤儿判别+视觉核查(12孤儿全噪声,证明 AX 路不丢真消息);对抗审计三修(等长5min窗/\_retyped floor/口3 t1 排序)。
- 07-10~13:一体化重构(fusion 中间文件废除,一条命令);46天审核大跑;canvas_B 修复批(碎片闸/收敛/OCR-grounding);上屏语义三修(apply_bs/空格→1/英文键盘不解码);canvas 输入法语义五修(v4,PII 归零)。
- 07-15~18:粘贴违规 47 条→三道闸+六裁定+段级手术+组级上膛(v6→v12);击键时间字段+跨路由去重(v10/v11);v13 三修(拼音空间背书+上膛方向性,见下)。

## ⚰️ 死路清单(实证否决,别复活)

- **v5 重写实验**(revert 0add63d)/ **keystroke 主导混合架构**(2026-06-24 整套回滚:82 条中间态垃圾,连发拆分零正向价值;关联 commit 1e4a331…2bccdaa 已是死路)。
- **同音字仲裁**(f39ca42 revert:OCR 对齐漂移+时/什族误改)。
- **KC_GATE=0 改直接 paste 信号**:35 条大块真 paste 涌入(endValue 出口不过剥离,kc-gate 是唯一闸)。
- **isMark 注入扩展**:注入非清框信号,当 marker 造 6 个假发送。
- **canvas 拼接**:逐区域邻居否决(剪0)/CL delete 反杀(98→73)/更严判据 R1R2(98→63;**trim 判据必须与 eval/guard 同构**);完整性兜底五死路(贪心补采/滚动折叠/merge 自愈/终愈频次闸 cnt≥2 选反/同列邻居);句级去重(删的全是真窗);**14B 拿到删/滤权必伤真内容(三次实证)**;Stage2 拆 canvas_B 14B 收尾(确定性 OCR-verify 0/40)。
- **短 canvas OCR 矫正确定性算法**(9 次实证:选择删/鼠标删 keystroke 不记,最终态不可确定性重建→LLM 判别)。
- **literal_tail ≥1 位数字**(10 条全误补,选字数字);**A闸 edit_log 扩展**(误吞 3 正确救回+脱靶);**盲开空格→选字**(吞英文 which);**走 librime 子进程切音节**(吞英文+9min);**url 软加分**(脏帧反有 url)。
- **闸C 内容硬编码**(URL/路径正则+EDIT_COVER 放行,用户退回:严格 30 闸一切以击键为主)。

## 教训(方法论,刻进流程)

- **传感器证据 > 用户记忆**(4 次实证);**用户连纠两次,先查实根因别预设**(误判过"同音字""14B方差")。
- **gold 高 ≠ 成品干净**:新方案必须 sonnet/opus 逐条核对照;gold 探针测不出中间态垃圾涌入。
- **别只看"字数变少"判回归**(可能是用户自己删的);拿 AX end_value 当真值逐条核。
- 枚举字符类判掩码必漏(PUA);码点范围判语言必错 → 掩码=宽枚举+PUA 区间,语言=Unicode 属性。
- 多音字简拼让击键分不开字(天/大 tai)→ 退到来源或屏幕。
- **复刻管线诊断必须用真分组逻辑**(时间重叠也算链;ev635 长事件桥接漏掉害我误诊 B11)。
- 跑批:session 会被不定期 SIGKILL(高发 14B 加载)→ `launchctl submit` 钉 `/opt/homebrew/bin/python3`(**KeepAlive 会反复覆盖 md,收工必须 remove**)或 `nohup+disown`(无此问题,现用);后台 redirect 用绝对路径(cwd 漂移 EXIT=1);分块缓存可恢复。
- 并行 session 同仓库:`git commit -F msg -- <文件>` path-limited,绝不 `git add -A`;commit 前两次 git status。
- Edit 写中文注释防 `\u` 转义字面化。
- 自指污染:Obsidian 审核文档被采回,查证按原始日期+app 过滤;OCR 证据窗收紧排自指帧。

## 近期状态(v6→v13,活跃区)

### 粘贴治理(2026-07-15~17,完整报告在 Obsidian)

- v6 审核坐实 47 条粘贴违规(三条旁路:⌘V 在事件前/粘贴伪装 commit/endValue 兜底)→ 三道闸。
- v8 审核 13 条 → **用户四裁定**:①闸A 无限回扫 ②粘贴少数派整条留(**2026-07-17 已撤销**:「超30的很多啊,小于30倒是可以留」→ >30 无背书段即便跟手打正文也裁,段级手术;`paste_minor` 成 dead code)③6/25 前采集层误裁不追 ④旧数据(无 input_source)击键不送 librime(pick 数字=IME 铁证例外,恢复解码)。
- v9 44✓;遗留挂账:145 地址(口3 OCR 捞屏通道)/URL 蹭正文背书/@提及块/乱码2(qqqqqq/WASD)/AX 装配怪象(旧数据)/24h 日期归因差(06-10#105)。
- 击键时间字段+跨路由去重 → v10(缓存重排)/v11(GPU 干净全跑,**44✓ 上一完好成品**)。

### v12(2026-07-18,42✓/1🟡/2✗)→ v13 三修(aef83eb+8df10fa,全量在跑)

- v12 组级上膛+段级手术进重建层:Ubuntu 文档消失✓/ev598 阶段5+localhost✓,但 A20/B11 双✗。
- **v13 修**:①闸C 拼音空间背书(`_backed_mask` 两路并集,治 A20;⚠️简拼部分拼音路盖不住,靠 commit 流那路,别指望拼音路单独扛)②上膛证据只向前传 ③证据打真实时间戳+占位符不算证据(ev635 案:24min 长事件 started_at 远早于它的 ⌘V)。冒烟(05-28/06-05)A20✓/B11✓/拆分残0;**全量 44✓/1🟡/0✗ 验收通过**(Ubuntu 文档 0/localhost 0/VALIS 全文在/ElevenLabs 在)。
- **B11 定性反转(重要)**:「我没在env里面」全库击键流不存在、无 commit 无 ⌘V——5/28 采集黑洞/鼠标粘贴旧数据。它活着靠**不上膛**,不是背书救回;任何让它上膛的改动都会再杀它。

## 待做(优先级)

2. 遗留挂账(上面 v9 段)+ dead code 清理(`paste_minor`)。
3. 老待办(仍有效):H 类 race 尾巴挂前条进口3;R4 幻觉插入/R5 账本副本/A1 guard 拒自家 TOP(cands 6→10);ledger 解码带 ctx;字序仲裁/前条锚;组级gate→逐条判(部分已做);用户词库挖矿/消歧四元组;librime 常驻进程化(性能);canvas 记录粒度(span→按回车+停顿切,用户当时选"算了");#3 draft/send 幸存者倒置(2026-07-07 审计,未裁定);det 对证器 commit 前缀保护等 🟡 结构确认项。
4. 远期:四级漏斗完整化、canvas 本地化(用户做)、移植 Swift(必须用户批准)。

## 铁律/用户决策(违者必被退回)

- **只记手打**:commit(键盘)背书才记,粘贴一律不记;**宁缺毋错**(正确>残渣>丢>错字);残渣可见、错字不可见;不确定→口3/未定区(审核而非丢弃)。
- **粘贴政策**:单段≤30(PASTE_MAX 可调)且非纯粘贴→留;**>30 无背书段一律裁**(2026-07-17 收紧);闸C 零内容/形态硬编码,严格 30 闸,一切以击键为主。
- **REVIEW_MODE=det**(2026-06-14 裁定,代码默认已是 det,跑全量仍显式带);**PORTRAIT_OCR_ANCHOR=1** 全量必带。
- **每次动本机 GPU 前停下等用户明确指令**(逐次批准,无跨轮 standing;离线确定性脚本不受限)。
- bug 攒着修完一起跑一轮;发版只有用户明说才发。
- 零硬编码语言知识(ime_schema);不用 /tmp 放文件;~/.screenpipe 只读。
- commit 只 add 自己的文件(并行 session);AX 全本地;Pass4 LLM 禁用;切回帧窗=60s。
- A1 gold=「记得」;A10 卖个惨=结构性天花板挂账;单字孤儿全留;@提及不碰 OCR;搜索/地址栏碎片照记(数据清洗推迟,修 bug 走"找回丢失输入"非"过滤")。
- gold(44 项+P0)= 旧管线基准资产,改动必须重放;新架构(decode 关)不拿旧 gold 验(会假回归)。

## 怎么跑

```bash
cd Tests/writing-capture-extract   # cwd 必须在此(相对 import + eval/)
# 全量(v13 口径;后台 redirect 用绝对路径):
PORTRAIT_DAYS=all REVIEW_MODE=det PORTRAIT_OCR_ANCHOR=1 \
  PORTRAIT_OUT=/Users/joyzhang14/Desktop/Obsidian/生产接入前审核大跑-vNN-日期.md \
  /opt/homebrew/bin/python3 faithful_v2.py
python3 compare_gold.py <产出路径>    # gold 判分(离线,不受 GPU 限)
python3 ocr3.py                      # 口3 七案例回归
```

- 跑前:确认 GPU 空(`ps` 查别的 .py;别的 session 常跑 event-lab/MLX)+ 用户批准。
- watcher 模式:`nohup zsh <watcher>.sh & disown`(busy 检测排除 faithful_v2/watcher/.hermes/blender/uv/grep);**勿 launchctl submit**(KeepAlive 覆盖 md)。
- gold 复跑旧口径:`PORTRAIT_LIBRIME_DECODE=1 PORTRAIT_DAYS=<6天> PORTRAIT_CANVAS=eval/canvas_merged_src.json`。
- 重建层改动 → 清 `eval/v2cache/*.json` 再跑;写出层改动 → 缓存重排即可(不动 GPU)。
