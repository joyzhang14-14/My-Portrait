#!/usr/bin/env python3
"""阶段二验收测试。**完全离线**(只读 fixtures/cases.json,不连活库)。失败返回非零退出码。
覆盖:
  · fixture 含 §3.1 最低字段
  · message 型:从原始 edit_log+击键重derive → classify_delivery 命中冻结期望(脱敏不改判定)
  · 短真消息必为 sent(不被过滤);草稿 must_not_exist + delivery=draft
  · 粘贴/占位符负样本:重derive 作者证据 = 非用户手打(铁律);高频短消息 = 用户手打必保留
  · 破坏期望 → 验证可靠失败;脱敏结构一致性:签名自洽 + 抓到人为结构破坏
"""
import sys, os, json, copy
from signals_raw import box_clears_from_raw, author_evidence_from_entry
from signals import (SendSignals, classify_delivery, to_delivery,
                     detect_confirmed_message_boundaries)
from evidence import AuthorEvidence
from fixtures_lib import (load_fixtures, validate_fixture, check_structure_preserved)

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

SIG_FIELDS = ("is_chat_surface", "return_key", "reset_to_known_placeholder", "reset_to_empty",
              "next_session_transition_reliable", "delete_pattern", "physical_key_support",
              "content_len", "n_nonbs_keys", "tail_backspaces", "ts")
def to_sig(s): return SendSignals(**{k: s[k] for k in SIG_FIELDS})

CASES = load_fixtures(os.path.join(os.path.dirname(__file__), "fixtures", "cases.json"))
MSG = [c for c in CASES if c.get("target_ts") is not None]            # message 型(send-evidence)
AUTH = [c for c in CASES if c.get("target_idx") is not None]          # 作者证据型(粘贴/占位符/高频)

def derive_msg(case):
    sigs = box_clears_from_raw(case["edit_log"], case["keystroke_log"], case["app"], 0)
    classified = [(classify_delivery(to_sig(s))[0], to_sig(s)) for s in sigs]
    bounds = detect_confirmed_message_boundaries(classified)
    target = next((s for s in sigs if s["ts"] == case["target_ts"]), None)
    if target is None: return None, bounds
    return to_delivery(classify_delivery(to_sig(target))[0]), bounds

def verify_msg(case):
    res, bounds = derive_msg(case)
    if res is None: return False
    deliv, conf = res
    return (deliv.value == case["expected_delivery"]
            and conf.value == case["expected_delivery_confidence"]
            and bounds == case["expected_boundaries"])

print(f"=== 0. 离线加载 {len(CASES)} 个 fixture(不连活库;message {len(MSG)} / author {len(AUTH)})===")
check("cases.json 非空", len(CASES) > 0)

print("=== 1. §3.1 最低字段齐全 ===")
bad = [(c["id"], validate_fixture(c)) for c in CASES if validate_fixture(c)]
check("所有 fixture 字段齐全", not bad)
for cid, e in bad[:6]: print(f"      {cid}: {e}")

print("=== 2. message 型:重derive 判定命中冻结期望(脱敏不改判定)===")
miss = [c["id"] for c in MSG if not verify_msg(c)]
check(f"{len(MSG)} 个 message fixture 全命中(未命中 {len(miss)})", not miss)
for m in miss[:8]: print(f"      未命中: {m}")

print("=== 3. 真实短消息必为 sent(不被过滤)===")
shorts = [c for c in CASES if c["category"] == "short_message"]
check(f"{len(shorts)} 条短消息全部 delivery=sent", shorts and all(c["expected_delivery"] == "sent" for c in shorts))

print("=== 4. 草稿:must_not_exist 含草稿文本 + delivery=draft + 无 output ===")
drafts = [c for c in CASES if c["category"] == "draft_negative"]
check(f"{len(drafts)} 条草稿标 draft 且有 must_not_exist",
      all(c["expected_delivery"] == "draft" and len(c["must_not_exist"]) >= 1 for c in drafts))
check("草稿无 expected_output", all(c["expected_output"] is None for c in drafts))

print("=== 5. 粘贴/占位符负样本:重derive 作者证据 = 非用户手打(铁律)===")
negs = [c for c in CASES if c["category"] in ("paste_negative", "placeholder_negative")]
for c in negs:
    redev = author_evidence_from_entry(c["edit_log"], c["target_idx"], c["keystroke_log"])
    ae = AuthorEvidence(**redev)
    check(f"{c['id']}: 重derive=冻结 且 非用户手打 且 must_not_exist 非空",
          redev == c["expected_author_evidence"] and (not ae.is_user_authored()) and len(c["must_not_exist"]) >= 1)

print("=== 6. 高频短消息:用户手打、必须保留(不在 must_not_exist)===")
hf = [c for c in CASES if c["category"] == "high_freq_short"]
for c in hf:
    ae = AuthorEvidence(**author_evidence_from_entry(c["edit_log"], c["target_idx"], c["keystroke_log"]))
    check(f"{c['id']}: 用户手打 且 must_not_exist 空(保留)", ae.is_user_authored() and not c["must_not_exist"])

print("=== 7. 四类发送等级在 fixture 中均有覆盖 ===")
levels = {c["expected_level"] for c in CASES if c.get("expected_level")}
for lv in ("confirmed_sent", "probable_sent", "confirmed_draft"):
    check(f"覆盖 {lv}", lv in levels)

print("=== 8. 破坏一个期望结果 → 验证可靠失败 ===")
good = next(c for c in MSG if c["category"] == "labeled")
check("原 fixture 通过验证", verify_msg(good))
broken = copy.deepcopy(good)
broken["expected_delivery"] = "draft" if good["expected_delivery"] != "draft" else "sent"
check("篡改 expected_delivery 后验证失败", not verify_msg(broken))
broken2 = copy.deepcopy(good); broken2["expected_boundaries"] = good["expected_boundaries"] + [999999]
check("篡改 expected_boundaries 后验证失败", not verify_msg(broken2))

print("=== 9. 脱敏结构一致性:签名自洽 + 抓到人为结构破坏 ===")
sample = CASES[0]
ok, b = check_structure_preserved(sample, sample)
check("同一 case 结构签名自洽", ok and b is None)
mut = copy.deepcopy(sample)
for e in mut["edit_log"]:
    if e.get("text"): e["text"] = e["text"] + "丂"; break
ok2, b2 = check_structure_preserved(sample, mut)
check("改文本长度被结构校验抓到", (not ok2) and b2 is not None)

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
