#!/usr/bin/env python3
"""阶段四 · 确定性 patch 验证器(规范 §5.2/§5.3/§5.4)。**不相信模型自报**。

铁律:模型自报来源 ≠ 证据;每条 replacement 字符都要能追溯到击键(英文)/拼音候选(中文)/
commit(标点),否则拒绝整个 patch。verification_passed ≠ completeness(分别计算)。
"""
import hashlib
from patch import Patch

def skeleton_hash(s: str) -> str:
    return hashlib.sha256((s or "").encode("utf-8")).hexdigest()[:16]

def _ranges_overlap(a, b):
    (s1, e1), (s2, e2) = a, b
    if s1 == e1 and s2 == e2:        # 两个同点插入 = 冲突
        return s1 == s2
    return max(s1, s2) < min(e1, e2)

def _is_latin(c): return c.isascii() and c.isalpha()
def _is_cjk(c): return '一' <= c <= '鿿'


# ---- §5.2 单 patch 九条验证 ----
def verify_patch(patch: Patch, group: dict):
    """返回 (ok: bool, failed_rule: str|None)。任一规则失败 → 拒绝整个 patch(规则9)。"""
    sk = group["skeleton"]
    ks = group.get("keystrokes", [])

    # 1. 引用事件真实存在且属于本候选消息组
    if not set(patch.supporting_event_ids) <= set(group.get("event_ids", [])):
        return False, "rule1_event_not_in_group"

    # 2. 击键区间真实存在、时间合法、不跨 confirmed message boundary
    for i in patch.supporting_keystrokes:
        if i < 0 or i >= len(ks):
            return False, "rule2_keystroke_missing"
    seg = group.get("segment_range")
    bnds = group.get("boundaries", [])
    if patch.supporting_keystrokes:
        used = [ks[i]["ts"] for i in patch.supporting_keystrokes]
        lo, hi = min(used), max(used)
        if seg and not (seg[0] <= lo and hi <= seg[1]):
            return False, "rule2_keystroke_out_of_segment"
        if any(lo < b < hi for b in bnds):
            return False, "rule2_cross_boundary"

    # 3. replace_range + 锚点在骨架中唯一、稳定定位
    s, e = patch.replace_range
    if not (0 <= s <= e <= len(sk)):
        return False, "rule3_range_oob"
    located = patch.anchor_before + sk[s:e] + patch.anchor_after
    at = s - len(patch.anchor_before)
    if at < 0 or sk[at:at + len(located)] != located:
        return False, "rule3_anchor_mismatch"
    if located and sk.count(located) != 1:
        return False, "rule3_not_unique"

    # 4. 不删除没有明确删除证据的骨架内容
    removed = patch.removed_text(sk)
    if patch.operation == "inserted":
        if s != e:
            return False, "rule4_insert_with_removal"
    else:  # replaced
        if removed and removed not in group.get("deletes", []):
            return False, "rule4_delete_without_evidence"

    # 5/6/8. 每个 replacement 字符可追溯到证据(英文顺序/中文候选/标点来自commit),上下文不作来源
    ok, reason = _verify_sources(patch, group)
    if not ok:
        return False, reason

    # 7. 已明确删除且未重新输入的内容不得进入结果
    reinput = group.get("reinput", [])
    for d in group.get("deletes", []):
        if d and d not in reinput and d in patch.replacement_text:
            return False, "rule7_deleted_content_resurfaced"

    return True, None


def _verify_sources(patch: Patch, group: dict):
    """规则 5(英文按击键顺序)/ 6(中文按拼音候选)/ 8(上下文不作文本来源)。"""
    ks = group.get("keystrokes", [])
    typed = [ks[i]["char"] for i in patch.supporting_keystrokes
             if 0 <= i < len(ks) and not ks[i]["is_backspace"] and _is_latin(ks[i]["char"])]
    cands = patch.pinyin_candidates                 # per-patch:librime 对本 patch 源拼音的逐字候选
    commits_concat = "".join(group.get("commits", []))
    anchors = patch.anchor_before + patch.anchor_after
    li = ci = 0
    for ch in patch.replacement_text:
        if _is_latin(ch):                            # 规则5:英文按真实字母击键顺序,不查词典
            if li >= len(typed) or typed[li].lower() != ch.lower():
                return False, "rule5_english_not_keystroke_ordered"
            li += 1
        elif _is_cjk(ch):                            # 规则6:中文每字过对应音节候选
            if ci >= len(cands) or ch not in cands[ci]:
                return False, "rule6_cjk_not_in_candidate"
            # 规则6b 反幻觉(可选):中文必须有真实「中文 commit」背书,不许从英文/latin 重解成中文
            #   (gmail 只有 latin commit → 购买了 被拒;海报有 commit '海报' → 合法)
            if group.get("require_cjk_commit_backed") and ch not in "".join(group.get("commits", [])):
                return False, "rule6b_cjk_not_committed"
            ci += 1
        elif ch.isspace():
            continue
        else:                                        # 规则8:标点/数字必须在 commit/锚点里,不能凭空来
            if ch not in commits_concat and ch not in anchors:
                return False, "rule8_unsourced_char"
    return True, None


