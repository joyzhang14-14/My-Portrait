#!/usr/bin/env python3
"""阶段五 · #40 整条重建的触发判定 + 回退 + 击键去重(规范 §6,确定性、零模型)。

铁律:
- 仅在**明确数据不一致**时触发重建(§6.1),消息长度只加风险分、不单独触发。
- 所有重建走阶段四验证器(见 recon.py);无法安全应用 → 回退 captured,标 partial/unrecoverable。
- 不调用任何云端模型。
"""

def _has_cjk(s): return any("一" <= c <= "鿿" for c in (s or ""))
def _is_latin(c): return c.isascii() and c.isalpha()


def pinyin_residue_spans(skeleton: str):
    """**只认尾巴残渣**:最后一个 CJK 之后的 latin 连续段 = IME 尾巴截断的签名(#41)。
    中间的合法英文(header/ai/focus/OCR)不算残渣;纯 latin 无 CJK(gmail)也不算(那是 #42)。
    返回 [(start, end, text)](至多一段尾巴)。"""
    if not _has_cjk(skeleton):
        return []
    last_cjk = max(i for i, c in enumerate(skeleton) if "一" <= c <= "鿿")
    tail = skeleton[last_cjk + 1:]
    seg = tail.strip()
    if len(seg) >= 2 and all(_is_latin(c) or c == " " for c in seg):
        start = skeleton.find(seg, last_cjk + 1)
        return [(start, start + len(seg), seg)]
    return []


def reconstruction_triggered(group):
    """§6.1:仅在明确数据不一致时触发。返回 (triggered: bool, reason: str)。长度不在内。"""
    sk = group.get("skeleton", "")
    # ① AX 文本无法覆盖已确认属于本消息的 commit 流(某中文 commit 不在骨架)
    for c in group.get("commits", []):
        if _has_cjk(c) and c not in sk:
            return True, "ax_misses_committed_chinese"
    # ② 击键/commit 支持某段,但 AX 中段缺失(骨架里有拼音残渣未转换)
    if pinyin_residue_spans(sk):
        return True, "pinyin_residue_uncovered"
    # ③ 多个连续事件存在可证明属于同一消息的互补片段(跨事件分析给出)
    if group.get("cross_event_fragments"):
        return True, "cross_event_complementary"
    # ④ 逐段重建无法对齐,且未对齐区段有可靠输入证据
    if group.get("misaligned_with_evidence"):
        return True, "misaligned_reliable_evidence"
    return False, "no_inconsistency"


def risk_score(group):
    """长度只贡献风险分(advisory),**绝不**单独触发重建。供排序/审计,不进触发判定。"""
    return len(group.get("skeleton", "")) // 20


def dedupe_keystrokes(event_keystroke_lists):
    """§6.2:去除重叠事件导致的击键重复消费。按 (ts, char, is_backspace) 去重,按 ts 排序。"""
    seen, out = set(), []
    for ks in event_keystroke_lists:
        for k in ks:
            key = (k.get("ts"), k.get("char"), k.get("is_backspace"))
            if key in seen:
                continue
            seen.add(key)
            out.append(k)
    return sorted(out, key=lambda k: (k.get("ts") is None, k.get("ts")))


def decide_outcome(group, recon):
    """§6.2 回退:给定重建结果(recon.py 的 reconstruct() 返回),决定最终 text + completeness。
    - 重建成功且全覆盖 → complete;成功但有未覆盖证据 → partial。
    - 重建失败(验证器拒/无法安全应用)→ 回退 captured:有残文→partial;无残文→unrecoverable。
    绝不把回退/残缺伪装成 complete。"""
    sk = group.get("skeleton", "")
    if recon.get("ok"):
        text = recon["text"]
        # 完整性独立判:重建后是否还有未消费的中文 commit 没进结果
        uncovered = [c for c in group.get("commits", []) if _has_cjk(c) and c not in text]
        comp = "partial" if uncovered else "complete"
        return {"text": text, "completeness": comp, "via": recon.get("proposal", {}).get("via", "model"),
                "fallback": False}
    # 无法安全应用 → 回退 captured
    if (sk or "").strip():
        return {"text": sk, "completeness": "partial", "fallback": True, "why": recon.get("why")}
    return {"text": None, "completeness": "unrecoverable", "fallback": True, "why": recon.get("why")}
