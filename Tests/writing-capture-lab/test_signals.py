#!/usr/bin/env python3
"""阶段一验收测试。失败返回非零退出码。
读冻结 fixture(fixtures/send_signals.json),不读活库。覆盖:
  · 标注用例(confirmed_sent / probable_sent / confirmed_draft)等级正确
  · 草稿负样本误收=0(没有一条草稿被判 sent)
  · 四类等级全覆盖(含 unknown)
  · probable_sent 在对外映射中仍可与 confirmed_sent 区分
  · 已确认消息边界只含 confirmed_sent,不跨 probable/draft/unknown
"""
import sys, os, json
from signals import (SendSignals, DeliveryLevel, classify_delivery, to_delivery,
                     classify_delete_pattern, detect_confirmed_message_boundaries)
from evidence import Delivery, DeliveryConfidence

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

SIG_FIELDS = ("is_chat_surface", "return_key", "reset_to_known_placeholder",
              "reset_to_empty", "next_session_transition_reliable", "delete_pattern",
              "physical_key_support", "content_len", "n_nonbs_keys", "tail_backspaces", "ts")
def to_sig(d): return SendSignals(**{k: d[k] for k in SIG_FIELDS})

fx = json.load(open(os.path.join(os.path.dirname(__file__), "fixtures", "send_signals.json")))

print("=== 1. classify_delete_pattern 区分退格抹除 / 一次性清空 ===")
check("退格≥内容长 → backspace_erase", classify_delete_pattern(4, 5) == "backspace_erase")
check("退格<内容长 → clean_clear", classify_delete_pattern(30, 2) == "clean_clear")
check("零退格 → clean_clear", classify_delete_pattern(8, 0) == "clean_clear")

print("=== 2. 标注用例等级正确(三分判据)===")
seen_levels = set()
for c in fx["labeled"]:
    lvl, ev = classify_delivery(to_sig(c))
    seen_levels.add(lvl.value)
    check(f"{c['name']} → {c['expected']}(实得 {lvl.value})", lvl.value == c["expected"])

print("=== 3. 草稿负样本误收=0(无草稿被判 sent)===")
mis = []
for c in fx["draft_negatives"]:
    lvl, _ = classify_delivery(to_sig(c))
    deliv, _ = to_delivery(lvl)
    if deliv == Delivery.sent:
        mis.append((c["ev_id"], c["content"], lvl.value))
check(f"{len(fx['draft_negatives'])} 条草稿负样本,误收 {len(mis)} 条", len(mis) == 0)
for ev, txt, lv in mis:
    print(f"      误收: ev{ev} {txt!r} → {lv}")

print("=== 4. 四类等级全覆盖(confirmed_sent/probable_sent/confirmed_draft/unknown)===")
# unknown:clean_clear 真发送但无任何 reset 证据(证据不足)→ unknown
u = SendSignals(is_chat_surface=True, return_key=False, reset_to_known_placeholder=False,
                reset_to_empty=False, next_session_transition_reliable=False,
                delete_pattern="clean_clear", physical_key_support=True, content_len=5)
ulvl, _ = classify_delivery(u)
check("无 reset 证据的 clean_clear → unknown", ulvl == DeliveryLevel.unknown)
seen_levels.add(ulvl.value)
for lv in ("confirmed_sent", "probable_sent", "confirmed_draft", "unknown"):
    check(f"覆盖等级 {lv}", lv in seen_levels)

print("=== 5. probable_sent 在对外映射中仍可与 confirmed_sent 区分 ===")
ps = to_delivery(DeliveryLevel.probable_sent)
cs = to_delivery(DeliveryLevel.confirmed_sent)
check("两者 delivery 都是 sent", ps[0] == Delivery.sent and cs[0] == Delivery.sent)
check("delivery_confidence 可区分(probable vs confirmed)", ps[1] != cs[1])
check("probable→probable", ps[1] == DeliveryConfidence.probable)

print("=== 6. 已确认消息边界只含 confirmed_sent ===")
classified = [(classify_delivery(to_sig(c))[0], to_sig(c)) for c in fx["labeled"]]
bounds = detect_confirmed_message_boundaries(classified)
sent_ts = sorted(to_sig(c).ts for c in fx["labeled"]
                 if classify_delivery(to_sig(c))[0] == DeliveryLevel.confirmed_sent)
check("边界数 == confirmed_sent 数", len(bounds) == len(sent_ts))
check("边界 ts 全来自 confirmed_sent", bounds == sent_ts)
# probable/draft 的 ts 不得进入边界
nonsent_ts = {to_sig(c).ts for c in fx["labeled"]
              if classify_delivery(to_sig(c))[0] != DeliveryLevel.confirmed_sent}
check("probable/draft 不构成边界", not (set(bounds) & nonsent_ts))

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
