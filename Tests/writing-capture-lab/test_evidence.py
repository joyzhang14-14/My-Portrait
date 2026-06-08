#!/usr/bin/env python3
"""阶段零验收测试。失败返回非零退出码(可进 CI)。
覆盖:状态固定行为表 / partial·draft·unknown·unrecoverable 不进风格分析 /
Pass4 失败不误收不删 / unrecoverable 不生成正文 / author 多信号 / delivery 强弱保留。"""
import sys
from evidence import (EvidenceResult, AuthorEvidence, Completeness, Delivery,
                      DeliveryConfidence, Pass4Status, downstream_behavior)

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

def er(comp, deliv, *, text="x", dconf=DeliveryConfidence.confirmed,
       author=None, p4=Pass4Status.not_applicable):
    return EvidenceResult(completeness=comp, delivery=deliv, delivery_confidence=dconf,
                          author_evidence=author or AuthorEvidence(physical_key_backed=True),
                          text=text, pass4_status=p4)

print("=== 1. unrecoverable 不生成正文 ===")
# unrecoverable + 有 text → 必须报错
raised = False
try: EvidenceResult(Completeness.unrecoverable, Delivery.sent, DeliveryConfidence.confirmed,
                    AuthorEvidence(), text="不该有正文")
except ValueError: raised = True
check("unrecoverable 给 text 报错", raised)
u = EvidenceResult(Completeness.unrecoverable, Delivery.sent, DeliveryConfidence.confirmed,
                   AuthorEvidence(), text=None)
check("unrecoverable.text is None", u.text is None)
check("unrecoverable 下游不生成正文(eligible_final=False)", not downstream_behavior(u).eligible_final)
# complete 无 text → 报错
raised = False
try: EvidenceResult(Completeness.complete, Delivery.sent, DeliveryConfidence.confirmed,
                    AuthorEvidence(), text="")
except ValueError: raised = True
check("complete 无 text 报错", raised)

print("=== 2. 状态固定行为表 ===")
# complete+sent+accepted → 进最终 + 风格分析
d = downstream_behavior(er(Completeness.complete, Delivery.sent, p4=Pass4Status.accepted))
check("complete+sent+accepted → eligible_final", d.eligible_final)
check("complete+sent+accepted → in_style_analysis", d.in_style_analysis)
check("complete+sent+accepted → pass4 review", d.pass4_action == "review")
# complete+sent 未过 Pass4(not_applicable)→ 还不能进最终
d = downstream_behavior(er(Completeness.complete, Delivery.sent))
check("complete+sent 未accepted → 不进最终", not d.eligible_final)
# partial+sent → 进入但标记,不删,不进风格
d = downstream_behavior(er(Completeness.partial, Delivery.sent))
check("partial+sent → in_staged", d.in_staged)
check("partial+sent → eligible_final(标记)", d.eligible_final)
check("partial+sent → pass4 not_applicable(不删)", d.pass4_action == "not_applicable")
check("partial+sent → 不进风格分析", not d.in_style_analysis)
check("partial+sent → 展示不完整", d.display_label == "不完整")
# draft → 不进最终
for comp in (Completeness.complete, Completeness.partial):
    d = downstream_behavior(er(comp, Delivery.draft))
    check(f"{comp.value}+draft → 不进最终", not d.eligible_final)
    check(f"{comp.value}+draft → 不进风格分析", not d.in_style_analysis)
# unknown → 待审计,不进
d = downstream_behavior(er(Completeness.complete, Delivery.unknown))
check("delivery=unknown → 不进最终", not d.eligible_final)
check("delivery=unknown → 展示待确认", d.display_label == "待确认")

print("=== 3. partial/draft/unknown/unrecoverable 都不进写作风格分析 ===")
cases = [er(Completeness.partial, Delivery.sent),
         er(Completeness.complete, Delivery.draft),
         er(Completeness.complete, Delivery.unknown),
         u]
check("四类都不进风格分析", all(not downstream_behavior(c).in_style_analysis for c in cases))

print("=== 4. Pass4 失败:不误收进最终 + 不删 staged ===")
d = downstream_behavior(er(Completeness.complete, Delivery.sent, p4=Pass4Status.review_failed))
check("review_failed → 不进最终", not d.eligible_final)
check("review_failed → 留 staged(不删)", d.in_staged)
check("review_failed → pass4_action review_failed", d.pass4_action == "review_failed")
check("review_failed → 不进风格分析", not d.in_style_analysis)
# rejected → 不进最终(进 discarded)
d = downstream_behavior(er(Completeness.complete, Delivery.sent, p4=Pass4Status.rejected))
check("rejected → 不进最终", not d.eligible_final)

print("=== 5. author_evidence 多信号共存 ===")
a = AuthorEvidence(physical_key_backed=True, commit_backed=True)
check("可同时 physical + commit", a.physical_key_backed and a.commit_backed)
check("physical_key_backed → is_user_authored", a.is_user_authored())
check("app_injected → 非用户写作", not AuthorEvidence(commit_backed=True, app_injected=True).is_user_authored())
check("只 commit 缺击键 → 不算用户写作", not AuthorEvidence(commit_backed=True).is_user_authored())

print("=== 6. delivery_confidence 保留 confirmed/probable 强弱(不压成 sent)===")
p = er(Completeness.complete, Delivery.sent, dconf=DeliveryConfidence.probable)
c = er(Completeness.complete, Delivery.sent, dconf=DeliveryConfidence.confirmed)
check("probable 与 confirmed 在数据中可区分",
      p.delivery_confidence != c.delivery_confidence and p.delivery == c.delivery == Delivery.sent)

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
