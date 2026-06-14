#!/usr/bin/env python3
"""v21 对照工具(离线,零模型)。解析 det 成品文档的「🆕 新 pipeline·成品」段,
逐天 diff v21 vs 上次产出。用于 v21 归档文档的「和上次跑的成果做对比」部分。"""
import re, sys

_PUNCT = re.compile(r'[\s，,。.!？?！…、:：;；"\'"“”‘’()（）]+')
def norm(t): return _PUNCT.sub('', (t or '')).lower()

def parse_product(path):
    """→ {day: [(idx, src, app, text)]}。只取每天 🆕 段(到下一个 ### 截止)。"""
    days = {}
    cur_day = None; in_prod = False
    src = app = None
    lines = open(path, encoding='utf-8').read().splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = re.match(r'^##\s+(\d{4}-\d{2}-\d{2})\s*$', ln)
        if m:
            cur_day = m.group(1); days.setdefault(cur_day, []); in_prod = False
            i += 1; continue
        if re.match(r'^###\s+🆕', ln):
            in_prod = True; i += 1; continue
        if re.match(r'^###\s', ln):           # 任何其它 ### 段 → 退出成品段
            in_prod = False; i += 1; continue
        if in_prod and cur_day is not None:
            mm = re.match(r'^\*\*(\d+)\.\*\*\s+`\[([^\]]+)\]`\s+📍\s+`([^`]+)`', ln)
            if mm:
                idx, src_kind, app = int(mm.group(1)), mm.group(2), mm.group(3)
                src = src_kind.split('/')[0]
                # 文本 = 紧接的 > 行(可能多行)
                j = i + 1; txt = []
                while j < len(lines) and not lines[j].startswith('> ') and lines[j].strip() == '':
                    j += 1
                while j < len(lines) and lines[j].startswith('> '):
                    txt.append(lines[j][2:]); j += 1
                days[cur_day].append((idx, src, app, '\n'.join(txt).strip()))
                i = j; continue
        i += 1
    return days

def diff_day(v21_recs, base_recs):
    """逐天 set diff(归一文本)。→ (v21_only, base_only, common_n)。"""
    bset = {norm(t): (s, a, t) for _, s, a, t in base_recs}
    vset = {norm(t): (s, a, t) for _, s, a, t in v21_recs}
    v21_only = [(s, a, t) for k, (s, a, t) in vset.items() if k not in bset]
    base_only = [(s, a, t) for k, (s, a, t) in bset.items() if k not in vset]
    common = sum(1 for k in vset if k in bset)
    return v21_only, base_only, common

if __name__ == '__main__':
    # 自测:解析现有基准,打印每天条数
    for p in sys.argv[1:]:
        d = parse_product(p)
        print(f"\n=== {p} ===")
        for day, recs in sorted(d.items()):
            print(f"  {day}: {len(recs)} 条")
            for idx, s, a, t in recs[:3]:
                print(f"    {idx}. [{s}] {a}: {t[:40]!r}")
