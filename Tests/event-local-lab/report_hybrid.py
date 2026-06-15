#!/usr/bin/env python3
"""把 hybrid(脱敏 digest → Codex 全天聚类)产出的事件导成 md。

纯离线、只读 lab.db,不跑模型。
  python3 report_hybrid.py --day 2026-06-07

内容:三方对比表(hybrid / 本地 v3 / 生产)+ hybrid 事件全量。
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

    hev = con.execute("SELECT id,batch_idx,title,summary,type,tags,facets,member_ids,"
                      "join_ref FROM hybrid_events WHERE day=? ORDER BY id",
                      (day,)).fetchall()
    if not hev:
        print(f"{day} 无 hybrid 事件,先跑 hybrid_cluster.py"); return
    n_h = len(hev)
    cover = sorted({s for e in hev for s in json.loads(e["member_ids"])})
    joins = sum(1 for e in hev if e["join_ref"])
    batches = len({e["batch_idx"] for e in hev})
    digested = con.execute("SELECT COUNT(*) FROM raw_sessions WHERE day=? AND "
                           "digest IS NOT NULL", (day,)).fetchone()[0]
    n_local = con.execute("SELECT COUNT(*) FROM events WHERE day=?", (day,)).fetchone()[0]

    L = [f"# hybrid 事件产出 · {day}", "",
         "口径:本地清洗的**脱敏 digest** → Codex(gpt-5.4)全天分批聚类(×80,"
         f"{batches} 批,带跨批 join)。原始 OCR 未上云。", "",
         "## 三方对比", "",
         "| 方案 | 上云内容 | 事件数 | 覆盖 session | 浓缩比 |",
         "|---|---|---|---|---|",
         f"| **hybrid**(本方案) | 脱敏 digest | **{n_h}** | {len(cover)}/{digested} | "
         f"{len(cover)/max(1,n_h):.0f}:1 |",
         f"| 本地 v3(全本地 14B) | 不上云 | {n_local} | — | — |",
         f"| 生产(现网) | **原始 OCR** | {PROD_COUNT} | — | — |",
         "",
         f"- hybrid 把 {len(cover)} 个 session 聚成 {n_h} 个事件,其中 {joins} 个事件是"
         f"跨批 join 合并而来。",
         "- 对比口径见同目录《云端vs本地-对比》《本地清洗结果》。", "",
         "## hybrid 事件全量", ""]

    for e in hev:
        m = json.loads(e["member_ids"])
        tags = ", ".join(json.loads(e["tags"]))
        facets = ", ".join(
            (f.get("facet", "") + ":" + f.get("value", "")) if isinstance(f, dict) else str(f)
            for f in json.loads(e["facets"])) if e["facets"] else ""
        jn = f"  ·  ↩join {e['join_ref']}" if e["join_ref"] else ""
        L.append(f"### h{e['id']} · {e['title']}  ({e['type']}, {len(m)} session){jn}")
        L.append(f"- **summary**: {e['summary']}")
        L.append(f"- **tags**: {tags}" + (f"  ·  **facets**: {facets}" if facets else ""))
        L.append(f"- **members**: {m}")
        L.append("")

    path = OUT.format(day=day)
    open(path, "w").write("\n".join(L) + "\n")
    print(f"[report] {path}")
    print(f"  hybrid 事件={n_h} 覆盖={len(cover)}/{digested} join={joins} 批={batches} "
          f"· 本地v3={n_local} 生产={PROD_COUNT}")


if __name__ == "__main__":
    main()
