# 写作采集本地化 · 交接文档(2026-06-09/10)

> 给下一个 session(或 compact 后的自己)。**单一恢复入口**。配合
> `~/Desktop/Obsidian/修复对照报告.md`(两轮对照)+ `~/Desktop/写作采集/写作采集-问题总集.md`(标注真值)。

## 大局

- **生产 Swift 零改动** = 仍是老 pipeline(云端 haiku,`WritingCaptureWorker` unifiedExtract)。本目录全部是 Python 实验线。
- 实验线 = `faithful_v2.py`(用户当时的 14B 版,标 failed 后**逐点修复中**,用户决断方向)。
- 用户双目标:**最大保留用户最终输入** + **计算最大本地化**(AX 路全本地;canvas 云端,用户之后亲自做)。
- v5 重写实验已 revert(0add63d),别复活;教训在 memory `project_send_draft_discriminator`。

## 当前架构(faithful_v2 主链,全部已提交至 e65f402)

```
旧staged refs 取事件组(⚠️遗留依赖,移植Swift前要换成自家分组)
→ event_sends_with_ts(回车检测真发送;KNOWN_PH 占位符三层拦截)
→ rebuild.reconstruct_message:librime(项目内 rime/,词库gitignore)确定性打底
   + 14B disambig(TOP偏置+时间邻域上下文 ctx_window:条间gap>5min断,≤6条)
   + 逃生门(NONE→留残渣给口3)+ guard(新增汉字∈候选/英文字面保留/汉字数不减)
   + 字面残渣保护(大写/单字母不解码:6个G)+ #42英文补全(扫全部picks)
→ 组级击键gate / slash gate(⚠️仍整组丢,违背最大保留,待改逐条)
→ dedup_truncated / is_residue(汉字≤2才丢)/ is_ph / 去重
→ 击键账本恢复(铁律「有击键就记录」:<CR>段对账,未消费段纯击键重建;脏段守卫=选字后退格跳过)
→ Phase1.5 口3(全天就位后跑,有下文):
   · 残渣/击键账大额未消费 → complete_tail(OCR锚定+击键验证补尾)
   · 机器选字尾(PROOF留痕) → proofread_tail(OCR校对:睡得→睡的!的/得硬骨头已端)
   · 帧规则=同app+url,return后最早锚定命中帧(≤60s)+ 切回帧(用户灵感:60s内异app帧→切回首帧)+ 发送前一帧兜底,都无跳过
   · 护栏:消费≥残渣字母数 / 消费≥2×汉字数 / 汉尾不换ASCII / 不粘下一条记录前缀 / 不过换下一帧
→ Pass4 固定逻辑(LLM禁用,用户指令):只丢 .com结尾(含URL,用户接受)+ 连续≥6掩码符号
→ 文档:成品 + 🔧口3修正(原文→修后+via+ev+时间)+ 🗑️全闸口丢弃审计
```

## 关键文件

| 文件                    | 职责                                                                                                 |
| ----------------------- | ---------------------------------------------------------------------------------------------------- |
| `faithful_v2.py`        | 主链(脚本式,跑=全量4天:5/27,28,29,6/5)                                                               |
| `rebuild.py`            | librime重建+逃生门+guard+event_sends_with_ts                                                         |
| `ocr3.py`               | 口3:complete_tail/proofread_tail/pick_frames/verify_tail/keys_segment                                |
| `ime_schema.py`         | **零硬编码**方案层:单元表/输出字符集从部署rime词库提取(换五笔/双拼/日韩=换环境变量PORTRAIT_RIME_DIR) |
| `extract_compare_v2.py` | newExtract(=生产unifiedExtract移植)+is_ph;import时自跑对照(慢,正常)                                  |
| `rime/`                 | 项目内librime(cands/lattice源码入git;ice词库65M+136M gitignore,build.sh重编)                         |
| `eval/`                 | canvas_cloud.json等(gitignore)                                                                       |

## 已修(对照用户18处标注,第二轮:8全修+4部分+三回归清零)

✓ 6个G/84G、pipeline、yi x(=「一下测试」,用户确认原标注「一次」记忆有误)、te d→特点、
k n→看论文、挺不错的/说实话(账本找回)、H特定的人(原型✓)、XPC/赛博永生/Pass4误杀(回归清零)、
**睡得→睡的(校对模式,函数级验证✓,待全量验证)**

