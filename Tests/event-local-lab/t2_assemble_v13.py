"""v1.3 训练包组装 —— 全确定性(2026-07-14 五路侦察 + 对抗核查后重定案)。

⚠️ 与旧方案的根本区别:不再吃 /tmp/v13_out 的 sonnet 手术产出。
   侦察实锤:手术 activity 重写率 99.6%,定向剥掉帧2+内容(-33%),删的 1596 个锚点
   98.1% 在 OCR 里逐字仍在(纯白换),还长出新口癖(未获焦点 0→29)。
   LLM 只保留一个极窄口子:2图样本降单图后,零 OCR 命中候选句的去留裁决(只删不改写),
   裁决结果从 /tmp/v13_imgfix_decisions.json 读入,由本脚本确定性消费。

对 v1.2 的五处改动(全部确定性):
  D1 题头:裸 app 名,零提示(prep 已做,本脚本只验收)
  D2 图数:全部单图对齐生产 + 帧2独有句按裁决整句删除(其余句子逐字节不动)
  D3 who:剥 hedge 括号保名字本体 → 杀 AI 助手/用户自己/非人实体;social 否定式→空串
  D4 锚点:教师原始锚点池 → 逐字校验 → spec_junk 去垃圾(app条件化) → 去重 → cap 12
       (先去垃圾再截,==12 的撞墙率自然下降,模型才学得会"何时停";绝不拆 cap)
  D5 activity:剥 hedge 括号短语(「(具体字样过小,无法辨认)」类,纯删除)

内置闸门(过不了就不出包):
  ① 全部行单图 ② 题头零泄题 ③ ==12 撞墙率 <20% ④ 终版锚点垃圾率 ≤0.6%
  ⑤ hedge 短语全库 <20 处 ⑥ n-gram 审计(非结构 8-gram >5% 报警) ⑦ MUST_KEEP 锚点存活
"""
import argparse
import collections
import json
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spec_junk import classify  # noqa: E402  一把尺子:lab.db补救/训练包/输出闸共用

SPEC_CAP = 12
SENT_SPLIT = re.compile(r'(?<=[。;；!！?？])')   # 与 t2_img_skew_v13.py 同一把刀
# hedge 括号短语:纯删除,不留模板(v1.1 死于 882 次逐字 hedge)
HEDGE_PAREN = re.compile(r'[（(][^（）()]*(?:过小|无法辨认|无法逐字辨认|未逐字录得)[^（）()]*[）)]')


