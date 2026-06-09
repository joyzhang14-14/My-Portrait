#!/usr/bin/env python3
"""阶段三验收测试。离线(读 cases.json)。失败返回非零退出码。
覆盖:§4.2 决策表 / #44/#45(commit 注入占位符被删、不造「他说」)/ 用户真打占位符例外保护 /
短消息·高频保护 / learned 占位符纯审计不改判定。"""
import sys, os, json
from placeholder import (is_known_placeholder, placeholder_decision, apply_placeholder_filter,
                         learned_placeholder_candidates, PlaceholderDecision)
from signals_raw import author_evidence_from_entry, cv, box_clears_from_raw
from evidence import AuthorEvidence
from fixtures_lib import load_fixtures

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

CASES = load_fixtures(os.path.join(os.path.dirname(__file__), "fixtures", "cases.json"))
def case_of(cat): return [c for c in CASES if c["category"] == cat]
APP_INJ = AuthorEvidence(app_injected=True)                       # 无击键注入
USER = AuthorEvidence(physical_key_backed=True, commit_backed=True)  # 用户手打

print("=== 1. known 占位符配置 + 匹配 ===")
check("匹配 'Write a message…'", is_known_placeholder("Write a message…"))
check("匹配 'Type / for commands'", is_known_placeholder("Type / for commands\n"))
check("普通消息不误判占位符", not is_known_placeholder("我今天去看电影"))

print("=== 2. §4.2 决策表 ===")
check("占位符+无击键+注入 → 删除",
      placeholder_decision("Write a message…", APP_INJ, has_send_evidence=False) == PlaceholderDecision.delete_placeholder)
check("占位符+有击键+发送 → 保留(例外)",
      placeholder_decision("Write a message", USER, has_send_evidence=True) == PlaceholderDecision.keep_user_input)
check("占位符+证据冲突(有击键无发送)→ 待审计",
      placeholder_decision("Write a message", USER, has_send_evidence=False) == PlaceholderDecision.unknown_audit)
check("非占位符 → not_placeholder",
      placeholder_decision("随便一句话", USER, has_send_evidence=True) == PlaceholderDecision.not_placeholder)

print("=== 3. #44/#45:commit 注入占位符被识别并删除(不是只认 paste)===")
phneg = case_of("placeholder_negative")
check("有 placeholder_negative fixture", len(phneg) >= 1)
for c in phneg:
    text = cv(c["edit_log"][c["target_idx"]].get("text", ""))
    ae = AuthorEvidence(**author_evidence_from_entry(c["edit_log"], c["target_idx"], c["keystroke_log"]))
    dec = placeholder_decision(text, ae, has_send_evidence=False)
    out = apply_placeholder_filter(text, dec)
    # 该 fixture 是 commit 注入占位符(非 paste)→ 必须被删
    check(f"{c['id']}: commit注入占位符 → 删除", dec == PlaceholderDecision.delete_placeholder)
    check(f"{c['id']}: 删除后空串(不泄漏)", out == "")

print("=== 4. #44/#45:绝不剥前缀造「他说X」(占位符整体删或整体留)===")
ph = "Write a message…"
check("删除决策 → 空串(无残留片段)", apply_placeholder_filter(ph, PlaceholderDecision.delete_placeholder) == "")
check("保留决策 → 原文逐字不动", apply_placeholder_filter(ph, PlaceholderDecision.keep_user_input) == ph)
check("任何决策都不产出『他说』前缀", "他说" not in apply_placeholder_filter(ph, PlaceholderDecision.delete_placeholder)
      and "他说" not in apply_placeholder_filter(ph, PlaceholderDecision.keep_user_input))

print("=== 5. 保护真实短消息 / 高频短消息(不被当占位符删)===")
prot = case_of("high_freq_short") + case_of("draft_negative")
def target_text(c):
    if c.get("target_idx") is not None: return cv(c["edit_log"][c["target_idx"]].get("text", ""))
    sigs = box_clears_from_raw(c["edit_log"], c["keystroke_log"], c["app"], 0)
    t = next((s for s in sigs if s["ts"] == c.get("target_ts")), None)
    return t["content"] if t else ""
non_ph = [c for c in prot if not is_known_placeholder(target_text(c))]
check(f"{len(non_ph)}/{len(prot)} 条短/高频/草稿内容非占位符 → 不被占位符规则删",
      all(placeholder_decision(target_text(c), USER, True) == PlaceholderDecision.not_placeholder for c in non_ph) and len(non_ph) == len(prot))
# 短真消息正样本:不被占位符规则触碰
shorts = case_of("short_message")
check("短真消息内容非占位符", shorts and all(not is_known_placeholder(target_text(c)) for c in shorts))

print("=== 6. learned 占位符:纯审计,不改判定 ===")
# 构造:某非 known 串在多个注入态出现 → 成 learned 候选,但 placeholder_decision 不删它
injected = ["发送", "发送", "随便", "Write a message"]   # '发送'×2 是疑似 learned 候选
cands = learned_placeholder_candidates(injected)
check("learned 候选发现复现注入串", any(x["text"] == "发送" for x in cands))
check("learned 候选不含 known 占位符", all(not is_known_placeholder(x["text"]) for x in cands))
# 关键:learned 候选('发送')不被 placeholder_decision 当占位符删(只 known 才删)
check("learned 候选不影响判定(非 known → not_placeholder)",
      placeholder_decision("发送", APP_INJ, has_send_evidence=False) == PlaceholderDecision.not_placeholder)

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
