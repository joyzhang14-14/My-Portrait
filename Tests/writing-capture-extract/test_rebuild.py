#!/usr/bin/env python3
"""rebuild.py 确定性部分的快速测试(不调 MLX):分类器 / 击键解析 / 防幻觉 guard。"""
import rebuild as R

ok = bad = 0
def chk(name, got, want):
    global ok, bad
    if got == want: ok += 1; print(f"  ✓ {name}")
    else: bad += 1; print(f"  ✗ {name}: got {got!r} want {want!r}")

print("=== 分类器 classify(py, picked) ===")
# 英文:rime 英文词典(cands[0]==自己)
for w in ['attention', 'coding', 'notebook', 'gemini', 'google']:
    chk(f"{w}→english", R.classify(w, None)[0], 'english')
# 英文:无选字 + 单辅音音节(gmail/xpc,rime 没收录)
chk("gmail→english", R.classify('gmail', None)[0], 'english')
chk("xpc→english", R.classify('xpc', None)[0], 'english')
# 中文:有选字数字
chk("nitian(选字)→chinese", R.classify('nitian', 0)[0], 'chinese')
chk("tedian→chinese", R.classify('tedian', 0)[0], 'chinese')
chk("buxing→chinese", R.classify('buxing', 0)[0], 'chinese')
chk("shuide→chinese", R.classify('shuide', 0)[0], 'chinese')
# 残缺:末尾单辅音
chk("henbux→incomplete", R.classify('henbux', None)[0], 'incomplete')

print("=== librime 候选 #0(确定性主力)===")
chk("nitian[0]=逆天", R.cands('nitian')[0], '逆天')     # F:不该是你替
chk("tedian[0]=特点", R.cands('tedian')[0], '特点')     # K
chk("buxing[0]=不行", R.cands('buxing')[0], '不行')     # N
chk("sha[0]=啥", R.cands('sha')[0], '啥')               # B
chk("meikandong[0]=没看懂", R.cands('meikandong')[0], '没看懂')  # B

print("=== 击键解析 parse_picks ===")
chk("dian1shuide1", [(p, i) for p, i, c in R.parse_picks(list('dian1shuide1'))], [('dian', 0), ('shuide', 0)])
chk("nitian1", [(p, i) for p, i, c in R.parse_picks(list('nitian1'))], [('nitian', 0)])
chk("sha1meikandong1", [(p, i) for p, i, c in R.parse_picks(list('sha1meikandong1'))], [('sha', 0), ('meikandong', 0)])
chk("gmail(无选字)", [(p, i, c) for p, i, c in R.parse_picks(list('gmail'))], [('gmail', None, False)])

print("=== 退格/分段 ===")
chk("ge<BS>mail→gmail", R.split_cr('ge<BS>mail<CR>'), [list('gmail')])
chk("两条消息按CR切", len(R.split_cr('sha1<CR>meikandong1<CR>')), 2)
# 退格感知(ev461):单音节 na1<BS>na1 = 打「那」→删→重打,只剩单字 na(非 nana→娜娜叠字)
chk("na1<BS>na1→na(不叠字)", [(p, i) for p, i, c in R.parse_picks(R.split_cr('na1<BS>na1<CR>')[0])], [('na', 0)])
chk("hao1na1<BS>→只删na(留hao)", [(p, i) for p, i, c in R.parse_picks(R.split_cr('hao1na1<BS><CR>')[0])], [('hao', 0)])
# 多音节上屏多个字:退格只删**末字**(dabao1=打包 → 删「包」剩 da1=打),不是整删也不是只弹数字
chk("dabao1<BS>→da(打包删包剩打)", [(p, i) for p, i, c in R.parse_picks(R.split_cr('dabao1<BS><CR>')[0])], [('da', 0)])
chk("nihao1<BS>→ni(你好删好)", [(p, i) for p, i, c in R.parse_picks(R.split_cr('nihao1<BS><CR>')[0])], [('ni', 0)])
# 简拼也算数:zhongy=zhong+y=重要(2字),退格删「要」剩「重」
chk("简拼zhongy1<BS>→zhong", [(p, i) for p, i, c in R.parse_picks(R.split_cr('zhongy1<BS><CR>')[0])], [('zhong', 0)])
# ⚠️英文/残渣不是拼音上屏:数字是字面,保持旧逐字弹,否则英文词会被整个吞掉
chk("英文sonnet1<BS>不整删", [(p, i) for p, i, c in R.parse_picks(R.split_cr('sonnet1<BS><CR>')[0])], [('sonnet', None)])
chk("乱码ubia1<BS>不整删", [(p, i) for p, i, c in R.parse_picks(R.split_cr('ubia1<BS><CR>')[0])], [('ubia', None)])

print("=== 防幻觉 guard ===")
# J:模型把 gmail 幻觉成"购买了",但"购买了"不在任何候选/原文 → 回退
chk("J gmail→购买了 回退", R.guard('gmail', '购买了', allowed_han=set(), eng={'gmail'}), 'gmail')
# F:候选里有逆天,模型输出逆天 → 放行
chk("F 逆天 放行", R.guard('', '逆天', allowed_han=set('逆天'), eng=set()), '逆天')
# 模型输出你替,但只有逆天在候选 → 你替的"替"无来源 → 回退
chk("F 你替(替无来源) 回退", R.guard('', '你替', allowed_han=set('逆天你'), eng=set()), '')

print(f"\n=== {ok} 通过 / {bad} 失败 ===")
