"""t2_pkg_v2 构建 Stage-3:裁决合并 + 重写队列 + 终装。

--stage queue:合并 W1 近失裁决(确定性回验 corrected 必须真在语料里),
              算每样本移除量,产出 W2 重写队列(重删样本送 sonnet 改写叙述)。
--stage final:合并 W2 改写(JSON/锚点回验,失败退确定性兜底),组装
              train/valid.jsonl v2 + 审计抽样 md + 统计。
"""
import argparse
import json
import os
import random
import re
import unicodedata

SPEC_CAP = 8
HEAVY_MIN, HEAVY_RATIO = 5, 0.5


def norm(s):
    s = unicodedata.normalize("NFKC", str(s))
    return re.sub(r"\s+", "", s).lower()


def corpus_of(w):
    """从 question_v2 里抠出 OCR 块+题头,重建验证语料。"""
    q = w["question_v2"]
    m = re.search(r"<<<\n(.*)\n>>>", q, re.S)
    ocr = m.group(1) if m else ""
    return norm(ocr + q.split("已知(OCR")[0])


def resolve_specs(w, verdicts):
    """按教师原序合成最终 specifics;返回 (final, removed)。"""
    cor = corpus_of(w)
    nearmiss_fate = {}
    for ni, nm in enumerate(w["spec_nearmiss"]):
        v = verdicts.get(f"{w['_si']}_{ni}")
        ok = bool(v and v["keep"] and v["corrected"] and norm(v["corrected"]) in cor)
        nearmiss_fate[nm["anchor"]] = v["corrected"] if ok else None
    final, removed = [], []
    for s in [str(x) for x in (w["answer"].get("specifics") or [])]:
        if s in w["spec_kept"]:
            final.append(s)
        elif s in nearmiss_fate:
            c = nearmiss_fate[s]
            final.append(c) if c is not None else removed.append(s)
        else:
            removed.append(s)                    # spec_dropped
    return final[:SPEC_CAP], removed + final[SPEC_CAP:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, choices=["queue", "final"])
    ap.add_argument("--work", required=True)
    ap.add_argument("--verdicts", required=True, help="W1 裁决 json(verdicts 数组)")
    ap.add_argument("--rewrites", help="W2 改写 json(final 阶段用)")
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    work = json.load(open(args.work))
    for si, w in enumerate(work):
        w["_si"] = si
    verdicts = {v["gid"]: v for v in json.load(open(args.verdicts))["verdicts"]}
    os.makedirs(args.outdir, exist_ok=True)

    resolved = [resolve_specs(w, verdicts) for w in work]

    if args.stage == "queue":
        qdir = os.path.join(args.outdir, "rw_items")
        os.makedirs(qdir, exist_ok=True)
        queue = []
        for w, (final, removed) in zip(work, resolved):
            total = len(final) + len(removed)
            if not (len(removed) >= HEAVY_MIN
                    or (total >= 2 and len(removed) / total >= HEAVY_RATIO)):
                continue
            m = re.search(r"<<<\n(.*)\n>>>", w["question_v2"], re.S)
            item = {"si": w["_si"], "answer": w["answer"],
                    "final_specs": final, "removed": removed,
                    "ocr": (m.group(1) if m else "")[:6000]}
            p = os.path.join(qdir, f"rw_{w['_si']:03d}.json")
            json.dump(item, open(p, "w"), ensure_ascii=False, indent=1)
            queue.append(p)
        json.dump(queue, open(os.path.join(args.outdir, "rw_queue.json"), "w"))
        print(f"重写队列: {len(queue)}/{len(work)} 样本 → {args.outdir}/rw_items")
        return

    # ---- final ----
    rewrites = {}
    if args.rewrites and os.path.exists(args.rewrites):
        for r in json.load(open(args.rewrites))["rewrites"]:
            rewrites[int(r["si"])] = r
    stats = {"total": len(work), "rewritten": 0, "rewrite_fallback": 0,
             "spec_final": 0, "spec_removed": 0}
    out = {"train": [], "valid": []}
    audit = []
    for w, (final, removed) in zip(work, resolved):
        ans = dict(w["answer"])
        rw = rewrites.get(w["_si"])
        used_rw = False
        if rw:
            try:
                cand = rw["answer"] if isinstance(rw["answer"], dict) \
                    else json.loads(rw["answer"])
                cor = corpus_of(w)
                specs_ok = all(norm(s) in cor for s in (cand.get("specifics") or []))
                act = str(cand.get("activity", ""))
                if specs_ok and 50 <= len(act) <= 2500:
                    ans = cand
                    ans["specifics"] = (cand.get("specifics") or [])[:SPEC_CAP]
                    used_rw = True
                    stats["rewritten"] += 1
            except Exception:
                pass
            if not used_rw:
                stats["rewrite_fallback"] += 1
        if not used_rw:
            ans["specifics"] = final
        stats["spec_final"] += len(ans["specifics"])
        stats["spec_removed"] += len(removed)
        out[w["split"]].append({
            "question": w["question_v2"],
            "answer": json.dumps(ans, ensure_ascii=False),
            "images": w["images"]})
        audit.append({"si": w["_si"], "day": w["day"], "key": w["key"],
                      "used_rw": used_rw, "removed": removed,
                      "final_specs": ans["specifics"]})
    for split, rows in out.items():
        with open(os.path.join(args.outdir, f"{split}.jsonl"), "w",
                  encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    json.dump(audit, open(os.path.join(args.outdir, "audit_all.json"), "w"),
              ensure_ascii=False, indent=1)
    # 抽样审计 md
    random.Random(7).shuffle(audit)
    lines = ["# t2_pkg_v2 抽样审计(20/559)\n",
             "每条:锚点删了什么/留了什么/是否走了叙述改写。OCR注入后锚点可验证率=100%(构造保证)。\n"]
    for a in audit[:20]:
        lines.append(f"\n## s{a['key']} ({a['day']}) {'[改写]' if a['used_rw'] else ''}")
        lines.append("**留** " + (" | ".join(a["final_specs"]) or "(无)"))
        lines.append("**删** " + (" | ".join(str(x)[:60] for x in a["removed"]) or "(无)"))
    open(os.path.expanduser("~/Desktop/t2v2-抽样审计-2026-07-10.md"), "w",
         encoding="utf-8").write("\n".join(lines))
    print(json.dumps(stats, ensure_ascii=False))
    print(f"→ {args.outdir}/train.jsonl valid.jsonl + 桌面审计md")


main()
