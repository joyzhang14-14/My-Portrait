# 阶段0:AX IME 重建 — 尝试记录(别回头忘了)

> 目标:全本地 librime + MLX 重建 IME 尾巴(A–N 那批退步),不用 sonnet。
> harness 在 `/tmp/rime-test/eval/`:`rebuild.py`(核心)、`e2e_rebuild.py`(A–N 端到端)、
> `det_test.py`(确定性快测,不烧 MLX)、`test_rebuild.py`(确定性单元)、`dbg_think.py`(thinking 消歧验证)。
> librime 工具:`/tmp/rime-test/cands <拼音> <n>`(候选)、`/tmp/rime-test/lattice <拼音>`(TOP + 逐音节 SYL 集)。

## 试过的路 + 结果(按时间)

1. **纯模型自由组装**(模型看 captured+keystroke+candidates 自己拼整句)
   → ❌ 吐"你你天"(F)、A 只补到"点"。问题:模型自由逐字组装;guard 只查"字∈候选池",
   `你`/`天`分属不同候选→"你你天"被误放行。**教训:不能让模型自由组装,要确定性打底。**

2. **按序号对齐击键**(整组击键按 CR 切段,按 newExtract 消息序号一一配)
   → ❌ 对齐错乱,每条消息配到错误/空击键段,候选集空→模型没东西补,全原样返回。
   **教训:消息↔击键不能按序号对齐。**

3. **ts 时间窗对齐**(每条发送的 ts 窗 [prev_send_ts, this_send_ts] 取自己的击键)
   → ✅ 对齐对了(我今天早上5 配到 dian1shuide1)。但 `event_sends_with_ts` 当时用
   `cover>=0.4` 把**每个 IME 改写删除**(delete 'zao s' 换 '早上')都当发送 → 一堆噪声发送。

4. **真发送判据**(改用 withinSends 同款:占位符/空框夹 + 回车检测 sent())
   → ✅ 只剩真发送。但尾 pad=2000ms 太大,窗漏进下条(mai ge can 配到 ni1fa)→ 改**不对称 pad
   (头 2000 尾 300)**,发送击键到回车为止,修好。

5. **确定性打底 + run 级匹配**(lattice TOP 打底;run 级按「每音节∈该音节候选集」匹配已 commit 汉字,
   同音也算 commit 不重解;pos 没消费完 captured 汉字=对不齐→保守不动)
   → ✅ 不再搞坏 committed 文本(`单看模型…`/`他骂你你也不会和他继续了` 完整)。B/F 对;A=点水的(待消歧)。
   **教训:必须 run 级 + 候选集匹配(`单`∈`dan`候选),否则重解把好文本搞成`但看模型`。**

6. **多行按行重建**(captured 按 `\n` 切行,击键按 CR 切段,尾部 N 段配 N 行,逐行重建)
   → ✅ M 长文末行 yuegaoyueh→越高越好 对了(之前整条匹配对不齐→保守不动→没改)。

7. **残渣/击键调和**(captured 末尾拼音残渣 vs 击键 run)
   - 发现:F 的击键 `ninitian`(打错回删的噪声)→你你天;captured 残渣 `ni tian` 才干净。
   - 但 B 的 captured 残渣 `mei kan d` 是**截断的**,击键 `meikandong` 才完整。
   - → 规则:**captured 残渣是击键 run 前缀(captured 截断)就用击键;否则用 captured 残渣(去击键前导噪声);
     带上击键的选字数字判完整性**(M 的 `yuegaoyueh1` 的 `1`=已落定,免被判残缺)。
   → ✅ F✓ M✓ 阿拉伯语(a la bo yu→阿拉伯语)✓。

8. **MLX disambig 用约束 JSON**(每音节候选集内挑,字数=音节数硬校验)
   → ❌ 8b 挑"水的"不挑"睡的"、"买个参"不"卖个惨"。**约束 JSON 解码压制了推理,模型只会回声 TOP。**

9. **传当前句前缀做 context**(判睡/水靠"我今天早上5点__")
   → ❌ 约束模式下仍"水的"。直接 debug `dbg_disambig.py`:8b 约束输出对 shuide(给上下文)/maigecan
   都回 TOP。**确认不是 context 缺失,是约束解码的问题。**

10. **⭐ 放开约束 + 开 thinking**(`dbg_think.py`,enable_thinking=True,自由推理后抽"答案=XX")
    → ✅ **成功**:shuide 推理"睡得作时间不合→睡的";maigecan→"答案应该是卖个惨"。
    **结论:约束 JSON 压制推理;让消歧模型先 thinking 再抽答案(再验候选集),本地 8b 能正确消歧同音字。**

## 当前状态(2026-06-08)

- **确定性 floor 稳**:B(啥/没看懂)、F(逆天)、M(越高越好)、阿拉伯语、K(特点/不行类的 #0 正确)。
- **同音字**(A 睡的 / E 卖个惨):约束模式挑不对;**thinking 模式刚验证可行,待接回 decode_run 重跑 e2e。**
- **防幻觉住了**:J 的 gmail 没变"购买了"(英文判定 + residue_skip),保留 `g mai l`。
- **没解决**:H(特定的人)/I(Google的生态)= 截断尾巴没找到(击键窗里没尾巴,或 race 在发送后才打)——待查。
- **L**(hen bu x)=用户没打完的残缺拼音,类6 低优先,目标只是别幻觉。

## 关键架构(已定型)

```
每条真发送(event_sends_with_ts:withinSends判据+回车检测)
  → ts 时间窗取本条击键(头2000尾300 pad)
  → reconstruct_message:按行(\n/CR)对齐,逐行 _reconstruct_line:
       路①: captured 末尾拼音残渣 → 调和(残渣vs击键run)→ decode_run
       路②: captured 干净汉字、尾巴整段没进 → run级音节候选集匹配committed,尾巴 run → decode_run
  → decode_run: lattice TOP 打底;歧义→MLX thinking 在音节候选集内消歧(字数=音节数+∈集合 硬校验,否则回TOP)
  → guard: 模型新增汉字必须∈候选/原文,英文字面保留,否则回退(防幻觉)
```

## 下一步

1. 把 **thinking 消歧**接进 `decode_run`(替掉约束 JSON),重跑 e2e 验 A→睡的、E→卖个惨。
2. 查 H/I 截断尾巴为什么没找到(击键窗 vs 发送 ts 的 race)。
3. 全 A–N 过了再把 supersede/merge(类4/5a)、canvas(类5b)补上,然后才谈 Swift 移植(阶段2)。
