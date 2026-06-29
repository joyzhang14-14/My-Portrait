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

## ✅ 2026-06-10 晚增量(v8-v10,接终裁之后)

- **v8**(归档):三小修=det consumed阈值max(2,汉字)/路①击键终态优先(今天mei li→今天没来)/prev锚3→2字(基地→记得);17✓
- **v9**(归档):双守卫=路②无汉字行不做中文补尾(v5-8英文垃圾尾回归,根因=修guard放宽暴露对齐真空;
  结尾标点决定走路①或路②纯属运气)+R4多行空行守卫(数据生成context正式关账);14B调用53→30;18✓1🟡5✗
- **v10**(归档,**当前最佳 20✓ 0🟡 4✗**),三改动全量验证通过:
  ① **a81f501 尾60对证**(用户裁定:长文尾恒可见/头被窗吞/错全在尾;头60=查不会错的放过会错的)+归一对称补齐
  →红利:v9两条未定区误报找回成品(ev516你大概能…/ev1148可以改一下OCR逻辑,OCR证据本含原文,v9标点不对称误判矛盾)
  ② **4dd6c42 发送清空快照过组级闸**(#40,用户裁定"直接拿快照当成品"):快照通道本就存在,cover手打闸只看单事件
  commit流→跨事件长文被杀(Blueprint快照对ev633自家流0.35,对组级流0.66);A6翻绿(222字全文含'就叫Blueprint'中段插入);
  ev1148/1154整条找回;ev1146用户自删的'比如说在一个虚拟机'残尾不再混入(更忠实)
  ③ **3ac32d8 L7零回车草稿圈离**:A18苹果某些→未定区✓;拦截面=8条全为真零回车草稿(writing placement/google doc/
  irvine/beatoven/v1.1.0/cleanup boddy/jeff chang是谁/苹果某些);看你怎么哟(yo案真发送但CR竞速丢)也进未定区——
  错字退出成品,按宁缺毋错排序是改善
  - 剩余4✗:A12特定的人/A13Google字序/A16a挺不错的(账本废除已接受代价)/A17yo(存量伪影,见下,不再修)
- **L5/yo 关账(用户裁定:修过就跳过)**:帧归属漂移**源头已治本**=Swift侧 d588339(6/4 00:12,入库前
  NSWorkspace实时校正app归属),新帧不再漂;yo真相帧(6/4 22:31,发送前1.4s,IME预编辑渲染'看你怎么用',
  归属漂成My Portrait)在库里已记错且不回溯——当晚app大概率没重build(击键流证明截图瞬间Discord在前台)。
  5/27-29帧全部早于修复。**读端漂移帧窗不加**;A17=存量数据伪影非pipeline缺陷,本数据集逻辑满分=20✓+A12/A13/A16a。
  若想eval翻21✓:pick_frames加[send-5s,send+10s]无视app窗(排切回帧后/兜底帧前),对新数据无副作用,3行
- 用户裁定:「我的」(ev1131)=真发送保留(可能发错但确实发了);「苹果某些」(ev1137)=零回车草稿快照,librime把mouxie→某些
- 自指污染实锤扩大:Obsidian审文档的事件(ev2161/2253等)会干扰DB查证,查原始证据须按原始日期+app过滤
- screen_audit.py=离线OCR对证工具(不重跑LLM直接撞):88条短消息=67一致/19无证言/2矛盾(零误报)
- 混合行(今天天气非常good)实测安全:守卫只对整行零汉字生效;英文/拼音边界5层防护+det兜底

## ✅ 2026-06-11 幻影发送+过期快照(用户标注两案,v11 已验证 **21✓ 0🟡 4✗,当前最佳**)

- 用户证实机制:AI窗口点发送后可点暂停继续改 → 框不清空 = 幻影发送的现实来源,证人测试天然覆盖
- v11 全量验证:B1/B2 翻✓,v10 全部 21 项保住零回归;成品 135→132(三条过期态归并,全可追溯于丢弃审计);
  writingample 2 从未定区改进为 dedup 归并(拼写正确的等长快照胜出);剩余4✗=A12/A13/A16a/A17(存量伪影)不变

- **案1 vos/vcd组(5/28)**:ev616 **假submit**(AX发submit但框没清;"submit绝对可信"假设被实证推翻),
  过期vos中间态当真发送;ev617(vos+md)/ev618(vcd+md终稿)等长,dedup"必须更长"卡死全留→成品三胞胎
- **案2 关SIP(6/5)**:ev1148 假delete快照(AX重渲染value换占位符)+IME确认回车凑巧→'关SIP…jiu s s'
  假发送;真身ev1150 endValue原样延续(edit_log首笔'。',前缀未重打=框从没清过);真发送无目击
- **修1(3589989)幻影发送降级**:同bundle 60s内后续事件endValue原样延续发送文本为前缀+其commit流
  未重打(cover<0.5)→降级草稿。submit不豁免;前缀<10字不动;同事件endv相等判禁用(会误杀真发送)。
  全4天扫:恰好降级2条目标,116条真发送零误伤
- **修2(21b71d2)dedup等长条款**:草稿对草稿,等长+cover≥0.9+时序靠后者胜。增量扫:仅多丢2条过期态
  (vos快照/writingample 2漏S快照),真身均存活
- 两案模拟:各归并成唯一真终稿✓;gold新增B1/B2(8b74d65),v10产出上双🟡待v11翻绿

## ✅ 2026-06-11 下午三修(v12 已验证 **22✓ 0🟡 3✗,当前最佳**)

- **回车背书升格(3c84fd9)**:jeff chang案(用户证实网页Gemini真发送)——回车落在事件关闭后150ms,
  endValue路径is_send写死False被L7误圈。升格条件=≤20字+事件收尾紧跟裸回车(晚于末笔编辑150ms;
  IME确认回车伴随commit天然排除;yo竞速回车在末笔前天然不升)。只收窄L7射程(长文升格会让
  过期中间态以真发送入册,ev1152/1153实测)。9条升格全合法
- **行段对齐弃漏键残段+末位失配扫picks(722ef81)**:挺不错的案(ev1132,有选字1+回车的真发送)——
  keys_in_window尾pad漏进下条前导键'shuo'(无CR残段)→"尾部N段配N行"对齐被抢位→真run整段丢→
  解码放弃→残渣闸误丢。**A16a翻绿**。副产物:未定区yo案文本已解成正确的'看你怎么用'(仍因零回车+
  无帧圈离);yi x案重建中间态变'一些'但口3校对兜回'一下测'(A7✓)
- **残渣~residue标记入册(dba3841)**:用户裁定ok/okay/oki类语气词不清除——is_residue从丢弃闸改src标记
  (占位符/去重闸保留);顺带清旧账L1=残渣保留自动进口3有OCR找回机会
- 剩余3✗:A12特定的人(下一个可修项)/A13Google字序/A17yo(存量伪影已关账,正确文本已在未定区)

## ✅ 2026-06-11 晚两修(v13 已验证 **22✓ 0🟡 3✗,当前最佳**;对v12 diff仅两案零波及)

- **syl_cands词库全集反查(6f7cd14)**:用户标注'一下测'应为'一下测试'——OCR渲染/击键都完整,
  断在verify_tail的syl_cands用lattice候选窗(shi仅前6字),'试'在窗外最后一字断链(与A1记得案同族)。
  修=char_units反转全集(shi=374字);A/B回归口3七案例唯一diff=本案,screen_audit 90条0矛盾
- **残渣副本拼音平铺去重(abb916d)**:'jeff chang shi shei'(ev1173,IME未上屏AX泄漏)与
  'jeff chang 是谁?'(ev1174真身)双入册——残渣改标记后文本不等去重闸拦不住。
  修=~residue(字母≥4)与±10s同bundle邻条拼音平铺等值(多音字词库回溯)→真身胜;
  单测7绿:全拼才判重(半截tingbucuod不误删)/shei≠shui/ok不在射程

## ✅ 2026-06-11 深夜两修(v14 已验证 **23✓ 0🟡 2✗,当前最佳**;剩 A12/A13 两真遗留)

- **中间态草稿折叠(b9e5864)**:hen bu x案(ev1143)——'那个输入法我hen bu x'是用户删行重写的弃稿,
  弃行把cover拉到0.8之下漏过dedup。修=~draft与同bundle 15min内后续真发送共享长前缀
  (≥max(10,草稿norm一半))→中间快照折叠进审计。与vos/vcd(等长改字)/ev1153(删9字)同族第三形态
- **条件B击键升格(5730168)**:yo案(ev1133)用户证实真发送——击键铁证yong1+l1+回车@02.441,
  AX的'y' commit迟到4.4s把ended_at拖后,条件A(锚AX时间)全扑空(**第三次被AX时间坑,击键时间轴才可信**)。
  条件B=事件击键span内最后一个回车是终态(其后无键)+紧邻其前是选字数字(数字已清空组合区,
  不可能是IME确认)→真发送。**A17看你怎么用翻绿**(成品缺'了':l1的run在AX残渣yo射程外,口3续接课题)
- v14扫尾观察:ev1153/1154 rebuild后文本收敛一致,去重收掉后到的sent条,成品单条无重复
  (标记仍~draft,真发送被去重——纯标记瑕疵);条件B另11条升格均为已在册真发送的重复快照,零影响

## ⏳ 2026-06-12 待验证批次(**v15 未跑,等用户指令**——event-local-lab 在占 GPU)

- 已提交未全量验证(离线全绿):续接run≥2字母+引号补全(3fc7454)/简拼下界闸+短base前条锚
  =A12特定的人+我的意思(857bbaa)/干净文本补尾只认return后帧(1adef07)/gold更新=A13翻案
  (截图+击键证实'生态的'实发,第三次传感器胜记忆)+B3闭引号+B4我的意思(857bbaa)
- **v15 预期 27 项 gold 全绿满分**(A12 是最后一个✗,已离线修通)
- 单字母续接裁定:不靠librime猜(cands('l')=来里老啦了,live输入法首位是了,候选序分歧),
  走口3校对=OCR渲染当解码器+击键仲裁,只认return后帧,没有就算了。
  ev1133实测return后帧已滚走→保持'看你怎么用'('了'按裁定放弃)
- **悬决**:之类的(零AX痕迹纯击键消息,4帧OCR确证)开不开窄账本(干净段+选字+终态CR+
  渲染确证,B2通道现成)——用户未裁定
- '我的'路②unaligned 根因记录:选字后BS按token弹(1BS=1字地雷,IMEStateMachine未接线),绕道口3不碰

## ✅ 2026-06-12 v15-v17(**v17 = 27✓ 0🟡 0✗ gold 满分,当前最佳**)

- **v15 作废**:staged 表跑批中途被外部清空(5/27/28 处理时还在→5/29 时全表归零;底层
  typing_events/keystroke_log/frames 完好;清表者不明,生产侧若仍依赖 staged 值得查)
- **自家分组(84c8634)**:同 bundle+10min 时间链连桶,UTC 切日同口径——staged 遗留依赖了断
  (移植 Swift 前必做项被迫提前)。桶只服务组级 gate/slash gate/组级 commit 流,容错高。
  副作用:staged 从没引用过的事件域(Obsidian 笔记等)涌入,14B 调用 30→402,跑批 40-60min
- **窄账本(84c8634,LEDGER_MODE=narrow 默认)**:双回车包夹+选字+无脏退格+秒发≤10s;
  入册唯一通道=渲染确证;副本/未确证进丢弃审计不刷未定区。离线扫:候选129/已消费55/
  入册27/拦47(基地/狗的/zillow.com胡话全拦,零漏);真实管线入册6(Phase1.75拼音查重再收21)
- **v16 两回归同批修(58db49e)**:①XPC 整桶连坐→组级 gate 逐条复检(≤20字或 cover≥0.5 留),
  老待办'组级gate→逐条判'了断;②关SIP 贴'米'→干净文本补尾下限(尾≥2字+消费≥4,
  residue=0 时原消费护栏恒过的真空补死)
- **v17 满分明细**:A12特定的人✓(简拼下界闸)/A13翻案✓/B3闭引号✓/B4我的意思✓(前条锚);
  账本入册6=之类的/还可以(真增益)+增加pass/给pass/让pass/就是pass(**Notes笔记碎片,
  真手打但半截——Notes长会话消费判定±3s窗失配,待用户裁定**);未定区19(新事件域贡献)

## ✅ 2026-06-12 v18(**27✓ 满分保持,纯 raw data 全链路,当前最佳**)

- 用户四指正全落地:①**存量框 submit 剥离**(d18f6d8+b97e464):submit全文=存量大文本+手打增量,
  cover<0.5/≥0.4 分野只记增量;框清空证人防假submit误剥(ev616);剥离命中清同事件竞速渣
  ('这'/'事态你帮我改变'/'go'残骸=zh/shi/go假delete候选及其错字重建,全消)。
  作文需求5条找回(这样可以吗你觉得/时态你帮我改吧/这样可以吗?你觉得?/够了吧/+5条同病老案)
  ②掩码/.com/邮箱未定区与审计不展示(8cdfb42:Pass4审计只留理由行,joyzhang_14@163.com实锤
  泄漏封堵;掩码阈值≥3) ③>120字大块静默 ④账本质量门汉字≥3(入册只剩之类的/还可以)
- A类四条(像不像ai写的等)= **采集层断档**(5/26晚一小时仅2事件,击键423键完整,6/4修复前老app),
  实验线无米下锅;击键流在,窄账本天然救回部分
- ⚠️ 残留呈现小账:'传然后给pass'(口3产物)/'w'类单字草稿仍在未定区——降噪课题未了

## ✅ 2026-06-12 v19(**36✓ 0🟡 0✗,gold 扩到 36 项,当前最佳**)

- 用户 v18 六指认全修(1972cac+7e05ad0):①Writ=OCR占位符'Write a message…'前缀+击键中段
  writign冒领 → **suffix_only治本**(竞速尾键必在账尾,中英文占位符通治,用户质询'中文占位符
  怎么办'催生;纯ASCII拒降为第二防线) ②localhost:5173→URL扩(://、localhost:、TLD路径形)
  ③●●●●●●→数据层掩码闸(≥4纯掩码,loginwindow密码框) ④header案=IME整句上屏被AX记成paste,
  commit流只剩6字被复检冤杀 → gate逐条复检加击键fallback(简拼下界闸) ⑤邮箱任何@形态Pass4
  直接扔(zzhang@…k12.nc.us;@him/@他/@joyzhang14 实测不误伤——正则要求@两侧紧贴+域名.后缀形)
  ⑥Sin=真输入后8分钟被大改写删除/微信@=用户自删未发(BS×31无回车),两案查证无修
- **gold 扩到 36 项(60adfb6+0b44cf6)**:B5a-d作文需求/B6 Writ/B7 header/B8窄账本质量(独立行
  口径,'给pass3传入…'真消息子串误报已修)/B9竞速渣/P0全文档隐私零泄漏(不只成品段);
  试刀v18=33✓1🟡2✗精确命中已知问题,标准有牙

## ✅ 2026-06-12 v20(**38✓ 0🟡 0✗,gold 扩到 38 项,当前最佳**)

- 用户 v19 三指认全修:①ev563'去重但不在产出'=URL_PAT.search('://')连坐正文含github链接的
  302字真消息 → **URL整条匹配**(fullmatch才丢,正文链接合法;417e5aa) ②VALIS_BEATOVEN_API_KEY
  被剥离腰斩 → 剥离改**非手打存量口径**(len×(1-cover组流)>30才剥;本案27≤30整条留,作文案292剥)
  ③loginwindow密码圆点仍显示=PUA U+F79A 骗过枚举字符类 → 先一刀切('无字母汉字')又被用户
  纠偏((> -)颜文字误杀+假名/谚文/阿拉伯文不能当符号)→ **is_mask=宽枚举掩码集+PUA范围**
  (ecb5fd0),单测11绿(多语言/颜文字全保留)
- gold 38 项:B10含链接真消息/B11 VALIS全文唯一/P0掩码残留通用检查+URL类ban行级
  (正文链接合法 ev1158实证);v18对照仍抓4类泄漏,没放水
- ⚠️教训沉淀:**枚举字符类判掩码必漏(PUA),码点范围判语言必错(日韩阿俄)**——
  掩码=宽枚举+PUA区间,语言=Unicode属性(isalpha),展示/数据/gold三层同口径

## 🚧 2026-06-12 canvas 本地化开工(v1=81%覆盖/64%精确,零模型,0ae2afa)

- 测试样本=5/28 writingSample2(Google Docs,640帧/中位10s/击键5520);真值=用户终稿docx
  → eval/canvas_gold.txt(**程序化对照,不展示内容**——用户指令);canvas_eval.py 自动验证
- **架构(与AX路相反)**:OCR帧为骨(全帧联合覆盖90%),击键退为辅(线性重放仅34%——长文
  写作大量鼠标跳改);canvas_local.py 十轮迭代笔记详见 commit 0ae2afa
- 核心招:行级击键背书(列投票败于自指污染:Terminal里Claude会话引用essay原文)/x间隙切段/
  两遍法x锚/双簇拆分/弹窗中文剥离/击键词典纠错(频次仲裁,距离1优先曾反向作案leaned)/
  邻居否决delete/低票淘汰/版本组检测(Jaccard≥0.45近邻12,旧版进delete=diff feature增强)
- **diff timeline 保留**(用户硬需求):104 commit + 17 delete
- 剩余19%缺口:x锚误伤(标题/居中行)+OCR未拍段+错字窗;精确率36%缺口=交错残余+旧版漏网
- **⚡反转(用户'太长滚出屏幕'质疑触发重测)**:统一归一口径下 gold 每窗都被某帧拍到过
  (10s/帧足够密)——物理丢失=0,**确定性天花板是100%**;18窗缺口全是管线自丢(可逐窗验尸);
  击键重放只能补2窗(联合83%)→内容获取不需要击键,VLM 可能也不需要
- 下一步候选:①commit时间线用击键时序精化 ②x锚多列支持(标题列)③VLM兜底(正文框,
  Qwen3-VL-8B 4bit≈5GB,mlx-vlm现成)——确定性到瓶颈再上
- **LLM行级仲裁实验(0f3db1e,CANVAS_LLM开关默认关)**:用户裁定窗口位置不定+中文canvas需LLM清洗
  →14B只判行Y/N零写权;实测79%/51%**不如纯确定性81%/64%**——模糊带判别信息本质是空间的
  (行在哪个窗口),纯文本LLM看GitHub简介vs essay无从区分。两修:prompt标题/作者条款+解析bug
  (模型输出'1. Y'点号vs正则冒号;raw字符串\\s双反斜杠)。**下一步=喂空间上下文(x/y/邻行结构化)
  或VLM圈正文框(用户最初直觉)**;14B判断质量本身可以(单批测试:标题Y/作者Y/GitHub N/正文Y全对)
- **VLM圈框实验(2026-06-12,用户授权)**:技术栈全通=mlx-vlm 0.4.4+torch/torchvision
  (--break-system-packages 补装)+Qwen2.5-VL-7B-Instruct-4bit(已缓存~4.5GB)+抽帧链
  (video_chunks.file_path 相对~/.portrait,ffmpeg -ss offset_ms/1000 抽帧,eval/vlm_test_frame.jpg)。
  **但 7B-4bit 圈框质量不合格**:多窗复杂截图上,问法一=整屏当文档区([0,0,1511,980]);
  问法二(原生grounding语态)=占位符胡说((10,10,100,100))。
  **下一步候选**:①升级 Qwen3-VL 系(grounding 强,需升 mlx_vlm)②退而求其次:VLM 不出 bbox,
  改判"屏幕左/中/右哪一块是文档"(粗分区,容错高)③结构化空间上下文喂14B文本模型(x/y/邻行,零新模型)。
  **倾向③**:省内存(14B已驻留)+判断质量已验证,只缺空间信息——把坐标给它就是了
- **大prompt拆解落地(431d20d,用户指令)**:生产云端canvas=sonnet大杂烩prompt(判正文+diff+拼接,
  conf0.8硬编码,Explore agent摸底:WritingCapturePrompts.swift:577-620/CanvasAgent.swift)。
  拆解=去噪/diff时间线/拼接三件归确定性(且diff可审计),唯一真模型任务=**T1正文行判别**
  (weak行带坐标,prompt给同帧strong行坐标做空间参照,14B判Y/N零写权)。
  本数据集79%/54%不及纯确定性81%/64%(x锚本就有效)——**T1真正战场=x锚失效场景**
  (中文canvas/窗口移动过),CANVAS_LLM=1可开,待用户供中文canvas样本验证。
  工程坑三连:?标记撞OCR真问号(→\x01)/负坐标正则/replace转义层级无assert骗过
- **目标线量化+v2拼接路线(6872430)**:库中canvas_fusion同尺=**95%/98%**(用户:81%不够,
  haiku没强多少,要同等效果)。拆解升级:确定性去噪快照→14B窄拼接→幻觉guard(逐窗∈快照全集,
  > 10%拒轮,两版稳定生效)。v2a全文复述=83%/67%(膨胀3倍+3500token截断);v2b增量=56%/45%
  > (重叠即NONE漏报+时间序append打断文档序)。**下步=层级归并**:24张快照分4组,组内6张
  > 一次性给14B拼(输入6k出≤2k),4块再拼一次——每层输出有界无滚雪球,v2a形态+无截断。
  > canvas_merge.py 可改;diff时间线仍由canvas_local确定性产出(不受拼接路线影响)
- **v2c层级归并定格(7a84e4d,用户目标=100% haiku水平95/98)**:24快照分4组拼→顶层拼,
  5次14B调用幻觉guard零拒=**82%/80%平台**(±3点LLM输出方差);v2d三变量齐动倒退的教训
  =精炼pass删真内容。**95%路线图(质的一步,按序试)**:①学haiku少预过滤——去噪闸只滤
  chrome,把chrome词表交给14B拼接prompt自己滤(haiku的输入就是带噪的,我们0.5背书闸
  把标题/局部行滤掉了=覆盖缺口主因) ②温度锁0+三跑窗口多数投票(治方差)
  ③快照取同视口多帧投票版(行池的纠错红利,拼接路线丢了) ④顶层重叠:输出后确定性
  连续重复段检测(代码去重,不靠LLM精炼——v2d实证LLM精炼会删真内容)
- **平台结论(8785d53,8变体实测)**:v2c形态=82±3/80±3,微调(滤噪权/精炼/少过滤/频次闸/
  帧级锚)全在平台内摆;铁律再证:**14B拿到删/滤权必伤真内容**(三次实证)。帧级x锚版保留
  (窗口移动自适应,泛化优)。**98%假说=下轮第一刀**:haiku的98%含隐性纠错(重写时自然修
  OCR错字,发明但发明对了),我们零幻觉guard关死此门;释放=guard窗口判定加编辑距离容差
  (窗∉快照但与某快照窗ed≤2=OCR错字修复放行,大幻觉仍拦)——铁律精确化非放弃。
  eval一并升级:24字窗对错字零容忍,同样加ed容差口径才公平对比

- **半窗容差落地(4e84c9d)**:guard+eval 同口径,24字窗任一半12字∈快照/gold=OCR错字修复放行,
  两半皆无=真幻觉拒(ed≤2 方案改为更便宜的半窗,效果同向)。新口径:**库中=96%/100%,
  本地 v2e=95%/88%——覆盖率追平 haiku(1窗差)**,剩精确缺口12点
- **句级去重离线验证失败**:5623→3431字但精确 88→80,删的全是重复真窗;23个坏窗是独特噪声
  非重复——下刀方向=坏窗定位清除,不是去重(路线图④作废)
- **坏窗验尸反转(canvas_autopsy.py,纯离线)**:23坏窗全部 strong 行(背书0.67-1.00,
  freq高达47,x在锚上)——**不是外部噪声,是 essay 自己的旧版残留**(被用户重写掉的旧段落,
  新旧两版全进产出,部分×3重复=膨胀主因)。去噪闸/guard 都拦不了(真手打+真在快照)。
  病根=拼接 prompt"重叠选更通顺的版本":通顺≠最新。**v2f=选版标准改"时间靠后片段胜,
  旧版整段丢"+同句只出一次**(铁律安全区内:选版是14B合法权限)。
  v2f 实测:膨胀治了(5623→3383)但坏窗只清3个(20/110=82%)——14B 在 6k 字块间认不出新旧版
- **🎯 v2g 破案+达标(2026-06-12 深夜):98%/99%,反超库中 haiku(96%/100%)**。
  终读窗诊断推翻"旧版被重写后消失"假设(最后10min帧里旧版指纹5/6在场)→ OCR上下文破案:
  **用户收尾前3min翻了 Google Docs 版本历史**,旧版以干净文本重现(同URL拦不住);删除线签名
  =词间连字符(that-humans/on-the,删除线穿词缝)+特征错字(c→e:extraet/colleetion/sereen) +作者条目'• Joy Zhang'。两道确定性闸(零模型权):
  ① **is_history_frame 剔历史帧**(54/627张):界面词∨删除线行≥3,快照取材+终读池都剔
  ② **终稿仲裁 trim**:剔历史后会话末120min帧池=终读全景(用户有通读动作,gold覆盖98%,
  旧版残留0/6);拼接产出逐句半窗核验,命中率<0.5=被重写旧版→剪(本轮剪4句)
  字数2804贴库中2770;唯一坏窗='Occasion: Personal reflective writing'(题干类小噪声,
  weak路放进,不为1窗动闸)。⚠️FINAL_READ_MS=120min 是本样本拟合参数,泛化待做
  =自动探测通读段(无通读动作的会话终稿仲裁会误剪,先 fallback 关trim)
- **v2i 两线收口(2026-06-13,用户指令"把这两条线做一下")**:
  ① **diff timeline 接入拼接路线**:canvas_merge 产出时调 CL.main(drop_history=True) 拿
  确定性时间线写进 json(100 commit+15 delete,剔历史口径);is_history_frame 下沉 canvas_local 共用
  ② **120min 墙钟常数废除**:终读池改**末 25% 非历史帧**(会话相对量,本样本=143帧≈115min,
  与手调 120min 重合)+安全阀(剪句>20%=疑无通读动作→整体弃 trim 宁多勿错);
  在 v2h(另一个 14B roll,原始 17 坏窗)上离线复现 98%/99%,剪的正好是 4 条真旧版——跨 roll 稳定
- **⚰️ 三条死路实证(别复活)**:
  a) **逐区域邻居否决(剪0)**:整段重写=邻居也被重写,事后永远等不到邻居同台;
  共享前缀旧版被半窗 present 拖到会话末,否决窗归零
  b) **CL delete 反杀(覆盖98→73)**:15条delete里8条半窗口径命中gold=假delete,直接连坐真句
  c) **更严判据 R1视口上下文+R2特征窗时效(覆盖98→63)**:判据比评测口径严=错位——
  **半窗口径天然原谅小幅改写(Back then→Back to the time 这种),只有整段重写才该剪;
  trim 判据必须与 eval/guard 同构**(本轮最大教训)
