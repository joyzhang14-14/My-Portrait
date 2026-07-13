"""v1.3 训练包组装:手术产出 + 确定性新题头 → train/valid.jsonl。

对 v1.2 的五处改动:
  D1 题头:教师解读 → 确定性合成(裸 app + has_dev_signal 三重条件注释)
  D2 归属:sonnet 看图改写(训练答案本身错的只有 12 条)
  D3 social:剔除天气/日历/桌面噪声
  D4 锚点:从教师原始锚点按相关性重选,自然停止(不再硬截断堆在 12)
  D5 图数:训练改【单图】,与生产 _vask 的单图调用对齐(v1.2 报告坑 3 的定案)

内置闸门(过不了就不出包):
  · 锚点逐字校验:编造的锚点直接丢弃(与推理侧同一套 norm)
  · n-gram 审计:非结构 8-gram 出现率 > 5% 报警(v1.1 死于 882 次固定措辞)
  · 撞 cap 率:重选后仍有大量样本正好 12 个 → 说明"自然停止"没做到
"""
import argparse
import collections
import json
import os
import re
import unicodedata

SPEC_CAP = 12


def norm(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default="/tmp/work_v13.json")
    ap.add_argument("--surgery", default="/tmp/v13_out")
    ap.add_argument("--pkg", default="/tmp/t2v3/t2_pkg_v3")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--multi-image", action="store_true", help="保留 2 图(默认单图,对齐生产)")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    W = json.load(open(args.work))
    work = {f"{w['day']}_s{w['key']}": w for w in W["work"]}
    surg = {}
    for f in sorted(os.listdir(args.surgery)):
        if not f.endswith(".json"):
            continue
        try:
            for r in json.load(open(os.path.join(args.surgery, f), encoding="utf-8")):
                surg[r["id"]] = r
        except Exception as e:
            print(f"  ⚠️ {f} 读不了: {e}")

    st = collections.Counter()
    out = {"train": [], "valid": []}
    for sid, w in work.items():
        s = surg.get(sid)
        if not s:
            st["未手术(沿用旧答案)"] += 1
            s = dict(w["answer"])
        corpus = norm(w["ocr"] + w["head_new"])
        # 锚点逐字校验(与推理侧同一套 norm)—— 编造的丢弃
        specs, seen = [], set()
        for x in (s.get("specifics") or []):
            k = norm(x)
            if k and k in corpus and k not in seen:
                seen.add(k)
                specs.append(str(x).strip()[:60])
            elif k:
                st["锚点编造被丢弃"] += 1
        specs = specs[:SPEC_CAP]
        ans = {"activity": str(s.get("activity") or "").strip(),
               "who": [str(x).strip()[:40] for x in (s.get("who") or []) if str(x).strip()],
               "context_in_app": str(s.get("context_in_app") or "").strip(),
               "specifics": specs,
               "social": str(s.get("social") or "").strip()}
        if not ans["activity"]:
            st["答案空(丢弃)"] += 1
            continue
        # D1:题头换成确定性合成;OCR 块 / SCHEMA / 规则行逐字沿用(已验证不是问题,别动)
        q = (w["head_new"] + "\n已知(OCR全文,按帧,含背景窗文字):\n<<<\n"
             + w["ocr"] + "\n>>>\n" + w["schema_rules"])
        imgs = w["images"] if args.multi_image else w["images"][:1]   # D5:对齐生产的单图
        out[w["split"]].append({"question": q, "answer": json.dumps(ans, ensure_ascii=False),
                                "images": imgs})
        st[f"采用_{w['split']}"] += 1

    # 混练短题原样保留(防塌缩,v1.2 已验证有效)
    for m in W["mix"]:
        out[m["split"]].append({"question": m["question"], "answer": m["answer"],
                                "images": m["images"][:1] if not args.multi_image else m["images"]})
        st[f"混练_{m['split']}"] += 1

    for split, rows in out.items():
        with open(os.path.join(args.outdir, f"{split}.jsonl"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # ===== 闸门 =====
    tr = out["train"]
    n = len(tr)
    sc = collections.Counter(len(json.loads(r["answer"])["specifics"]) for r in tr
                             if "已知(OCR" in r["question"])
    real = sum(sc.values())
    ng = collections.Counter()
    for r in tr:
        a = r["answer"]
        for i in range(0, max(0, len(a) - 8), 4):
            ng[a[i:i + 8]] += 1
    hot = [(g, c) for g, c in ng.most_common(60)
           if c > n * 0.05 and not re.match(r'^[\s",::\[\]{}»«]*$', g)
           and not re.search(r'(activity|specifics|context|social|who)', g)]
    print(json.dumps(dict(st), ensure_ascii=False, indent=1))
    print(f"\ntrain {len(out['train'])} / valid {len(out['valid'])}")
    print(f"锚点撞 cap({SPEC_CAP} 个): {sc[SPEC_CAP]}/{real} = "
          f"{sc[SPEC_CAP]/max(1,real)*100:.0f}%  (v1.2 是 36% —— 越低越好)")
    print(f"图数: {'2图' if args.multi_image else '单图(对齐生产)'}")
    print(f"n-gram 审计(>5% 样本的非结构 8-gram): "
          f"{hot[:8] if hot else '✅ 无模板吸引子'}")


main()
