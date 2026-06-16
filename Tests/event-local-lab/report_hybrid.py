#!/usr/bin/env python3
"""把 hybrid(脱敏 digest → Codex 全天聚类 + 下游 impact/occurrence)导成 md。

纯离线、只读 lab.db,不跑模型。
  python3 report_hybrid.py --day 2026-06-07

内容:三方对比表 + impact 分布 + 按 weight 排序的事件全量(impact/occurrence)。
"""
import argparse
import json

import labdb

OUT = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/hybrid事件产出-{day}.md"
PROD_COUNT = 28   # 生产(原始 OCR→云端)产出数,取自既有 obsidian 文档


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-07")
    args = ap.parse_args()
    day = args.day
    con = labdb.connect()

    hev = con.execute("SELECT * FROM hybrid_events WHERE day=? ORDER BY id",
                      (day,)).fetchall()
    if not hev:
        print(f"{day} 无 hybrid 事件,先跑 hybrid_cluster.py"); return
    cols = set(hev[0].keys())

    def g(e, k, d=None):
        return e[k] if k in cols and e[k] is not None else d

    scored = "impact" in cols and any(g(e, "impact") is not None for e in hev)
    n_h = len(hev)
    cover = sorted({s for e in hev for s in json.loads(e["member_ids"])})
    processed = con.execute("SELECT COALESCE(SUM(n_events),0) FROM hybrid_progress "
                            "WHERE day=?", (day,)).fetchone()[0]
    merges = max(0, processed - n_h)
    batches = con.execute("SELECT COUNT(*) FROM hybrid_progress WHERE day=?",
                          (day,)).fetchone()[0]
    digested = con.execute("SELECT COUNT(*) FROM raw_sessions WHERE day=? AND "
                           "digest IS NOT NULL", (day,)).fetchone()[0]
    n_local = con.execute("SELECT COUNT(*) FROM events WHERE day=?", (day,)).fetchone()[0]
    xday = sum(1 for e in hev if g(e, "historical_ref"))

    L = [f"# hybrid 事件产出 · {day}", "",
         "口径:本地清洗的**脱敏 digest** → Codex(gpt-5.4)全天分批聚类 + 下游 "
         "impact 打分 + 跨天 occurrence(生产历史只读)。原始 OCR 未上云。", "",
         "## 三方对比", "",
         "| 方案 | 上云内容 | 事件数 | 覆盖 session |",
         "|---|---|---|---|",
         f"| **hybrid**(本方案) | 脱敏 digest | **{n_h}** | {len(cover)}/{digested} |",
         f"| 本地 v3(全本地 14B) | 不上云 | {n_local} | — |",
         f"| 生产(现网) | **原始 OCR** | {PROD_COUNT} | — |",
         "",
         f"- 全天分批共产出 {processed} 候选,跨批 join 合并 {merges} → 最终 {n_h} 个。"
         f"覆盖 {len(cover)}/{digested} session。"]

    if scored:
        imps = [g(e, "impact", 0) for e in hev]
        dist = {"0-2": 0, "2-3": 0, "3-4": 0, "4+": 0}
        for v in imps:
            dist["0-2" if v < 2 else "2-3" if v < 3 else "3-4" if v < 4 else "4+"] += 1
        L.append(f"- impact 分布(0-5):" + " · ".join(f"{k}:{v}" for k, v in dist.items())
                 + f"(均 {sum(imps)/len(imps):.1f});跨天续接 **{xday}** 个事件"
                 f"(occurrence>1,merge 进历史)。")
    L += ["- 对比口径见同目录《hybrid-vs-生产-对比》。", "",
          ("## hybrid 事件全量(按 weight 降序)" if scored else "## hybrid 事件全量"), ""]

    order = sorted(hev, key=lambda e: g(e, "weight", -1.0), reverse=True) if scored else hev
    for e in order:
        m = json.loads(e["member_ids"])
        tags = ", ".join(json.loads(e["tags"]))
        facets = ", ".join(
            (f.get("facet", "") + ":" + f.get("value", "")) if isinstance(f, dict) else str(f)
            for f in json.loads(e["facets"])) if e["facets"] else ""
        if scored:
            L.append(f"### [{g(e,'weight',0):.2f}w · impact {g(e,'impact',0):.1f}] "
                     f"h{e['id']} · {e['title']}  ({e['type']}, {len(m)}s)")
            ev = g(e, "impact_evidence")
            if ev:
                L.append(f"- **impact evidence**: {ev}")
        else:
            jn = f"  ·  ↩join {e['join_ref']}" if e["join_ref"] else ""
            L.append(f"### h{e['id']} · {e['title']}  ({e['type']}, {len(m)}s){jn}")
        L.append(f"- **summary**: {e['summary']}")
        L.append(f"- **tags**: {tags}" + (f"  ·  **facets**: {facets}" if facets else ""))
        occ = g(e, "occurrences")
        if occ:
            dates = json.loads(occ)
            if len(dates) > 1 or g(e, "historical_ref"):
                ref = g(e, "historical_ref")
                L.append(f"- **occurrences**: {len(dates)} 天 {dates}"
                         + (f" · 续接历史 `{ref}` — {g(e,'historical_title')}" if ref else ""))
        L.append(f"- **members**: {m}")
        L.append("")

    path = OUT.format(day=day)
    open(path, "w").write("\n".join(L) + "\n")
    print(f"[report] {path}")
    msg = f"  hybrid 事件={n_h} 覆盖={len(cover)}/{digested} 候选={processed} merge={merges}"
    if scored:
        msg += f" · 跨天续接={xday} · impact均={sum(imps)/len(imps):.1f}"
    print(msg + f" · 本地v3={n_local} 生产={PROD_COUNT}")


if __name__ == "__main__":
    main()
