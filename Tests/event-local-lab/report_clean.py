#!/usr/bin/env python3
"""把本地清洗(Phase B:OCR → 活动 digest)的结果导成 md,给用户审。

纯离线、只读 lab.db,不跑任何模型。
  python3 report_clean.py --day 2026-06-07

内容:统计概况 + 隐私审计(残留 PII 扫描)+ OCR→digest 抽检(看清洗质量)
     + 全量 digest 列表(按时间)。
"""
import argparse
import time

import labdb
import redact

OUT = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/本地清洗结果-{day}.md"


def hhmm(ms):
    t = time.gmtime(ms // 1000)
    return f"{t.tm_hour:02d}:{t.tm_min:02d}"


def first_line(s):
    return (s or "").split("\n", 1)[0].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-07")
    ap.add_argument("--spot", type=int, default=18, help="抽检 OCR→digest 对数")
    args = ap.parse_args()
    day = args.day
    con = labdb.connect()

    rows = con.execute(
        "SELECT id,start_ms,end_ms,app,window,ocr,digest,bg_media,status "
        "FROM raw_sessions WHERE day=? AND digest IS NOT NULL ORDER BY start_ms",
        (day,)).fetchall()
    n = len(rows)
    if not n:
        print(f"{day} 无 digest"); return
    skipped = con.execute("SELECT COUNT(*) FROM raw_sessions WHERE day=? AND "
                          "status='skipped_no_ocr'", (day,)).fetchone()[0]
    avg = sum(len(r["digest"]) for r in rows) / n
    bg = sum(1 for r in rows if r["bg_media"])

    # 隐私审计:脱敏占位符 + 残留 PII
    placeholders = sum(1 for r in rows if any(
        p in r["digest"] for p in ("<email>", "<phone>", "<secret>", "<token>",
                                   "<card>", "<id>")))
    leaks = []
    for r in rows:
        _, hits = redact.redact(r["digest"])
        if hits:
            leaks.append((r["id"], hits))

    # app 分布
    apps = {}
    for r in rows:
        apps[r["app"]] = apps.get(r["app"], 0) + 1
    top_apps = sorted(apps.items(), key=lambda x: -x[1])[:15]

    # 抽检:bg_media 全要 + OCR 最长的若干 + 均匀采样补齐
    chosen, seen = [], set()
    for r in rows:
        if r["bg_media"] and r["id"] not in seen:
            chosen.append(r); seen.add(r["id"])
    for r in sorted(rows, key=lambda x: -len(x["ocr"] or "")):
        if len(chosen) >= args.spot:
            break
        if r["id"] not in seen:
            chosen.append(r); seen.add(r["id"])
    step = max(1, n // max(1, args.spot))
    for i in range(0, n, step):
        if len(chosen) >= args.spot:
            break
        r = rows[i]
        if r["id"] not in seen:
            chosen.append(r); seen.add(r["id"])
    chosen.sort(key=lambda x: x["start_ms"])

    L = [f"# 本地清洗结果 · {day}", "",
         "Phase B(本地小模型 Qwen3-4B):屏幕 OCR 原文 → ~230 字活动 digest。",
         "**这是 hybrid 里唯一会上云的东西**(原始 OCR 永不出本地)。", "",
         "## 概况", "",
         f"- digest 条数:**{n}**  ·  另有 `skipped_no_ocr` {skipped} 条(无 OCR 内容,跳过)",
         f"- digest 长度:平均 {avg:.0f} 字 / 最长 {max(len(r['digest']) for r in rows)} 字",
         f"- 背景媒体标记(`bg_media`,音乐播放器在前台但在干别的):{bg} 条", "",
         "## 隐私审计", "",
         f"- 含脱敏占位符(`<email>`/`<secret>`…)的 digest:**{placeholders}** 条"
         + ("(这批 digest 早于 redact 脱敏闸接入,故为 0;下次清洗会走闸)"
            if placeholders == 0 else ""),
         f"- **残留 PII 扫描**(用 redact 正则回扫所有 digest 找漏网邮箱/手机/密钥):"
         f"**{len(leaks)}/{n}** 命中"
         + ("  → 即使没过脱敏闸,本地清洗实际也没把 PII 写进 digest ✓"
            if not leaks else ""), ""]
    if leaks:
        L.append("漏网明细(需修):")
        for sid, h in leaks[:30]:
            L.append(f"- #{sid}: {h}")
        L.append("")

    L += ["## app 分布(top 15)", ""]
    L += [f"- {a}: {c}" for a, c in top_apps]
    L += ["", f"## OCR → digest 抽检({len(chosen)} 条,看清洗质量)", "",
          "口径:**OCR** = 原始屏幕文字(截断);**digest** = 本地洗出、会上云的摘要。", ""]
    for r in chosen:
        tag = " `[bg]`" if r["bg_media"] else ""
        win = r["window"] or "(none)"
        L.append(f"### #{r['id']} · {hhmm(r['start_ms'])} · {r['app']} — {win}{tag}")
        ocr = (r["ocr"] or "").replace("\n", " ")[:500]
        L.append(f"- **OCR**: {ocr}")
        L.append(f"- **digest**: {r['digest']}")
        L.append("")

    L += ["## 全量 digest(按时间)", ""]
    for r in rows:
        tag = " `[bg]`" if r["bg_media"] else ""
        win = (r["window"] or "")[:30]
        L.append(f"- **#{r['id']}** `{hhmm(r['start_ms'])}` `{r['app']}`{tag} "
                 f"{win} — {first_line(r['digest'])}")

    path = OUT.format(day=day)
    open(path, "w").write("\n".join(L) + "\n")
    print(f"[report] {path}")
    print(f"  digested={n} skipped={skipped} bg={bg} 残留PII={len(leaks)} 抽检={len(chosen)}")


if __name__ == "__main__":
    main()
