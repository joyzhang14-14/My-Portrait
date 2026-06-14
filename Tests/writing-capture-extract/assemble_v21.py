#!/usr/bin/env python3
"""组装 v21 归档文档 = 对比摘要段 + 完整产品。摘要含 gold 评分卡 + 逐天 diff vs 上次产出。"""
import io, contextlib
from v21_compare import parse_product, diff_day
import compare_gold

PROD = 'eval/v21_product.md'
V20 = '/Users/joyzhang14/Desktop/Obsidian/Pipeline成品归档/v20-URL整条+剥离非手打+掩码通用(det).md'
INTEG = '/Users/joyzhang14/Desktop/Obsidian/6.3-6.4-本地集成产出.md'
OUT = '/Users/joyzhang14/Desktop/Obsidian/Pipeline成品归档/v21-双return英文修复(gmail案,6天集成,det).md'

# gold 评分卡(抓 compare_gold 输出)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rows, sc = compare_gold.main(PROD)
gold_lines = buf.getvalue().strip().splitlines()

v21 = parse_product(PROD); v20 = parse_product(V20); integ = parse_product(INTEG)
base = {**v20, **integ}

# 逐天 diff
diff_md = []
for day in sorted(v21):
    vrecs = v21[day]; brecs = base.get(day, [])
    bsrc = 'v20' if day in v20 else ('6.3-6.4集成' if day in integ else '无基准')
    vonly, bonly, common = diff_day(vrecs, brecs)
    head = f"**{day}** — v21 `{len(vrecs)}` vs {bsrc} `{len(brecs)}` ｜ 共有 {common}"
    if not vonly and not bonly:
        diff_md.append(head + " ｜ **逐字一致** ✓")
    else:
        diff_md.append(head + f" ｜ v21多 {len(vonly)} / 上次多 {len(bonly)}")
        for s, a, t in vonly:
            diff_md.append(f"  - ➕ v21 有：`[{s}]` {a} · {t[:48]!r}")
        for s, a, t in bonly:
            diff_md.append(f"  - ➖ 上次有：`[{s}]` {a} · {t[:48]!r}")

H = []
H.append("# v21 — 双 return 英文修复(gmail 案)· 6 天集成 · det\n")
H.append("> **本轮唯一代码改动**:中文 IME 下打英文 = 字母 + `<CR>`(组合区上屏成字面)+ `<CR>`(发送)= 双 return。")
H.append("> 对 `~residue` 残渣记录,取其击键窗,若含「拉丁 run + `<CR><CR>`」且该英文词(去空格小写)== 残渣字母 →")
H.append("> **直接用击键字面替换**(零 LLM,击键 g-m-a-i-l 就是字面)。只命中 `~residue` 且精确匹配的记录,纯拼音(选字数字/空格,无双回车)零误抓。\n")
H.append("> **运行配置**:`PORTRAIT_DAYS`=5/27,5/28,5/29,6/3,6/4,6/5(全局 6 天)｜ `PORTRAIT_CANVAS`=`canvas_merged_src.json`(复现上次 6 天跑,唯一 delta = 本修复)｜ AX 路纯从 `typing_events`/`keystroke_log` 重建。")
H.append(f"> **产出规模**:226 条成品(5/27=56｜5/28=29｜5/29=25｜6/3=24｜6/4=28｜6/5=64)｜14B disambig 调用 427 次。\n")
H.append("---\n")
H.append("## 📊 本轮验证摘要\n")

H.append("### ① 核心修复:gmail 翻绿\n")
H.append("- **6/5 第 25 条**:`g mai l`(残渣)→ **`gmail`**(`[ax_cleaned]`,残渣标记已剥离)。")
H.append("- 真实事件 ev1132(143s 长 event,内含多条 Discord 消息);击键 `g-m-a-i-l<CR><CR>`,`double_return_eng` 解出 `gmail`,精确匹配残渣字母 `gmail` → 字面替换。")
H.append("- 改动记入 `🔧 口3 修正` 审计(via=`双return英文`),可逐条追溯。\n")

H.append("### ② Gold 对照(38 项 + P0 隐私)\n")
H.append("```")
H.extend(gold_lines)
H.append("```")
H.append("- **唯一 ✗ = A1「记得」**:ev522(5/27 Discord,简拼 `ji d`)本轮 14B 简拼消歧解成「基地」,口3 OCR 未找回。")
H.append("  - **与 gmail 修复无关(铁证)**:该记录是 `[ax_cleaned]` 非 `~residue`,根本不进本次修改的 `~residue` 分支;`ji d` 是拼音无双回车。")
H.append("  - **非本次引入**:与上一次 6 天跑一致(A1 一贯 14B 简拼方差,guard 拒 librime TOP,历来靠口3 OCR 偶然找回)。")
H.append("- B12「Were you encouraged」存量草稿:v21 已剥离(✓),优于 saved v20 的 🟡。\n")

H.append("### ③ 逐天 diff vs 上次产出(gold 天→v20 ｜ 6/3,6/4→6.3-6.4 集成)\n")
H.extend(diff_md)
H.append("")
H.append("> **6/3、6/4 与上次逐字一致**:实证 gmail 修复在这两天是 no-op(两天共 7 条 `~residue` 英文记录 Lab/open/Yep/okay/ok/100/UC 全部不变),且 14B 在清晰文本上稳定。")
H.append("> **5/27/28/29/6/5 的差异全为 `~draft`/`~residue` 碎片的 14B run-to-run 方差**(简拼/草稿密集天,disambig 调用多→产出微抖);非 gmail 修复所致(修复只碰精确匹配双 return 的 residue)。")
H.append("> A1(记得↔基地)与 B12(Were you encouraged 在↔不在)均为此类方差,v21 相对 saved v20 是「A1 失 / B12 得」的对冲。\n")
H.append("---\n")

with open(OUT, 'w', encoding='utf-8') as f:
    f.write("\n".join(H) + "\n")
    f.write(open(PROD, encoding='utf-8').read())
print("已写", OUT)
import os
print("大小", os.path.getsize(OUT), "bytes")
