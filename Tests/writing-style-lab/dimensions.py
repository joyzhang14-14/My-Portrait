"""维度定义 —— 一 agent 一维度一信息。

每个维度 = 一个窄问题 + 它专属的确定性特征切片 + 一档模型。orchestrator 对
**每个 app-group** 跑每个维度(所以维度⑦"按 app/场景/对象分别分析"由分组天然实现,
不单列 agent)。小模型只做"给已量好的信号起名/确认",不做"从头发现"。

model tier → 实际模型(可被 run.py --model 全局覆盖成一个):
  small = Qwen3-4B-4bit    (确定性算完,LLM 只贴标签)
  mid   = Qwen3-8B-4bit
  big   = Qwen3-14B-4bit   (中文语序/情感这种真判断)
"""

TIER_MODELS = {
    "small": "mlx-community/Qwen3-4B-4bit",
    "mid":   "mlx-community/Qwen3-8B-4bit",
    # ⚠️ big 已被 A/B 实测淘汰(14B:3/6 崩 JSON、5-18s 最慢、message_structure 漏判),
    # 现在**没有任何维度用 big**。保留只为 --model 显式对照。16GB 部署只用 small/mid。
    "big":   "mlx-community/Qwen3-14B-4bit",
}

# 共享输出契约 —— 所有维度同一个 schema,便于聚合/对比。
OUTPUT_CONTRACT = """
OUTPUT — ONLY this JSON object, no prose, no markdown fence, third person ("the user"):
{
  "present":    true | false,   // 这个上下文里,这个维度有没有值得记的、有证据的稳定习惯
  "label":      "短标题(中文,≤12字)",
  "pattern":    "一句话描述这个习惯(中文)",
  "evidence":   ["引用的原话或具体现象1", "现象2"],
  "confidence": "high" | "medium" | "low"
}
Rules:
- present=false 时其余字段可留空/空数组。宁缺毋滥:没有稳定证据就 false,别硬凑。
- evidence 必须具体:引一句原话,或指出一个数字/现象。禁止"用户写得随意"这种空话。
"""


def _sys(body: str) -> str:
    return body.strip() + "\n" + OUTPUT_CONTRACT


