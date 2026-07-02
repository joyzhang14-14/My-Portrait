#!/usr/bin/env python3
"""本地事件聚类的**确定性骨架**(无模型部分)。

流水(推荐架构 STEP 1/3/4/6 的确定性部分;嵌入通道 + LLM 步留接口):
 STEP1 锚点挖掘:每 session 的判别锚点 = 14B 产的 kw ∪ doing 里正则挖的技术 token。
 IDF 加权:df/idf 平滑,跨切通用锚点(my portrait/claude/terminal…)自动低权,
           判别子系统锚点(librime/qwen3-asr/posthog…)高权。替掉糙的 DF>30% 停用词。
 STEP3 亲和:S[i,j] = α·cos(embed) + β·IDF加权Jaccard(anchors)。
           骨架先只用锚点通道(α=0);嵌入通道 --emb <npy> 加载后融合。
 STEP3/4 分桶:complete-linkage 凝聚(抗链式塌缩)+ 大小封顶 ≤CAP(粗粒度子系统桶)。
 STEP6 覆盖修复:分桶 by construction 即穷尽不相交 → Rule 1 代码保证。
 输出:buckets(每桶 session-key 列表),供后续 LLM 桶内细切分+命名。

  python3 cluster_skeleton.py                 # 锚点通道空跑,打印分桶 + 子系统落桶自检
  python3 cluster_skeleton.py --tau 0.18 --cap 30
  python3 cluster_skeleton.py --emb /tmp/v4_emb.npy --alpha 0.5   # 融合嵌入(嵌入步产出后)
"""
import argparse, json, math, re, collections

MD = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/视觉增量v4-2026-06-07.md"

# doing 里补挖的技术 token:文件名/驼峰/下划线标识符/error码/子系统名
_FILE = re.compile(r"\b[A-Za-z_][\w-]*\.(?:swift|py|ts|md|onnx|m4a|sqlite|toml|json|log)\b", re.I)
_CAMEL = re.compile(r"\b[a-z]+(?:[A-Z][a-z0-9]+){1,}\b")            # extractSentMessages 类
_SNAKE = re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+){1,}\b")        # keystroke_count 类
_ERR = re.compile(r"\b(?:error\s*\d+|[A-Z][a-z]+Error)\b")


def load_sessions():
    """从持久的 v4 报告 MD 解析 337 段(key/app/parts/doing/kw)。"""
    md = open(MD).read()
    out = []
    for b in re.split(r"\n## s", md)[1:]:
        h = re.match(r"(\d+) · (.+?) · parts=\[([\d,\s]+)\]", b)
        if not h:
            continue
        doing = re.search(r"^- doing: (.+)$", b, re.M)
        kw = re.search(r"^- kw: (.*)$", b, re.M)
        out.append({
            "key": int(h.group(1)), "app": h.group(2).strip(),
            "parts": [int(x) for x in h.group(3).split(",")],
            "doing": doing.group(1).strip() if doing else "",
            "kw": [t.strip().lower() for t in kw.group(1).split(",")]
                  if kw and kw.group(1).strip() else [],
        })
    return out


def mine_anchors(s):
    """判别锚点 = kw ∪ doing 里正则技术 token。小写、去极短。"""
    A = set(t for t in s["kw"] if len(t) > 1)
    d = s["doing"]
    for rx in (_FILE, _CAMEL, _SNAKE, _ERR):
        for m in rx.findall(d):
            t = m.lower().strip()
            if len(t) > 2:
                A.add(t)
    return A


def compute_idf(sessions):
    N = len(sessions)
    df = collections.Counter()
    for s in sessions:
        for a in s["anchors"]:
            df[a] += 1
    # 平滑 idf:df 越小(越判别)权重越高;df→N(跨切)权重→~0
    return {a: math.log((N + 1) / (c + 0.5)) for a, c in df.items()}, df


def wjaccard(A, B, idf):
    """IDF 加权 Jaccard:共享判别锚点比共享通用锚点更值钱。"""
    if not A or not B:
        return 0.0
    uni = A | B
    denom = sum(idf.get(a, 0.0) for a in uni)
    if denom <= 0:
        return 0.0
    return sum(idf.get(a, 0.0) for a in (A & B)) / denom


