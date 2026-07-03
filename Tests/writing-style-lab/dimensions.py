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
    # ① 消息结构 —— 中文语序判断,给 14B
    {
        "key": "message_structure", "name": "消息结构", "tier": "big",
        "needs_ks": False,
        "feature_keys": ["rhetorical_hint", "final_particles"],
        "system": _sys("""
You analyze ONE aspect of the user's writing in ONE app/context: SENTENCE / MESSAGE
STRUCTURE (句法形状). Look ONLY at word order and clause shape, not tone or content.
Detect any consistent structural habit among:
  - 倒装 inversion:「走吧我们」「冷死了今天」(谓语/状语提前)
  - 反问 rhetorical question:「这不明摆着吗」「有啥用」
  - 追加式 additive/append:短句一条接一条地补
  - 后置补说 afterthought:「我去了，昨天」句末补成分
  - 宾语前置 object fronting:「这个我知道」「作业我写完了」
  - 连动结构 serial-verb:「去买菜做饭」「拿去用」
The feature line gives light hints (rhetorical_hint / final_particles). Confirm from the
actual text; a hint alone is NOT evidence. Only emit present=true for a pattern that
RECURS across the messages, and quote the specific sentences.
"""),
    },
    # ② 语气 / 情感基调 —— 内容判断,给 14B
    {
        "key": "tone", "name": "语气", "tier": "big",
        "needs_ks": False, "feature_keys": [],
        "system": _sys("""
You analyze ONE aspect of the user's writing in ONE app/context: TONE / AFFECT (语气·态度).
This is about emotional/attitudinal lean, NOT formality-of-structure. Detect a consistent
attitude among axes like:
  - 愤世嫉俗 cynical ↔ 真诚 earnest
  - 轻松愉快 lighthearted/playful ↔ 严肃 serious   (humor, 「哈哈」, exclamation, emoji, 自嘲)
  - 攻击/直冲 aggressive ↔ 温和/委婉 gentle
  - 冷淡疏离 cold ↔ 亲近热情 warm
Only emit present=true when a stable lean shows across multiple messages; quote 2-3 phrases
as evidence. Do NOT restate content; name the attitude.
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
