#!/usr/bin/env python3
"""阶段六验收测试(确定性、无模型)。失败返回非零退出码。
Pass4:四状态可达 / 每条输入恰好一个状态 / 解析失败不默认全留(→review_failed)/ 覆盖不全→review_failed /
       review_failed 留 staged 不进最终不删 / 按 (app,url) 分组。
Canvas:合规通过 / 最长OCR补尾·未过Pass4·新增缺证据·跨app当来源 均被拦。"""
import sys
from pass4 import run_pass4, group_key, coverage_exactly_once
from canvas import validate_canvas_record
from evidence import (Pass4Status, EvidenceResult, AuthorEvidence, Completeness,
                      Delivery, DeliveryConfidence, downstream_behavior)

FAILS = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAILS.append(name)

def rec(i, app="Discord", url=None, comp="complete", deliv="sent"):
    return {"id": i, "app": app, "url": url, "completeness": comp, "delivery": deliv, "text": f"msg{i}"}

# 输入:2 条 complete+sent(eligible)+ 1 partial + 1 draft(not_applicable)
RECS = [rec(1), rec(2), rec(3, comp="partial"), rec(4, deliv="draft")]

print("=== 1. Pass4 四状态可达 + 每条恰好一个状态 ===")
def review_mixed(grp):  # 1→accept, 2→reject
    return {"ok": True, "parse_ok": True, "raw": "...",
            "verdicts": {1: "accept", 2: "reject"}, "output_ids": [r["id"] for r in grp]}
st, audit = run_pass4(RECS, review_mixed)
check("#1 complete+sent+accept → accepted", st[1] == Pass4Status.accepted)
check("#2 complete+sent+reject → rejected", st[2] == Pass4Status.rejected)
check("#3 partial → not_applicable", st[3] == Pass4Status.not_applicable)
check("#4 draft → not_applicable", st[4] == Pass4Status.not_applicable)
check("每条输入恰好一个状态", audit["each_input_exactly_one_status"] and len(st) == 4)

print("=== 2. 解析失败 → review_failed(绝不默认全留)===")
def review_parsefail(grp):
    return {"ok": True, "parse_ok": False, "raw": "坏JSON", "verdicts": {}, "output_ids": []}
st2, a2 = run_pass4(RECS, review_parsefail)
check("解析失败 → eligible 全 review_failed", st2[1] == Pass4Status.review_failed and st2[2] == Pass4Status.review_failed)
check("失败组计数 +1", a2["failed_groups"] == 1)
check("解析失败不默认 accepted(不全留进最终)", st2[1] != Pass4Status.accepted)

print("=== 3. 覆盖不全(输入没恰好出现一次)→ review_failed ===")
def review_gap(grp):  # 只覆盖 #1,漏了 #2
    return {"ok": True, "parse_ok": True, "verdicts": {1: "accept"}, "output_ids": [1]}
st3, a3 = run_pass4(RECS, review_gap)
check("覆盖不全 → 整组 review_failed", st3[1] == Pass4Status.review_failed and st3[2] == Pass4Status.review_failed)
check("coverage_exactly_once:漏一条=False", not coverage_exactly_once([1, 2], [1]))
check("coverage_exactly_once:重复=False", not coverage_exactly_once([1, 2], [1, 2, 2]))
check("coverage_exactly_once:恰好=True", coverage_exactly_once([1, 2], [2, 1]))

print("=== 4. 调用失败 → review_failed ===")
st4, _ = run_pass4(RECS, lambda g: {"ok": False, "parse_ok": False, "output_ids": []})
check("调用失败 → review_failed", st4[1] == Pass4Status.review_failed)

print("=== 5. review_failed 留 staged,不进最终,不删(接 downstream_behavior)===")
er = EvidenceResult(Completeness.complete, Delivery.sent, DeliveryConfidence.confirmed,
                    AuthorEvidence(physical_key_backed=True), text="x", pass4_status=Pass4Status.review_failed)
d = downstream_behavior(er)
check("review_failed → 留 staged", d.in_staged)
check("review_failed → 不进最终", not d.eligible_final)
check("review_failed → 不进风格分析", not d.in_style_analysis)

print("=== 6. Pass4 按 (app, url) 分组 ===")
check("group_key = (app, url)", group_key(rec(1, app="Slack", url="u")) == ("Slack", "u"))
recs_g = [rec(1, app="A"), rec(2, app="A"), rec(3, app="B")]
seen = {}
def review_bygroup(grp):
    seen[grp[0]["app"]] = len(grp)   # 记录每组大小
    return {"ok": True, "parse_ok": True, "verdicts": {r["id"]: "accept" for r in grp},
            "output_ids": [r["id"] for r in grp]}
run_pass4(recs_g, review_bygroup)
check("A 组 2 条、B 组 1 条(分组正确)", seen == {"A": 2, "B": 1})

print("=== 7. Canvas 约束(§7.2)===")
good = {"source_method": "frame_edit", "cross_app_pool_role": "candidate_discovery",
        "is_new_content": True, "evidence": {"frame_evolution": True, "keystroke_or_edit": True,
        "reliable_doc_identity": True}, "canvas_pass4_done": True, "uses_evidence_result_contract": True}
ok, v = validate_canvas_record(good)
check("合规 Canvas 记录通过", ok and not v)
ok, v = validate_canvas_record({**good, "source_method": "longest_ocr_frame"})
check("最长 OCR 帧补尾 → 拦", (not ok) and any("最长 OCR" in x for x in v))
ok, v = validate_canvas_record({**good, "canvas_pass4_done": False})
check("绕过 Canvas 专用 Pass4 → 拦", (not ok) and any("Pass4" in x for x in v))
ok, v = validate_canvas_record({**good, "evidence": {"frame_evolution": True}})  # 缺击键+文档身份
check("新增内容缺证据 → 拦", (not ok) and any("缺证据" in x for x in v))
ok, v = validate_canvas_record({**good, "cross_app_pool_role": "text_source"})
check("跨 app 合池当文本来源 → 拦", (not ok) and any("候选发现" in x for x in v))
ok, v = validate_canvas_record({**good, "uses_evidence_result_contract": False})
check("不用 EvidenceResult 契约 → 拦", (not ok) and any("EvidenceResult" in x for x in v))

print(f"\n=== {len(FAILS)} 失败 ===")
sys.exit(1 if FAILS else 0)
