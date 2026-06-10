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

## 待做(优先级)

1. **全量重跑验证校对模式**(本 session 已启动,看 /tmp/faithful_run4.log)→ 第三轮对照报告(对照修复标注版,产出按 `修复对照报告.md` 格式追加)
2. **H 类路由集成**:race 尾巴(CR后孤儿段)挂前一条记录进口3——原型能修,faithful 路由 gate 接不住
3. **原记录消失之谜**:几点/记得(5/27#14)、5点睡的原 AX 记录、ElevenLabs 账本未恢复——查丢弃审计段定位环节
4. ledger 解码带 ctx_window(治「水的」无语境错字+重复)
5. I 字序仲裁(OCR提议字集,击键定顺序)/ 前一条消息锚(肯下来了/卖个惨,全残渣无base可锚)
6. 组级gate→逐条判;#40长消息中段重建(设计=完整击键+captured喂14B+guard,未建)
7. 5a 用户词库挖矿(custom_phrase audit-only;3561条免费对子已确认)/ 5b 攒消歧四元组
8. 远期:口1击键对账门闩、四级漏斗完整化、canvas本地化(用户做)、移植Swift(必须用户批准)

## 铁律/用户决策(违者必被退回)

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
