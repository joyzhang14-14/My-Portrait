"""留出日验收:确定性指标 + 分层对比(v1.2 vs 原版底座)。

为什么必须分层:6-05 的题目系统性比 6-07 简单(OCR 9k+ 长尾 2.9% vs 8.9%),
总体数字会天然好看。按 OCR 长度分桶才能把「题目更简单」和「泛化更好」分开。
A/B 只在共同的抽样 key 上做配对比较(base 只跑了 120 条)。

用法: python eval_holdout.py --a /tmp/v12_day_2026-06-05.md.jsonl \
                             --b /tmp/base_2026-06-05.md.jsonl
"""
import argparse
import collections
import json
import re
import sys
import unicodedata

BUCKETS = [(0, 1000, "0-1k"), (1000, 3000, "1-3k"), (3000, 6000, "3-6k"),
           (6000, 9000, "6-9k"), (9000, 10**9, "9k+")]
HEDGE = re.compile(r"无法(?:逐字)?辨认|字样过小|分辨率不足|难以看清|看不清楚|不易分辨|不可辨")

# ⚠️ who 只判非空是个已被实锤的假信号:6-05 A/B 里 base「21.7% vs 11.7% 领先」
# 全是 base 把 Claude/AI助手/用户自己当人塞进 who 造出来的(按「含至少一个真人」
# 两边 13/120 打平)。必须拆成 who_person / who_noise 两列。
WHO_NOISE = re.compile(r'^(claude|chatgpt|copilot|gemini)\b|subagent|子代理|ai ?助手'
                       r'|ai ?编程助手|cli ?助手|助手$', re.I)
WHO_SELF = {'joyzhang14', 'joy', 'joy zhang', 'zhuoyi', 'zhuoyi zhang', '用户', 'user', '我'}
WHO_APP = {'finder', 'terminal', 'safari', 'xcode', 'spotify', 'obsidian', 'mail',
           'sourcetree', 'wechat', '微信', 'discord', 'goodnotes', '无'}


def who_split(who):
    """返回 (真人条数, 噪声条数)。裸名判身份(括号注释剥掉)。"""
    person = noise = 0
    for x in who or []:
        raw = str(x).strip()
        if not raw:
            continue
        base = re.split(r'[（(]', raw, 1)[0].strip()
        if WHO_NOISE.search(raw) or base.casefold() in WHO_SELF or base.casefold() in WHO_APP:
            noise += 1
        else:
            person += 1
    return person, noise


SOCIAL_NEG = re.compile(r'^(无|没有|未见|未发现|不涉及|非社交)')


