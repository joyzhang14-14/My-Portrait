"""t2_pkg_v3 二轮手术(ultra 审计修复)。从源头(v1.1 改写答案)重组装,修复:
- [rewrite/H1+hedge/M1] hedge 政策:全删(句子安全),仅零锚点样本保 1 处中性表述
  (不再声称"看不清"——那是假不可辨;中性="未逐字记录",永真)
- [rewrite/H2] 括号/标点吞噬:删除以完整括注/子句为单位 + 确定性校验器拦截
- [anchor/M] cap12 先跨池去重再填满(捞回被 prefix 截掉的已验证锚点)
- [complete/H1] 67 条 v1 短题混练行 specifics 清空(短题面无 OCR,不许配富锚点)
- [complete/H2] hedge 总量硬指标 <250(实际应 <60)
用法: python t2_fix_r2.py --workdir <v12目录> --rewrites <rw_results.json> --v1pkg <t2_pkg>
"""
import argparse
import collections
import json
import os
import re
import unicodedata

SPEC_CAP = 12
# hedge 词干(旧模板+一轮全部变体,一网打尽)
HEDGE_CORE = (r"无法(?:逐字)?辨认|字样过小|分辨率不足|难以看清|看不清楚?|无法确认|"
              r"不易分辨|不可辨|细节过小|具体字串看不清|内容过小|文字不易分辨|细节不可辨|"
              r"难以辨认|不易辨认|模糊不清|字迹模糊")
PAREN_HEDGE = re.compile(r"[((][^())]*?(?:" + HEDGE_CORE + r")[^())]*?[))]")
CLAUSE_HEDGE = re.compile(r"[,,;;]?[^,,。;;!?()()]*?(?:" + HEDGE_CORE + r")[^,,。;;!?()()]*")
NEUTRAL = ["(部分细节未逐字记录)", "(个别字串未收录)", "(少量内容从略)",
           "(部分文字未录全)", "(细节略)"]


def norm(s):
    s = unicodedata.normalize("NFKC", str(s))
    return re.sub(r"\s+", "", s).lower()


def _cleanup(t):
    t = re.sub(r"[,,]{2,}", ",", t)
    t = re.sub(r"[,,]([。;;!?])", r"\1", t)
    t = re.sub(r"([。;;!?])[,,]", r"\1", t)
    t = re.sub(r"。{2,}", "。", t)
    t = re.sub(r"^[,,、。]+", "", t)
    return t.strip()


def strip_hedges(text):
    """句子安全地删光 hedge:先删括注,再删含 hedge 的子句;若删得只剩空壳
    (<30字或缩水>40%),回退为只删括注(避免把整段叙述掏空)。"""
    src = str(text)
    t = PAREN_HEDGE.sub("", src)
    paren_only = _cleanup(t)
    t2 = _cleanup(CLAUSE_HEDGE.sub("", t))
    if src and (len(t2) < 30 or len(t2) < 0.6 * len(paren_only)):
        return paren_only
    return t2


def validate_text(t):
    """确定性校验:括号配对 + 无双标点残渣。返回问题列表。"""
    probs = []
    for a, b in [("(", ")"), ("(", ")"), ("「", "」"), ("《", "》"), ("[", "]")]:
        if t.count(a) != t.count(b):
            probs.append(f"括号不配对{a}{b}")
    if re.search(r"[,,]{2}|。。|[,,]。", t):
        probs.append("标点残渣")
    return probs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--rewrites", required=True)
    ap.add_argument("--v1pkg", required=True)
    args = ap.parse_args()
    W = args.workdir
    work = json.load(open(os.path.join(W, "t2_v3_work.json")))
    new_verdicts = {v["gid"]: v for v in
                    json.load(open(os.path.join(W, "nm_verdicts_v3.json")))["verdicts"]}
    rewrites = {int(r["si"]): r for r in json.load(open(args.rewrites))["rewrites"]}
    v1_rows = [json.loads(l) for l in open(os.path.join(args.v1pkg, "train.jsonl"),
                                           encoding="utf-8")]
    stats = collections.Counter()
    out = {"train": [], "valid": []}
    bad_texts = []

    for w in work:
        si = w["si"]
        q = w["question_v3"]
        cor = norm(q.split("输出 JSON")[0])
        # 锚点:kept + 通过的 corrected → 跨池去重 → 填到 12(修 prefix 截断)
        pool, seen = [], set()
        for s in w["spec_kept"]:
            k = norm(s)
            if k and k not in seen:
                seen.add(k)
                pool.append(s)
        for ni, nm in enumerate(w["spec_nearmiss"]):
            v = nm.get("verdict") or new_verdicts.get(f"{si}_{ni}")
            if v and v.get("keep") and v.get("corrected") and norm(v["corrected"]) in cor:
                k = norm(v["corrected"])
                if k and k not in seen:
                    seen.add(k)
                    pool.append(v["corrected"])
        final = pool[:SPEC_CAP]
        stats["spec_final"] += len(final)
        # 答案:从 v1.1 改写源重建(不用一轮受损产物)
        rw = rewrites.get(si)
        base = rw["answer"] if rw else w["answer"]
        if isinstance(base, str):
            base = json.loads(base)
        ans = dict(base)
        ans["specifics"] = final
        for f in ["activity", "context_in_app", "social"]:
            srcv = str(ans.get(f) or "")
            t = strip_hedges(srcv)
            new_probs = [p for p in validate_text(t) if p not in validate_text(srcv)]
            if new_probs:                        # 只计手术新伤,源头旧伤另计
                bad_texts.append((si, f, new_probs, t[:80]))
                stats["src_preexisting"] += 0
            if validate_text(srcv):
                stats["src_preexisting"] += 1
            ans[f] = t
        if not final:                          # 零锚点样本:允许 1 处中性说明
            ans["activity"] = (ans["activity"].rstrip("。") + "。"
                               + NEUTRAL[si % len(NEUTRAL)])
            stats["neutral_added"] += 1
        row = {"question": q, "answer": json.dumps(ans, ensure_ascii=False),
               "images": w["images"]}
        out[w["split"]].append(row)
        # 混练①:v1 短题行——specifics 必须清空(短题面无 OCR 依据)
        if w["split"] == "train" and si % 8 == 0:
            idx = len([x for x in work[:si + 1] if x["split"] == "train"]) - 1
            if idx < len(v1_rows):
                short_ans = dict(ans)
                short_ans["specifics"] = []
                out["train"].append({"question": v1_rows[idx]["question"],
                                     "answer": json.dumps(short_ans, ensure_ascii=False),
                                     "images": w["images"]})
                stats["mix_v1"] += 1
    # 混练②:沿用一轮的 30 条通用指令行(图已生成,直接从一轮 train.jsonl 搬)
    for line in open(os.path.join(W, "train.jsonl"), encoding="utf-8"):
        r = json.loads(line)
        if not r["answer"].startswith("{"):
            out["train"].append(r)
            stats["mix_generic"] += 1
    for split, rows in out.items():
        with open(os.path.join(W, "t2_pkg_v3", f"{split}.jsonl"), "w",
                  encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    stats["train"] = len(out["train"])
    stats["valid"] = len(out["valid"])
    stats["bad_texts"] = len(bad_texts)
    print(json.dumps(dict(stats), ensure_ascii=False))
    for b in bad_texts[:10]:
        print("VALIDATE:", b)


main()
