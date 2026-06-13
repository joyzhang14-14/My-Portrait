#!/usr/bin/env python3
"""canvas 重建自动验证(程序化对照 gold,不展示 gold 内容——用户指令)。
指标:覆盖率(gold窗→重建)/精确率(重建窗→gold)/chrome残留/timeline统计。
用法:python3 canvas_eval.py [eval/canvas_v1.json]
"""
import json, re, sys

def normx(s):
    s = (s or '').replace('&quot;', '"').replace('（', '(').replace('）', ')')
    s = s.replace('“', '"').replace('”', '"').replace('’', "'").replace('‘', "'")
    return re.sub(r'[^a-z0-9一-鿿]', '', s.lower())

def windows(s, w=24):
    ws = [s[i:i + w] for i in range(0, max(1, len(s) - w), w)]
    if len(s) > w: ws.append(s[-w:])   # 尾窗:不足一窗的结尾也要查(实证漏过"断在句中")
    return ws

def main(path):
    d = json.load(open(path))
    rec = normx(d['final_text'])
    gold = normx(open('eval/canvas_gold.txt').read())
    def hit(c, hay):   # 半窗容差:错字窗(1-2字伤)算命中;与guard同口径
        return c in hay or (c[:12] in hay and len(c) >= 20) or (c[12:] in hay and len(c) >= 20)
    gw = windows(gold)
    cov = sum(1 for c in gw if hit(c, rec))
    rw = windows(rec)
    prec = sum(1 for c in rw if hit(c, gold))
    # chrome 残留探针(已保存/保存中/菜单词/调查题干指纹)
    probes = ['已保存', '保存中', 'filEditViewInsert', 'surveysoitdoesnttimeout', 'pressuptoedit']
    leaks = [p for p in probes if normx(p) in rec]
    tl = d.get('timeline', [])
    kinds = {}
    for _, k, _t in tl: kinds[k] = kinds.get(k, 0) + 1
    print(f"覆盖率: {cov}/{len(gw)} = {cov/len(gw):.0%}")
    print(f"精确率: {prec}/{len(rw)} = {prec/len(rw):.0%}" if rw else "精确率: n/a")
    print(f"chrome残留: {leaks if leaks else 0}")
    print(f"timeline: {kinds} | 帧 {d.get('frames')} | chrome行 {d.get('chrome_lines')}")
    return cov / len(gw) if gw else 0

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'eval/canvas_v1.json')