- **🎯 v2r 断尾修复定格(2026-06-13,用户标注"i can 之后断掉")**:**98%/98%(诚实口径),
  结尾逐字完整**;库中 haiku 同口径=96%/100%,错误总量持平(2缺+2坏 vs 4缺+0坏),覆盖+2。
  断尾根因:结尾写于 5/29 凌晨 00:40(帧536),写完即滚走只在场 1-2 帧,均匀采样(步长23)
  恰好跳过;eval 滑窗不查 <24 字尾巴所以 98% 没报警(已修:windows() 补 s[-24:] 尾窗)。
  **5/29 白天无后续**:02:00 后该 URL 零帧,全天 1077 帧无任何 essay 内容(传感器证据)。
  修复=**终愈续尾**(口3 complete_tail 移植):成品结尾与帧行 12+ 字精确重叠→接延伸,迭代;
  变体按击键背书率择优(tumn/turn 案)+续尾后补跑词典纠错。剩余:@144/@744 两历史缺口
  (题头准入/池外区域,v2g 起就有)+旧题头坏窗(裁定保留)+续尾 1 个 OCR 残渣窗
- **⚰️ 完整性兜底的五条死路(2026-06-13 实证,别复活)**:
  ①贪心补采进拼接(快照50-60张撑爆 merge:顶层吞行→直连爆膨胀 23605字/68%)
  ②滚动折叠顶层(一步拒收→累积体雪球,步步拒)③merge 层完整性自愈(与"旧版整段丢弃"
  指令天然冲突,正确丢旧版被当吞行误拒)④终愈频次闸 cnt≥2(**选反**:标签页像素稳定
  帧帧同key高频,真内容行 OCR 抖动变体各 cnt=1——专留垃圾专杀内容,尾巴就是它挡的)
  ⑤终愈同列邻居判据(顶栏标签与文档列 x 重合破功,一行垃圾进册即级联全家)。
  **存活架构:merge 允许有损(22张快照5调用,v2g 形态神圣不可改),完整性只做尾部续接
  (12+字精确重叠天然防垃圾);in_final 只可用于否决(缺席=旧版),不可用于准入
  (终读池里有中间态/UI/半渲染)**
