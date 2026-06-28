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

EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'eval')


def route_day(con, day):
    """一天的 canvas 会话路由。返回 (b_records 给 fusion, c_pending 待 GPU)。"""
    (t0,) = con.execute("SELECT strftime('%s', :d) * 1000", {"d": day}).fetchone()
    (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day') * 1000", {"d": day}).fetchone()
    b_recs, c_pending = [], []
    for sp in B.canvas_spans(con, t0, t1):
        app = sp['bundle'].rsplit('.', 1)[-1]
        if sp['bucket'] == 'B':
            text = CL.decode_span(con, sp['bundle'], sp['t0'], sp['t1'])
            if text:
                b_recs.append({'source': 'canvas_B', 'text': text, 'app': app})
        else:   # C 长文 → canvas_merge(要 GPU),本文件不跑
            c_pending.append({**sp, 'app': app})
    return b_recs, c_pending


def main():
    con = sqlite3.connect(B.DB)
    if len(sys.argv) > 1:
        days = sys.argv[1:]
    else:
        (tmax,) = con.execute("SELECT max(ts_ms) FROM keystroke_log").fetchone()
        (d,) = con.execute("SELECT date(:t/1000, 'unixepoch')", {"t": tmax}).fetchone()
        days = [d]

    fusion, pending = {}, []
    for day in days:
        b, c = route_day(con, day)
        fusion[day] = b
        for sp in c:
            pending.append((day, sp))

    os.makedirs(EVAL, exist_ok=True)
    out = os.path.join(EVAL, 'canvas_route_fusion.json')
    json.dump(fusion, open(out, 'w'), ensure_ascii=False)

    nb = sum(len(v) for v in fusion.values())
    print(f"canvas 路由(替 discriminate)· {len(days)} 天 · B {nb} 段已解 · C {len(pending)} 段待 GPU")
    print(f"→ 写 {out}(B 段,供 faithful_v2 PORTRAIT_CANVAS 读)\n")
    for day in days:
        for r in fusion[day]:
            print(f"  [B {day}] {r['app']:<10} {r['text'][:46]!r}")
    for day, sp in pending:
        print(f"  [C {day}] {sp['app']:<10} {sp['nkeys']}键 {(sp['url'] or '-')[:34]} → 待 canvas_merge(GPU)")


if __name__ == '__main__':
    main()
