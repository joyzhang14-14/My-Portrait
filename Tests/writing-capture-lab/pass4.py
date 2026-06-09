#!/usr/bin/env python3
"""阶段六 · Pass4 固定行为状态机(规范 §7.1)。**确定性、可无模型测**(review_fn 抽象)。

§7.1:
  成功 accepted → 进入最终 writing_records
  成功 rejected → 进入 discarded + 保存原因
  调用失败 / 解析失败 / 输入记录未被输出恰好覆盖一次 → 留 staged,review_failed,不进最终,不删
  partial / draft / unknown / unrecoverable → pass4_status = not_applicable
必须记录:原始输出、解析状态、每条输入是否恰好出现一次、失败组数量。
分组按生产 (app, url) 一致。解析失败**绝不默认全留**(→ review_failed)。
"""
from collections import Counter
from evidence import Pass4Status

def eligible_for_pass4(rec) -> bool:
    """只有 complete + sent 进 Pass4 审查;其余按数据契约 not_applicable。"""
    return rec.get("completeness") == "complete" and rec.get("delivery") == "sent"

def group_key(rec):
    """生产一致分组:(app, url)。"""
    return (rec.get("app"), rec.get("url"))

def coverage_exactly_once(input_ids, output_ids) -> bool:
    """每条输入恰好出现一次,且输出不含输入以外的 id。"""
    c = Counter(output_ids)
    return all(c.get(i, 0) == 1 for i in input_ids) and set(output_ids) <= set(input_ids)

def run_pass4(records, review_fn):
    """records: [{id, app, url, completeness, delivery, text}]。
    review_fn(group_records) → {ok, parse_ok, verdicts:{id:'accept'|'reject'}, output_ids:[...], raw}。
    返回 (status_by_id: {id: Pass4Status}, audit)。"""
    status = {}
    audit = {"raw": {}, "parse_ok": {}, "coverage_ok": {}, "failed_groups": 0,
             "each_input_exactly_one_status": True}

    # 1. 非 eligible(partial/draft/unknown/unrecoverable 等)→ not_applicable
    elig = []
    for r in records:
        if eligible_for_pass4(r):
            elig.append(r)
        else:
            status[r["id"]] = Pass4Status.not_applicable

    # 2. 按 (app, url) 分组
    groups = {}
    for r in elig:
        groups.setdefault(group_key(r), []).append(r)

    # 3. 逐组审查 + 覆盖校验
    for key, grp in groups.items():
        rev = review_fn(grp)
        input_ids = [r["id"] for r in grp]
        covered = coverage_exactly_once(input_ids, rev.get("output_ids", []))
        audit["raw"][key] = rev.get("raw")
        audit["parse_ok"][key] = bool(rev.get("parse_ok"))
        audit["coverage_ok"][key] = covered
        # 4. 调用失败 / 解析失败 / 覆盖不全 → 整组 review_failed(不默认全留,不删)
        if (not rev.get("ok")) or (not rev.get("parse_ok")) or (not covered):
            audit["failed_groups"] += 1
            for r in grp:
                status[r["id"]] = Pass4Status.review_failed
        else:
            for r in grp:
                v = rev.get("verdicts", {}).get(r["id"])
                status[r["id"]] = Pass4Status.accepted if v == "accept" else Pass4Status.rejected

    # 校验:每条输入恰好一个状态
    audit["each_input_exactly_one_status"] = (len(status) == len(records)
                                              and set(status) == {r["id"] for r in records})
    return status, audit