- **🎯 v2v 定格(2026-06-13,用户两指认:delete 假条目+commit 杂乱须可合成文章/尾部"报错样"变体堆)**:
  **98%/99%,结尾逐字终态,timeline 构造性自洽**。
  ① **timeline 从成品派生**(行池启发式退役):commit=成品逐句+首次成稿帧 ts(文档序存储,
  逐条拼接==最终文章,程序断言 True);delete=终稿仲裁剪掉的旧版句+最后在场 ts(4条全真:
  The hardest part/Therefore I initiated/I made 3 collection/It runs silently)。不按时间重排,
  展示侧自行 sort ② **尾部终态化**(续接机制四败后定型):'it can remember what…'是被删中间态,
  in_final 分不开(终读池含新旧两态)——两步锚定:真相帧 R=尾段(末300字)全部 24 字锚的
  最后命中帧最大者(单锚会锚进中间态帧 idx462,实证);剪点=成品里 R 支持的最靠后锚,
  锚后整体替换为 R 的文档列延续(idx536:截 'itcan' 6 字→接 'making me an "undead" person')。
  击键流可证伪中间态(21:43 原文)但线性重放对鼠标改写无力,只作旁证
- **🎯 v2x delete 行池派生(2026-06-13,用户指认两条库中 delete 缺失:ADHD写后94秒删/China改写)**:
  **delete 10条 0假删,两案全回,自洽性保持,成品指标不动(98/99/2821)**。
  根因:旧法 delete=只记 trim 剪掉的拼接幸存句,但①ADHD 存活94秒进不了快照②China旧版
  在拼接层就被 14B 选版淘汰——都到不了 trim。**改为全帧行池聚类派生**:
  候选四闸=不在成品(maj<0.4)∧不在终读池(maj<0.2,标签页/别窗常驻垃圾天然排除)∧
  击键16-gram背书(用户真打过;survey/Claude引用文被吸收)∧len≥24;
  共享16-gram并查集聚类+二次合并(代表互含)+簇内最晚末见=删除时刻;
  **假删闸**=代表行击键背书的gram大半仍在成品→剔(烂OCR孤儿变体冒充删除,huge idea案);
  同文去重取最晚。gold开发期校验:0假删(代表对gold全<0.5)。
  ⚠️delete文本含旧版固有OCR脏(‖/Hhichen),展示侧 rstrip 噪声尾
- **🎯 三路集成落地(2026-06-13,用户"把判别+AX+canvas接起来,直接跑6/3 6/4看实战")**:
  ① **判别路径(integrated_run.py,零模型)**:扫一天 frames+keystroke,文档编辑器域名白名单
  ∧帧数≥30∧浏览器击键≥200 → canvas 会话;否则全 AX。6/3 6/4 判 0 canvas(击键91/134<200,
  无文档域名),与库中(全 ax_cleaned)一致 ② **faithful_v2 参数化**(3处环境变量,默认不变):
  PORTRAIT_DAYS 换天/PORTRAIT_CANVAS 切本地 canvas 源/PORTRAIT_OUT 输出路径——AX 路纯从
  typing_events+keystroke_log 重建,不碰 writing_records 成品 ③ 端到端跑 6/3 6/4(算法从没在
  这两天调过=真泛化):6/3 本地24 vs 库中24(持平,本地多4真消息少3微信),6/4 本地28 vs 库中18
  (本地多捞 Discord,含3条3字碎片)。无 gold,谁对谁错需人工核对;本地倾向多保留(符合最大保留原则)。
  产出:Obsidian 根 6.3-6.4-{库中,本地集成}产出.md
- **🎯 实战暴露两 AX bug + 修复(2026-06-13,用户对 6/3 6/4 产出逐条核)**:
  ① **ev1013「Nice! lemme check en」被拼成「Nice!了么么车诚恳」**(rebuild.\_is_eng_tail):
  多词英文短语被拼成单 token(lemmechecken)查 rime 英文词典必查不到→当拼音解码。
  修=**逐词判**,含 ≥1 标准英文词(cands(w)==w)即英文不解码。对拼音简拼尾(te d/k n/hen bu x)
  逐词无英文词→False,零回归(只英文短语 False→True 纯增益)。⚠️rime 词典对双关词
  (made→妈的/make→马克/let→乐天/wait→外套)漏判,纯生僻英文词尾仍可能误解码(已知边界)
  ② **ev1081「这玩意现在全球排32」丢「32」**(faithful_v2.literal_tail):结尾字面数字是
  整条尾巴补全链路盲区(LATIN_TAIL 只匹配字母尾;未消费统计 re.sub('[^a-zA-Z]') 删数字)。
  根因=回车竞速 AX 没记 32。修=**时间对账三约束**(逐条踩坑):锚必须含汉字 commit/submit
  (AX 把拼音残渣串 ji d 也记 commit,会把其后选字数字误当字面尾)+ submit 也算成稿点
  (「了」靠 submit;ev1084 漏认会误补 1)+ **只补 ≥2 位纯数字**(IME 选字一次 1 位 1-9,
  ≥2 位连续数字不可能选字,必字面)。全范围 250 发送实测**仅 ev1081 命中零误补**;
  代价=单个字面数字尾(排5)漏(单数字选字歧义大,宁缺毋错);标点尾不补(实测重复补问号)
  ③ **验证(6天全跑,canvas_merged_src 合并源)**:两修复翻正✓✓;gold **37✓ 1✗**——
  唯一✗=A1「记得」(ev522 简拼 ji d 未解码)。**铁证非本次引入**:literal_tail 对 ev522 返回
  ''(等价函数不存在)+ \_is_eng_tail('ji d')=False(与改前一致),ev522 解码路径字节级不经过
  我改的分支;A1 本就是 HANDOFF 独立待办(guard 拒 librime TOP),历来靠口3 OCR 偶然找回,
  本次没找回。⚠️v20「满分」产出文件已不存在,无法溯源 A1 当时为何✓(口3找回有方差)
- **🎯 中英文判别设计 + input_source 采集落地(2026-06-13,用户主导头脑风暴)**:
  详见 `输入法判别设计.md`。核心结论:**不判双关词,判用户当时的输入法**。
  · **采集层(Swift,已落地+验证)**:`keystroke_log.input_source` 字段(Schema v41 +
  KeystrokeCharLogger)。⚠️TIS/TSM API 必须主线程调(callback 线程同步调崩 EXC_BREAKPOINT,
  已修=`InputSourceCache` 主线程缓存+监听切换通知,callback 只读)。commit e831791/e008894。
  实测验证:英文键盘→`com.apple.keylayout.US`,中文拼音→`com.apple.inputmethod.SCIM.ITABC`,
  同字母串 shurufaceshi 两种输入法干净分开。⚠️**只对重新 build 后的新采集生效,历史数据全 NULL**。
  · **判别逻辑(全在实验线,Swift 不加 —— 用户裁定)**:input_source 是 keylayout=英文字面 /
  inputmethod=拼音。其余信号(双 return/选字含空格/preedit 对账)见文档 5.5 节,各有边界,组合用。
  · **多轮实证教训**:误判已≈0(修 ev1013 后,reconstruct 下游保护让英文短词留字面);
  双 return 信号验证有效但精确接主链有边界(残渣误标),**无 failing case 不接主链**(逐案风格);
  工作流量化误判 5.7% 是幻觉(只看中间判定没验产出),核实后真误判=0。
  · **双 return 英文检测器(地基已落地,commit,验证通过)**:`enzh_double_return.py`。
  历史数据 input_source=NULL,用**双 return 击键信号**:"拉丁 run + <CR><CR>"=中文 IME 打的英文字面。
  ⚠️编码 return 别用 'R'(撞大写字母 R),用 '\n'。实测:gmail 案 ev1132「g mai l」残渣的击键
  `gmail<CR><CR>` 抓出 ['notebookLM','gmail']✓,英文 bug/sparkle/doc/icon 抓对✓,纯拼音零误抓✓。

