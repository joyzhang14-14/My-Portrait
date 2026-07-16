#!/usr/bin/env python3
"""canvas 路由编排 —— 替代 integrated_run 的 discriminate 流程(新文件,不改 integrated_run/rebuild)。

承载率 `ax_bearing.canvas_spans` 逐段判别(零硬编码,替老白名单+整session+200键门槛)→
  · B 短(≤120键)→ `canvas_librime` 解码(确定性,**本文件可跑**)
  · C 长(>120键)→ `canvas_merge`(OCR,**要 GPU**,本文件留占位待跑)
AX 承载段不在这(faithful_v2 自己从 typing_events/keystroke_log 重建)。

产出 `eval/canvas_route_fusion.json` = `{day: [{source,text,app}]}`,格式同 integrated_run 的
canvas_local_fusion,直接给 faithful_v2 `PORTRAIT_CANVAS` 读。⚠️ C 段无 text(待 canvas_merge),
不写进 fusion(faithful 读 text 会炸),只在终端报告哪些会话待 GPU 跑。
"""
import os, sys, json, sqlite3
import ax_bearing as B
import canvas_librime as CL
import canvas_c_run as CC   # C 档聚合(collect_c);2026-07-11 整合成单入口后 canvas_c_run 只作库复用
import canvas_merge as CM

EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'eval')
ENG_STRIP_CUTOFF = '2026-06-25'   # 采集层改版日:此前旧采集才有「英文+拼音粘连」#3 类事件(用户裁定,同 faithful decode 分界)


def route_day(con, day, llm=None):
    """一天的 canvas 会话路由。返回 (b_records 给 fusion, c_pending 待 GPU)。"""
    (t0,) = con.execute("SELECT strftime('%s', :d) * 1000", {"d": day}).fetchone()
    (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day') * 1000", {"d": day}).fetchone()
    CL._ENG_STRIP = day < ENG_STRIP_CUTOFF   # 英文前缀剥离只对旧采集(<6/25)开,新采集干净路不跑(消误剥风险)
    b_recs, c_pending = [], []
    for sp in B.canvas_spans(con, t0, t1):
        app = sp['bundle'].rsplit('.', 1)[-1]
        if sp['bucket'] == 'B':
            text = CL.decode_span(con, sp['bundle'], sp['t0'], sp['t1'])
            text = CL.ocr_correct_llm(con, sp, text, llm)   # llm=None → 回退 librime(GPU 占用/不跑模型)
            text2 = CL.ax_verify(con, sp, text)   # AX 验证 keystroke(2026-07-10 用户裁定:十七块政策案)
            src = 'canvas_B+axv' if text2 != text else 'canvas_B'
            text = text2
            if text.strip():   # 纯空白不产成品(correctness);有内容哪怕一个「，」都留(用户裁定)
                # bundle/t0/t1:成品时间字段用(2026-07-17 用户指定,击键真值分 session)
                b_recs.append({'source': src, 'text': text, 'app': app,
                               'bundle': sp['bundle'], 't0': sp['t0'], 't1': sp['t1']})
        else:   # C 长文 → canvas_merge(要 GPU),本文件不跑
            c_pending.append({**sp, 'app': app})
    return b_recs, c_pending


def build_canvas(con, days, llm=None):
    """一体化 canvas 构建(B+C 两桶)→ 返回 (fusion, creport, cnoanchor)。
    fusion={day:[{source,text,app}]}(同 canvas_route_fusion.json 结构)。faithful_v2 主程序**内联调用
    本函数**(不落 fusion 中间文件);llm=主程序已加载的 14B callable(共享,不重复加载),无则 B 回退
    librime、C 内部自 load。B 由 route_day 逐 span;C 按 Google docid 跨天聚合、一文档一次 canvas_merge
    (共享 llm 的 model),无 url 的 C span 无锚点透明丢弃。"""
    fusion = {}
    for day in days:
        b, _c = route_day(con, day, llm)   # B 段;C 由下方按文档聚合驱动(不再逐 span pending)
        fusion[day] = b
    cdocs, cnoanchor = CC.collect_c(con, days)
    cmodel = getattr(llm, 'model', None); ctok = getattr(llm, 'tok', None)
    creport = []
    for did, e in cdocs.items():
        (fmin, fmax) = con.execute("SELECT min(timestamp_ms), max(timestamp_ms) FROM frames "
                                   "WHERE browser_url LIKE :u AND ocr_words_json IS NOT NULL",
                                   {"u": f"%{did}%"}).fetchone()
        if not fmin:
            cnoanchor.append({'day': '?', 'app': e['bundle'], 'nkeys': 0, 'reason': f'{did[:16]} 有url库中无帧'}); continue
        r = CM.reconstruct(con, did, e['bundle'], fmin, fmax, model=cmodel, tok=ctok)
        assigned = max(sp[0] for sp in e['spans'])
        if r['final_text'].strip():
            fusion.setdefault(assigned, []).append({'source': 'canvas_C', 'text': r['final_text'], 'app': e['bundle'],
                                                    'bundle': e.get('bundle_full'),
                                                    't0': min(sp[1] for sp in e['spans']),
                                                    't1': max(sp[2] for sp in e['spans'])})
            creport.append((assigned, did, e['bundle'], r['frames'], len(r['final_text'])))
    return fusion, creport, cnoanchor


def main():
    con = sqlite3.connect(B.DB)
    args = [a for a in sys.argv[1:] if a != '--llm']
    llm = CL.make_llm() if '--llm' in sys.argv else None   # 默认不跑模型;--llm 且 GPU 空时才开
    if args:
        days = args
    else:
        (tmax,) = con.execute("SELECT max(ts_ms) FROM keystroke_log").fetchone()
        (d,) = con.execute("SELECT date(:t/1000, 'unixepoch')", {"t": tmax}).fetchone()
        days = [d]

    fusion, creport, cnoanchor = build_canvas(con, days, llm)

    os.makedirs(EVAL, exist_ok=True)
    out = os.path.join(EVAL, 'canvas_route_fusion.json')
    json.dump(fusion, open(out, 'w'), ensure_ascii=False)

    nb = sum(1 for v in fusion.values() for x in v if x['source'].startswith('canvas_B'))
    ncc = sum(1 for v in fusion.values() for x in v if x['source'] == 'canvas_C')
    print(f"canvas 单入口 · {len(days)} 天 · B {nb} 段 · C {ncc} 篇 · 无锚点 C {len(cnoanchor)}")
    print(f"→ 写 {out}(供 faithful_v2 PORTRAIT_CANVAS 读)\n")
    for a, did, app, nf, nc in creport:
        print(f"  [C {a}] {app:<10} {did[:16]} {nf}帧 → {nc}字")
    for n in cnoanchor:
        print(f"  [C-DROP] {n['day']} {n['app']:<10} {n.get('nkeys', 0)}键 {n['reason']}")


if __name__ == '__main__':
    main()
