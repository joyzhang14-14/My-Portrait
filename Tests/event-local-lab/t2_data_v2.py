"""t2_pkg_v2 构建 Stage-1:OCR 注入 + 确定性锚点过滤。

样本帧 → 生产库 full_text(全量,无截断)→ chrome 剥离 → OCR 块注入 question;
教师 specifics 逐条对 OCR 语料验证:精确命中=保留 / 4-gram≥0.5=近失(送 LLM 仲裁)/ 其余=删。
产出 work 文件(含近失队列)供 Stage-2 workflow 仲裁,不直接出最终包。

用法: python t2_data_v2.py --pkg <老t2_pkg目录> --out <work.json>
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chrome  # noqa: E402

PORTRAIT_DB = os.path.expanduser("~/.portrait/portrait.sqlite")
LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lab.db")
MANIFEST_SUFFIX = {"2026-06-07": "c"}          # 其余天是 v4b
OCR_CAP = 12000                                 # 与 source.MAX_OCR_CHARS 对齐
SPEC_CAP = 8                                    # 复读疫苗:specifics 上限
NEARMISS_LO = 0.5

RULES = ("规则:specifics 的逐字锚点必须逐字来自上方 OCR 文本;画面负责布局与归属,"
         "OCR 负责文字转写;两处都没有的内容宁可不写;无法辨认的部分直接省略。")


def norm(s):
    s = unicodedata.normalize("NFKC", str(s))
    return re.sub(r"\s+", "", s).lower()


def grams(s, n=4):
    return [s[i:i + n] for i in range(len(s) - n + 1)] or [s]


def gram_score(anchor_n, corpus_n):
    gs = grams(anchor_n)
    return sum(1 for g in gs if g in corpus_n) / len(gs)


def best_excerpt(anchor_n, ocr_raw, w=250):
    """定位近失锚点在原始 OCR 里最密集命中的窗口,给 LLM 仲裁看上下文。"""
    ocr_n = norm(ocr_raw)
    hits = [ocr_n.find(g) for g in grams(anchor_n) if g in ocr_n]
    if not hits:
        return ocr_raw[:2 * w]
    c = sorted(hits)[len(hits) // 2]
    # 按归一化比例折回原文位置(近似)
    p = int(c / max(1, len(ocr_n)) * len(ocr_raw))
    return ocr_raw[max(0, p - w):p + w]


def load_manifests():
    m = {}
    for day in ["2026-05-10", "2026-06-07", "2026-06-20", "2026-06-26", "2026-06-30"]:
        suf = MANIFEST_SUFFIX.get(day, "b")
        p = f"/tmp/vision_v4{suf}_{day}/v4_manifest.json"
        m[day] = json.load(open(p))
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkg", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    con_p = sqlite3.connect(f"file:{PORTRAIT_DB}?mode=ro", uri=True)
    con_l = sqlite3.connect(f"file:{LAB_DB}?mode=ro", uri=True)
    manifests = load_manifests()
    frames_all_cache = {}

    def frames_all(day, key):
        if (day, key) not in frames_all_cache:
            parts = manifests[day][str(key)]["parts"]
            fids = []
            for pid in parts:
                r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=?",
                                  (pid,)).fetchone()
                fids += json.loads(r[0])
            frames_all_cache[(day, key)] = fids
        return frames_all_cache[(day, key)]

    def frame_text(fid):
        r = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=?",
                          (fid,)).fetchone()
        return chrome.strip_session_text((r[0] or "").strip()) if r else ""

    work, stats = [], {"samples": 0, "specs": 0, "kept": 0, "nearmiss": 0,
                       "dropped": 0, "spec_capped": 0, "ocr_empty": 0}
    for split in ["train", "valid"]:
        for li, line in enumerate(open(os.path.join(args.pkg, f"{split}.jsonl"),
                                       encoding="utf-8")):
            r = json.loads(line)
            imgs = r["images"][:2]                     # 图与训练 max-images 一致
            m = re.match(r"frames/(\d{4}-\d{2}-\d{2})_s(\d+)_", imgs[0])
            day, key = m.group(1), int(m.group(2))
            # OCR 块对齐教师视野:manifest 的全部 kept 帧(≤3),不止展示的2张图
            texts, seen = [], set()
            for k, _jpg in manifests[day][str(key)]["frames"]:
                fid = frames_all(day, key)[k]
                t = frame_text(fid)
                if t and t not in seen:
                    seen.add(t)
                    texts.append(t)
            # 两轮分配:先保底平分,剩余预算补给被截的帧(密集帧不饿死另一帧)
            n = max(1, len(texts))
            alloc = [min(len(t), OCR_CAP // n) for t in texts]
            left = OCR_CAP - sum(alloc)
            for i, t in enumerate(texts):
                if left <= 0:
                    break
                add = min(left, len(t) - alloc[i])
                alloc[i] += add
                left -= add
            ocr_block = "\n".join(f"[帧{i+1}] {t[:alloc[i]]}"
                                  for i, t in enumerate(texts))
            if len(ocr_block) < 60:
                stats["ocr_empty"] += 1
            corpus_n = norm(ocr_block + r["question"].split("输出 JSON")[0])

            q = r["question"]
            head, schema = q.split("输出 JSON:", 1)
            q2 = (head.rstrip() + "\n已知(OCR全文,按帧,含背景窗文字):\n<<<\n"
                  + ocr_block + "\n>>>\n输出 JSON:" + schema.rstrip() + "\n" + RULES)

            ans = json.loads(r["answer"])
            specs = [str(s) for s in (ans.get("specifics") or [])]
            # cap 移到 Stage-3 组装时做(先验证再截,保住好锚点)
            kept, nearmiss, dropped = [], [], []
            for s in specs:
                sn = norm(s)
                stats["specs"] += 1
                if sn and sn in corpus_n:
                    kept.append(s); stats["kept"] += 1
                elif sn and gram_score(sn, corpus_n) >= NEARMISS_LO:
                    nearmiss.append({"anchor": s,
                                     "excerpt": best_excerpt(sn, ocr_block)})
                    stats["nearmiss"] += 1
                else:
                    dropped.append(s); stats["dropped"] += 1
            stats["samples"] += 1
            work.append({"split": split, "line": li, "day": day, "key": key,
                         "images": imgs, "question_v2": q2, "answer": ans,
                         "spec_kept": kept, "spec_nearmiss": nearmiss,
                         "spec_dropped": dropped})
    json.dump(work, open(args.out, "w"), ensure_ascii=False)
    print(json.dumps(stats, ensure_ascii=False))


main()
