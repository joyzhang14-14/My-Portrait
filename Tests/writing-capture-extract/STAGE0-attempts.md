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

11. **thinking 接进 pipeline**(decode_run 调 thinking model_fn,max_tokens=700,抽"答案=XX")
    → ❌ 仍"水的"。thinking 推理太长,700 token 没推到"答案="行就被截,抽取失败→回退 TOP。**thinking 不可控**。

12. **词级选择题**(`dbg_mc.py`,非 thinking,把 `cands(py)` 词级候选当选择题让模型选)
    → ❌ 不稳:`shuide→睡得`(睡对、的/得错)、`maigecan→麦格`(cands 里压根没"卖个惨")、
    **`buxing→不幸`(把本来对的 TOP「不行」改成错的「不幸」!)**。

13. **富上下文 + 自由 pick**(`dbg_rich.py`,8b,喂 app/url/周围真实对话/当前句前文/librime 词级+音节候选)
    → 🟡 shuide→睡的 **对了**(作息对话帮上忙);但 fashao→**发梢**、buxing→**不幸**(把本来对的 TOP 搞错)。
    自由 pick 仍是净负面。

14. **富上下文 + TOP 默认偏置**(`dbg_topbias.py`,8b,"默认上屏=X,合理就保留,只在明显选错才换")
    → 🟡 反过来太保守:buxing/fashao/特点 **保住了**✓,但 shuide 也不纠了(水的✗)。**8b 卡在中间穿不过**。

15. **⭐ 14b + TOP 偏置 + 富上下文**(`dbg_14b.py`,词级候选)
    → ✅ **两头都对得多**:buxing→不行✓、fashao→发烧✓、特点✓(没把对的搞错),shuide→**睡得**
    (认出"水的"错了→睡,就 的/得 小瑕疵)。maigecan→买个(rime 词库无"卖个惨"这个 slang,候选里压根没有,无解)。
    **8b 是瓶颈;14b 能穿过 keep-vs-override。**

16. **14b 音节级**(`dbg_14syl.py`,逐音节候选让模型拼)
    → ❌ 更糟:睡了/买个餐/不醒/发少(逐音节框架让模型乱拼)。**音节级是错框架,词级+TOP偏置才对。**

### ⚠️ 同音消歧结论(重要,已更新)
正确框架 = **词级 cands 候选 + TOP 默认偏置 + 富上下文(app/url/周围对话/当前句前文)**,不是音节级。
- **8b 穿不过** keep-vs-override:自由 pick 把对的 TOP 搞错(发烧→发梢);偏 TOP 又漏掉该改的(睡的没纠)。
- **14b 能穿过**:对的 TOP 保住(不行/发烧/特点),错的 TOP 认出来纠(水的→睡)。残留小瑕疵:的/得 助词、
  rime 词库没有的 slang(卖个惨)。
- → **disambig 该上 14b(仍全本地)**;或退而求其次 TOP-only(8b 时代的安全 floor)。

### (历史)8b 早期结论
**本地 8b 对「需上下文的同音字消歧」不可靠**:约束 JSON=回声 TOP;thinking=推理对但太长/不可控;
选择题=乱选,**还会把本来对的 TOP 改错**(不行→不幸 = 净负面)。
→ **确定性 lattice TOP 反而是最稳的 floor**:不行/越高越好/逆天/特点/啥/没看懂/发烧/阿拉伯语 全对;
只有真·上下文同音(睡的 vs 水的、卖个惨 vs 买个参)TOP 会错,但**消息至少完整**(我今天早上5点水的,人能读懂)。
**待用户拍板**:① TOP-only(快/稳/~80%字准,同音停 TOP)② 云端只做同音消歧(破"全本地")
③ 更大本地模型(14b/32b)试消歧 ④ 继续磨 8b prompt。

### disambig 最终落点(2026-06-08,用户先跳过细节)
- **架构定了**:librime 给词级候选选项 + **14b 按上下文从候选里挑**(TOP 默认偏置:默认信 librime TOP,
  只在明显语义矛盾时换)。**不靠选字数字**(我的 librime 排序 ≠ 用户的苹果输入法 SCIM.ITABC,数字对不上)。
  **不走实时截候选窗**(用户否决:① 易截到别的字 ② 按数字时候选条已消失)。
- **14b 把"意义"救对了**:水的→睡、逆天、不行、发烧、特点 都对。E 的"你发烧"靠确定性(guard 改按汉字数)修好。
- **两个硬骨头,用户先跳过、回头再想**:
  ① **的/得**:睡**得** vs 睡**的**(都在候选,14b 反复挑睡得,语义对、助词错)。候选 hack=句尾 V+的/得 后规则。
  ② **卖个惨**:librime 词库没这 slang(候选无),LLM 选不出不存在的 → 无解。候选 hack=自定义小词典。
- 词级自由选(不偏 TOP)会把对的搞错(fashao→发啥),**必须 TOP 偏置**。
- guard 关键修复:防删字按**汉字数**比,不是字符长度(否则拼音→汉字变短被误回退,你fa shao→你发烧 之前被卡)。

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