DIMENSIONS = [
    # ① 消息结构 —— 中文语序判断。实测(verify_v2)8B 加 few-shot 后能认出
    # 倒装/宾语前置/连动;而 14B 恰在本维度漏判(present=false)→ 用 mid(8B)。
    {
        "key": "message_structure", "name": "消息结构", "tier": "mid",
        "needs_ks": False,
        "feature_keys": ["rhetorical_hint", "final_particles"],
        "system": _sys("""
You detect ONE aspect of the user's writing in ONE app/context: habitual SENTENCE /
MESSAGE STRUCTURE — word order and clause shape only, NOT tone, NOT topic.

Detect a RECURRING structural habit. PREFER a SPECIFIC category over the generic
"additive" whenever a specific one genuinely recurs. Categories (with anchor examples;
detect the analogous word-order habit in ANY language, examples are just anchors):
  - inversion (predicate/adverbial fronted before subject)
  - object-fronting / topic-comment (object or topic placed first)
  - serial-verb (two+ verbs chained without connective)
  - rhetorical question (a question used to assert, not to ask)
  - afterthought / post-posed supplement (a piece tacked on AFTER the main clause)
  - additive burst (short independent clauses appended one after another) — the FALLBACK

The feature line gives weak hints (rhetorical_hint / final_particles); confirm from the
actual text — a hint alone is NOT evidence. Only present=true if the pattern RECURS across
messages; quote the specific sentences. If several habits appear, pick the most DISTINCTIVE
one (a specific category beats the generic "additive"). Label in the user's own language.

FEW-SHOT (map the form, not the topic):
① 「这个我知道」「作业我写完了」「那个我早删了」
   → {"present":true,"label":"宾语前置","pattern":"habitually fronts the object/topic before the subject-verb","evidence":["这个我知道","作业我写完了"],"confidence":"high"}
② 「走吧我们」「先睡了我」「冷死了今天」
   → {"present":true,"label":"倒装","pattern":"puts predicate/adverbial before the subject","evidence":["走吧我们","冷死了今天"],"confidence":"high"}
③ 「去买菜做饭」「拿去用」「起来看看」
   → {"present":true,"label":"连动结构","pattern":"chains multiple verbs in one clause without connectives","evidence":["去买菜做饭","起来看看"],"confidence":"medium"}
④ 「逆天」「取长补短啊」「说实话」「那你问Claude啊」 (no special word order, just short clauses in a row)
   → {"present":true,"label":"追加式短句","pattern":"appends short independent clauses one after another; no marked word order","evidence":["逆天","那你问Claude啊"],"confidence":"medium"}
"""),
    },
    # ② 语气 / 情感基调 —— 内容判断。实测(tone_fewshot_ab)8B 会把调侃误判成
    # "客观中立";加 few-shot + "话题≠语气"铁律后 8B 追平 30B → 用 mid(8B)即可。
    {
        "key": "tone", "name": "语气", "tier": "mid",
        "needs_ks": False, "feature_keys": [],
        "system": _sys("""
You detect ONE aspect of the user's writing in ONE app/context: TONE / AFFECT — the
emotional/attitudinal lean, NOT the topic and NOT sentence structure.

⚠️ CORE RULE: TOPIC ≠ TONE. A technical or serious TOPIC does NOT make the TONE
"neutral/objective". Judge tone ONLY from register markers:
  - net-slang / hyperbole (逆天, 笑死, 绝了, yyds, "insane", "dead") → playful / teasing
  - sentence-final particles & colloquial tails (啊, 呗, 嘛, 哈, "lol", "lmao") → casual / warm
  - short jabs, self-deprecation, jokes, rhetorical questions → playful / bantering
  - plain full sentences + problem-solving / analytical wording, no slang, no emotion → earnest / rational
  - dry sneer, "of course it broke" resignation → cynical
Do NOT default to "neutral/objective" just because the topic is technical — that is almost
always a MISS. "Neutral" is only valid when the WHOLE batch has zero register markers.

Axes (pick the closest): cynical↔earnest · playful↔serious · aggressive↔gentle · cold↔warm.
Label in the user's own language.

FEW-SHOT (map register markers, ignore the topic):
① 「逆天」「笑死 这也行」「那你问Claude啊」「取长补短啊」
   → {"present":true,"label":"轻松调侃","pattern":"casual net-slang and short jabs, teasing register even when discussing tech","evidence":["逆天","笑死 这也行","那你问Claude啊"],"confidence":"high"}
② 「这个 pipeline 用了 4 层 LLM 过滤,你觉得有什么可以优化的?」「AX 抓输入有时效性问题」
   → {"present":true,"label":"认真求解","pattern":"focused, plain wording, actively seeks evaluation; no slang, no emotion","evidence":["你觉得有什么可以优化的?","AX 抓输入有时效性问题"],"confidence":"high"}
③ 「又崩了,意料之中」「能用就行,别指望它」
   → {"present":true,"label":"愤世嫉俗","pattern":"resigned, look-down tone; pessimistic expectations","evidence":["又崩了,意料之中","别指望它"],"confidence":"medium"}
"""),
    },
    # ③ 输入习惯 —— 确定性算完,LLM 只命名,给 4B
    {
        "key": "input_habits", "name": "输入习惯", "tier": "small",
        "needs_ks": True,
        "feature_keys": ["ime_share", "ime_inferred", "input_source_seen",
                         "ime_switches_total", "ks_per_min_avg",
                         "gap_median_ms_avg", "mean_latin_run_avg",
                         "digit_picks_total", "pause_count_total"],
        "system": _sys("""
You NAME the user's INPUT habit in ONE app/context from ALREADY-MEASURED numbers. Do NOT
guess from the Chinese text — trust the feature line:
  - ime_share: 输入法占比(仅当 input_source_seen=true 可信),如 {"pinyin":0.6,"english":0.4}。
  - input_source_seen=false 时 ime_share 为空,改看 ime_inferred(从节奏推断:likely_pinyin=
    有选词数字键+短拉丁 run;likely_english=长 run 无选词)。此时结论 confidence 最多 medium。
  - ime_switches_total: 一句话中途切输入法的次数;>0 且不小 = "句中频繁切输入法"习惯。
  - ks_per_min_avg / gap_median_ms_avg: 打字速度与节奏(gap 小=连打,大且 pause 多=边想边打)。
  - mean_latin_run_avg: 拉丁 run 平均长(拼音音节≈2-6;明显更长=英文单词直入)。
  - digit_picks_total: 选词数字键次数(拼音特征)。
Turn these numbers into a plain-language habit. present=true only if the numbers show a
clear, non-trivial pattern (enough keystrokes to matter). Put the key numbers in evidence.
"""),
    },
    # ④ 修改习惯 —— edit_log 时序,给 8B
    {
        "key": "editing_habits", "name": "修改习惯", "tier": "mid",
        "needs_ks": False,
        "feature_keys": ["one_shot_rate", "delete_ratio_avg", "max_delete_run",
                         "send_total", "backspace_ratio_avg"],
        "system": _sys("""
You analyze the user's EDITING rhythm in ONE app/context from the timing numbers + edit_log:
  - one_shot_rate: 一次成稿(几乎不删)的比例。高 = "想好再打"。
  - delete_ratio_avg / max_delete_run: 删改密度。max_delete_run 大 = "写完一整段再回头批量纠错";
    零散小删多 = "边写边实时纠错"。
  - send_total: 发送/提交次数(消息切分线索)。
Decide whether the user is a 批量纠错(finish-then-fix) or 实时纠错(fix-as-you-type) type,
or 一次成稿(one-shot). Note: 句首补词(如打完在最前面加 please)这类需要光标位置,本实验室
v1 暂无该信号 —— 若无证据就不要断言。Quote the numbers/patterns as evidence.
"""),
    },
    # ⑤ 标点与排版 —— 确定性字符统计,LLM 命名,给 4B
    {
        "key": "punctuation_layout", "name": "标点与排版", "tier": "small",
        "needs_ks": False,
        "feature_keys": ["ending_dist", "pangu_ratio_avg", "send_total"],
        "system": _sys("""
You NAME the user's PUNCTUATION / LAYOUT habit in ONE app/context from measured stats:
  - ending_dist: 每条消息句尾字符分布。none 占多 = "结尾不加句号"(聊天常见语用);
    cjk_period 多 = 习惯用「。」。对比不同上下文差异很有意义。
  - pangu_ratio_avg: 中英文之间加空格(盘古之白)的比例。None=无中英边界;接近1=总加;0=从不。
    ⚠️ 仅在键盘背书(source=ax_cleaned)记录上可信;OCR 重建文本的空格不可信,证据里注明。
  - send_total: 消息切分(一个意思拆成几条发)的线索。
Turn stats into a habit. present=true only for a clear tendency. Put the numbers in evidence.
"""),
    },
    # ⑥ 写作习惯(流线/流式/跳跃)—— 节奏+时序,给 8B
    {
        "key": "writing_mode", "name": "写作习惯", "tier": "mid",
        "needs_ks": False,
        "feature_keys": ["one_shot_rate", "delete_ratio_avg", "gap_median_ms_avg",
                         "pause_count_total", "ks_per_min_avg"],
        "system": _sys("""
You classify the user's COMPOSITION mode in ONE app/context from rhythm numbers:
  - 流线型 streamlined: 一气呵成往下写(one_shot_rate 高、delete_ratio 低、gap 均匀)。
  - 流式型 stream-of-consciousness: 连续不断地输出(ks_per_min 高、pause 少、篇幅长)。
  - 跳跃型 jumping: 写写停停、回头改中间(pause 多、delete 高)。注意:真正的"改中间"需要
    光标位置信号,本实验室 v1 无 —— 只能从 pause+delete 给出"疑似",confidence 相应压低。
Pick the dominant mode with evidence from the numbers. present=false if rhythm is ambiguous.
"""),
    },
]

DIM_BY_KEY = {d["key"]: d for d in DIMENSIONS}
