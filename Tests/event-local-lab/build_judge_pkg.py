"""构建双盲裁判包:每个会话 = 帧图 + OCR + 两份匿名 digest(v1.2 / base 随机打乱)。

确定性指标(JSON 合法/锚点可验证)会被骗:背景桌面碎渣也能"逐字来自 OCR"。
真正要问的是「这份 digest 对三个消费者(event / writing-style / personality)有没有用」,
那必须让裁判看着画面判。

用法: python build_judge_pkg.py --a /tmp/v12_day_2026-06-05.md.jsonl \
        --b /tmp/base_2026-06-05.md.jsonl --out /tmp/judge_pkg.json
"""
import argparse
import json
import os
import random

FRAMES = "/tmp/vision_frames_v4b_2026-06-05"
MANIFEST = "/tmp/vision_v4b_2026-06-05/v4_manifest.json"
OCR_SHOW = 2500      # 裁判看的 OCR 上限(够判归属和锚点相关性)


def load(p):
    rows = {}
    for l in open(p, encoding="utf-8"):
        r = json.loads(l)
        rows[r["key"]] = r
    return rows


def slim(d):
    """只给裁判看内容字段,抹掉血统线索(specifics_raw_n / json_ok 会泄题)。"""
    return {k: d.get(k) for k in ("activity", "who", "context_in_app", "specifics", "social")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="v1.2 jsonl")
    ap.add_argument("--b", required=True, help="base jsonl")
    ap.add_argument("--prompts", default="/tmp/v12_prompts_0605.json")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    A, B = load(args.a), load(args.b)
    P = json.load(open(args.prompts))
    M = json.load(open(MANIFEST))
    rnd = random.Random(605)

    pkg = []
    for k in sorted(set(A) & set(B)):
        sk = str(k)
        q = P[sk]
        ocr = q.split("<<<\n", 1)[1].split("\n>>>", 1)[0]
        head = q.split("\n已知(OCR", 1)[0]
        # 双盲:随机决定谁是"甲"
        a_first = rnd.random() < 0.5
        pkg.append({
            "key": k,
            "head": head,                       # 模型看到的「已知(系统API)」原文
            "frame": os.path.join(FRAMES, M[sk]["frames"][0][1]),
            "ocr": ocr[:OCR_SHOW],
            "ocr_truncated": len(ocr) > OCR_SHOW,
            "ocr_len": len(ocr),
            "甲": slim((A if a_first else B)[k]["digest"]),
            "乙": slim((B if a_first else A)[k]["digest"]),
            "_key_甲": "v1.2" if a_first else "base",   # 裁判看不到(评分后才对表)
        })
    json.dump(pkg, open(args.out, "w"), ensure_ascii=False, indent=1)
    na = sum(1 for x in pkg if x["_key_甲"] == "v1.2")
    print(f"[judge] {len(pkg)} 会话 → {args.out}(v1.2 当「甲」{na} 次 / 当「乙」{len(pkg)-na} 次)")


main()