## ✅ 2026-06-13 v21 双 return 英文修复接入主链(gmail 案,**6 天全跑验证通过**)

- **接入(28d69c0)**:`faithful_v2` 加 `double_return_literal(bundle,t0,t1,residue_text)`,在 out_f 的
  `if '~residue' in src0` 分支开头调用:残渣击键窗 `[t0-2000,t1+2000]` 跑 `double_return_eng`,
  若双 return 英文词(去空格小写)== 残渣字母 → 字面替换 + 剥 ~residue 标记 + 记 C3FIX(via=双return英文)+ continue。
  命中即跳过下游残渣副本去重/草稿折叠。**唯一行为变更**:~residue 精确匹配双 return 的记录被替换,其余字节级不变。
- **运行**:`PORTRAIT_DAYS`=6 天 + `PORTRAIT_CANVAS=eval/canvas_merged_src.json`(复现上次 6 天跑,唯一 delta=本修复);
  14B disambig 427 次,~30min;产物 `eval/v21_product.md`(gitignore),归档 = `Pipeline成品归档/v21-双return英文修复(gmail案,6天集成,det).md`。
- **结果**:**gmail 翻绿**(6/5 第25条 ev1132「g mai l」→「gmail」,`[ax_cleaned]`);**Gold 38✓ 0🟡 1✗**,
  唯一 ✗=A1「记得」(ev522 在 **5/27** 非 5/29!)——**与 gmail 修复无关铁证**:ev522 是
  `[ax_cleaned]` 非 ~residue,不进改的分支。⚠️**真因见下「查因」节,不是 14B 方差(我曾误判)**。
- **零副作用实证(gmail 部分仍成立)**:**6/3、6/4 与上次产出逐字一致**(两天 7 条 ~residue 英文
  Lab/open/Yep/okay/ok/100/UC 全不变=no-op)。gmail 改动确实零副作用。
- 工具:`v21_compare.py`(解析 det 成品段+逐天 diff)/`assemble_v21.py`(组装归档文档),均已 commit。
  ⚠️工作流临时文件 `analyze_enzh*.py`×4 + `rime/cands_batch*` 仍待用户定夺清不清(无价值)。

## ⚠️ 2026-06-14 v21 三问题查因(用户逐条核出,**先不修先查因**)

**统一真因:v21 用了默认 `REVIEW_MODE=llm`,v20 当时用 `REVIEW_MODE=det`**。两路在多处**确实有 diff**
(HANDOFF 旧记「det=llm 零diff」对这些 case 不成立)。⚠️**代码 `faithful_v2.py:206` 默认仍是 `'llm'`,
但 HANDOFF 终裁是「LLM 复查退役、det 为准」——默认值从没改成 det,我 v21 继承了过时默认**。
⚠️**纠正**:我上一轮把 A1/碎片差异说成「14B run-to-run 方差」是**错的**,真因是 REVIEW_MODE(确定性可复现)。

- **#1「记得→基地」= REVIEW_MODE**:`cands('jid')` TOP=「基地」(确定性,记得排2);ev522 窗口 OCR 帧
  **有「记得」**(`M 55 明天 记得 吴承申…`×4 帧)。det 路 `verify_tail`(`line 576/599`,零14B)从帧捞回「记得」替换;
  llm 路 referee 判「基地」可信留下。**det 跑就确定性回「记得」**,不靠运气。
- **#2 密码「•••」= 独立 bug(非 REVIEW_MODE)**:ev603 `edit_log=[{kind:paste,text:"•••"}]`,**击键 0=粘贴**;
  AX 抓掩码渲染就 3 个圆点(U+2022×3,"只有3字符"因为它是粘贴、AX 看不到真长度)。掩码闸 `is_mask(t,n=4)`
  要 ≥4 才滤 → 3 个**差一个漏网**。修复方向:阈值降 3 / 纯粘贴掩码值一律滤 / 纯粘贴密码不入册。
- **#3 单「@」= 微信@提及残片 + REVIEW_MODE**:ev704 击键`@ha`、ev706`@ta<BS><BS>`——打@唤微信提及弹窗
  再打名字首字母筛人;人名由弹窗插入,AX 的 edit_log 只 commit 了「@」。det 路这俩进**未定区**(`line 574` 无帧短草稿);
  llm 路 `line 559` 直接进成品。
- **residue/短草稿碎片路由(用户「v20 更好」)= REVIEW_MODE**:残渣**标记逻辑两版完全一样**(标 ~residue/副本去重
  /gmail 改动都不碰 123/Z/J——字母<2 直接跳)。差的是复查路由:纯 AX 短草稿(`end_value` 直接是 123/Z/J/My-Meeting,
  非 machine_touched)→ **det 进未定区(`line 558` screen_only 只在 det 成立),llm 进成品**。
  实证:6/5 未定区 v20=**7 条** vs v21=**1 条**;123/Z/J/My-Meeting/clean up boddy 全从未定区涌进成品。
  苹果某些(ev1137,机器解的=machine_touched)两版都在未定区(referee 也拦),故 A18 仍✓。

  ### ✅ det 重跑已验证 —— **用户裁定:det 明显更好,定为 canonical / 当前最佳**(2026-06-14)
  - **裁定**:`REVIEW_MODE=det` 版本明显优于 llm(用户「这版本明显更好」)。det = 复查正式口径,
    所有后续全量跑一律 `REVIEW_MODE=det`(见「怎么跑」段);v21-det 归档文档 = 当前最佳基准。
  - `REVIEW_MODE=det` 重跑 6 天覆盖 v21(产物 `eval/v21_product.md`,归档同名 v21 文档已覆盖)。
    ⚠️首跑 det 命令因 **shell cwd 被重置**(redirect `eval/...` 找不到目录)EXIT=1 没跑成,第二次 cwd 已回正才成。
  - **Gold 41✓ 0🟡 0✗ 满分**(40 项 + P0):#1 记得✓(det verify_tail 从 OCR 帧捞回)/#3 单@✓(进未定区)/
    碎片✓(123/Z/J/My-Meeting/clean up boddy 进未定区)/#2 密码✓(det 路由进未定区被 sensitive n=3 过滤,不泄漏);
    gmail 仍✓(独立于复查模式);未定区 22 条(det 更厚),202 条成品(vs llm 226)。
  - **gold 加三回归探针(ba3028e)**:B13 单@不入成品 / B14 短碎片不入成品 / DOC_BAN 加粘贴密码 `•••`(U+2022×3)。
    旧 llm 产品上验证全部如期暴露(A1✗/B13🟡/B14🟡/P0✗),det 产品全✓——探针即 det/llm 复查路由的回归哨兵。

  ### ⏳ 仍待修(代码层,本轮只跑 det 没改默认)
  1. **`REVIEW_MODE` 默认仍是 `llm`**(`faithful_v2:206`),违「LLM 复查退役」终裁——下次仍会踩同坑;待用户裁定是否改默认 `det`。
  2. **#2 掩码独立 bug 未根治**:`is_mask` 数据层默认 `n=4`,3 圆点密码若落进成品仍泄漏(det 这次靠路由躲过,非根治);待降阈值/纯粘贴掩码一律滤。
  3. 远期:多词/歧义双 return 英文(框架已留)/ input_source 判别接实验线(待新采集数据)。

- **Occasion 坏窗结案(用户问"为什么没被记录")**:它在 docx 里也在 gold 里——不是缺录,
  是**题头 -92min 被用户改过措辞**,我们留的是旧版;时间窗对它原理性无解(旧题头-92min改,
  而部分真区域最后一见在-90~-120min,无窗可分);整句剪掉会连坐共享真内容(净亏),裁定保留。
  顺带结案覆盖缺口2窗:'Written: May 2026'=整行仅1个≥4字母词,结构上进不了准入闸(toks≥2拒);
  github链接行=OCR变体分裂(joyzhang 14-14/14-14)各自频次1+题头居中不在正文列锚——
  即已挂账的"x锚多列支持(标题列)"待办

## ✅ 2026-06-15/16 用户逐条标注修复(5/30-6/2 实战产出)+ OCR 取帧重构

**背景**:用户在 `~/Desktop/Obsidian/5.30-6.2-本地新pipeline产出.md` 标了 ❌(系统错+正确版)/❓(该丢弃)。
逐条查因(详见各 commit + `v22Problem&solution.md`)。**铁律:用户连纠两次,先查实根因别预设**(我曾误判"同音字"/"14B方差",都错)。

### 已修(都 commit,原子可单独 revert)

- **`6f82a5c` url 同站匹配**:`pick_frames` 的 url 过滤改 scheme+host 前缀 LIKE。真因:`typing_events.url`
  带 SPA 路径(chatgpt.com/c/<id>)vs `frames.browser_url` 只到域名(chatgpt.com/)→ 精确相等把 OCR 帧
  全滤掉,proofread/补尾静默失效。**#13「让公式站→占大头」救回**(gold D2)。gold 41✓ 零回归(`eval/gold_urlfix.md`)。
- **`dd811fa` pick_frames 6 级帧降级链**(用户设计):①+②同app(+host url)后向帧→③切回帧→④发送前帧→
  ⑤异app转场漂移帧(≤1)→⑥切回点异app帧(≤1)。异app级各取1帧(转场只第一帧留旧画面),仅①-④全失败兜底,
  每帧仍过锚+击键验证。**#60「我也去强→抢」救回**(内容只在+48s Terminal异app帧,降级链⑥抓到;gold D1)。
- **斜杠命令逐条过滤**(最新 commit):`is_slash_command` 丢 Discord `/play /s /stop`+自动补全UI(`+2 more`)。
  真因:`slash gate`(faithful_v2:~325)是**组级击键**判断,漏逐条AX命令。离线验证:5/30 五条❓全捕获、零误杀、
  零漏(/Users路径放过)。gold D3。
- **gold 加 D1/D2/D3 探针**(compare_gold):#60我也去抢/#13让公式占大头/斜杠不入成品;clean版三🟡检出。
- `v22Problem&solution.md`(类5 调研):斜杠命令 + 浏览器地址栏/搜索/表单碎片(ad min/s c)过滤方案。

### ❌/❓ 标注分类(真因,**不是同音字**)

- #60/#13 = **末尾竞速丢字**(AX记字面拼音 qiang/zhan,丢IME选字)+ reconstruct残渣路径librime TOP盲猜(强/站)
  - OCR校对本能救但取帧失败 → 上面两修治本。⚠️同音字仲裁是死路已 revert(`f39ca42`)别复活(OCR对齐漂移+时/什族误改)。
- #14 jp→jpg(AX末尾丢g,类3)/#38 em→恶魔(过度解码,类4)/#12 mi o ah su(未解码+和#13重复,类2;url修复连带救回"描述的字")/
  斜杠命令+搜索碎片(类5,斜杠已修,搜索碎片待做见 v22 方向A url黑名单)。

### 异app帧结论(用户问"我修过没")

- `d588339`(6/4,Swift采集层)治的是**切换瞬间帧标错app**(label drift)——已修,新数据不再漂。
- 但"消息内容只在异app帧"(分屏/多窗对话露在别app的窗,**正确标注**非bug)新数据 6/6-6/16 仍 ~12%(旧9%)。
- **6级降级链就是对这个的系统解**(异app帧当最后兜底)。#60 证明有效。

### ⏳ 待验证/待做

