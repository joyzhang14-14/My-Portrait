#!/usr/bin/env python3
"""遗留问题对照工具:对一份产出文档(成品段)逐条判分用户 gold 标注。
用法:python3 compare_gold.py <产出文档路径>
gold 来源:输出成品-改前的pipeline-修复标注版.md 的 18 处标注 + 用户后续裁定更正
(一次→一下 / 几点→记得 / 卖个惨 / 看你怎么用了 / Blueprint 全文)。"""
import re, sys

GOLD = [
    # (名称, 必须出现, 不许出现)
    ("A1 记得(裁定gold)", ["记得"], []),
    ("A2 5点睡的", ["我今天早上5点睡的"], ["睡得", "点水的"]),
    ("A3 6个G", ["6个G"], ["6个个"]),
    ("A4 84G", ["84G"], ["84个"]),
    ("A5 writingSample2", [], ["writingSample2是"]),
    ("A6 Blueprint整条(用户称有证据)", ["就叫Blueprint", "前端会显示什么已经跑过了", "log也移动到Blueprint板块"], []),
    ("A7 yi x→一下测试(裁定)", ["余额跑一下测"], ["余额跑yi x"]),
    ("A8 pipeline", ["pipeline"], []),
    ("A10 卖个惨(裁定gold)", ["卖个惨"], ["买个参"]),
    ("A11 te d→特点", ["自己的特点"], ["自己的te d"]),
    ("A12 特定的人H", ["就问特定的人"], []),
    # A13 翻案(2026-06-12 用户截图+击键证实:第二条实发'生态的',原标注把两条消息语序记串)
    ("A13 Google生态的(翻案)", ["很喜欢Google生态的", "而且有Google的生态"], []),
    ("A14 啃下来了", ["啃下来了"], ["肯下来了"]),
    ("A15 k n→看论文", ["拿那个看论文"], ["拿那个k n"]),
    ("A16a 挺不错的(独立行)", ["\n> 挺不错的\n"], []),
    ("A16b 说实话(独立行)", ["\n> 说实话\n"], []),
    ("A17 yo→用了(裁定gold)", ["看你怎么用"], ["看你怎么哟", "看你怎么yo"]),
    ("A18 苹果某些(幻影)", [], ["苹果某些"]),
    ("A20 ElevenLabs", ["ElevenLabs"], []),
    # 第三轮审计抓到的回归(也算 gold)
    ("R4 无幻觉插入", [], ["数据生成context\n"]),
    ("R-旧 无XPC截短", ["用XPC"], []),
    ("R-旧 赛博永生干净", ["赛博永生"], ["赛博永生 数字人"]),
    ("R-新 希望是够的", ["希望是够的"], ["希望是狗的"]),
    # 2026-06-11 用户标注两案(幻影发送+过期快照):唯一终稿,过期态不入册
    ("B1 vos/vcd组唯一终稿", ["这个pipeline是和vcd有关，和vos无关", "直接给我生成一个md文档即可"], ["这个pipeline是和vos有关"]),
    ("B2 关SIP全文唯一", ["你这个提案我就看出不少问题来"], ["关SIP能不能饶过这个限制，就是说\n"]),
    # 2026-06-12 用户Discord截图三连(10:26 PM):闭引号竞速/我的意思尾竞速/特定的人(=A12)
    ("B3 闭引号(截图gold)", ["这首歌的背景怎么样”"], []),
    ("B4 我的意思(截图gold)", ["我的意思"], ["> 我的\n"]),
]

def main(path):
    D = open(path).read()
    prods = "\n".join(re.findall(r'### 🆕 新 pipeline·成品.*?(?=### )', D, re.S))
    sc = {"✓": 0, "🟡": 0, "✗": 0}
    rows = []
    for name, want, ban in GOLD:
        w = all(x in prods for x in want) if want else True
        b = [x for x in ban if x in prods]
        mark = "✓" if (w and not b) else ("🟡" if w else "✗")
        sc[mark] += 1
        extra = f"含:{b}" if b else ("" if w else f"缺:{[x for x in want if x not in prods][:2]}")
        rows.append((mark, name, extra))
        print(f"{mark} {name}  {extra}")
    # 结构统计
    n_pend = re.findall(r'未定区[^（(]*[（(](\d+)[)）]', D)
    n_rev = D.count("审核打回重修")
    n_ledger = prods.count("keystroke_recovered")
    print(f"\n得分: {sc} | 未定区: {n_pend} | 审核打回重修: {n_rev} | 入册账本记录: {n_ledger}")
    return rows, sc

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else
         "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-阶段0.md")
