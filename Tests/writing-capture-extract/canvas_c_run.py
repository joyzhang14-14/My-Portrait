#!/usr/bin/env python3
"""canvas C 档(长文档)驱动 —— 按【文档】而非按天/按 span 跑 canvas_merge.reconstruct。

为什么按文档:canvas_spans 按 60s 击键突发切段,一篇长文档被切成很多 C span(还可能跨天,
如 gold essay 05-28→05-29);canvas_merge 是「整篇文档一次重建」粒度。若按 C span 逐个跑,
同一文档会被重建 N 次(且每次按 browser_url 拉全部帧)→ 重复。故这里按 docid 聚合,一文档一次。

流程:扫全部天的 C span → 按 Google docid 聚合(url 里 /d/<id>);无 url 的 C span 无法定位帧
(canvas_merge 靠 browser_url 找帧)→ 记 dropped 上报,不臆造。每文档:时间窗=该 docid 全部帧的
时间跨度(含收尾通读帧);归属天=最后一个 C span 的天。产出并入 canvas_route 写的
eval/canvas_route_fusion.json(source=canvas_C),timeline 侧存 eval/canvas_c_timeline.json。

⚠️ 加载 14B(GPU)。⚠️ canvas_merge 启发式是 gold essay 拟合值,泛化到别的文档未验证(审核文档标注)。
用法: python3 canvas_c_run.py [day1 day2 ...]   默认=全部有 keystroke 记录的天(UTC)。
"""
import os, sys, json, re, sqlite3
import ax_bearing as B
import canvas_merge as CM

EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'eval')
FUSION = os.path.join(EVAL, 'canvas_route_fusion.json')


def docid(url):
    m = re.search(r'/d/([A-Za-z0-9_-]+)', url or '')
    return m.group(1) if m else None


def all_days(con):
    return [r[0] for r in con.execute(
        "SELECT DISTINCT strftime('%Y-%m-%d', ts_ms/1000, 'unixepoch') FROM keystroke_log ORDER BY 1")]


def collect_c(con, days):
    """扫这些天的 C span,按 docid 聚合。返回 (docs, noanchor)。"""
    docs, noanchor = {}, []
    for d in days:
        (t0,) = con.execute("SELECT strftime('%s', :d)*1000", {"d": d}).fetchone()
        (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day')*1000", {"d": d}).fetchone()
        for sp in B.canvas_spans(con, t0, t1):
            if sp['bucket'] != 'C':
                continue
            did = docid(sp['url'])
            short = sp['bundle'].rsplit('.', 1)[-1]
            if not did:
                noanchor.append({'day': d, 'app': short, 'nkeys': sp['nkeys'], 'reason': '无url,无法定位帧'})
                continue
            e = docs.setdefault(did, {'bundle': short, 'bundle_full': sp['bundle'], 'spans': []})
            e['spans'].append((d, sp['t0'], sp['t1']))
    return docs, noanchor


def main():
    con = sqlite3.connect(B.DB)
    days = sys.argv[1:] or all_days(con)
    docs, noanchor = collect_c(con, days)
    print(f"C 档扫描 · {len(days)} 天 · {len(docs)} 文档(有url) · {len(noanchor)} 个无锚点 C span", file=sys.stderr)

    model = tok = None
    results = []   # {assigned, docid, app, text, timeline, frames}
    for did, e in docs.items():
        (fmin, fmax) = con.execute(
            "SELECT min(timestamp_ms), max(timestamp_ms) FROM frames "
            "WHERE browser_url LIKE :u AND ocr_words_json IS NOT NULL", {"u": f"%{did}%"}).fetchone()
        if not fmin:
            noanchor.append({'day': '?', 'app': e['bundle'], 'nkeys': 0, 'reason': f'{did[:16]} 有url但库中无帧'})
            continue
        if model is None:
            from mlx_lm import load
            model, tok = load("mlx-community/Qwen3-14B-4bit")
        r = CM.reconstruct(con, did, e['bundle'], fmin, fmax, model=model, tok=tok)
        assigned = max(sp[0] for sp in e['spans'])   # 归属最后一个 C span 的天
        results.append({'assigned': assigned, 'docid': did, 'app': e['bundle'],
                        'text': r['final_text'], 'timeline': r['timeline'], 'frames': r['frames']})

    # 并入 fusion(不清 canvas_route 写的 B 段)
    fusion = json.load(open(FUSION)) if os.path.exists(FUSION) else {}
    for r in results:
        if r['text'].strip():
            fusion.setdefault(r['assigned'], []).append(
                {'source': 'canvas_C', 'text': r['text'], 'app': r['app']})
    json.dump(fusion, open(FUSION, 'w'), ensure_ascii=False)
    json.dump({r['docid']: {'assigned': r['assigned'], 'frames': r['frames'], 'timeline': r['timeline']}
               for r in results},
              open(os.path.join(EVAL, 'canvas_c_timeline.json'), 'w'), ensure_ascii=False)

    print(f"\nC 档驱动 · {len(results)} 文档解出 · {len(noanchor)} 个无锚点丢弃 · 写 {FUSION}")
    for r in results:
        print(f"  [C {r['assigned']}] {r['app']:<8} {r['docid'][:16]}  {r['frames']}帧 → {len(r['text'])}字  {r['text'][:44]!r}")
    for n in noanchor:
        print(f"  [C-DROP] {n['day']} {n['app']:<8} {n['nkeys']}键  {n['reason']}")


if __name__ == '__main__':
    main()
