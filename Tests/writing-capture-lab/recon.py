#!/usr/bin/env python3
"""阶段四 · #41/#42 重建 harness —— 把三条腿拼起来:
  真库案例 → MessageGroup(骨架 + 证据 + librime 候选)
  → Qwen3-1.7B(小 MLX 模型)提"这段残渣本来是什么"(不直接替换整条)
  → harness 确定性建 Patch → §5 验证器(含 rule6b 反幻觉)→ 重建文本。
模型可能幻觉,但验证器(rule5 英文按击键 / rule6 中文按候选 / rule6b 中文须 commit 背书)把关。
跑:python3 recon.py
"""
import json, re, time
from rime_cands import candidates
from patch import Patch
from verifier import verify_patch

MODEL_ID = "mlx-community/Qwen3-1.7B-4bit"
_M = None
def _model():
    global _M
    if _M is None:
        from mlx_lm import load
        _M = load(MODEL_ID)
    return _M

SYSTEM = (
    "你是输入采集重建器。屏幕抓到的文本常把用户打的内容截断、或留成没转换的拼音/英文残渣。"
    "给你:残渣段、实际击键字母、已提交片段。判断这段残渣**本来是什么**,以及它是"
    "**英文**(英文单词,按字母拼)还是**中文**(拼音选字)。严格只依据证据,不要凭上下文编造内容。"
    '只输出一行 JSON:{"reconstruction":"正确文本","kind":"english 或 chinese"} —— 不要任何解释。'
)

def propose(group):
    from mlx_lm import generate
    model, tok = _model()
    hint = candidates(group["pinyin"], 8) if group.get("pinyin") else []
    u = (f"残渣段(**只重建这一段**,别回显整句): {group['residue']!r}\n"
         f"这段的实际击键字母: {group['pinyin']!r}\n"
         f"附近已提交的中文片段: {group['commits']}\n"
         f"若这段是中文拼音,librime 给的候选: {hint}\n"
         f"判断:这段字母是**英文单词**(如 gmail/notebook)还是**中文拼音**(要选字)?\n"
         f'只输出这一段应该是的样子:英文→原英文单词;中文→从候选里选对的字。')
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": u}]
    text = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
    out = generate(model, tok, prompt=text, max_tokens=120, verbose=False)
    m = re.search(r"\{[^{}]*\}", out, re.S)
    if not m:
        return None, out
    try:
        return json.loads(m.group(0)), out
    except json.JSONDecodeError:
        return None, out

def build_patch(group, proposal):
    """把模型的语义提议确定性地变成一个带证据的 Patch(锚点/区间/候选都由 harness 算)。"""
    sk, seg = group["skeleton"], group["residue"]
    recon = proposal.get("reconstruction", "")
    s = sk.find(seg) if seg else len(sk)
    if s < 0:
        return None
    e = s + len(seg)
    cjk_n = sum(1 for c in recon if "一" <= c <= "鿿")
    allowed = set("".join(candidates(group["pinyin"], 20))) if (cjk_n and group.get("pinyin")) else set()
    return Patch(
        replace_range=(s, e), replacement_text=recon,
        operation="replaced" if seg else "inserted",
        anchor_before=sk[max(0, s - 2):s], anchor_after=sk[e:e + 2],
        source_range=(0, len(group["keystrokes"])),
        supporting_event_ids=group["event_ids"],
        supporting_keystrokes=list(range(len(group["keystrokes"]))),
        supporting_commits=list(range(len(group["commits"]))),
        pinyin_candidates=[allowed] * cjk_n,
    )

def commit_match(group):
    """确定性:若 librime 对该拼音的候选里有"已提交的中文词",直接用它(高置信,免模型同音字幻觉)。"""
    if not group.get("pinyin"):
        return None
    committed = "".join(c for c in group["commits"] if any("一" <= ch <= "鿿" for ch in c))
    for cand in candidates(group["pinyin"], 20):
        if cand and all("一" <= ch <= "鿿" for ch in cand) and cand in committed:
            return cand
    return None

def reconstruct(group):
    # ① 确定性 commit-match 优先(海报这类已提交但被截断的尾巴)
    cm = commit_match(group)
    if cm:
        proposal, raw = {"reconstruction": cm, "kind": "chinese", "via": "commit-match"}, ""
    else:
        # ② 没 commit 背书 → 小模型提议(gmail 这类英文 / 未提交拼音尾巴),验证器把关
        proposal, raw = propose(group)
    if proposal is None:
        return {"ok": False, "why": "模型输出非合法JSON", "raw": raw[:160], "text": group["skeleton"]}
    patch = build_patch(group, proposal)
    if patch is None:
        return {"ok": False, "why": "残渣段不在骨架", "proposal": proposal, "text": group["skeleton"]}
    ok, reason = verify_patch(patch, group)
    if not ok:
        return {"ok": False, "why": f"验证器拒绝: {reason}", "proposal": proposal, "text": group["skeleton"]}
    s, e = patch.replace_range
    text = group["skeleton"][:s] + patch.replacement_text + group["skeleton"][e:]
    return {"ok": True, "proposal": proposal, "text": text, "reason": "通过验证器"}


def ks(letters, t0=100, step=10):
    return [{"ts": t0 + i * step, "char": c, "is_backspace": False} for i, c in enumerate(letters)]

# ---- 两个真实案例(从 ev1132 / ev907 抽取)----
# #42 gmail:用户逐字打 gmail,box='g mai l'(latin commit,无中文 commit)。正确=gmail,幻觉=购买了。
GMAIL = {
    "skeleton": "g mai l", "residue": "g mai l", "pinyin": "gmail", "typed": "gmail",
    "event_ids": [1132], "commits": ["ge", " ma", "i l"], "deletes": ["g mai l"], "reinput": [],
    "keystrokes": ks("gmail"), "boundaries": [], "segment_range": [0, 10_000],
    "require_cjk_commit_backed": True,
}
# #41 海报尾巴:AX 把尾巴留成拼音 'haibao',用户其实提交了 '海报'(中文 commit 背书)。
HAIBAO = {
    "skeleton": "介绍的haibao", "residue": "haibao", "pinyin": "haibao", "typed": "jieshaodehaibao",
    "event_ids": [907], "commits": ["介绍的", "海报"], "deletes": ["haibao"], "reinput": [],
    "keystrokes": ks("haibao"), "boundaries": [], "segment_range": [0, 10_000],
    "require_cjk_commit_backed": True,
}

def show(name, group, expect_must_not=None):
    print(f"\n{'='*60}\n【{name}】骨架={group['skeleton']!r}  击键={group['typed']!r}  commit={group['commits']}")
    t = time.time()
    r = reconstruct(group)
    print(f"  模型提议: {r.get('proposal')}")
    print(f"  验证器: {r.get('reason') or r.get('why')}")
    print(f"  ▶ 重建结果: {r['text']!r}   ({time.time()-t:.1f}s)")
    if expect_must_not:
        leaked = expect_must_not in r["text"]
        print(f"  反幻觉检查: {expect_must_not!r} {'❌ 泄漏!' if leaked else '✓ 未出现'}")
    return r

if __name__ == "__main__":
    print("加载 Qwen3-1.7B-4bit...")
    _model()
    show("#42 gmail 反幻觉", GMAIL, expect_must_not="购买了")
    show("#41 海报尾巴重建", HAIBAO)
