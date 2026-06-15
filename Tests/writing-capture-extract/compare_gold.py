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
    # 2026-06-12 v17/v18 用户标注批(存量框剥离/竞速渣/Writ/header/窄账本质量)
    ("B5a 作文需求-可以吗", ["这样可以吗你觉得"], []),
    ("B5b 作文需求-时态", ["时态你帮我改吧"], ["事态你帮我改变"]),
    ("B5c 作文需求-第二问", ["这样可以吗？你觉得"], []),
    ("B5d 作文需求-够了吧", ["够了吧"], []),
    ("B6 Writ尾(占位符OCR渣)", ["然后我直接现写"], ["现写 Writ"]),
    ("B7 header之类(IME整句paste)", ["我是不是还需要加什么header之类的东西"], []),
    ("B8 窄账本质量(独立行)", ["\n> 之类的\n", "\n> 还可以\n"],
     ["\n> 增加pass\n", "\n> 让pass\n", "\n> 就是pass\n", "\n> 给pass\n"]),   # 独立行口径:'给pass3传入…'真消息含子串,误报修正
    ("B9 竞速渣清零(独立行)", [], ["\n> 这\n", "\n> go\n", "\n> shi\n", "\n> zh\n"]),
    # 2026-06-12 v19 用户标注两案(URL连坐/剥离腰斩)
    ("B10 含链接真消息整条", ["https://github.com/joyzhang14-14/My-Portrait", "接着回答问题"], []),
    ("B11 VALIS全文唯一", ["VALIS_BEATOVEN_API_KEY= 我没在env里面找到"], ["\n> 找到，这个需要我自己填是吗\n"]),
    # 2026-06-12 v20 用户标注:剥离命中后endv残影(存量+真身合成)与真身重复
    ("B12 怎么写比较好唯一", ["这个我怎么写比较好"], ["Were you encouraged to use generative AI"]),
    # 2026-06-14 用户查因批(REVIEW_MODE det 应把短碎片/微信@残片挡进未定区,不入成品):
    # 这几条是 det/llm 复查路由的回归探针——det 跑应✓,llm 跑会✗(碎片涌进成品)。
    ("B13 单@提及残片不入成品", [], ["\n> @\n"]),
    ("B14 短残渣/零回车碎片不入成品", [],
     ["\n> 123\n", "\n> Z\n", "\n> J\n", "\n> My-Meeting\n", "\n> clean up boddy\n"]),
]
# 全文档级隐私 ban(不只成品段:未定区/审计也不许出现)。
# 邮箱/掩码=PII,任意位置 ban;URL 行级 ban(整条URL草稿才算——正文含链接是合法内容,
# ev1158'审核区http://localhost:5173/…'真消息实证,2026-06-12)
DOC_BAN = ["zzhang@students", "k12.nc.us", "●●●●●●", "joyzhang_14@163",
           "\n> localhost:5173", "\n> https://www.ikeyrent.com",
           "\n> •••\n"]   # 2026-06-14 粘贴掩码密码(3圆点U+2022,is_mask数据层n=4漏网)

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
    # 全文档级隐私 ban(密码/邮箱/URL 任何段落不展示)
    leaks = [x for x in DOC_BAN if x in D]
    # 密码残留通用检查(用户裁定 2026-06-12:审核区密码残留也算):任何 '> 内容' 行
    # 为纯符号/掩码≥4(无字母数字汉字;loginwindow 实测 PUA U+F79A,枚举字符类必漏)
    for m in re.finditer(r'^\s*>\s*(\S{4,})\s*$', D, re.M):
        s_ = m.group(1)
        MASK = set('•●○◦∙⋅・⬤⚫⚪🞄＊*※⁕▪▫■□◼◻●')
        if all(ch in MASK or '\ue000' <= ch <= '\uf8ff' for ch in s_):
            leaks.append(f"掩码残留:{s_[:8]!r}")
    mark = "✓" if not leaks else "✗"
    sc[mark] += 1
    print(f"{mark} P0 隐私零泄漏(全文档)  " + (f"泄漏:{leaks}" if leaks else ""))
    # 结构统计
    n_pend = re.findall(r'未定区[^（(]*[（(](\d+)[)）]', D)
    n_rev = D.count("审核打回重修")
    n_ledger = prods.count("keystroke_recovered")
    print(f"\n得分: {sc} | 未定区: {n_pend} | 审核打回重修: {n_rev} | 入册账本记录: {n_ledger}")
    return rows, sc

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else
         "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline-阶段0.md")