# ---- §5.3 多 patch:先全验、查冲突、倒序应用、骨架哈希二次确认 ----
def _detect_conflicts(patches):
    bad = set()
    for i in range(len(patches)):
        for j in range(i + 1, len(patches)):
            a, b = patches[i], patches[j]
            if _ranges_overlap(a.replace_range, b.replace_range):
                bad.add(i); bad.add(j)
            if a.source_range and b.source_range and _ranges_overlap(a.source_range, b.source_range):
                bad.add(i); bad.add(j)
    return bad

def verify_and_apply(patches, group):
    """规范 §5.3。返回 dict:text / applied / rejected / verification_passed / skeleton_stable。"""
    sk = group["skeleton"]
    h0 = skeleton_hash(sk)
    # 1. 先验证全部,不边验边应用
    verdicts = [(p, *verify_patch(p, group)) for p in patches]
    passed_idx = [k for k, (p, ok, r) in enumerate(verdicts) if ok]
    rejected = [{"patch": p, "reason": r} for (p, ok, r) in verdicts if not ok]
    # 2/3. 冲突检测:有冲突的 patch 全部拒绝,不自行选一个
    passed = [verdicts[k][0] for k in passed_idx]
    conf = _detect_conflicts(passed)
    if conf:
        rejected += [{"patch": passed[k], "reason": "conflict"} for k in sorted(conf)]
        passed = [p for k, p in enumerate(passed) if k not in conf]
    # 4. 通过的按骨架位置从后向前应用(用原始骨架坐标,前缀不受影响)
    ordered = sorted(passed, key=lambda p: p.replace_range[0], reverse=True)
    text = sk
    stable = True
    for p in ordered:
        s, e = p.replace_range
        # 5. 应用前二次确认:原始骨架的锚点/区间未变(骨架未被前面的应用动过该位置)
        located = p.anchor_before + sk[s:e] + p.anchor_after
        at = s - len(p.anchor_before)
        if sk[at:at + len(located)] != located or skeleton_hash(sk) != h0:
            stable = False
            continue
        text = text[:s] + p.replacement_text + text[e:]
    # verification_passed:采用文本只由通过验证的 patch 构成(从不应用未验证 patch)→ 恒为采用文本无证据外修改
    verification_passed = stable and all(verify_patch(p, group)[0] for p in passed)
    return {
        "text": text, "applied": passed, "rejected": rejected,
        "verification_passed": verification_passed, "skeleton_stable": stable,
    }


# ---- §5.4 completeness 独立计算 ----
def calculate_cross_source_coverage(group, text):
    """采用文本被 AX 骨架 / commit 流 / 击键结果互相覆盖的比例(0~1)。首版:文本里能在
    commit 流或骨架里找到的字符占比。"""
    if not text:
        return 1.0
    src = "".join(group.get("commits", [])) + group.get("skeleton", "")
    hit = sum(1 for c in text if c in src or c.isspace())
    return round(hit / len(text), 3)

def find_unconsumed_message_evidence(group, applied):
    """未被任何 patch 消费、又不在骨架里、却可能属于本消息的输入证据(commit)。返回列表。"""
    consumed = set()
    for p in applied:
        consumed.update(p.supporting_commits)
    sk = group.get("skeleton", "")
    out = []
    for idx, c in enumerate(group.get("commits", [])):
        if idx in consumed:
            continue
        if c and c not in sk:
            out.append(c)
    return out

def detect_capture_gap_or_race(group):
    """已知采集缺口/竞速。首版:group 显式标 capture_gap,或 AX 骨架明显短于 commit 流(IME 尾巴截断)。"""
    if group.get("capture_gap"):
        return True
    commits_len = sum(len(c) for c in group.get("commits", []))
    return len(group.get("skeleton", "")) * 2 < commits_len      # 骨架不到 commit 一半 → 疑似截断

def calculate_completeness(group, result, applied, rejected):
    """规范 §5.4:verification 全过 ≠ complete。独立判断。"""
    has_boundary = bool(group.get("boundaries"))
    full_transition = bool(group.get("post_send_transition_complete"))
    coverage_ok = calculate_cross_source_coverage(group, result) >= 0.95
    no_unconsumed = not find_unconsumed_message_evidence(group, applied)
    no_gap = not detect_capture_gap_or_race(group)
    no_rejected = len(rejected) == 0
    if has_boundary and full_transition and coverage_ok and no_unconsumed and no_gap and no_rejected:
        return "complete"
    if not (result or "").strip():
        return "unrecoverable"
    return "partial"
