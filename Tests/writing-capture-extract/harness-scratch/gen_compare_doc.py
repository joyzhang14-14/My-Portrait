#!/usr/bin/env python3
"""生成 老pipeline vs 新pipeline(v2) 逐会话对比 md → 桌面。"""
import extract_compare_v2 as M
import json, sqlite3, os

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-05']
PH = M.PH

def app_of(ids):
    r = con.execute("SELECT bundle_id FROM typing_events WHERE id=? ", (ids[0],)).fetchone()
    b = (r[0] if r else '') or ''
    return b.split('.')[-1] if b else '?'

def fmt(m):
    return m.replace('\n', ' ⏎ ').strip()

def classify_dropped(m):
    if any(p in m for p in ['Write a message', 'Type / for commands', 'Describe a task or ask a question', '+3 options']):
        return '占位符', True
    import re
    if re.fullmatch(r'[a-zA-Z ]+', m) or (len(m) and m[-1].isascii() and m[-1].isalpha() and len(m) <= 8):
        return '拼音/英文残渣', True
    if len(m) <= 3:
        return '短碎片', True
    return '⚠️真内容?', False

out = []
out.append("# 老 pipeline vs 新 pipeline 切分结果对比\n")
out.append("> 数据:四天真实会话(05-27 / 05-28 / 05-29 / 06-05)。")
out.append("> **老** = 现有逻辑(占位符集合≥3 + 字段reset启发式);**新** = v2(edit_log 回放)。")
out.append("> 对照的是**消息切分层**(unifiedExtract 的输出,未经 AxCleanup 补拼音 / Pass4 keep-discard)。")
out.append("> 会话边界从 staged 的 reference_typing_event_ids 重建。\n")

tot_o = tot_n = ph_o = ph_n = 0
changed = []
for day in DAYS:
    for (refs,) in con.execute("SELECT DISTINCT reference_typing_event_ids FROM writing_records_staged WHERE date_utc=? AND source IN('ax_cleaned','merged')", (day,)).fetchall():
        try: ids = [int(x) for x in json.loads(refs or '[]')]
        except: ids = []
        evs = M.loadev(ids)
        if not evs: continue
        old = M.oldExtract(evs, PH); new = M.newExtract(evs)
        tot_o += len(old); tot_n += len(new)
        ph_o += sum(1 for m in old if any(p in m for p in ['Write a message', 'Type / for commands', 'Describe a task or ask a question']))
        ph_n += sum(1 for m in new if any(p in m for p in ['Write a message', 'Type / for commands', 'Describe a task or ask a question']))
        added = [n for n in new if not any(M.related(n, o) or n in o for o in old)]
        dropped = [o for o in old if not any(M.related(o, n) or o in n for n in new)]
        if added or dropped:
            changed.append((day, ids, app_of(ids), old, new, added, dropped))

out.append("## 总览\n")
out.append(f"| | 老 pipeline | 新 pipeline |")
out.append(f"|---|---|---|")
out.append(f"| 切出消息总数 | {tot_o} | {tot_n} |")
out.append(f"| 占位符泄漏(Write a message…等) | {ph_o} | {ph_n} |")
out.append(f"| 有变化的会话 | — | {len(changed)} 个 |\n")
out.append("**怎么读**:`新增` = 新版抓到、老版漏的(大多是事件内多发送 / 跨事件长消息);")
out.append("`丢弃` = 老版有、新版没有的,后面标了类型(占位符/残渣/短碎片 = 该丢;⚠️真内容? = 要你重点看)。\n")
out.append("---\n")

out.append("## 逐会话对比(只列有变化的)\n")
for day, ids, app, old, new, added, dropped in changed:
    out.append(f"### [{day}] `{app}` · ev{ids[0]}…  (老 {len(old)}条 → 新 {len(new)}条)\n")
    out.append("**老 pipeline 切出:**")
    for m in old: out.append(f"- {fmt(m)}")
    out.append("\n**新 pipeline 切出:**")
    for m in new: out.append(f"- {fmt(m)}")
    if added:
        out.append("\n**🟢 新版新增(老版漏的):**")
        for m in added: out.append(f"- {fmt(m)}")
    if dropped:
        out.append("\n**🔴 新版丢弃:**")
        for m in dropped:
            tag, ok = classify_dropped(m)
            out.append(f"- {fmt(m)}  —— *{tag}*")
    out.append("\n---\n")

# #3 类:staged 无记录的会话(对照循环看不到),手动补蓝图
out.append("## 补充:#3 类「老 pipeline 整组丢」的会话\n")
out.append("这些会话在线上老 pipeline 里产出 **0 条**(staged 无记录),上面的对照循环看不到。")
out.append("新版能恢复。举证:\n")
for label, lit in [("Google Doc 蓝图随笔 [588,589,590]", [588, 589, 590]),
                   ("Safari 英文随笔 [674,675]", [674, 675])]:
    new = M.newExtract(M.loadev(lit))
    out.append(f"### {label}")
    out.append("**老 pipeline(线上):** 整组丢失,0 条")
    out.append("**新 pipeline:**")
    for m in new: out.append(f"- {fmt(m)}")
    out.append("")

path = os.path.expanduser("~/Desktop/Pipeline切分对比-老vs新.md")
open(path, "w").write("\n".join(out))
print(f"已生成: {path}")
print(f"老 {tot_o} 条 / 新 {tot_n} 条 / 变化会话 {len(changed)} 个 / 占位符泄漏 老{ph_o}→新{ph_n}")
