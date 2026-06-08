#!/usr/bin/env python3
"""把已算好的 老vs新 最终成品,重排成参考文档格式(按天分组 + [source/kind] 📍 app + 引用块)。
老 = 库里真实 staged;新 = 不变会话沿用 staged + 变化会话用本地重算的新成品(从已生成的 md 解析)。
不重跑 MLX。"""
import json, os, re, sqlite3
import extract_compare_v2 as M

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = M.PH

# 1) 解析已算好的 md,拿到「变化会话」的新成品(按 首event id)
doc = open("/Users/joyzhang14/Desktop/Obsidian/Pipeline最终成品对比-老vs新.md").read()
new_by_ev = {}    # first_ev -> [new_final texts]
for blk in doc.split("### ")[1:]:
    mev = re.search(r'ev(\d+)…', blk)
    if not mev: continue
    ev0 = int(mev.group(1))
    nidx = blk.find("**新切分 → 成品:**")
    if nidx < 0: continue
    lines = []
    for ln in blk[nidx:].split("\n"):
        ln = ln.rstrip()
        if ln.startswith("- "):
            t = ln[2:].replace(" ⏎ ", "\n").strip()
            if t and t != "*(无)*" and not t.startswith("*("): lines.append(t)
    new_by_ev[ev0] = lines

# 确定性残渣过滤(= A组#8 该做的;本地 MLX 小模型 Pass4 清不动这些,改用规则):
# 丢 ① 纯拉丁/数字的短串(w1/rofiol/oc/55/cou/in/p s/ji d/ming t)② 含中文但末尾挂≥3拉丁残尾的短消息。
import re as _re
def is_residue(t):
    c = M.cv(t)
    if not c: return True
    if _re.fullmatch(r'[a-zA-Z0-9 ]{1,12}', c): return True          # 纯拉丁/数字短串 = 拼音/乱码/数字
    m = _re.search(r'([a-zA-Z ]{3,})$', c)                            # 末尾未落定拼音
    if m and _re.search(r'[一-鿿]', c) and len(c) <= 22: return True
    return False

def kind_of(t): return "long_form" if len(t) >= 140 else "short_form"
def app_of(eid):
    r = con.execute("SELECT bundle_id FROM typing_events WHERE id=?", (eid,)).fetchone()
    return (r[0] or '').split('.')[-1] if r else '?'

def record_md(n, source, kind, app, text):
    body = text.replace("\n", "\n> ")
    return f"**{n}.** `[{source}/{kind}]` 📍 `{app}`\n\n> {body}\n"

old_doc = ["# 老 pipeline·成品(现有线上 staged)\n",
           "全文不省略。每条带 `[source/kind]` + 📍 app。这是**现有部署 pipeline**(旧切分逻辑)的真实产出。\n",
           f"天数:{', '.join(DAYS)}\n", "---\n"]
new_doc = ["# 新 pipeline·成品(v2 切分改写后)\n",
           "全文不省略。**切分有变化的会话**=新切分(v2)→ 本地 AxCleanup(Qwen3-4B,MLX)→ **确定性残渣过滤(A组#8)**;",
           "切分不变的会话沿用线上 staged。⚠️ **本地 1.7b Pass4 实测失效**(MLX 啥都不丢),所以残渣(w1/拼音碎片)",
           "改用确定性规则清掉,而非靠 LLM Pass4;`然后`/`托付` 这类「完整但可能是草稿」的短消息仍保留(bias-to-keep)。\n",
           f"天数:{', '.join(DAYS)}\n", "---\n"]

for day in DAYS:
    # 该天所有 staged 记录(老成品),按 id 顺序
    base = __import__('datetime').datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=__import__('datetime').timezone.utc)
    lo = int(base.timestamp() * 1000); hi = lo + 86400000
    staged = con.execute("SELECT id,app,source,text,reference_typing_event_ids FROM writing_records_staged "
                         "WHERE date_utc=? AND source IN('ax_cleaned','merged') ORDER BY id", (day,)).fetchall()
    old_recs = [(r[1].split('.')[-1], r[2], r[3], r[4]) for r in staged]   # (app, source, text, refs)

    # 新成品:按会话,变化会话用 new_by_ev,不变会话沿用 staged
    new_recs = []
    seen_refs = set()
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged "
                               "WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        if not ids: continue
        seen_refs.add(refs)
        evs = M.loadev(ids)
        if not evs: continue
        changed = set(M.oldExtract(evs, PH)) != set(M.newExtract(evs))
        app = app_of(ids[0])
        if changed and ids[0] in new_by_ev:
            for t in new_by_ev[ids[0]]:
                if is_residue(t): continue          # 确定性残渣过滤(A组#8)
                new_recs.append((app, "ax_cleaned", t, refs))
        else:   # 不变 → 沿用该会话的 staged 记录
            for r in staged:
                if r[4] == refs:
                    new_recs.append((r[1].split('.')[-1], r[2], r[3], r[4]))
    # #3 类(staged 无,新独有)
    for ev0, lit in [(588, [588, 589, 590]), (674, [674, 675])]:
        b = __import__('datetime').datetime.utcfromtimestamp(
            (con.execute("SELECT started_at FROM typing_events WHERE id=?", (ev0,)).fetchone() or [0])[0] / 1000)
        if b.strftime("%Y-%m-%d") == day and ev0 in new_by_ev:
            for t in new_by_ev[ev0]:
                if is_residue(t): continue
                new_recs.append((app_of(ev0), "ax_cleaned", t, None))

    old_doc.append(f"## {day}\n")
    old_doc.append(f"### 📦 老 pipeline·成品（{len(old_recs)}）\n")
    for i, (app, src, text, _) in enumerate(old_recs, 1):
        old_doc.append(record_md(i, src, kind_of(text), app, text))
    old_doc.append("\n---\n")

    new_doc.append(f"## {day}\n")
    new_doc.append(f"### 🆕 新 pipeline·成品（{len(new_recs)}）\n")
    for i, (app, src, text, _) in enumerate(new_recs, 1):
        new_doc.append(record_md(i, src, kind_of(text), app, text))
    new_doc.append("\n---\n")

p_old = "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-老pipeline.md"
p_new = "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md"
open(p_old, "w").write("\n".join(old_doc))
open(p_new, "w").write("\n".join(new_doc))
old_single = "/Users/joyzhang14/Desktop/Obsidian/Pipeline最终成品对比-老vs新.md"
print(f"已生成两个文档:\n  {p_old}\n  {p_new}")
print(f"(原单文件 {old_single} 保留作 v2 数据源,可手动删)")
