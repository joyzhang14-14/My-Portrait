#!/usr/bin/env python3
"""阶段二验收测试。**完全离线**(只读 fixtures/cases.json,不连活库)。失败返回非零退出码。
覆盖:
  · fixture 含 §3.1 最低字段
  · 从原始 edit_log+击键**重新推导**信号 → classify_delivery 命中冻结期望(脱敏不改判定)
  · 已确认边界与冻结期望一致
  · 草稿 must_not_exist 含草稿文本且 delivery=draft
  · 破坏一个期望结果 → 验证可靠失败(返回非零)
  · 脱敏结构一致性:签名自洽,且能抓到人为结构破坏
"""
import sys, os, json, copy
from signals_raw import box_clears_from_raw
from signals import (SendSignals, classify_delivery, to_delivery,
                     detect_confirmed_message_boundaries)
from fixtures_lib import (load_fixtures, validate_fixture, structure_signature,
                          check_structure_preserved)

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

SIG_FIELDS = ("is_chat_surface", "return_key", "reset_to_known_placeholder", "reset_to_empty",
              "next_session_transition_reliable", "delete_pattern", "physical_key_support",
              "content_len", "n_nonbs_keys", "tail_backspaces", "ts")
def to_sig(s): return SendSignals(**{k: s[k] for k in SIG_FIELDS})

CASES = load_fixtures(os.path.join(os.path.dirname(__file__), "fixtures", "cases.json"))

def derive(case):
    """离线重derive:返回 (目标clear的判定 (delivery,confidence), 该event的已确认边界)。"""
    sigs = box_clears_from_raw(case["edit_log"], case["keystroke_log"], case["app"], 0)
    classified = [(classify_delivery(to_sig(s))[0], to_sig(s)) for s in sigs]
    bounds = detect_confirmed_message_boundaries(classified)
    target = next((s for s in sigs if s["ts"] == case["target_ts"]), None)
    if target is None: return None, bounds
    return to_delivery(classify_delivery(to_sig(target))[0]), bounds

def verify_case(case):
    """判定是否匹配冻结期望(用于正例通过 + 破坏期望必失败的对照)。"""
    res, bounds = derive(case)
    if res is None: return False
    deliv, conf = res
    return (deliv.value == case["expected_delivery"]
            and conf.value == case["expected_delivery_confidence"]
            and bounds == case["expected_boundaries"])

print(f"=== 0. 离线加载 {len(CASES)} 个 fixture(不连活库)===")
check("cases.json 非空", len(CASES) > 0)

print("=== 1. §3.1 最低字段齐全 ===")
allok = True
for c in CASES:
    errs = validate_fixture(c)
    if errs: allok = False; print(f"      {c['id']}: {errs}")
check("所有 fixture 字段齐全", allok)

print("=== 2. 从原始数据重derive,判定命中冻结期望(脱敏不改判定)===")
miss = [c["id"] for c in CASES if not verify_case(c)]
check(f"{len(CASES)} 个 fixture 全部命中期望(未命中 {len(miss)})", not miss)
for mid in miss[:8]: print(f"      未命中: {mid}")

print("=== 3. 草稿 must_not_exist 含草稿文本 + delivery=draft ===")
drafts = [c for c in CASES if c["category"] == "draft_negative"]
ok = all(c["expected_delivery"] == "draft" and len(c["must_not_exist"]) >= 1 for c in drafts)
check(f"{len(drafts)} 条草稿 fixture 标 draft 且有 must_not_exist", ok)
# must_not_exist 的文本不应作为发送输出(草稿无 expected_output)
check("草稿无 expected_output", all(c["expected_output"] is None for c in drafts))

print("=== 4. 四类等级在 fixture 中均有覆盖 ===")
levels = {c["expected_level"] for c in CASES}
for lv in ("confirmed_sent", "probable_sent", "confirmed_draft"):
    check(f"覆盖 {lv}", lv in levels)

print("=== 5. 破坏一个期望结果 → 验证可靠失败 ===")
good = next(c for c in CASES if c["category"] == "labeled")
check("原 fixture 通过验证", verify_case(good))
broken = copy.deepcopy(good)
broken["expected_delivery"] = "draft" if good["expected_delivery"] != "draft" else "sent"
check("篡改 expected_delivery 后验证失败", not verify_case(broken))
broken2 = copy.deepcopy(good)
broken2["expected_boundaries"] = good["expected_boundaries"] + [999999]
check("篡改 expected_boundaries 后验证失败", not verify_case(broken2))

print("=== 6. 脱敏结构一致性:签名自洽 + 抓到人为结构破坏 ===")
sample = CASES[0]
ok, bad = check_structure_preserved(sample, sample)
check("同一 case 结构签名自洽", ok and bad is None)
mut = copy.deepcopy(sample)
# 人为破坏:改一条 edit_log 文本长度(加一个 CJK 字)
for e in mut["edit_log"]:
    if e.get("text"): e["text"] = e["text"] + "丂"; break
ok2, bad2 = check_structure_preserved(sample, mut)
check("改文本长度被结构校验抓到(返回不一致)", (not ok2) and bad2 is not None)

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