## ✅ 2026-06-10 审核agent里程碑(Phase1.75)
- 用户设计「审核而非丢弃」落地:referee(14B,零写权)+打回hint须OCR落地+击键逐字验证+未定区展示
- A/B 测试完成:**B(候选源门控)胜** 17✓ vs A 14✓;垃圾5/5拦、真货3/3入册、买个参→卖个惨(打回重修)
- 账本入册唯一通道=确定性渲染全文确证(referee对账本=循环论证,已退出);查重=拼音空间+时间窗±10s
- 留底:Pipeline成品-审核agent-{A直接删,B候选源门控}.md;报告:审核agent-AB测试与遗留问题报告.md
- ⚠️ B2留底含1已知回归(ikeyrent.聪明,代码已修0426bcd未重跑);未定区92条待降噪

## ✅ 2026-06-10 下午终裁:A胜出(账本废除默认off)/射程闸(librime修复才复查)/复查位确定性对证器与14B等价(det=llm零diff,REVIEW_MODE可切)→LLM复查退役;⚠️新雷=自指污染(Obsidian产出文档被采回)

## 待做(优先级)

1. **全量重跑验证校对模式**(本 session 已启动,看 /tmp/faithful_run4.log)→ 第三轮对照报告(对照修复标注版,产出按 `修复对照报告.md` 格式追加)
2. **H 类路由集成**:race 尾巴(CR后孤儿段)挂前一条记录进口3——原型能修,faithful 路由 gate 接不住
3. **第三轮审计结论(全部过对抗复核,修向见 修复对照报告.md 第三轮)**:
   - R4 ev607 幻觉插入「数据生成context」(14B双向语境回声;空行守卫须区分多行空行vs整空cap,简单堵会杀账本)
   - R5 「点水的」账本副本(消费判定改 同音近匹配+时间窗,AX路优先)
   - yo:app_switch 漂移帧被 app 过滤排除;窗须 [send-5s,send+10s] 双向 + 切回帧按时间窗多帧;且 endValue 类 t1=ended_at 晚于漂移帧
   - A1 记得:guard 连 librime 自家 TOP 都拒(独立bug);cands 6→10;is_send 残渣丢弃项接口3
   - H/ev1127 丢尾:末次commit后净字母 n≥4 检测,但须先判"已消费"(PROOF有mt→校对)再补尾,否则抢占校对分支(已实证回归)
   - ElevenLabs:已由粘贴新政收回✓(见铁律)
4. ledger 解码带 ctx_window(治「水的」无语境错字+重复)
5. I 字序仲裁(OCR提议字集,击键定顺序)/ 前一条消息锚(肯下来了/卖个惨,全残渣无base可锚)
6. 组级gate→逐条判;#40长消息中段重建(设计=完整击键+captured喂14B+guard,未建)
7. 5a 用户词库挖矿(custom_phrase audit-only;3561条免费对子已确认)/ 5b 攒消歧四元组
8. **性能:librime 常驻进程化**(现状每次调用拉新进程+加载138M词库≈1s/次;口3校对路由量大后成主要耗时,6/5单日口3阶段30min+)
9. 远期:口1击键对账门闩、四级漏斗完整化、canvas本地化(用户做)、移植Swift(必须用户批准)

## 铁律/用户决策(违者必被退回)

- **粘贴政策(2026-06-10 裁定,零LLM)**:消息内单段已知粘贴 ≤PASTE_MAX(30,rebuild.py 常量可调)且非纯粘贴 → 整条留;
  超限/纯粘贴 → 不留;无已知粘贴 → 原 cover 闸兜底。全量验证:只额外放行 3 条全真消息(ElevenLabs 收回)。
- **A1 gold=「记得」**(第4次传感器胜记忆;标注版已更正)。修复待办:ev522 残渣"ji d"丢弃项接口3 找回。

- 只记手打(粘贴只滤片段不整组删);宁缺毋错(保留正确>残渣>丢>错字);残渣可见、错字不可见
- 不确定→drop给口3(口3=Pass4前correction,同一漏斗;有下文=ultra准确)
- 零硬编码语言知识(ime_schema);不用/tmp放文件;commit只add自己的文件(并行session);
- AX全本地;Pass4 LLM禁用(8B乱咬实锤);.com副作用用户接受;切回帧窗=60s(拍照逻辑:typing_pause=500ms)
- 传感器证据 > 用户记忆(可以试试=草稿、一次→一下,两次实证)

## 怎么跑

```bash
cd Tests/writing-capture-extract
python3 faithful_v2.py          # 全量4天(14B Phase1≈30-60min,Pass4秒级),写 Obsidian/Pipeline成品-新pipeline-阶段0.md
python3 ocr3.py                 # 口3七案例回归(H/I/yi x/te d/yo/k n/卖个惨)
```

对照检查:用 `输出成品-改前的pipeline-修复标注版.md` 的标注逐条 grep 成品段(注意排除审计段引用的旧文本,只查 `### 🆕` 段)。