- `b92ydy0pb`(降级链全量验证,**在加斜杠过滤前启动**)跑完:查 `eval/gold_cascade.md` 应 41✓(降级链不回归);
  `eval/new4days_cascade.md` D1✓D2✓ **D3🟡**(斜杠没进那次跑)。
- **要 D1+D2+D3 全✓**:用最新代码(含斜杠)重跑 5/30-6/2。
- 用户要的 **6/6-6/16 md**(看异app是否还在)没跑(一直在修取帧);6/6 巨大855events,可挑天。
- 类2(尾巴/中间态折叠)/类3(AX末尾用击键兜底)/类4(em过度解码)/类5搜索碎片(v22方向A) 待做。

## ✅ 2026-06-16/17 本 session 修复(em双路 / hermes发送清空 / 全残渣OCR)+ 连发拆分设计

**逐案修(都 commit,原子可 revert)**:

- **`266e13d`+`4f4dbff` em→恶魔 过度解码(双解码路)**:`em`(小写2字母,`cands('em')` TOP=恶魔,像合法拼音)躲过
  guard 被 librime 当拼音解。两条路各解一次:① 主 `reconstruct`(`faithful_v2:299`)② 口3 OCR 锚不上
  → 14B 双向语境重试(`faithful_v2:538`)。修=两处对称传 `eng_literals`(新增 `eng_literals_of`):
  **双return(保历史,input_source=NULL)+ input_source=keylayout(解未来)**,不靠长度(`ni/wo` 照常解码)。
  guard 在 `rebuild.py:174` 加一条 `residue∈eng_literals → 不解码`。
- **`8d0abe6` hermes 整句丢(网页发送清空)**:ChatGPT 等网页打字 AX **不建 typing_event**,只在发送清空记一个
  **光杆 delete**(text=完整消息+`\n`,end_value 空);旧 delete 分支要 `isMark` 占位符+`cover` 背书,光杆过不了
  → 整句丢 → fallback 击键账本按 `<CR>` 切碎+漏段。修:① `rebuild.py` delete 分支加 `send_clear`
  (原文以`\n`结尾+`sent()`回车+框空)豁免 isMark/cover ② `faithful_v2` 账本消费窗对长段(≥6字)回看放宽 60s
  (接住被发送清空记录涵盖的击键碎片免重复)。验证:整句以 `[ax_cleaned]` 入册,碎片消费。
- **`178b41f` 全残渣短消息 OCR 整句救援(从哪找的案)**:`congnazhaod1` 你输入法#1=**从哪找的**,librime#1=
  **从那找到**(到/那 同击键,verify_tail 都过 → OCR 是唯一裁判)。OCR 帧有「从哪找的」但口3 用不上:
  `proofread_tail` 的 `base`(可锚前缀)=空(整条机器解码)→ 「base太短无法锚定,待建」直接放弃。
  修=补 `_whole_residue_ocr`(`ocr3.py`):机器猜首字锚 OCR 帧→取等长窗→同长+位置重合≥半+击键验证→以屏幕为准。
  补上了 `ocr3:212` 明标的待建洞。离线验证 ev426 从那找到→从哪找的;ocr3 七案例零回归。
