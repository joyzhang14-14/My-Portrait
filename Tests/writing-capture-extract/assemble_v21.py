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
_DAYS = ['2026-05-27', '2026-05-28', '2026-05-29', '2026-06-03', '2026-06-04', '2026-06-05']
_scale = '｜'.join(f"{d[5:]}={len(v21.get(d, []))}" for d in _DAYS)
_total = sum(len(v21.get(d, [])) for d in _DAYS)

H.append("# v21 — gmail 双 return 修复 + `REVIEW_MODE=det` · 6 天集成\n")
H.append("> **代码改动(本轮唯一)**:中文 IME 下打英文 = 字母 + `<CR>`(组合区上屏成字面)+ `<CR>`(发送)= 双 return。")
H.append("> 对 `~residue` 残渣记录,击键窗含「拉丁 run + `<CR><CR>`」且英文词(去空格小写)== 残渣字母 → **击键字面替换**(零 LLM)。")
H.append("> 只命中 `~residue` 精确匹配,纯拼音零误抓;**改动独立于复查模式**。\n")
H.append("> **复查模式 = `REVIEW_MODE=det`**(确定性 OCR 对证,HANDOFF 终裁「LLM 复查退役」的 canonical 模式;与 v20 同口径)。")
H.append("> ⚠️ 首跑误用默认 `llm`,暴露三问题(记得→基地 / 密码泄漏 / 单@入册);**det 重跑全部修正**,详见 ①③。\n")
H.append("> **运行配置**:`PORTRAIT_DAYS`=6 天 ｜ `PORTRAIT_CANVAS`=`canvas_merged_src.json` ｜ AX 路纯从 `typing_events`/`keystroke_log` 重建。")
H.append(f"> **产出规模**:{_total} 条成品({_scale})｜14B disambig 调用 427 次｜未定区(短草稿/碎片)更厚。\n")
H.append("---\n")
H.append("## 📊 本轮验证摘要\n")

H.append("### ① Gold 对照(40 项 + P0 隐私)— **满分**\n")
H.append("```")
H.extend(gold_lines)
H.append("```")
H.append("- 含本轮新增三探针:**B13 单@不入成品 / B14 短碎片不入成品 / P0 粘贴密码不泄漏**,全 ✓。\n")

H.append("### ② gmail 翻绿(核心修复,独立于 det)\n")
H.append("- **6/5**:`g mai l`(残渣)→ **`gmail`**(`[ax_cleaned]`)。ev1132 击键 `g-m-a-i-l<CR><CR>` → `double_return_eng` 解出 `gmail` → 字面替换。记入 `🔧 口3 修正`(via=双return英文)可追溯。\n")

H.append("### ③ det 修正的三问题(用户逐条核出)\n")
H.append("- **#1 记得**:5/27 ev522 简拼 `ji d`(librime TOP=「基地」)→ det 的 `verify_tail` 从 OCR 帧(`明天 记得 吴承申`)捞回「记得」(确定性对证替换)。A1 ✓。")
H.append("- **#2 密码**:ev603 粘贴掩码值 `•••`(3 圆点 U+2022)→ det 路由进未定区,被 sensitive(n=3)过滤,不入成品 → 不泄漏。P0 ✓。")
H.append("  ⚠️ 数据层 `is_mask(n=4)` 仍漏 3 圆点(若落进成品仍会泄漏)——独立 bug,待单独修阈值。")
H.append("- **#3 单@**:微信 @ 提及残片(击键 `@ha`/`@ta<BS>`,弹窗插人名 AX 记不到,只 commit 了「@」)→ det 进未定区。B13 ✓。")
H.append("- **短碎片**(123/Z/J/My-Meeting/clean up boddy):纯 AX 零回车草稿 → det 进未定区(llm 直入成品)。B14 ✓。")
H.append("  统一根因 = 复查路由:`det` 把无屏幕证据的短草稿挡进未定区,`llm` 绕过复查直入成品(`faithful_v2:558` screen_only 仅 det 成立)。\n")

H.append("### ④ 逐天 diff vs 上次产出(gold 天→v20[det] ｜ 6/3,6/4→6.3-6.4 集成[llm])\n")
H.extend(diff_md)
H.append("")
H.append("> gold 四天 vs v20(同为 det 口径):主要 diff = gmail 翻绿 + 14B 同音消歧微抖。")
H.append("> 6/3、6/4 vs 集成基准(当时是 llm 口径):det 把若干短碎片路由进未定区,成品更干净(条数略少属预期)。\n")
H.append("---\n")

with open(OUT, 'w', encoding='utf-8') as f:
    f.write("\n".join(H) + "\n")
    f.write(open(PROD, encoding='utf-8').read())
print("已写", OUT)
import os
print("大小", os.path.getsize(OUT), "bytes")
