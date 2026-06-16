#!/usr/bin/env python3
"""hybrid 下游:聚类后的**确定性**近重复合并 pass(#3 过度碎片化)。

为什么需要:hybrid_cluster.py 的跨批 join 候选只取最近 CARRY_MAX 个事件
(FIFO),相隔很多批的同主题事件(如首尾相接的两段 PostHog 调试)等后一批
跑时前一个早被挤出候选,没法 join → 裂成两个近重复事件。本 pass 不受 carry
窗口限制,全天扫,把"同主导 app + 时间相邻/重叠 + 标签或标题高度重合"的事件合并。

纯规则、模型无关、可 dry-run。合并改 member_ids,标题/摘要交给 resummarize_day
刷新,所以**跑序:cluster → merge → resummarize → impact**。

  python3 merge_day.py --day 2026-06-07            # dry-run,只打印会合并谁
  python3 merge_day.py --day 2026-06-07 --apply    # 落库

阈值保守且可调:必须同时满足 同 app + 相邻(gap≤--gap 分钟)+ (标签 Jaccard≥
--tagj 或 标题 Jaccard≥--titlej)。宁可漏合不可错合(错合把两件不同的事粘一起)。
"""
import argparse
import json
import re
from collections import Counter

import labdb

_STOP = {"the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with",
         "my", "user", "app", "and", "into", "from", "via", "using", "ran", "did"}


def _tok(s):
    return {w for w in re.findall(r"[a-z0-9]+", (s or "").lower()) if w not in _STOP
            and len(w) > 1}


def _jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _meta(con, e):
    """事件的 (主导app, 时间span(min_start,max_end), tag集, 标题token集, 成员list)。"""
    m = json.loads(e["member_ids"])
    rows = con.execute(
        f"SELECT app, start_ms, end_ms FROM raw_sessions WHERE id IN "
        f"({','.join('?' * len(m))})", m).fetchall() if m else []
    apps = [r["app"] for r in rows if r["app"]]
    dom = Counter(apps).most_common(1)[0][0] if apps else ""
    span = ((min(r["start_ms"] for r in rows), max(r["end_ms"] for r in rows))
            if rows else (0, 0))
    tags = {t.lower() for t in json.loads(e["tags"])}
    return dom, span, tags, _tok(e["title"]), m


def _gap_min(s1, s2):
    """两个时间 span 的间隔(分钟);重叠返回 0。"""
    a0, a1 = s1
    b0, b1 = s2
    if a1 >= b0 and b1 >= a0:
        return 0
    return max(b0 - a1, a0 - b1) // 60000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--gap", type=int, default=15, help="相邻判定:span 间隔≤几分钟")
    ap.add_argument("--tagj", type=float, default=0.6, help="标签 Jaccard 阈值")
    ap.add_argument("--titlej", type=float, default=0.5, help="标题 Jaccard 阈值")
    ap.add_argument("--apply", action="store_true", help="落库(默认 dry-run)")
    args = ap.parse_args()
    con = labdb.connect()

    evs = con.execute("SELECT id, title, tags, member_ids FROM hybrid_events "
                      "WHERE day=? ORDER BY id", (args.day,)).fetchall()
    if not evs:
        print(f"{args.day} 无 hybrid 事件。")
        return
    meta = {e["id"]: _meta(con, e) for e in evs}
    title_of = {e["id"]: e["title"] for e in evs}
    ids = [e["id"] for e in evs]

    # union-find:把可合并的事件并到同一组
    parent = {i: i for i in ids}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        parent[find(a)] = find(b)

    pairs = []
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            a, b = ids[i], ids[j]
            da, sa, ta, na, _ = meta[a]
            db, sb, tb, nb, _ = meta[b]
            if not da or da != db:                         # 必须同主导 app
                continue
            gap = _gap_min(sa, sb)
            if gap > args.gap:                             # 必须时间相邻/重叠
                continue
            tj, nj = _jaccard(ta, tb), _jaccard(na, nb)
            if tj >= args.tagj or nj >= args.titlej:       # 标签 OR 标题高度重合
                pairs.append((a, b, da, gap, round(tj, 2), round(nj, 2)))
                union(a, b)

    # 分组(>1 成员的组才需合并),组内最小 id 当幸存者
    groups = {}
    for i in ids:
        groups.setdefault(find(i), []).append(i)
    groups = {k: sorted(v) for k, v in groups.items() if len(v) > 1}

    if not pairs:
        print(f"[merge] {args.day}: 无近重复可合(同app+相邻+高重合)。")
        return
    print(f"[merge] {args.day}: 命中 {len(pairs)} 对近重复 → 合成 {len(groups)} 组:")
    for surv, members in groups.items():
        print(f"  组(幸存 h{surv}):")
        for hid in members:
            mark = "←保留" if hid == surv else " 并入"
            print(f"    h{hid}{mark}  [{meta[hid][0]}]  {title_of[hid][:50]}")

    if not args.apply:
        print("\n(dry-run;加 --apply 落库。合并后跑 resummarize_day 刷新标题/摘要。)")
        return

    merged = 0
    with con:
        for surv, members in groups.items():
            allm = []
            for hid in members:
                allm.extend(meta[hid][4])
            seen, uniq = set(), []
            for s in allm:                                 # 去重保序
                if s not in seen:
                    seen.add(s); uniq.append(s)
            con.execute("UPDATE hybrid_events SET member_ids=?, updated_at_ms=? "
                        "WHERE id=?", (json.dumps(uniq), labdb.now_ms(), surv))
            for hid in members:
                if hid != surv:
                    con.execute("DELETE FROM hybrid_events WHERE id=?", (hid,))
                    merged += 1
    print(f"\n[done] 合并 {merged} 个事件进 {len(groups)} 个幸存事件。"
          f"→ 下一步 resummarize_day.py 刷新标题/摘要。")


if __name__ == "__main__":
    main()