- **`a5c0363` gold D4 探针**:ban「从那找到」。现 gold 有 D1(#60抢)/D2(#13占大头)/D3(斜杠)/D4(从哪找的)。

**⚠️ 文档陈旧(下个 session 别被骗)**:

- **REVIEW_MODE 默认已是 `det`**(`faithful_v2:241`,本 HANDOFF「怎么跑」段+429/511 行还写 llm/`:206` 是**陈旧**)。
- `enzh_double_return.py` docstring 还写「⏳待接下一session」——**早接了**(`faithful_v2:411` double_return_literal)。
- 临时文件 `analyze_enzh*.py`×4 + `rime/cands_batch*` 待清。

**v23 产出(用户审核中)**:`Pipeline成品归档/v23-库中有的全date(5.24-6.5,det,本session全修).md`(本地全管线,
含 5/28-29 canvas_merge 重建的 essay)+ `v23-库中产出对照(5.24-6.5).md`(生产 writing_records)。
**生产写作采集只到 6/5**(之后转本地实验未跑生产),6/5 后无库中对照 → `v23延伸-6.6-6.17(库中无对照).md`。
**采集起点 = 5/24 20:07**(typing_events 与写作采集同时起,5/24 之前无打字采集)。用户已逐条标 5/24(6处❌/✅)。

**🎯 下个 session 主线 = 连发拆分(survey #42,用户设计)**:

- **现象**:Discord 快速连发多条,AX 记成**一个 typing_event** 只 1 条 submit;commit 流里前面几条连发**全漏**。
  5/25 Discord 实测 ~19 条漏(ev435/438/456「你能通过这个数据把我复活」/473/475/487… = 现成 failing case)。
- **用户设计(方向对)**:**keystroke `<CR>` 为单位切**(发送即回车,连发天然拆开)+ **AX 多行(含`\n`)合并**
  (Notes/shift+enter 的换行是消息内部,按 AX 并回)。两信号正交。
- **三个坑**:① IME 上屏回车/选字确认 ≠ 发送回车(双return),切完丢 trivial 段 + AX 合并兜② Enter=换行的 app
  靠 AX 多行兜③ AX 多行↔击键段映射按内容/拼音+时间对齐。⚠️ 动切分单元=架构级,send 检测改坏过,要小心。
- **同族**:hermes(多发送)已治网页发送清空那一面;连发是「事件内多条」那一面。

**⏳ 验证中**:`be273o06o`(5/25+gold天,验全残渣OCR修复:5/25 #31 从那找到→从哪找的 + D4✓ + gold 不回归)。

## 🚧 2026-06-18 keystroke 主导架构重构(用户设计,**进行中**,挂 `PORTRAIT_ARCH` 开关默认 ax 不变)

**动机**:用户标 5/25 发现 Discord 漏很多(后查实=管线问题非采集:难绷/比如说你有一个公司等真消息击键都在,
被窄账本「渲染确证」「汉字<3」「dirty」「去重」等闸丢)。用户拍板**架构倒置**:keystroke=完整发送骨架
(每键都记,零丢弃),AX 退为辅助(分组重组 + 文字复原)。

**已落地(`ks_primary.py` 独立模块 + `faithful_v2` 整合,commit `1e4a331/d62559c/63c6e43/c554898/4ade274`)**:

- **切分(`segment_keystrokes`)**:按真发送回车切段。判发送复用 **AX 占位符逻辑**(用户指令「复用现在ax发送的逻辑」):
  · **shift+return(mod&8)= 消息内换行**,不切(用户实证换行用 shift;⚠️`md&7` 只抓 cmd 组合 1/2/4,抓不到 shift=8,
  不修则 claudefordesktop 23 个换行被当发送切碎)
  · **`clear_times`**=框清空/占位符时刻:`﻿`(Discord 空框 ZWSP,且无内容)或 `X.is_ph`(claudefordesktop
  "Reply to Claude…"文字占位)。⚠️per-return 清空 AX 记太稀疏(79<123 回车)不能反推单条 → 用 **per-bundle**:
  `clear_times≥3`=聊天(回车=发送,连发每条都切)/ 0=编辑器(Notes/obsidian 纯`\n`换行无占位)→ 回车=换行整条
- **文字复原(`segment_sends`)**:每发送段配 commit 真字主体(captured,按击键边界逐条落,收到「下一条开始打字」
  含 IME 滞后尾),喂 `faithful_v2` 完整链(reconstruct+literal_tail+口3+14B);**不重解**(原型逐段重解=脏,教训)
- **自动分流(`faithful_v2:272`,不硬编码 app)**:`ARCH=keystroke` 且 bundle 是聊天(clear_times≥3)→ 走击键;
  否则(编辑器)→ 走旧 `event_sends_with_ts`(长文整条由 AX 给)。关掉重复账本(ARCH=keystroke)
- **排序**:成品按 t1(发送时刻)排(commit `ff1d2bd`,独立小修,已对 IM 时间线;边打边想长消息 ev461 不再顶前)

**5/25 实测(`eval/ksp_full.md`,REVIEW_MODE=det PORTRAIT_ARCH=keystroke PORTRAIT_DAYS=2026-05-25)**:

- 聊天 Discord 106 / claudefordesktop 36(**连发拆分**:对啊×2、半年就翻40倍 等回来);编辑器 Notes 3 / obsidian 2(走 AX,**不再碎**);D4✓ P0✓
- **零丢弃达成**:用户标的缺失(难绷/蝴蝶效应/比如说你有一个公司/可以简单的善后)全回(sonnet 逐条对照实证,见 Obsidian `v26-对照v24完整标记(5.25全app).md`)

**⚠️ 残留/待办**:

- **同音错字**(符号→复活、美丽→没了、爱→AI):commit 真字也没有、librime 猜错 → **#44**(OCR/14B),旧管线也有
- **截断的正确残段**(那比如说你就很 缺重要):commit 没记下尾字,不强解=宁缺毋错(正确>残渣>错字),非 bug
- **sandisk 类 IME 上屏英文**:历史 input_source=NULL 无法精判,聊天默认按发送切(拆开);新数据靠 input_source(keylayout)精合,待接
- **gold 全量验证未做**(单天 5/25 跑 gold 13✓32✗=假象,探针多在其它天):**下一步必须全量多天跑 `compare_gold` 确认聊天路不回归**
- **emoji 缺**(:emoji_xx: 点选非击键,keystroke 抓不到):符合「只记手打」,用户未裁定要不要补
- **claudefordesktop 36 vs 库中 24**:多的是连发拆分,质量待用户逐条核(v26 文档已 sonnet 初标)

## ⚠️ 2026-06-22 混合架构 + per-return 三态切分(**已于 2026-06-24 整套回滚,见文末;只留教训,代码不在执行路径**)

**背景**:全量两版对比(ax 44✓ / 纯 keystroke 26✓)暴露纯 keystroke 暴跌——captured 滤光英文 + 关账本。
用户裁定混合,经 4 次澄清逐步逼近最终设计。

**最终架构(commit `59db51b` 混合 + `2bccdaa` 三态)**:

```
keystroke return(候选切点)
 → ax 验证每个 return(ks_primary._is_send_return,只看回车那帧框内容):
     框清空 / 无记录 / 换成不相似新内容 = 真发送 → 切
     框没清空且与回车前相似(SequenceMatcher.ratio≥0.5:追加/改写/IME确认上屏)= 没发送 → 合并
 → 每段文字:优先借 ax(event_sends_with_ts,含英文/粘贴 sandisk/ElevenLabs);
     ax 把多条连发合并(nk>1)或 ax 漏(密集连发 ev454 漏16条)→ keystroke captured(完整commit真字)兜底
 → 全走老逻辑(reconstruct/口3/Pass4/去重)+ 开窄账本
```

**三处实现**:

- **A(`ks_primary` segment_sends captured)**:从"只留汉字"改**完整 commit 真字**(含英文/数字/拼音/标点),给 ax 漏的兜底段保英文(原 HAN-only 滤光 ElevenLabs/6个G)
- **B(`faithful_v2:281` keystroke 分支)**:ax 1对1 借 ax 文字 / nk>1 或 ax漏则 captured 兜底 / ax 独有段(nk=0)也保留,去重交老逻辑
- **C(`faithful_v2:480` 开账本)**:去掉 `ARCH=keystroke` 禁用,补切分够不到的零AX痕迹消息(查重防重复)
- **三态切分(`ks_primary._is_send_return`/`_edit_entries`)**:替 per-bundle is_chat。逐 return 比"回车那帧框内容 vs 回车前"相似度;统一聊天/编辑器(编辑器换行天然相似→合并整条),不硬分

**⚠️ 用户 4 次澄清(关键概念,别再搞错)**:

1. keystroke 只分段,文字用 ax,走老逻辑(口3/Pass4)
2. ax 根本没检测到的 session 不用管(keystroke 兜底),检测到的才合并
3. return 不一定是发送:有时中文输入法打英文按 return **上屏确认**,或单纯换行;看 ax 框有没有清空
4. 改写(vos→vcd)也该合并——**只看 return 那帧 ax 框内容与回车前是否相似**(不止前缀延续);
   实证 Discord 123 return 真连发零误合并(追加/IME确认/重复正确合并)

**gold 演进(全量 6 天,REVIEW_MODE=det)**:纯 keystroke 26✓ → 混合 40✓ → 混合+三态 40✓
(切分更准:289→278 条,合并了中间态/IME确认/改写)。距 ax 44✓ 差 4 个**下游回归**(非切分):

- **A1 记得 / A7 一下测**:简拼 ji d/yi x,口3 OCR 没找回(混合 captured 走口3但没救回)
- **A6 Blueprint**:长消息 captured 简拼解码弱
- **B1 vos/vcd**:下游 dedup 选了中间态「vos有关」而非终稿「vcd有关」(幻影发送/过期快照案,ax 路靠幻影降级选终稿)
- A10 卖个惨:ax 也✗(librime 词库无此 slang,**非回归**)

**产出**:Obsidian Pipeline成品归档/`v28-6天混合架构` / `v29-混合架构+三态切分` / `keystroke混合架构-验证报告`。
基准 `eval/v_ax_6day.md`(ax 44✓)/ `eval/v_ksp_hybrid3.md`(三态 40✓)。
**跑法**:`REVIEW_MODE=det PORTRAIT_ARCH=keystroke PORTRAIT_DAYS=2026-05-27,...,2026-06-05 PORTRAIT_CANVAS=eval/canvas_merged_src.json PORTRAIT_OUT=<abs> python3 faithful_v2.py`

**⏳ 待做(下轮)**:逐个修 4 回归(A1/A7 简拼接口3 / A6 长文借ax / B1 vos/vcd 幻影降级)——都是下游独立问题,切分架构已正确。

## ⚠️ 2026-06-24 keystroke 整套回滚(sonnet 逐条核翻盘 = 本轮最大教训)

**翻盘**:gold 一路 26→40→43✓ 看着成功,但 **sonnet 逐条核(6 天对照 ax 基准)揭穿是假象**:

- keystroke 混合(改动1=ax段未借走就保留)6 天多捞 83 条,**82 条是垃圾**(输入过程中间态:
  IME 拼音裸露/截断快照/逐步追加版本/单字残渣),只 1 条存疑真内容,还带 12 处错字;6 天 verdict 全"更差/持平"。
- **gold 探针测不出中间态垃圾涌入**——它只查"特定真消息在不在"(都在=43✓),不查噪声;
  程序去重也抓不到(中间态文本各不相同)。**必须 sonnet 逐条人工核才看得出**(用户一直坚持的方法对)。
- **ax 路 6 天 missing=0**(零漏真消息)且干净;**连发拆分(keystroke 核心卖点)零正向价值**
  (ax 早把连发拆好了,keystroke 没多找回真消息,只多了垃圾)。根因:keystroke「零丢弃」保留
  输入过程多个快照(借ax段 + captured IME 拼音),dedup 拦不住(is_send=True 不敢删/文本各异)。

**回滚(用户裁定)**:`git checkout ff1d2bd -- faithful_v2.py`(回 keystroke 之前纯 ax 路);
`ks_primary.py` 暂留不删(faithful_v2 不再 import)。全量 6 天重跑 diff `v_ax_6day.md` **逐字一致**,
确认干净回到 ax 路 44✓。**working tree 回滚未 commit**(用户有新思路待展开)。
⚠️ 关联 commit 仍在历史(1e4a331/d62559c/63c6e43/c554898/4ade274/177ee48/59db51b/2bccdaa/0fe4ca8),
HANDOFF 上面 2026-06-18/22 两节描述的就是它们,**已是死路**。

**教训(刻进下一步)**:① 质量看信噪比,不只看 gold;gold 高 ≠ 成品干净。② 新方案务必 sonnet 逐条核
对照 ax,别信 gold 探针。③ ax 路(event_sends_with_ts 抓渲染完成的最终态)零漏且干净,是强基准;
偏离它要先证明它真漏了什么(5/25 窄账本漏的那些,大概率是窄账本闸=渲染确证/汉字<3 的问题,
非 ax 路本身漏——这点待新思路验证)。

## ✅ 2026-06-25 采集层根治连发黑洞(ax 路源头修复,实测 9/9 全中)

**根因**(承 2026-06-24 调研):AX edit_log 黑洞 = 高频连发时 AX value-change 被系统 coalesce
(清空帧丢)+ debounce 350ms 重排不 fire。回车摇读(`submitRaceBurst`)本来主动读 value 救 IME
末尾字,但 ① 读到清空就 `return` 丢落定值 ② 判清空用 `value.isEmpty`,**Discord 发送后框是
占位符 `﻿\n` 不是空串**,从没触发。

**修复(3 commit,Swift 采集层 `Typing/`)**:

- `a0fc280` 摇读捕获框清空 → `writer.submitFromRace` 主动落 submit(绕 debounce+coalesce;
  记 lastNonEmpty 落定值,摇读没抢到回退 pendingValue/快照,治连发黑洞 + IME 末尾丢字)
- `d79f6d8` debounce 350→100ms(打字中间态落库更密)
- `1de33de` 清空判断认占位符(去 `﻿`+trim 判空,非 isEmpty)——**关键修复**

**实测**(用户真机 build&run 连发9条:1919/测试/快速测试/how are u/1234/3/\*/$/15$):
**submit 9/9 全中,一字不差**(修复前 ev2824 同样9条只记3 commit、0 submit)。

**意义(整条线收口)**:ax 路从源头不漏连发 → keystroke 主导/减法找遗失**都不需要了**;
难绷/蝴蝶那种漏以后不再发生。⚠️ 只对**新采集**生效,历史黑洞数据(5/25等)不回溯。

## ⏳ 2026-06-27 canvas AX 失灵 + 通用判据(讨论中,用户有思路,下轮实现)

**实测确认采集层 submit 已成**(承 06-25):连发 9 条 submit 9/9;分 session 干净(每条一 ev、无重叠);
keystroke 边界处偶有归属歧义(IME 打英文/数字=确认回车+发送回车=2回车,但 submit 只记发送,采集对)。

**canvas AX 失灵根因(查实)**:Google Docs 暴露给 AX 的**不是文档内容**,是 `​`(ZWSP)/`\xa0`
填充的输入捕获区——ev662 写 8.7 分钟,end_value 只有一个 `\xa0`;打字碎片(`​ba​`/`​Sin​`)瞬间显示,
提交后渲染进 canvas、捕获区清空回 ZWSP。**canvas 路必须 OCR,AX 在这儿原理上没用**(任何 canvas 编辑器同理)。

**摇读对 canvas 的误判(待修)**:回车摇读 `cleared` 判断(去 `﻿`+trim 判空),Google Docs 的 `\xa0`
会被 trim 当清空 → 误把 canvas **换行**当发送、产碎片 submit。影响小(碎片下游 `is_residue` 滤 + canvas 走 OCR),但该收紧。

**⚠️ 通用判据(用户要的,别硬编码 URL/app/ZWSP)**:区分「聊天发送 vs canvas 换行」靠 **AX value 是否
承载击键内容**——session 里 value 体量 vs 击键量:聊天相称(打 N 键 value≈N 字符)、canvas 远小于
(打几千键 value 仍是碎片)→ AX value 不可信、回车不当发送。对**任何** canvas 编辑器通用。
代码有影子(`isOversizedDelta` value跳变vs击键 / `windowHadKeystroke`)。下轮:rec 累积「value 承载率」+ 阈值,接 submitFromRace 前。

## ✅ 2026-06-27(续)librime AX 接线已拔 + canvas 四档路由定型

本轮把「canvas 通用判据」从讨论推进到设计定型 + 落地第一刀。

**① 拔接线已 commit(`b96e3d5`,改 rebuild.py)**:采集层摇读修复后 AX 直接给汉字(实测 Discord
submit「测试」「快速测试」、ChatGPT「这样的对吗?」、CKEditor 增量均为汉字),librime `decode_run`
的拼音→汉字**猜字**成了误判隐患(记得→基地,猜错=错字=铁律最坏类别)。加 `DECODE_LIBRIME` 开关
(env `PORTRAIT_LIBRIME_DECODE`,**默认关**),关时 `decode_run` 返回 `None`,现有逃生门把拼音残渣
路由给口3 OCR(屏幕真值)。**不影响**:口3 拼音表匹配(不走 decode_run)、字面/数字尾补全
(literal_tail 不是 librime)、guard。**blast radius**:窄账本(纯击键 librime 重建)会静音→见②反推。

**② 实测三桶 + 0AX=canvas 反推(扒 06-25 后新采集 typing_events 实证)**:

- 聊天(Discord/ChatGPT/claude desktop):摇读抓完整汉字 → **有 AX 痕迹**,AX 直接用
- 存量框编辑器(CKEditor/Notes/obsidian):value=整文档(demo 存量 ~1500 字)+ 手打增量,增量在
  value 末尾**找得到** → **有 AX 痕迹**,存量框剥离(`d18f6d8`)取增量,不需 OCR/librime
- canvas(Google Docs):value=`\xa0` 碎片、内容全无 → **0 AX 承载**
- **用户反推**:新数据里「0 真 AX 承载」**≈ 只剩 canvas**。所以①的窄账本静音**不是损失**——那些内容
  本质是 canvas、该走 OCR;而 librime 解纯击键正是已回滚的线性重放(对长文鼠标改写无力)=用错工具,
  静音掉反而对。**故 blast#2 不收窄开关,让它静音,靠逐段承载率把 0 承载段路由到 OCR。**

**③ 承载率算法(零硬编码,两层;判 AX-vs-OCR 路由)**:

- **第1层(廉价主判,抓 canvas)**:value 去 ZWSP(`​`/`﻿`)/`\xa0`/控制符/空白后的**实质字符
  长度**。canvas≈0(不随击键增长,永远 `\xa0`),聊天/编辑器有实质内容。一条判断揪出 Google Docs 这类
  结构性空 value。
- **第2层(防伪,拼音命中)**:value 汉字用**拼音表**(canvas_local 在用,多音字取任一读音)转拼音,看
  这段**击键拼音串在里面的连续命中覆盖率**。CKEditor 增量命中→承载;Google Docs 命中0→不承载(哪怕
  value 体量大)。防「value 大但不是你打的」。
- **不是「value 体量 vs 击键量」**(CKEditor value 大却含真增量,体量比会误判成 canvas)。先上第1层,第2层后补加固。

**④ 四档路由定型(用户设计,librime 终于有了不糟蹋它的用法)**:

```
逐段判形态:
 A. AX 有汉字(承载率高)          → AX 直接用                    [librime 关]
 B. AX 失灵 + 短+线性             → librime 解击键重构(OCR 能拍到则校验) [librime 开]
 C. AX 失灵 + 长+鼠标改写(GDocs)  → OCR 全量重建(canvas_local)   [librime 关,只背书]
```

- **B 档=本轮新归宿**:短 canvas 输入(便签/小编辑器/几行字、线性打无鼠标跳改)→ 击键流就是内容、能对齐
  → librime 解。**不是复活死路**:keystroke 主导回滚的死因是**全量长文鼠标改写**(线性重放34%),B 档的
  「短+线性」限定正好避开死因。**Google Docs 那种全量长文走 librime 会噪音涌入(鼠标改写/跳改),很难重构 → 必须 OCR**(用户明示)。
- **边界=「短+线性」vs「长+鼠标改写」**,不是 canvas-vs-非(零硬编码)。信号:长度 + 鼠标改写程度
  (退格率/光标跳转/击键间隔)。
- **铁律守**:B 档 librime 仍猜字(同音错字风险=最坏)。短输入通常 OCR 也拍得到→能 OCR 就 OCR/校验;
  只有 OCR 也没拍到才纯 librime(错字 vs 丢,默认待定)。
- 实现:librime 解码**只在 B 档显式开**(对那段 `DECODE_LIBRIME` on);A 档全局默认关保护。

**⑤ canvas+librime 走新文件(用户指令)**:bucket B 实现**另起新文件**,**import 复用 rebuild.py 的
reconstruct/decode_run,但不改 rebuild.py**——保留它原样,给 6/25 前历史数据重构(原逻辑可跑)。
新文件按需对短+线性段开 decode、调 reconstruct。

**不跑 gold(用户裁定)**:gold 全是**旧采集**产出,那个世界 librime 解码承重;拿拔接线后的新逻辑跑旧 gold
会出假回归。gold = 旧管线(decode 开)基准,不是新架构标尺。新架构验证 = 新采集手动抽查(已做:9/9、Safari、CKEditor)。

**⏳ 下轮**:① 承载率第1层(实质字符长度)落地 + 逐段路由(替 `integrated_run` 整 session 判)
② canvas+librime 新文件(bucket B,短+线性检测 + reconstruct 复用,不改 rebuild.py)
③ **6/25 前历史数据重构**(用户「最后再说」,跑时 `PORTRAIT_LIBRIME_DECODE=1` 开回原逻辑)。

## ✅ 2026-06-27(续2)承载率第1层 `ax_bearing.py` 落地 + Google Docs 实测校准

**新文件 `ax_bearing.py`(零模型/零硬编码/只读 DB,不碰现有 .py)**:承载率第1层 + canvas 判别替代件。
跑法:`python3 ax_bearing.py [YYYY-MM-DD]`(默认最近 24h)。

**算法定型(实测校准,非凭空)**:

- **单位 = keystroke_log 击键突发窗**(按 `BURST_GAP_MS=60s` 切),**不是 typing_event**——实测 Google Docs
  正文的击键落在两个 event 之间的空档里、根本没 typing_event(value 不变→事件不 fire);keystroke_log
  (CGEventTap)独立于 AX,内容一个不丢。
- **AX 实质内容 = edit_log 的 `commit`/`submit` 真字符**(strip ZWSP/`\xa0` 后),**不用 end_value**(聊天发送后
  end_value 是占位符 `﻿⏎`、canvas 的 edit_log 只有 `paste` 的 ZWSP)。
- **逐键覆盖**:每个键 ±`AX_PAD_MS=3s` 内有没有 commit/submit → 覆盖/未覆盖,连续同态聚子段。
  未覆盖子段 = 0承载(→canvas);覆盖 = 承载(→AX 路)。
- **三个用户裁定**:① 去 `MIN_KEYS`(最大保留,短到 ok 也判,噪声留下游口3);改用 `(modifiers&7)=0` 排除
  cmd/ctrl/opt 快捷键(cmd+v 噪声),保留 shift 大写 ② `GAP_KEYS=8`:承载窗**内部** <8 键的未覆盖段=AX commit
  时序空档(monkeytype 打字测试 chil/li 假阳),并回承载;整窗全未覆盖(standalone canvas 如 ok)不受此限;
  真 canvas 段(测试1正文 19 键)在阈值上仍判 0承载 ③ 术语:**承载 = 走 AX 路**(不是另一条路)。

**`canvas_spans()` = 替代老 `integrated_run.discriminate`**:把逐段 0承载按 bundle+时间相邻聚成 canvas 会话,
按击键数分桶(用户裁定 **`BUCKET_KEYS=120`**:>120=C 长走 OCR/canvas_merge,≤120=B 短走 librime),附文档 URL。
**关键:URL 只在承载率判定是 canvas **之后**才查(给 canvas_merge 定位帧),不再是判别门**——根治老
discriminate 三宗罪(① 硬编码 URL 白名单 ② 整 session 粒度,标题框/正文不分 ③ MIN_KEYS=200 门槛漏短文)。
⚠️ 仅判别逻辑,**未接 canvas_merge**(那步加载 14B,等 GPU + bucket B/C 建好)。

**Google Docs 实测结论(用户两个 docx + 一次 ok + monkeytype 极端测试)**:

- 正文 = **0 AX 承载**(end_value 纯 ZWSP,edit_log 只 `paste` ZWSP);标题框 = 普通 input,AX 抓得到 → 承载。
  两者同一 burst 内被逐键覆盖**正确拆开**(标题→AX,正文→canvas)。
- 击键全在 keystroke_log(`ceshi1ceshi1,canvas`、`The US military…` 全在)→ bucket B/C 输入有保障。
- **librime 还原实测暴露 B/C 必须分**:短+纯中文「测试测试canvas」librime 解对 ✓;**长+英文为主(337键)librime
  当拼音解=彻底乱码**(他和us米利唐…)→ 实锤长文必 OC,不能 librime;混合短(wtf+拼音)librime 解空 → bucket B
  也得 OCR 兜底。**CKEditor 那条反向验证拔接线对**:librime 把「打的字」解成「大的子」(同音错字),AX 有正确版。
- **bucket B 走口3 验证**(用户):librime 同音错字靠口3 OCR 屏幕真值纠;口3 要 14B,等 GPU。
- ⚠️ 残留:`o k` 这种中文输入法打英文(input_source=SCIM.ITABC + 双回车)librime 解空,应保留字面「ok」(双 return 英文信号,gmail 案同族)。

**⏳ 下一步(都不需 GPU 的确定性部分)**:① 把 `canvas_spans` 接进 `integrated_run`(替 discriminate)——但调
canvas_merge 要 14B,先只接判别、不跑提取 ② bucket B 短线性 librime 解码(确定性,口3 验证等 GPU)
③ 承载率噪声(finder/空键 standalone 0承载)是否要个最小真内容门——暂按最大保留留着,下游滤。

## ✅ 2026-06-28 bucket B librime 落地 + 接线编排(确定性部分全通,新文件不改现有 .py)

承上①②③全做完(确定性部分),GPU 部分留待。**三个新文件,都零模型/零硬编码/不碰 rebuild.py**:

**`canvas_librime.py`(bucket B 短 canvas 解码)**:0承载且短(≤120键,`BUCKET_KEYS`)的会话 →
`keys_in_window` + **逐 run 装配**(`_decode_segment`):拼音→`decode_run`(TOP)/英文→字面(保大小写)/
标点空格→保留。**不用 `reconstruct('',kw)`**(它丢标点[parse_picks 把逗号当分隔符]+丢纯英文[无中文 run 返空])。
与 AX 路共存:**运行时**临时置 `R.DECODE_LIBRIME=True` 再还原(AX 路默认关防误判,不改 rebuild.py 源码)。
实测:`测试测试,canvas`✓、`ok`→ok✓(字面)、`wtf↵泥土兄弟饿,好吧`(`泥土`应"你它"/`饿`应"额"=同音错字,**待口3 OCR 纠**)。

**`canvas_route.py`(接线,替 `integrated_run.discriminate` 流程)**:`canvas_spans` 逐段判别 →
B 短走 `canvas_librime`(确定性可跑)/ C 长走 `canvas_merge`(要 GPU,留占位)。产出
`eval/canvas_route_fusion.json`={day:[{source,text,app}]},格式同老 `canvas_local_fusion`,直接给
faithful_v2 `PORTRAIT_CANVAS` 读。AX 承载段不在这(faithful 自己重建)。跑法:`python3 canvas_route.py [day…]`。

**本轮用户裁定(都已落)**:

- **B/C 按击键数分桶,阈值 120**(`BUCKET_KEYS`):>120=C 长走 OCR(实测长英文 librime=乱码,必须 OCR);≤120=B 短走 librime。
- **承载率层不做内容过滤**(撤掉零真内容筛,纯最大保留):噪声照样出会话,价值判断交下游。
- **但 canvas 成品绕过下游过滤**(faithful 里 canvas text 直接 append 进成品,**不走 AX 路的口3/质量门/dedup**)——
  所以 `canvas_route` 加一道 **correctness 守卫**:`text.strip()` 空(纯空白)不产成品;有内容(哪怕单个`，`)就留。
- **`real_key`/`_decode_segment` 用 `isprintable()`**:排 ESC(`\x1b`)/US(`\x1f`)等控制键(非文字,correctness,非内容过滤);空格保留。

**⚠️ 关键差异(下个 session 记牢)**:**canvas 路 ≠ AX 路**——AX 噪声有下游(口3/质量门/dedup)兜底,canvas
成品**直接进 faithful 成品、零下游过滤**。所以 canvas 侧的脏数据必须在 `canvas_route`/`canvas_librime` 这层就干净。

**⏳ 仍待(GPU)**:① 口3 验证 bucket B(纠同音错字,要 14B)② `canvas_merge` 跑 C 长文(要 14B)
③ 6/25 前历史重构(`PORTRAIT_LIBRIME_DECODE=1`)。**确定性侧到此完整**:承载率判别 + bucket B 解码 + 接线 + 噪声 correctness 全部就绪、实测过。

## ✅ 2026-06-28(续)游戏过滤 + bucket B OCR 矫正定为 LLM 判别(确定性证明不可行)

**游戏/包装层不走 canvas(`ax_bearing.skip_canvas`,已 commit)**:游戏击键(WASD/技能/音游点击)无 AX→0承载,
会污染 canvas 成品(canvas 绕过下游过滤)。判据**不靠键/内容**(WASD 不全、音游会蒙混),靠 ① 系统类别
`LSApplicationCategoryType=games` ② **模拟/包装层 bundle 前缀**(CrossOver/Whisky/Wine/Parallels——跑非原生软件无
Mac AX,用户裁定可硬编码「无非那么几种」)。实测 CrossOver 包的 VILLAGE 游戏(`wwddsd`)排除✓。⚠️Python 快版:
走 AX 文本框的游戏聊天=承载走 AX 路不丢;非 AX 游戏聊天会丢(采集层「文本框焦点」闸=Swift 版才精准保)。

**🔬 短 canvas OCR 矫正:确定性算法 9 次实证不可行,定为 LLM 判别(`canvas_librime.ocr_correct_llm`,搭好未跑)**。
测试案 `Wtf↵逆天兄弟`(你写的)结论链:

- librime 解 = `wtf↵泥土兄弟饿,好吧`(同音错字 泥土/逆天、饿/额 + 含**打了又删**的「额好吧」)。
- **OCR 数据是好的**:`逆天兄弟` conf 1.0、frame_lines 干净给出。**关键 bug**:`browser_url LIKE` 过滤把干净帧滤掉了
  ——干净帧的 `browser_url` 常是 **NULL**(带 url 的反是脏帧:额好吧/桌面/自指污染)。改 **app_name+时间窗,不过滤 url**。
- 但 9 种确定性帧选择/锚/多帧全栽,**决定性根因**:`额好吧` 是**选择删/鼠标删**掉的,`keystroke_log` 只记单字符按键、
  **抓不到选择删**(全 session decode 后 `额好吧` 还在)→ **最终态无法确定性重建**(同 keystroke 主导被回滚的根因)。
  且删后没拍到干净帧,OCR 侧也无「最终态」锚。
- **用户裁定:改 LLM 判别**。`ocr_correct_llm(con, sp, librime_text, llm)`:给 librime 候选 + OCR 锚定行(共享子串锚=简拼免疫;
  `_ocr_evidence` 按 app+时间窗收集,**不过滤 url**),本地 **14B(MLX,非 sonnet)**输出最终干净内容。`make_llm` 惰性加载
  (导入不 load);`llm=None`/无证据 → 回退 librime(残渣可见,宁缺毋错)。已接 `canvas_route`(`--llm` 旗标)。
  **实测(不跑模型):OCR 证据正确含「逆天兄弟」**,GPU 空喂 LLM 应出「Wtf 逆天兄弟」。
- **GPU 空了跑验证**:`python3 canvas_route.py --llm`(会 `make_llm` 加载 14B;⚠️ event-local-lab 占 GPU 时会 OOM,先确认)。
- **✅ 2026-06-28 已跑通、两修后基本可用**:① **证据窗收紧到 span 末**(非 5min-gap 长 session)→ 排掉很久之后我讨论它时的
  **自指污染帧**(关键)② **few-shot 示例**治好 14B 的 echo(原样吐证据列表)+ `enable_thinking=False`(否则思考模式吃光 token)。
  实测:**测试1 案 → `测试测试，canvas` 完全正确**;**wtf 案 → `逆天兄弟，好吧`**(`泥土`→`逆天` 同音错字**靠 OCR 修对了**✓)。
  残留:wtf 多了删掉的「好吧」(OCR 证据窗内仍含 `额好吧` 帧,LLM 不知它被删=删除内容硬边界,需多帧稳定剔瞬态)+ 丢「wtf」。
  **结论:LLM 判别基本可用,主功能(OCR 纠同音错字)成;删除内容剔除是剩余边界,待多帧稳定迭代。**

## 🏁 2026-06-28 写作采集本轮告一段落 —— canvas 本地化全链路就绪

**这轮从「拔 librime AX 接线」一路做到「canvas 短输入 LLM 判别」,整条 canvas 本地化链路落地(全新文件,不改 rebuild/ocr3/canvas_local 现有函数)**:

```
keystroke_log/edit_log
 → ax_bearing.canvas_spans   逐段「承载率」判别(替老 discriminate 的 URL白名单+整session+200键三宗罪)
     · 游戏/包装层(skip_canvas:LSApplicationCategoryType=games + CrossOver/Whisky 等前缀)→ 不进 canvas
   ├ 承载(AX 接到内容)→ faithful_v2 AX 路
   └ 0承载(canvas)→ canvas_route
       ├ B 短(≤120键)→ canvas_librime:librime 确定性解(0 LLM)→ ocr_correct_llm(1 次 14B,可选 --llm)
       │                  以 OCR 屏幕真值纠同音错字;GPU 占/不开 --llm → 回退 librime(0 LLM)
       └ C 长(>120键)→ canvas_merge(OCR 层级归并,约 5 次 14B)
 → eval/canvas_route_fusion.json(供 faithful_v2 PORTRAIT_CANVAS 读)
```

**LLM 调用量:短 canvas(bucket B)1 次/段 vs 长 canvas(canvas_merge)~5 次/篇**——短路靠击键 librime 挑大梁、本地化更彻底,LLM 只兜底纠错。

**本轮关键技术点(踩过的坑,别重犯)**:

- librime AX 接线已拔(`DECODE_LIBRIME` 默认关,env 可开回历史用);AX 给汉字时 librime 猜字=隐患。
- 承载率 = 逐键看 ±3s 内 AX 有无 commit/submit;`isprintable` 排控制键;`modifiers&7=0` 排 cmd+v;GAP_KEYS=8 并回 commit 空档。
- **canvas OCR 矫正确定性不可行**(选择删/鼠标删 keystroke_log 不记 → 最终态不可重建)→ 改 LLM 判别。
- **LLM 判别三招**:`enable_thinking=False`(否则 token 全花在 `<think>`)+ 证据窗收紧到 span 末(排自指污染)+ few-shot 示例(治 echo)。
- **`browser_url` 字段又漏又过期**(干净帧常 NULL),别当过滤;用 `app_name`+时间窗+内容锚。url 软加分实测会反伤(脏帧反而有 url),不加。

**实测验证**:测试1 `测试测试，canvas`✓全对;wtf `逆天兄弟，好吧`(泥土→逆天 OCR 修对✓,残留删掉的「好吧」=多帧稳定待迭代)。
**整合跑 6/26-6/28 验证中**(`eval/integrated_run_0628.log` / `eval/integrated_0628.md`)。

**剩余待迭代(非阻塞,本轮收)**:① 多帧稳定剔删除内容(去 wtf 的「好吧」)② C 长文 canvas_merge 实跑(本轮 6/26-28 多为短输入,C 少)③ 采集层「文本框焦点」闸(Swift,精准保游戏内聊天)④ 6/25 前历史重构(`PORTRAIT_LIBRIME_DECODE=1`)。⑤ **渐进 IME 草稿态去重漏**(6/26 Safari 表单逐字打「这样的对吗?」:`zhe y`/`这样d`/`这样的对吗`/`这样的对吗?` 四条没合并成一条——拼音态↔汉字态字符串对不上,现有截断/前缀去重不认;修向=未发送草稿同 element+时间相邻、后者更长且前者是其打字前缀→折叠成最终态。和 vos/vcd 过期快照同族)。**✅ 2026-06-29 已修(框清空否决 + 拼音空间折叠),见下节。**

## ✅ 2026-06-29 渐进IME草稿态合并 + 口3校对错字两修(全程 REVIEW_MODE=det,gold 6天 44✓ 1✗ 零回归)

本轮修两类用户标注问题,**5 个原子 commit**,全在 AX 路实验线(faithful_v2/ocr3),不碰采集层/canvas。
gold 基准跑法 = `REVIEW_MODE=det PORTRAIT_LIBRIME_DECODE=1`(旧采集 6 天**必须开 decode=1** 还原当时
decode-on 世界,否则假回归)+ 标准 6 天 + canvas_merged_src。唯一 ✗ = **A10 卖个惨**(librime 词库缺词,预先存在)。

### A. 渐进 IME 草稿态合并(待办⑤,「这样的对吗?」案)

- **现象**:6/26 Safari 表单(同 element_hash 17521502)逐字打「这样的对吗?」,产出 4 条没合并:
  `zhe y`/`这样d`/`这样的dui ma`(口3后→这样的对吗)/`这样的对吗?`。
- **双根因**:① 三道现有闸全靠**字符串前缀/LCS**,拼音态↔汉字态对不上(`这样的dui ma` vs `这样的对吗?`)
  ② DB 真相:4 条**只有 ev2848 有真 submit**,前 3 条只有 commit;但 end_value 都带尾随 `\n`,被
  **「回车背书升格」(jeff chang 案)只认回车击键、不认框清空**误升成 is_send=True → 不是 ~draft → 折叠接不住。
- **修**:
  - `ac2caf7` **渐进草稿态折叠**(faithful_v2 out_f 循环,平行于「中间态草稿折叠」):未发送 `~draft` 前缀态
    折叠进同 bundle ≤15min 更完整态。跨形态用新 helper **`_py_prefix`**(把文本拍平成**字母串**比前缀,
    简拼免疫 `zheyangd⊂zheyangde`、免口3时序 `这样的dui ma` 与 `这样的对吗` 拼音相同);完整度 **`_completeness`**
    按拼音字母长排序(不被拼音残渣字符数骗)。(注:`pyseq`/`seq_in` 是逐位**集合相交**,治不了逐字符ascii vs
    逐音节、简拼声母 d vs 全拼 de,故另起字母串前缀。)
  - `ac91ea3` **折叠审计行遮蔽邮箱**:reason 嵌 survivor 预览 `cv(sup[1])`,survivor 可能是邮箱最终态 →
    P0「全文档」泄漏。预览前先 `re.sub(邮箱→⟨遮蔽⟩)`(EMAIL_PAT 在 line 756 运行时晚于此循环,内联 scrub)。
  - `d3756c4` **回车背书升格加「框清空否决」**(根因修):升格前查**同 element_hash 60s 内后续事件 value
    是否拼音延续本段**(`_py_prefix`,治 d/的)→ 延续=框没清=非真发送,不升格保持 ~draft。真发送(jeff
    chang/yo/生态的)框会清、value 不延续 → 照常升格不回归。`ev['id']` 有,element_hash 靠 JOIN 查。
- **验证**:6/26-28 成品只剩一条「这样的对吗?」;gold 44✓;jeff/yo/生态升格全保住。

### B. 口3 校对引入错字两变体(用户审 gold 逐条发现,同族:`_whole_residue_ocr` 拿 OCR 覆盖了不该覆盖的)

口3 `proofread_tail` 在 base<3 时走 `_whole_residue_ocr`(机器猜首字锚 OCR、整窗替换),丢了正常路的 base 锚保护。

- **今天→今大**(`f83a6b4`,ev523):「今天」是 edit_log **字面 commit**(jint1→今天),OCR 把天误读成大。
  **关键坑:大有多音字读音 `tai`,用户为天打的简拼 `t` 同时兼容大(tai)→ 击键分不开天/大,per-char 击键否决无效**;
  只能靠**来源**。修=把 `base` 传进 `_whole_residue_ocr`,**OCR 候选须保留 commit 的 base 前缀**(今大≠今天则拒)。
- **看看→看M**(`a2a19f8`,ev649):简拼 `k k`→librime 解码看看(base 空真全残渣),OCR 把第二个看误读成英文 M。
  `verify_tail` 只验上「看」(M 是 ASCII 无 m 击键),但 `consumed≥len(L)-1` 仍过,**返回的却是完整 cand「看M」**。
  修=**要求 verify_tail 的 tail 覆盖完整 cand**(未验字符=OCR 噪声拒)。
- **两守卫互补**:今大经 tai 读音全验过、靠**前缀守卫**拦;看M 没全验、靠**整窗守卫**拦。
- **不回归**:`从哪找的`(base 空真全残渣、全验上)仍救回;ocr3 七案例与 HEAD 零 diff。

### ⚠️ 三条新坑(下次别重踩)

1. **发送判定有两层且不一致**:采集层(Swift)用「回车后框清空」(→submit kind);pipeline 的「回车背书升格」
   只认回车击键、**不认框清空** → textarea 换行 `\n` 被误当发送。已加框清空否决,但同类升格逻辑要警惕。
2. **多音字简拼让击键无法分字**:大有 tai 读音 → 简拼 t 分不开天/大。凡「击键背书」判据遇多音字简拼会失效,
   需退到来源(commit vs 机器猜)或屏幕。
3. **`_whole_residue_ocr` 是 OCR 覆盖重灾区**:base<3 才走它、丢了 base 锚保护 + 接受未全验 cand。两道守卫已补,
   但它本质是「整条机器解码时 OCR 当裁判」,任何 OCR 误读都可能进;后续若再出 口3 错字,优先查这条。

产出:`eval/fold_gold_test.md`(6天 gold)/`eval/fold_newdays_test.md`(6/26-28);Obsidian `6.29-*` 两份(已手动反映翻正)。

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
- **复查模式 REVIEW_MODE=det(2026-06-14 裁定:det 明显更好)**:全量跑必带 `REVIEW_MODE=det`。
  llm 会让无屏幕证据的短碎片/微信@残片/粘贴密码涌进成品,且丢确定性 OCR 对证(记得→基地不纠)。
  ⚠️代码默认仍 `llm`(`faithful_v2:206`)没改,跑时务必显式带 det(或哪天改默认)。

## 怎么跑

> ⚠️ **跑前必须先和用户确认**(2026-06-11 立规):全量跑会加载 MLX 14B,用户并行在跑
> event-local-lab(同一块 GPU/统一内存)。实测每轮 26-38 分钟,全 4 天,无抽样模式。
> 离线确定性脚本(screen_audit/compare_gold/不加载模型的回归)不受限。

```bash
cd Tests/writing-capture-extract
# ⚠️ 复查模式必须 REVIEW_MODE=det(用户 2026-06-14 裁定:det 明显优于 llm——
#    llm 会让无屏幕证据的短碎片/微信@残片/粘贴密码涌进成品,且丢掉确定性 OCR 对证(记得→基地不纠))。
# ⚠️ cwd 必须在本目录(脚本 import 本地模块 harness/rebuild/... + redirect 用相对 eval/);
#    后台跑务必 redirect 用绝对路径,否则 cwd 漂移会 EXIT=1 静默没跑(2026-06-14 踩过)。
REVIEW_MODE=det python3 faithful_v2.py    # 全量(14B Phase1≈30-60min);默认4天,PORTRAIT_DAYS 覆盖
# 6 天集成跑(gmail案 v21 那版,canvas 合并源):
# REVIEW_MODE=det PORTRAIT_DAYS=2026-05-27,2026-05-28,2026-05-29,2026-06-03,2026-06-04,2026-06-05 \
#   PORTRAIT_CANVAS=<abs>/eval/canvas_merged_src.json PORTRAIT_OUT=<abs>/eval/v21_product.md python3 faithful_v2.py
python3 ocr3.py                 # 口3七案例回归(H/I/yi x/te d/yo/k n/卖个惨)
python3 compare_gold.py <产出路径>   # gold 40 项 + P0 隐私;det 跑应 41✓ 满分(含 B13/B14/密码 P0 探针)
```

对照检查:`compare_gold.py` 自动判分(gold 在脚本内);或用 `输出成品-改前的pipeline-修复标注版.md` 标注逐条 grep `### 🆕` 段(排除审计段引用的旧文本)。
