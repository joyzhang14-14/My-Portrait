"""t2_pkg_v3 构建(v1.2 数据手术)。处方见《验收-EventSessionVision-1.1-2026-07-11.md》§四。

--stage build: 重建 OCR 块(行级去重+预算10000)→ 锚点重分类(近失带放宽到
              [0.35,1.0),复用 v1.1 已有裁决,只把"新进近失带"的产出增量仲裁队列。
--stage assemble: 合并新旧裁决 → specifics(cap 12)→ 答案去模板(hedge≤1处+
              措辞变体轮换)→ 规则行三变体轮换 → 混练(v1短题67+通用指令30,全
              确定性)→ n-gram 审计 → train/valid.jsonl v3 + 审计报告。
"""
import argparse
import collections
import json
import os
import random
import re
import sqlite3
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chrome  # noqa: E402

PORTRAIT_DB = os.path.expanduser("~/.portrait/portrait.sqlite")
LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lab.db")
MANIFEST_SUFFIX = {"2026-06-07": "c"}
OCR_CAP = 10000                      # 12000→10000:捞回 21 个 OOM 长尾
SPEC_CAP = 12                        # 8→12:恢复锚点供给
NEARMISS_LO = 0.35                   # 0.5→0.35:放宽近失带

RULES_VARIANTS = [
    "规则:specifics 的逐字锚点必须逐字来自上方 OCR 文本;画面负责布局与归属,OCR 负责文字转写;两处都没有的内容宁可不写;无法辨认的部分直接省略。",
    "要求:specifics 只能填在上方 OCR 原文里逐字找得到的字串;布局和归属看画面,文字转写以 OCR 为准;没有依据的内容不要写。",
    "注意:锚点必须原样摘自 OCR 文本;画面用于判断位置与归属;OCR 里找不到的具体字串一律省略,拿不准就不写。",
]
HEDGE_PAT = re.compile(r"[((][^))]{0,30}?(?:无法(?:逐字)?辨认|字样过小|分辨率不足)[^))]{0,30}?[))]")
HEDGE_INLINE = re.compile(r"无法(?:逐字)?辨认|字样过小(?:,)?无法\S{0,6}|分辨率不足以\S{0,6}")
HEDGE_VARIANTS = ["(细节过小,难以看清)", "(具体字串看不清楚)", "(内容过小无法确认)",
                  "(该处文字不易分辨)", "(细节不可辨)"]
INLINE_VARIANTS = ["难以看清", "看不清楚", "无法确认", "不易分辨", "不可辨"]


def norm(s):
    s = unicodedata.normalize("NFKC", str(s))
    return re.sub(r"\s+", "", s).lower()


def grams(s, n=4):
    return [s[i:i + n] for i in range(len(s) - n + 1)] or [s]


def gram_score(anchor_n, corpus_n):
    gs = grams(anchor_n)
    return sum(1 for g in gs if g in corpus_n) / len(gs)


