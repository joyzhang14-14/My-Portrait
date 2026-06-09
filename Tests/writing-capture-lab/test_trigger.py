#!/usr/bin/env python3
"""阶段五验收测试(确定性、零模型)。失败返回非零退出码。
覆盖:#40 触发四条件 / 长度不单独触发 / gmail(纯英文)不算拼音残渣 / 重叠事件击键去重 /
回退正确标 partial·unrecoverable 不伪装 complete。
(「重建只出 patch、过验证器、不产生无证据新增」由 verifier.py + test_verifier + recon.py 保证。)"""
import sys
from trigger import (reconstruction_triggered, risk_score, dedupe_keystrokes,
                     decide_outcome, pinyin_residue_spans)

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

print("=== 1. #40 触发四条件(§6.1)===")
# ① AX 漏了已提交中文
g1 = {"skeleton": "介绍的", "commits": ["介绍的", "海报"]}   # 海报 没进骨架
t, r = reconstruction_triggered(g1)
check("AX 漏已提交中文 → 触发", t and r == "ax_misses_committed_chinese")
# ② 拼音残渣
g2 = {"skeleton": "介绍的haibao", "commits": ["介绍的"]}
t, r = reconstruction_triggered(g2)
check("拼音残渣未转换 → 触发", t and r == "pinyin_residue_uncovered")
# ③ 跨事件互补片段
t, r = reconstruction_triggered({"skeleton": "完整", "commits": ["完整"], "cross_event_fragments": True})
check("跨事件互补片段 → 触发", t and r == "cross_event_complementary")
# ④ 逐段重建无法对齐 + 可靠证据
t, r = reconstruction_triggered({"skeleton": "完整", "commits": ["完整"], "misaligned_with_evidence": True})
check("逐段无法对齐+可靠证据 → 触发", t and r == "misaligned_reliable_evidence")

print("=== 2. AX 覆盖完整 → 不触发(哪怕很长)===")
long_ok = {"skeleton": "我" * 200, "commits": ["我" * 200]}   # 很长但 AX 全覆盖
t, r = reconstruction_triggered(long_ok)
check("长但全覆盖 → 不触发", (not t) and r == "no_inconsistency")
check("长度只进风险分(>0)、不触发", risk_score(long_ok) > 0 and not reconstruction_triggered(long_ok)[0])

print("=== 3. gmail(纯英文、无CJK)不算拼音残渣(那是 #42 不是 #40)===")
check("'g mai l' 无 CJK → 残渣为空", pinyin_residue_spans("g mai l") == [])
check("纯英文骨架不触发 #40", not reconstruction_triggered({"skeleton": "g mai l", "commits": ["ge", " ma"]})[0])

print("=== 4. 重叠事件击键去重(§6.2)===")
e1 = [{"ts": 100, "char": "h", "is_backspace": False}, {"ts": 110, "char": "a", "is_backspace": False}]
e2 = [{"ts": 110, "char": "a", "is_backspace": False}, {"ts": 120, "char": "i", "is_backspace": False}]  # ts110 重叠
dd = dedupe_keystrokes([e1, e2])
check("重叠击键去重(4→3)", len(dd) == 3 and [k["char"] for k in dd] == ["h", "a", "i"])

print("=== 5. 回退:正确标状态,不伪装 complete(§6.2/验收)===")
g = {"skeleton": "介绍的", "commits": ["介绍的", "海报"]}
# 重建成功且全覆盖 → complete
o = decide_outcome({"skeleton": "介绍的海报", "commits": ["介绍的", "海报"]},
                   {"ok": True, "text": "介绍的海报", "proposal": {"via": "commit-match"}})
check("重建成功全覆盖 → complete", o["completeness"] == "complete" and not o["fallback"])
# 重建成功但仍有未覆盖中文 commit → partial(不伪装 complete)
o = decide_outcome(g, {"ok": True, "text": "介绍的", "proposal": {}})   # 海报 仍没进
check("成功但有未覆盖证据 → partial", o["completeness"] == "partial")
# 重建失败 + 有残文 → 回退 captured,标 partial
o = decide_outcome(g, {"ok": False, "why": "验证器拒绝: rule6b"})
check("失败+有残文 → 回退 captured 标 partial", o["text"] == "介绍的" and o["completeness"] == "partial" and o["fallback"])
# 重建失败 + 无残文 → unrecoverable
o = decide_outcome({"skeleton": "", "commits": ["海报"]}, {"ok": False, "why": "x"})
check("失败+无残文 → unrecoverable(text=None)", o["completeness"] == "unrecoverable" and o["text"] is None)
# 回退绝不标 complete
outs = [decide_outcome(g, {"ok": False, "why": "x"}),
        decide_outcome({"skeleton": "", "commits": []}, {"ok": False, "why": "x"})]
check("任何回退都不标 complete", all(o["completeness"] != "complete" for o in outs))

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