def complete_linkage(aff, tau, cap):
    """complete-linkage 凝聚聚类(LW 更新,d=max)。大小封顶 ≤cap。
    合并条件:两簇**所有**跨对亲和 ≥ tau(即完全连接距离 ≤ 1-tau)。"""
    N = len(aff)
    D = [[1.0 - aff[i][j] for j in range(N)] for i in range(N)]
    members = {i: {i} for i in range(N)}
    active = list(range(N))
    thr = 1.0 - tau
    while True:
        best, bd = None, thr + 1e-9
        for xi in range(len(active)):
            for yi in range(xi + 1, len(active)):
                a, b = active[xi], active[yi]
                if len(members[a]) + len(members[b]) > cap:
                    continue
                if D[a][b] <= bd:
                    bd, best = D[a][b], (a, b)
        if best is None or bd > thr:
            break
        a, b = best
        members[a] |= members[b]
        for k in active:
            if k != a and k != b:
                D[a][k] = D[k][a] = max(D[a][k], D[b][k])   # complete linkage
        active.remove(b); del members[b]
    return [members[a] for a in active]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tau", type=float, default=0.15, help="分桶阈值(越高桶越碎)")
    ap.add_argument("--cap", type=int, default=30, help="单桶大小封顶")
    ap.add_argument("--emb", default=None, help="嵌入 npy(N×d,行序同加载序);给了就融合")
    ap.add_argument("--alpha", type=float, default=0.5, help="嵌入通道权重(β=1-α)")
    args = ap.parse_args()

    sess = load_sessions()
    for s in sess:
        s["anchors"] = mine_anchors(s)
    idf, df = compute_idf(sess)
    N = len(sess)
    noanchor = sum(1 for s in sess if not s["anchors"])
    print(f"[load] {N} 段 · 唯一锚点 {len(idf)} · 无锚点段 {noanchor}")
    hi = sorted(idf.items(), key=lambda x: -df[x[0]])[:6]
    print(f"[idf] 最低权(跨切通用)锚点: " + ", ".join(f"{a}(df{df[a]})" for a, _ in hi))

    # 亲和矩阵:锚点通道(+ 可选嵌入通道)
    beta = 1.0 - args.alpha if args.emb else 1.0
    alpha = args.alpha if args.emb else 0.0
    emb = None
    if args.emb:
        import numpy as np
        emb = np.load(args.emb)
        emb = emb / (np.linalg.norm(emb, axis=1, keepdims=True) + 1e-9)
    A = [s["anchors"] for s in sess]
    aff = [[0.0] * N for _ in range(N)]
    for i in range(N):
        for j in range(i + 1, N):
            v = beta * wjaccard(A[i], A[j], idf)
            if emb is not None:
                v += alpha * float((emb[i] * emb[j]).sum())
            aff[i][j] = aff[j][i] = v
    src = f"锚点(β{beta:.1f})" + (f" + 嵌入(α{alpha:.1f})" if emb is not None else "")

    buckets = complete_linkage(aff, args.tau, args.cap)
    key = [s["key"] for s in sess]
    bk = sorted(([key[i] for i in b] for b in buckets), key=len, reverse=True)
    # 覆盖自检(Rule 1)
    allk = set(); dup = 0
    for b in bk:
        for k in b:
            if k in allk:
                dup += 1
            allk.add(k)
    print(f"\n[cluster] {src} · tau={args.tau} cap={args.cap} → {len(bk)} 桶")
    print(f"          覆盖 {len(allk)}/{N} · 重复 {dup} · "
          f"桶大小 {[len(b) for b in bk[:12]]}{'…' if len(bk)>12 else ''}")

    # 子系统落桶自检
    id2bucket = {}
    for bi, b in enumerate(bk):
        for k in b:
            id2bucket[k] = bi
    probes = ["librime", "rime", "pinyin", "qwen3-asr", "silero", "speaker", "voiceprint",
              "posthog", "spotify", "wechat", "powerprofile", "sidebar", "caffeinate"]
    print("\n[自检] 子系统 → 落在哪些桶(理想:各自集中在少数桶)")
    for p in probes:
        hits = [s["key"] for s in sess if any(p in a for a in s["anchors"])]
        if not hits:
            continue
        dist = collections.Counter(id2bucket[k] for k in hits)
        top = ", ".join(f"桶{b}×{c}" for b, c in dist.most_common(3))
        print(f"  {p:12} {len(hits):3}段 → {len(dist)}个桶 · {top}")


if __name__ == "__main__":
    main()
