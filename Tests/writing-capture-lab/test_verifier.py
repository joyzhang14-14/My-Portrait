#!/usr/bin/env python3
"""阶段四验收测试。纯算法、无模型。失败返回非零退出码。
覆盖:九条验证规则失败场景(无来源新增/跨边界/删骨架/已删复活)、多 patch 冲突(重叠/重复消费)、
部分失败不破坏骨架、多 patch 应用稳定可复现、verification_passed ≠ completeness、反幻觉(CJK 非候选拒绝)。"""
import sys
from patch import Patch, parse_patches
from verifier import verify_patch, verify_and_apply, calculate_completeness

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

def ks(seq, t0=100, step=10):
    return [{"ts": t0 + i * step, "char": c, "is_backspace": False} for i, c in enumerate(seq)]

def base_group():
    # 骨架 "介绍的"(IME 尾巴截断),完整应为 "介绍的海报";commit 流含尾巴证据
    return {"skeleton": "介绍的", "event_ids": [1], "commits": ["介绍的", "海报"],
            "deletes": [], "reinput": [], "keystrokes": ks("haibao"), "boundaries": [],
            "segment_range": [0, 10_000], "post_send_transition_complete": True, "capture_gap": False}

def insert_tail(repl="海报", cands=("海", "报"), src=(0, 6)):
    return Patch(replace_range=(3, 3), replacement_text=repl, operation="inserted",
                 anchor_before="的", anchor_after="", source_range=src,
                 supporting_event_ids=[1], supporting_keystrokes=[0, 1, 2, 3, 4, 5],
                 pinyin_candidates=[set(c) for c in cands])

print("=== 1. 合法 patch(拼音候选背书的尾巴)→ 通过并应用 ===")
g = base_group()
check("合法 CJK 尾巴 patch 通过", verify_patch(insert_tail(), g)[0])
res = verify_and_apply([insert_tail()], g)
check("应用后骨架补全为 介绍的海报", res["text"] == "介绍的海报")
check("verification_passed=True", res["verification_passed"])

print("=== 2. 合法英文尾巴(gmail)按击键顺序 → 通过 ===")
ge = {"skeleton": "我用g", "event_ids": [1], "commits": ["我用g", "mail"], "deletes": [], "reinput": [],
      "keystrokes": ks("mail"), "boundaries": [], "segment_range": [0, 10_000]}
def gmail_patch(repl, kidx, cands=()):
    return Patch(replace_range=(3, 3), replacement_text=repl, operation="inserted",
                 anchor_before="g", anchor_after="", supporting_event_ids=[1],
                 supporting_keystrokes=kidx, pinyin_candidates=[set(c) for c in cands])
check("英文 mail 按击键顺序通过", verify_patch(gmail_patch("mail", [0, 1, 2, 3]), ge)[0])

print("=== 3. 反幻觉:CJK 不在拼音候选 → 拒绝(rule6)===")
ok, r = verify_patch(gmail_patch("购买了", [0]), ge)   # 无候选
check("gmail→购买了 幻觉被拒(rule6)", (not ok) and r == "rule6_cjk_not_in_candidate")

print("=== 4. 无来源英文(多出未击键字母)→ 拒绝(rule5)===")
ok, r = verify_patch(gmail_patch("mailx", [0, 1, 2, 3]), ge)   # 多打 'x',击键里没有
check("多出未击键字母被拒(rule5)", (not ok) and r == "rule5_english_not_keystroke_ordered")

print("=== 5. 跨 confirmed message boundary → 拒绝(rule2)===")
gb = base_group(); gb["boundaries"] = [125]   # 边界落在击键 span(100..150)中间
ok, r = verify_patch(insert_tail(), gb)
check("击键跨边界被拒(rule2)", (not ok) and r == "rule2_cross_boundary")

print("=== 6. 删除无证据的骨架内容 → 拒绝(rule4)===")
pdel = Patch(replace_range=(0, 2), replacement_text="", operation="replaced",
             anchor_before="", anchor_after="的", supporting_event_ids=[1])
ok, r = verify_patch(pdel, base_group())   # 删 "介绍" 但 deletes 里没有
check("删无删除证据骨架被拒(rule4)", (not ok) and r == "rule4_delete_without_evidence")

print("=== 7. 已删未重输内容复活 → 拒绝(rule7)===")
g7 = base_group(); g7["deletes"] = ["海报"]; g7["reinput"] = []
ok, r = verify_patch(insert_tail(), g7)
check("已删未重输内容复活被拒(rule7)", (not ok) and r == "rule7_deleted_content_resurfaced")