def norm(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


# ---------------------------------------------------------------- who 清洗
WHO_AI = re.compile(r'^(claude|chatgpt)\b|subagent|子代理|ai ?助手|ai ?编程助手|cli ?助手', re.I)
WHO_SELF = {'joyzhang14', 'joy', 'joy zhang', 'zhuoyi', 'zhuoyi zhang'}
# 括号里的非人实体标记(游戏角色/机器人/服务/群),命中即杀整条
WHO_NONPERSON_MARK = re.compile(r'游戏角色|游戏内角色|非真实人物|非聊天对象|声纹标签|机器人|新闻账号|验证服务|服务器/群')
# curated:无标记但确定是 app/游戏/频道名的已知坏条目
WHO_NONPERSON_EXACT = {'绝区零', '绝区零工坊', '肥鹅美食街', '第五人格', '黑马程序员',
                       '服务号', '无', 'writing-capture-researcher'}


def clean_who(who):
    out, seen = [], set()
    for x in who or []:
        raw = str(x).strip()
        if not raw:
            continue
        if WHO_AI.search(raw) or WHO_NONPERSON_MARK.search(raw):
            continue
        core = HEDGE_PAREN.sub('', raw).strip()       # 剥 hedge 括号,保名字本体
        base = re.split(r'[（(]', core, maxsplit=1)[0].strip()  # 判身份用裸名
        if not core or base.casefold() in WHO_SELF or base in WHO_NONPERSON_EXACT:
            continue
        core = core[:40]
        if norm(core) in seen:
            continue
        seen.add(norm(core))
        out.append(core)
    return out


def clean_social(s):
    s = str(s or '').strip()
    # 否定式开头:剥掉前导否定分句,保留其后的真内容(「无直接社交互动;但侧栏
    # 透露…」后半是真信号);纯否定 → 空串。一刀清空会误杀复裁恢复的正例。
    if re.match(r'^(无|没有|未见|未发现|不涉及|非社交)', s):
        parts = re.split(r'[;;。]', s, maxsplit=1)
        rest = parts[1].strip() if len(parts) > 1 else ''
        rest = re.sub(r'^(但|不过|然而|仅|只是)', '', rest).strip()
        s = rest if len(rest) >= 8 else ''
    return HEDGE_PAREN.sub('', s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default="/tmp/work_v13.json")
    ap.add_argument("--imgfix", default="/tmp/v13_imgfix_decisions.json",
                    help="帧2独有句裁决(极窄LLM产出);缺文件则拒绝出包")
    ap.add_argument("--wash", help="v1.3.1 手术编辑 json(noiseEdits/socEdits/recEdits)")
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    W = json.load(open(args.work))
    fix = {d['id']: set(d['delete_indices'])
           for d in json.load(open(args.imgfix))['decisions']}
    # v1.3.1 手术编辑(--wash):结构化编辑,确定性应用。
    #   noise: {id: {delete_substrings:[], drop_specifics:[]}}(只删,子串须逐字命中)
    #   social: {id: social_new}(字段级)
    #   recon: {id: {sentence, pos}}(一句和解表述,mismatch=true 才有)
    wash = {'noise': {}, 'social': {}, 'recon': {}}
    if args.wash:
        E = json.load(open(args.wash))
        wash['noise'] = {x['id']: x for x in E.get('noiseEdits', [])}
        wash['social'] = {x['id']: x['social_new'] for x in E.get('socEdits', [])
                          if x.get('verdict') != '不动'}
        wash['recon'] = {x['id']: x for x in E.get('recEdits', []) if x.get('mismatch')}

    st = collections.Counter()
    out = {"train": [], "valid": []}
    who_pos = {"train": [], "valid": []}
    soc_have = set()          # 组装时直接记 sid(head_new 不唯一,禁止事后反查)
    for w in W['work']:
        sid = f"{w['day']}_s{w['key']}"
        ans0 = w['answer']
        # ---- D2/D5: activity = 整句删除(裁决) + 剥 hedge 括号,其余逐字节不动
        act = ans0.get('activity') or ''
        if sid in fix and fix[sid]:
            sents = SENT_SPLIT.split(act)
            act = ''.join(s for i, s in enumerate(sents) if i not in fix[sid])
            st['activity整句删除'] += len(fix[sid])
        n_hedge = len(HEDGE_PAREN.findall(act))
        if n_hedge:
            act = HEDGE_PAREN.sub('', act)
            st['hedge括号剥除'] += n_hedge
        # ---- v1.3.1 噪音刀:只删逐字命中的子串(imgfix 之后应用,找不到=静默跳过并计数)
        ne = wash['noise'].get(sid)
        if ne:
            for sub in ne.get('delete_substrings', []):
                if sub and sub in act:
                    act = act.replace(sub, '', 1)
                    st['噪音子串删除'] += 1
                elif sub:
                    st['噪音子串未命中(跳过)'] += 1
            act = re.sub(r'\s{2,}', ' ', act)
        # ---- v1.3.1 和解刀:插入一句(start/end)
        re_ = wash['recon'].get(sid)
        if re_ and (re_.get('sentence') or '').strip():
            s_ = re_['sentence'].strip()
            if not s_.endswith(('。', '.', ';', ';')):
                s_ += '。'
            act = (s_ + act) if re_.get('pos') == 'start' else (act.rstrip() + s_)
            st['和解句插入'] += 1
        act = act.strip()
        if not act:
            st['答案空(丢弃)'] += 1
            continue
        # ---- D4: 锚点池 = v1.2 已校正锚点(优先,保密度) + 教师原始池(补充,自然停止)
        # ⚠️ 只用原始池是坑(实测):v1.1 用 147 个 sonnet agent 校正过的近失锚点
        # 全在 v1.2 答案里,原始池没有 —— 只吃原始池会让中位 9→4、零锚点 46→122,
        # 教模型"少写锚点",亲手毁掉 v1.2 最大的优势。
        corpus = norm(w['ocr'] + w['head_new'])
        pool = list(ans0.get('specifics') or []) + list(w.get('teacher_specifics_raw') or [])
        # v1.3.1 噪音刀:剔除被点名的 specifics(按 norm 匹配)
        if ne and ne.get('drop_specifics'):
            drop = {norm(x) for x in ne['drop_specifics']}
            before = len(pool)
            pool = [x for x in pool if norm(str(x).strip()[:60]) not in drop]
            st['锚点点名剔除'] += before - len(pool)
        specs, seen = [], set()
        for x in pool:
            t = str(x).strip()[:60]
            k = norm(t)
            if not k or k not in corpus:
                st['锚点无OCR出处(弃)'] += 1
                continue
            g, _r = classify(t, w.get('app_bare'))
            if g:
                st['锚点垃圾(弃)'] += 1
                continue
            if k in seen:
                continue
            seen.add(k)
            specs.append(t)
        specs = specs[:SPEC_CAP]
        soc_src = wash['social'].get(sid, ans0.get('social'))   # v1.3.1:重裁值优先
        ans = {"activity": act,
               "who": clean_who(ans0.get('who')),
               "context_in_app": str(ans0.get('context_in_app') or '').strip(),
               "specifics": specs,
               "social": clean_social(soc_src)}
        q = (w['head_new'] + "\n已知(OCR全文,按帧,含背景窗文字):\n<<<\n"
             + w['ocr'] + "\n>>>\n" + w['schema_rules'])
        row = {"question": q, "answer": json.dumps(ans, ensure_ascii=False),
               "images": w['images'][:1]}                       # D2: 单图
        out[w['split']].append(row)
        if ans['who']:
            who_pos[w['split']].append((sid, len(out[w['split']]) - 1))
        if ans['social']:
            soc_have.add(sid)
        st[f"采用_{w['split']}"] += 1

    # who 分层:valid 里 who 正例 ≥5,否则 who 崩了看不见(train38/valid1 的地雷)
    need = 5 - len(who_pos['valid'])
    for k in range(min(need, len(who_pos['train']))) if need > 0 else []:
        sid, idx = who_pos['train'][k]
        # 与 valid 里第 k 个 who 阴性行对换(保持两边行数不变)
        vneg = [i for i in range(len(out['valid']))
                if not json.loads(out['valid'][i]['answer'])['who']]
        if not vneg:
            break
        j = vneg[k % len(vneg)]
        out['train'][idx], out['valid'][j] = out['valid'][j], out['train'][idx]
        st['who分层对换'] += 1

    # 混练短题:原样保留(防塌缩,v1.2 已验证有效),只降单图
    for m in W['mix']:
        out[m['split']].append({"question": m['question'], "answer": m['answer'],
                                "images": m['images'][:1]})
        st[f"混练_{m['split']}"] += 1

    for split, rows in out.items():
        with open(os.path.join(args.outdir, f"{split}.jsonl"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # ================= 闸门 =================
    print(json.dumps(dict(st), ensure_ascii=False, indent=1))
    tr = out['train']
    fails = []
    # ① 单图
    multi = sum(1 for s in out.values() for r in s if len(r['images']) != 1)
    print(f"\n闸门① 单图: 多图行 {multi} (须为0)")
    if multi:
        fails.append('单图')
    # ② 题头零泄题(app 字段裸名 = 不含'(')
    leak = 0
    for r in tr:
        if '已知(OCR' not in r['question']:
            continue
        app_seg = r['question'].split('前台 app = ', 1)[1].split(';窗口标题', 1)[0]
        if '(' in app_seg or '(' in app_seg:
            leak += 1
    print(f"闸门② 题头泄题: {leak} (须为0)")
    if leak:
        fails.append('泄题')
    # ③ 锚点分布:撞墙率要降,但密度绝不许掉(v1.2 的核心优势=锚点中位 9/零锚点 8.6%;
    #    只吃教师原始池会把中位打到 4、零锚点 23% —— 撞墙率的"改善"是锚点饥饿的假象)
    ns = sorted(len(json.loads(r['answer'])['specifics']) for r in tr
                if '已知(OCR' in r['question'])
    real = len(ns)
    wall = ns.count(SPEC_CAP) / max(1, real)
    zero = ns.count(0) / max(1, real)
    med = ns[real // 2] if ns else 0
    print(f"闸门③ 锚点: ==12 撞墙 {wall*100:.1f}% (须<v1.2 的 36.5%) / "
          f"中位 {med} (须≥8) / 零锚点 {zero*100:.1f}% (须≤10%)")
    if wall >= 0.365:
        fails.append('撞墙率')
    if med < 8:
        fails.append('锚点密度')
    if zero > 0.10:
        fails.append('零锚点')
    # ④ 终版锚点垃圾率(同一把分类器复检;app 从题头取,与组装口径一致)
    junk = tot = 0
    for r in tr:
        if '已知(OCR' not in r['question']:
            continue
        app = r['question'].split('前台 app = ', 1)[1].split(';窗口标题', 1)[0]
        for s in json.loads(r['answer'])['specifics']:
            tot += 1
            if classify(s, app)[0]:
                junk += 1
    print(f"闸门④ 终版锚点垃圾率: {junk}/{tot} = {junk/max(1,tot)*100:.2f}% (须≤0.6%)")
    if junk / max(1, tot) > 0.006:
        fails.append('垃圾率')
    # ⑤ hedge 残留
    hedge = sum(len(re.findall(r'过小|无法辨认|未逐字录得', r['answer'])) for r in tr)
    print(f"闸门⑤ hedge 残留: {hedge} 处 (须<20;v1.1 塌缩时 882)")
    if hedge >= 20:
        fails.append('hedge')
    # ⑥ n-gram 审计
    ng = collections.Counter()
    for r in tr:
        a = r['answer']
        for i in range(0, max(0, len(a) - 8), 4):
            ng[a[i:i + 8]] += 1
    hot = [(g, c) for g, c in ng.most_common(60)
           if c > len(tr) * 0.05 and not re.match(r'^[\s",::\[\]{}»«]*$', g)
           and not re.search(r'(activity|specifics|context|social|who)', g)]
    print(f"闸门⑥ n-gram: {hot[:8] if hot else '✅ 无模板吸引子'}")
    # ⑦ MUST_KEEP 抽查:已知真锚点必须存活在对应样本里
    probes = [('2026-06-07_s661', 'Sources/MyPortrait/Memory/MemoriesView.swift'),
              ('2026-06-30_s2289', '何成')]
    all_ans = {f"{w['day']}_s{w['key']}": w for w in W['work']}
    for sid, needle in probes:
        w = all_ans.get(sid)
        ok = w and any(norm(needle) in norm(json.dumps(r['answer'], ensure_ascii=False))
                       for s in out.values() for r in s
                       if w['head_new'] in r['question'])
        print(f"闸门⑦ {sid} 含 {needle!r}: {'✅' if ok else '⚠️ 没找到(人工核)'}")
    # who/social 终版统计
    wt = sum(1 for r in tr if '已知(OCR' in r['question'] and json.loads(r['answer'])['who'])
    wv = sum(1 for r in out['valid'] if '已知(OCR' in r['question'] and json.loads(r['answer'])['who'])
    st_soc = sum(1 for r in tr if '已知(OCR' in r['question'] and json.loads(r['answer'])['social'])
    print(f"\nwho 正例: train {wt} / valid {wv} (valid 须≥5) | social 非空: {st_soc}")
    if wv < 5:
        fails.append('who分层')
    if args.wash:
        # ⑧ 教师裁定的非空 social 必须存活(防 v1.3 削正例保守化重演)。
        # 不用正则代理计数(前两版闸门都被代理口径坑了:156 基线灌水/桌面字样误杀)。
        # 精确口径:socEdits 里教师终态非空的 id,逐个核包内是否仍非空;容忍 ≤3
        # (答案空丢弃的样本)。
        want = {x['id'] for x in json.load(open(args.wash)).get('socEdits', [])
                if x.get('verdict') != '不动' and (x.get('social_new') or '').strip()}
        lost = want - soc_have
        print(f"闸门⑧ 教师裁定非空 social 存活: {len(want & soc_have)}/{len(want)} "
              f"(丢 {len(lost)},容忍≤3) | 包内 social 非空总数 {len(soc_have)}")
        if len(lost) > 3:
            print(f"   丢失: {sorted(lost)[:10]}")
            fails.append('social正例')
        print(f"闸门⑨ 和解句插入: {st['和解句插入']} 条 / 噪音删除 {st['噪音子串删除']} 处"
              f"(未命中跳过 {st['噪音子串未命中(跳过)']})")
    print(f"\ntrain {len(out['train'])} / valid {len(out['valid'])}")
    if fails:
        print(f"\n❌ 闸门不过: {fails} —— 不出包,别拿去训练")
        sys.exit(1)
    print("\n✅ 全部闸门通过")


main()