def best_excerpt(anchor_n, ocr_raw, w=250):
    ocr_n = norm(ocr_raw)
    hits = [ocr_n.find(g) for g in grams(anchor_n) if g in ocr_n]
    if not hits:
        return ocr_raw[:2 * w]
    c = sorted(hits)[len(hits) // 2]
    p = int(c / max(1, len(ocr_n)) * len(ocr_raw))
    return ocr_raw[max(0, p - w):p + w]


def dedup_lines(text):
    """OCR 块内行级去重(v1.1 教训六:块内重复行是复读诱饵)。full_text 是
    空格分隔 blob,按 ⏎ 和 20+ 字滑窗都不可靠——用简单可靠的:按空格切段,
    连续重复 token 串折叠 + 已见过的 ≥12 字片段丢弃。"""
    toks = text.split(" ")
    out, prev = [], None
    for t in toks:
        if t == prev:                # 连续重复 token 折叠
            continue
        out.append(t)
        prev = t
    text = " ".join(out)
    seen, keep = set(), []
    for seg in re.split(r"(?<=[。;!?.;!?])", text):
        k = norm(seg)
        if len(k) >= 12 and k in seen:
            continue
        if len(k) >= 12:
            seen.add(k)
        keep.append(seg)
    return "".join(keep)


def load_manifests():
    m = {}
    for day in ["2026-05-10", "2026-06-07", "2026-06-20", "2026-06-26", "2026-06-30"]:
        suf = MANIFEST_SUFFIX.get(day, "b")
        m[day] = json.load(open(f"/tmp/vision_v4{suf}_{day}/v4_manifest.json"))
    return m


def stage_build(args):
    con_p = sqlite3.connect(f"file:{PORTRAIT_DB}?mode=ro", uri=True)
    con_l = sqlite3.connect(f"file:{LAB_DB}?mode=ro", uri=True)
    manifests = load_manifests()
    cache = {}

    def frames_all(day, key):
        if (day, key) not in cache:
            fids = []
            for pid in manifests[day][str(key)]["parts"]:
                r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=?",
                                  (pid,)).fetchone()
                fids += json.loads(r[0])
            cache[(day, key)] = fids
        return cache[(day, key)]

    old_work = json.load(open(args.old_work))
    # v1.1 裁决按 (样本序, 近失序) 编 gid;换成 (si, anchor文本) 索引以便复用
    old_verdicts = {v["gid"]: v for v in json.load(open(args.old_verdicts))["verdicts"]}
    old_nm_anchor = {}
    for si, w in enumerate(old_work):
        for ni, nm in enumerate(w["spec_nearmiss"]):
            v = old_verdicts.get(f"{si}_{ni}")
            if v:
                old_nm_anchor[(si, nm["anchor"])] = v

    work, new_queue = [], []
    stats = collections.Counter()
    for si, w in enumerate(old_work):
        day, key = w["day"], w["key"]
        texts, seen = [], set()
        for k, _ in manifests[day][str(key)]["frames"]:
            r = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=?",
                              (frames_all(day, key)[k],)).fetchone()
            t = dedup_lines(chrome.strip_session_text((r[0] or "").strip()))
            if t and t not in seen:
                seen.add(t)
                texts.append(t)
        n = max(1, len(texts))
        alloc = [min(len(t), OCR_CAP // n) for t in texts]
        left = OCR_CAP - sum(alloc)
        for i, t in enumerate(texts):
            if left <= 0:
                break
            add = min(left, len(t) - alloc[i])
            alloc[i] += add
            left -= add
        ocr_block = "\n".join(f"[帧{i+1}] {t[:alloc[i]]}" for i, t in enumerate(texts))

        q1 = w["question_v2"]
        head = q1.split("已知(OCR")[0].rstrip()
        schema = "输出 JSON:" + q1.split("输出 JSON:", 1)[1]
        schema = schema.split("规则:")[0].rstrip()          # 剥掉旧规则行
        rules = RULES_VARIANTS[si % len(RULES_VARIANTS)]
        q3 = (head + "\n已知(OCR全文,按帧,含背景窗文字):\n<<<\n" + ocr_block
              + "\n>>>\n" + schema + "\n" + rules)
        corpus_n = norm(ocr_block + head)

        # 锚点重分类:教师原始 specifics 全量重扫(阈值放宽)
        specs = [str(x) for x in (w["answer"].get("specifics") or [])]
        kept, nearmiss, dropped = [], [], []
        for s in specs:
            sn = norm(s)
            if sn and sn in corpus_n:
                kept.append(s); stats["kept"] += 1
            elif sn and gram_score(sn, corpus_n) >= NEARMISS_LO:
                old = old_nm_anchor.get((si, s))
                if old is not None:
                    # 复用旧裁决(corrected 需在新语料复验,assemble 时做)
                    nearmiss.append({"anchor": s, "verdict": old})
                    stats["nm_reused"] += 1
                else:
                    nearmiss.append({"anchor": s,
                                     "excerpt": best_excerpt(sn, ocr_block)})
                    new_queue.append({"gid": f"{si}_{len(nearmiss)-1}",
                                      "anchor": s,
                                      "excerpt": best_excerpt(sn, ocr_block)})
                    stats["nm_new"] += 1
            else:
                dropped.append(s); stats["dropped"] += 1
        work.append({"si": si, "split": w["split"], "day": day, "key": key,
                     "images": w["images"], "question_v3": q3, "answer": w["answer"],
                     "spec_kept": kept, "spec_nearmiss": nearmiss,
                     "spec_dropped": dropped})
    json.dump(work, open(os.path.join(args.outdir, "t2_v3_work.json"), "w"),
              ensure_ascii=False)
    os.makedirs(os.path.join(args.outdir, "nm_batches_v3"), exist_ok=True)
    B = 20
    for bi in range(0, len(new_queue), B):
        json.dump(new_queue[bi:bi + B],
                  open(os.path.join(args.outdir, "nm_batches_v3",
                                    f"batch_{bi//B:03d}.json"), "w"),
                  ensure_ascii=False, indent=1)
    stats["new_batches"] = (len(new_queue) + B - 1) // B
    print(json.dumps(dict(stats), ensure_ascii=False))


def surgery_answer(ans, si, final_specs):
    """答案去模板:hedge 括注第1处换变体、第2+处删;行内 hedge 措辞轮换。"""
    ans = dict(ans)
    ans["specifics"] = final_specs
    for field in ["activity", "context_in_app", "social"]:
        t = str(ans.get(field) or "")
        cnt = [0]

        def par_sub(m):
            cnt[0] += 1
            return HEDGE_VARIANTS[(si + cnt[0]) % len(HEDGE_VARIANTS)] if cnt[0] == 1 else ""

        t = HEDGE_PAT.sub(par_sub, t)
        icnt = [0]

        def in_sub(m):
            icnt[0] += 1
            return INLINE_VARIANTS[(si + icnt[0]) % len(INLINE_VARIANTS)]

        t = HEDGE_INLINE.sub(in_sub, t)
        ans[field] = t
    return ans


GENERIC_QS = ["这张截图的前台应用是什么?直接回答应用名,不要JSON。",
              "屏幕当前聚焦在哪个应用?一句话回答。",
              "用一句话说出这张截图正在使用的应用程序名称。"]


def stage_assemble(args):
    work = json.load(open(os.path.join(args.outdir, "t2_v3_work.json")))
    new_verdicts = {}
    if args.new_verdicts and os.path.exists(args.new_verdicts):
        for v in json.load(open(args.new_verdicts))["verdicts"]:
            new_verdicts[v["gid"]] = v
    rewrites = {int(r["si"]): r for r in json.load(open(args.rewrites))["rewrites"]}
    v1_rows = [json.loads(l) for l in open(os.path.join(args.v1pkg, "train.jsonl"),
                                           encoding="utf-8")]
    stats = collections.Counter()
    out = {"train": [], "valid": []}

    for w in work:
        si = w["si"]
        q = w["question_v3"]
        cor = norm(q.split("输出 JSON")[0])
        final = list(w["spec_kept"])
        for ni, nm in enumerate(w["spec_nearmiss"]):
            v = nm.get("verdict") or new_verdicts.get(f"{si}_{ni}")
            if v and v.get("keep") and v.get("corrected") \
                    and norm(v["corrected"]) in cor:
                final.append(v["corrected"])
        final = final[:SPEC_CAP]
        stats["spec_final"] += len(final)
        # 答案:优先用 v1.1 的外科改写(叙述已对齐删除),再做去模板手术
        rw = rewrites.get(si)
        base_ans = rw["answer"] if rw else w["answer"]
        if isinstance(base_ans, str):
            base_ans = json.loads(base_ans)
        ans = surgery_answer(base_ans, si, final)
        row = {"question": q, "answer": json.dumps(ans, ensure_ascii=False),
               "images": w["images"]}
        out[w["split"]].append(row)
        # 混练①:每 8 个训练样本加一条 v1 短题版(v1题面+手术后答案)
        if w["split"] == "train" and si % 8 == 0 and si < len(v1_rows) * 8:
            idx = len([x for x in work[:si + 1] if x["split"] == "train"]) - 1
            if idx < len(v1_rows):
                out["train"].append({"question": v1_rows[idx]["question"],
                                     "answer": row["answer"],
                                     "images": w["images"]})
                stats["mix_v1"] += 1
    # 混练②:30 条通用指令(15 合成图形 + 15 前台app问答,全确定性)
    from PIL import Image, ImageDraw
    gdir = os.path.join(args.outdir, "generic_imgs")
    os.makedirs(gdir, exist_ok=True)
    rnd = random.Random(42)
    shapes = ["circle", "rect", "ellipse"]
    colors = [("红色", "red"), ("蓝色", "blue"), ("绿色", "green"), ("黄色", "gold")]
    for gi in range(15):
        im = Image.new("RGB", (640, 480), "white")
        d = ImageDraw.Draw(im)
        cn, cv = colors[gi % 4]
        k = rnd.randint(1, 4)
        for j in range(k):
            x, y = 40 + j * 150, 60 + (j % 2) * 180
            d.ellipse([x, y, x + 100, y + 100], fill=cv)
        for j in range(rnd.randint(1, 3)):     # 干扰形状(异色矩形)
            x, y = 60 + j * 160, 300
            d.rectangle([x, y, x + 80, y + 60],
                        fill=colors[(gi + 2) % 4][1])
        p = os.path.join(gdir, f"g{gi}.jpg")
        im.save(p)
        out["train"].append({
            "question": f"图中有几个{cn}的圆形?直接回答数字,不要JSON。",
            "answer": str(k), "images": [os.path.relpath(p, args.outdir)]})
        stats["mix_generic"] += 1
    picked = [w for w in work if w["split"] == "train"][10::34][:15]
    for gi, w in enumerate(picked):
        m = re.search(r"前台 app = ([^;;\n]+)", w["question_v3"])
        if not m:
            continue
        app = m.group(1).strip()
        out["train"].append({"question": GENERIC_QS[gi % 3],
                             "answer": app, "images": w["images"][:1]})
        stats["mix_generic"] += 1
    # 落盘 + n-gram 审计
    for split, rows in out.items():
        with open(os.path.join(args.outdir, f"{split}.jsonl"), "w",
                  encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    stats["train"] = len(out["train"])
    stats["valid"] = len(out["valid"])
    ng = collections.Counter()
    for r in out["train"]:
        a = r["answer"]
        for i in range(0, max(0, len(a) - 8), 4):
            ng[a[i:i + 8]] += 1
    n = len(out["train"])
    hot = [(g, c) for g, c in ng.most_common(40)
           if c > n * 0.05 and not re.match(r'^[\s",::\[\]{}»«]*$', g)
           and not re.search(r'(activity|specifics|context|social|who)', g)]
    print(json.dumps(dict(stats), ensure_ascii=False))
    print("n-gram审计(答案侧,>5%样本的非结构8-gram):", hot[:12] if hot else "✅ 无")


if __name__ == "__main__":       # 加守卫:推理侧 v12_day.py 要 import dedup_lines(训推共用一份实现)
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, choices=["build", "assemble"])
    ap.add_argument("--old-work")
    ap.add_argument("--old-verdicts")
    ap.add_argument("--new-verdicts")
    ap.add_argument("--rewrites")
    ap.add_argument("--v1pkg")
    ap.add_argument("--outdir", required=True)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    stage_build(a) if a.stage == "build" else stage_assemble(a)