print("=== 8. 重叠 patch(各自合法纠错)→ 全部拒绝(冲突,不自选其一)===")
# 骨架 "睡的觉" 应为 "睡得觉"(的→得);两个纠错 patch 区间重叠
g8 = {"skeleton": "睡的觉", "event_ids": [1], "commits": ["睡的觉"], "deletes": ["的", "睡的"], "reinput": [],
      "keystrokes": ks("shuidejiao"), "boundaries": [], "segment_range": [0, 10_000]}
a = Patch(replace_range=(1, 2), replacement_text="得", operation="replaced", anchor_before="睡", anchor_after="觉",
          supporting_event_ids=[1], source_range=(0, 2), pinyin_candidates=[set("得")])
b = Patch(replace_range=(0, 2), replacement_text="睡得", operation="replaced", anchor_before="", anchor_after="觉",
          supporting_event_ids=[1], source_range=(3, 5), pinyin_candidates=[set("睡"), set("得")])
check("a/b 各自合法", verify_patch(a, g8)[0] and verify_patch(b, g8)[0])
res = verify_and_apply([a, b], g8)
check("重叠 patch 全被拒(applied 空 + conflict)",
      len(res["applied"]) == 0 and any(x["reason"] == "conflict" for x in res["rejected"]))

print("=== 9. source_range 重复消费 → 冲突拒绝 ===")
c1 = insert_tail(src=(0, 6))
c2 = Patch(replace_range=(3, 3), replacement_text="", operation="inserted", anchor_before="的", anchor_after="",
           supporting_event_ids=[1], source_range=(2, 5))   # source 与 c1 重叠
res = verify_and_apply([c1, c2], base_group())
check("重复消费 source 冲突", any(x["reason"] == "conflict" for x in res["rejected"]))

print("=== 10. 部分 patch 失败不破坏骨架 ===")
bad = Patch(replace_range=(0, 2), replacement_text="乱改", operation="replaced", anchor_before="", anchor_after="的",
            supporting_event_ids=[1])   # rule4 删无证据
res = verify_and_apply([insert_tail(), bad], base_group())
check("好 patch 应用、坏 patch 拒绝", res["text"] == "介绍的海报" and len(res["rejected"]) == 1)
check("骨架前缀未被坏 patch 破坏", res["text"].startswith("介绍的"))

print("=== 11. 多 patch 应用稳定可复现 ===")
gm = {"skeleton": "A的B", "event_ids": [1], "commits": ["A的B"], "deletes": [], "reinput": [],
      "keystrokes": ks("haibao"), "boundaries": [], "segment_range": [0, 10_000]}
p1 = Patch(replace_range=(1, 1), replacement_text="海", operation="inserted", anchor_before="A", anchor_after="的",
           supporting_event_ids=[1], source_range=(0, 1), pinyin_candidates=[set("海")])
p2 = Patch(replace_range=(3, 3), replacement_text="报", operation="inserted", anchor_before="B", anchor_after="",
           supporting_event_ids=[1], source_range=(2, 3), pinyin_candidates=[set("报")])
r1 = verify_and_apply([p1, p2], gm)
r2 = verify_and_apply([p2, p1], gm)   # 输入顺序颠倒
check("两 patch 应用结果 = A海的B报", r1["text"] == "A海的B报")
check("patch 输入顺序无关、结果可复现", r1["text"] == r2["text"])

print("=== 12. verification_passed=True 但 completeness=partial(独立)===")
g12 = base_group()
res2 = verify_and_apply([insert_tail(), insert_tail(repl="购买了", cands=())], g12)
comp = calculate_completeness(g12, res2["text"], res2["applied"], res2["rejected"])
check("有被拒 patch → verification_passed 但 completeness=partial", res2["verification_passed"] and comp == "partial")
gg = {**base_group(), "capture_gap": True}
rg = verify_and_apply([insert_tail()], gg)
check("capture_gap → completeness=partial",
      calculate_completeness(gg, rg["text"], rg["applied"], rg["rejected"]) == "partial")

print("=== 13. 全条件满足 → completeness=complete ===")
gc = {"skeleton": "你好世界", "event_ids": [1], "commits": ["你好世界"], "deletes": [], "reinput": [],
      "keystrokes": ks("nihaoshijie"), "boundaries": [50], "segment_range": [0, 10_000],
      "post_send_transition_complete": True, "capture_gap": False}
rc = verify_and_apply([], gc)
check("无缺口完整消息 → complete",
      calculate_completeness(gc, gc["skeleton"], rc["applied"], rc["rejected"]) == "complete")

print("=== 14. parse_patches 容错解析 ===")
ps = parse_patches('{"patches":[{"replace_range":[3,3],"replacement_text":"海报","operation":"inserted"},{"bad":1}]}')
check("解析出 1 个合法 patch(坏项跳过)", len(ps) == 1 and ps[0].replacement_text == "海报")

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