def norm(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


def bucket(n):
    for lo, hi, nm in BUCKETS:
        if lo <= n < hi:
            return nm
    return "9k+"


def repeats(t, n=12):
    """复读检测:任一 12-gram 出现 ≥4 次。"""
    g = collections.Counter(t[i:i + n] for i in range(0, max(0, len(t) - n), 3))
    return bool(g) and g.most_common(1)[0][1] >= 4


def load(p):
    rows = {}
    for l in open(p, encoding="utf-8"):
        r = json.loads(l)
        rows[r["key"]] = r          # 后写覆盖先写(--redo-bad 重跑的以最新为准)
    return rows


def metrics(rows):
    """一行 = 一个会话。返回逐会话的指标 dict。"""
    out = {}
    for k, r in rows.items():
        d = r["digest"]
        act = str(d.get("activity") or "")
        specs = d.get("specifics") or []
        out[k] = {
            "bucket": bucket(r["ocr_len"]),
            "n_frames": r["n_frames"],
            "app": r["app"],
            "json_ok": bool(d.get("json_ok")),
            # 空壳:JSON 崩了,或 activity 短到没信息量 —— 对三个消费者等于永久隐形
            "shell": (not d.get("json_ok")) or len(act) < 30,
            "n_spec": len(specs),                       # 已过 OCR 逐字校验
            "n_spec_raw": int(d.get("specifics_raw_n") or 0),
            "verif": (len(specs) / d["specifics_raw_n"]) if d.get("specifics_raw_n") else None,
            "who_person": who_split(d.get("who"))[0] > 0,
            "who_noise": who_split(d.get("who"))[1] > 0,
            "has_social": (bool(str(d.get("social") or "").strip())
                           and not SOCIAL_NEG.match(str(d.get("social") or "").strip())),
            "has_ctx": bool(str(d.get("context_in_app") or "").strip()),
            "act_len": len(act),
            "hedge": bool(HEDGE.search(act)),
            "repeat": repeats(act),
            # 跑飞 = JSON 没闭合且原始输出很长 → v1.2 的已知缺陷「列表刹不住」(rp1.05 压住了,
            # 留出日要复查有没有在新分布上复发)
            "runaway": (not d.get("json_ok")) and r.get("raw_len", 0) > 3000,
        }
    return out


def agg(ms, keys=None):
    ks = [k for k in ms if keys is None or k in keys]
    n = len(ks) or 1
    f = lambda p: sum(1 for k in ks if ms[k][p]) / n * 100
    spec = sorted(ms[k]["n_spec"] for k in ks)
    vs = [ms[k]["verif"] for k in ks if ms[k]["verif"] is not None]
    return {
        "n": len(ks),
        "JSON合法%": round(sum(1 for k in ks if ms[k]["json_ok"]) / n * 100, 1),
        "空壳%": round(f("shell"), 1),
        "锚点中位": spec[len(spec) // 2] if spec else 0,
        "锚点可验证%": round(sum(vs) / len(vs) * 100, 1) if vs else 0.0,
        "who人%": round(f("who_person"), 1),
        "who噪%": round(f("who_noise"), 1),
        "social%": round(f("has_social"), 1),
        "ctx%": round(f("has_ctx"), 1),
        "hedge%": round(f("hedge"), 1),
        "复读%": round(f("repeat"), 1),
        "跑飞%": round(f("runaway"), 1),
    }


def table(title, rows, cols):
    print(f"\n{title}")
    w = max(len(str(r[0])) for r in rows) + 2
    print("  " + "".ljust(w) + "".join(c.rjust(12) for c in cols))
    for name, m in rows:
        print("  " + str(name).ljust(w) + "".join(str(m.get(c, "-")).rjust(12) for c in cols))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="v1.2 jsonl")
    ap.add_argument("--b", help="base 对照 jsonl(可选)")
    args = ap.parse_args()

    A = metrics(load(args.a))
    COLS = ["n", "JSON合法%", "空壳%", "锚点中位", "锚点可验证%", "who人%", "who噪%",
            "social%", "hedge%", "复读%", "跑飞%"]

    print(f"=== v1.2 留出日全量({len(A)} 会话)===")
    table("总体", [("v1.2", agg(A))], COLS)

    # §31 的核心假设:降级率随 OCR 长度暴涨。分桶验证。
    rows = []
    for _, _, nm in BUCKETS:
        ks = {k for k in A if A[k]["bucket"] == nm}
        if ks:
            rows.append((nm, agg(A, ks)))
    table("按 OCR 长度分桶(验证 §31「长 OCR = 降级根因」)", rows, COLS)

    rows = []
    for lo, hi, nm in [(1, 2, "1帧"), (2, 3, "2帧"), (3, 99, "3+帧")]:
        ks = {k for k in A if lo <= A[k]["n_frames"] < hi}
        if ks:
            rows.append((nm, agg(A, ks)))
    table("按帧数分桶", rows, COLS)

    rows = []
    for app, _ in collections.Counter(A[k]["app"] for k in A).most_common(6):
        ks = {k for k in A if A[k]["app"] == app}
        rows.append((app, agg(A, ks)))
    table("按前台 app(top6)", rows, COLS)

    if not args.b:
        return
    B = metrics(load(args.b))
    both = set(A) & set(B)
    print(f"\n\n=== A/B 配对对照(共同 {len(both)} 会话,同题面/同解码,只换权重)===")
    table("总体", [("v1.2", agg(A, both)), ("base(原版底座)", agg(B, both))], COLS)

    for _, _, nm in BUCKETS:
        ks = {k for k in both if A[k]["bucket"] == nm}
        if len(ks) >= 5:
            table(f"OCR {nm}({len(ks)} 会话)",
                  [("v1.2", agg(A, ks)), ("base", agg(B, ks))], COLS)

    # 逐会话胜负(锚点数 —— 唯一无需教师即可判优劣的硬指标)
    win = sum(1 for k in both if A[k]["n_spec"] > B[k]["n_spec"])
    lose = sum(1 for k in both if A[k]["n_spec"] < B[k]["n_spec"])
    sa = sum(1 for k in both if A[k]["shell"])
    sb = sum(1 for k in both if B[k]["shell"])
    print(f"\n逐会话锚点数:v1.2 胜 {win} / 平 {len(both)-win-lose} / 负 {lose}")
    print(f"空壳(对三个消费者=永久隐形):v1.2 {sa} 条 vs base {sb} 条")


main()
