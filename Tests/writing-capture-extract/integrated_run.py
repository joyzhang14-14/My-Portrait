#!/usr/bin/env python3
"""集成判别路径:对一天的写作活动,判别哪些是 canvas 长文会话(网页文档编辑器,
AX 拿不到完整内容、靠 OCR 帧重建)→ 走 canvas_merge;其余全交 AX 路(faithful_v2)。
产出 eval/canvas_local_fusion.json(按天索引,供 faithful_v2 PORTRAIT_CANVAS 读)。

判别信号(确定性,零模型):
  ① browser_url 命中文档编辑器域名白名单(docs.google/notion/yuque/feishu/overleaf…)
  ② 该 URL 在窗口内帧数 ≥ MIN_FRAMES(够长,排除一闪而过)
  ③ 该 URL 时段的浏览器击键 ≥ MIN_KEYS(真在写,排除纯阅读)
三条全中 = canvas 会话。canvas 路只在判别命中时才加载 14B。

用法:PORTRAIT_DAYS=2026-06-03,2026-06-04 python3 integrated_run.py
"""
import sqlite3, os, json, re, sys, datetime
from collections import Counter

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
EVAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval")

DOC_EDITORS = [
    'docs.google.com/document', 'notion.so', 'notion.site', 'yuque.com',
    'feishu.cn/docx', 'larksuite.com/docx', 'overleaf.com', 'hackmd.io',
    'craft.do', 'quip.com', 'onedrive.live.com/edit', 'office.com/word',
]
MIN_FRAMES = 30      # ≈5 分钟(10s/帧)
MIN_KEYS = 200       # 长文写作下限(5/28 essay=5520;聊天/搜索远不及)

def utc_window(day):
    d = datetime.datetime.strptime(day, '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp() * 1000), int((d + datetime.timedelta(days=1)).timestamp() * 1000)

def discriminate(day):
    """返回 [(url_frag, t0_local_str, t1_local_str, n_frames, n_keys, app)] —— canvas 会话。"""
    T0, T1 = utc_window(day)
    # 文档编辑器候选 URL 的帧聚合(按 URL 前 80 字分组)
    rows = con.execute(
        "SELECT browser_url, timestamp_ms, app_name FROM frames "
        "WHERE timestamp_ms BETWEEN ? AND ? AND browser_url IS NOT NULL ORDER BY timestamp_ms",
        (T0, T1)).fetchall()
    by_url = {}
    for url, ts, app in rows:
        if not any(pat in (url or '') for pat in DOC_EDITORS):
            continue
        k = (url or '')[:80]
        e = by_url.setdefault(k, {'url': url, 'a': ts, 'b': ts, 'n': 0, 'app': app})
        e['b'] = ts; e['n'] += 1
    sessions = []
    for k, e in by_url.items():
        if e['n'] < MIN_FRAMES:
            continue
        nk = con.execute(
            "SELECT COUNT(*) FROM keystroke_log WHERE ts_ms BETWEEN ? AND ? "
            "AND (bundle_id LIKE '%Safari%' OR bundle_id LIKE '%Chrome%' OR bundle_id LIKE '%Arc%') "
            "AND (modifiers&7)=0", (e['a'] - 5000, e['b'] + 5000)).fetchone()[0]
        if nk < MIN_KEYS:
            continue
        # canvas_merge 用本地时间字符串;URL 片段取文档 id 段做 LIKE
        m = re.search(r'/document/d/([A-Za-z0-9_-]{6,})', e['url'] or '')
        frag = m.group(1)[:12] if m else (e['url'] or '')[:40]
        ls = datetime.datetime.fromtimestamp(e['a'] / 1000).strftime('%Y-%m-%d %H:%M')
        le = datetime.datetime.fromtimestamp(e['b'] / 1000 + 600).strftime('%Y-%m-%d %H:%M')
        sessions.append((frag, ls, le, e['n'], nk, e['app']))
    return sessions

def main():
    days = os.environ.get('PORTRAIT_DAYS', '2026-06-03,2026-06-04').split(',')
    fusion = {}
    print("=" * 56)
    print("判别路径(canvas vs AX)")
    print("=" * 56)
    canvas_merge = None
    for day in days:
        sess = discriminate(day)
        T0, T1 = utc_window(day)
        # 概览:这天浏览器击键总量 + 文档编辑器候选数
        nk = con.execute("SELECT COUNT(*) FROM keystroke_log WHERE ts_ms BETWEEN ? AND ? "
                         "AND (bundle_id LIKE '%Safari%' OR bundle_id LIKE '%Chrome%') AND (modifiers&7)=0",
                         (T0, T1)).fetchone()[0]
        print(f"\n[{day}] 浏览器击键 {nk} | canvas 会话 {len(sess)}")
        recs = []
        for frag, t0s, t1s, nf, nks, app in sess:
            print(f"  → canvas: {frag} ({t0s}~{t1s}, {nf}帧/{nks}键) 走 canvas_merge", flush=True)
            if canvas_merge is None:
                import canvas_merge as canvas_merge  # 仅判别命中才加载 14B
            body = canvas_merge.main(frag, t0s, t1s)
            d2 = json.load(open(os.path.join(EVAL, 'canvas_v2.json')))
            recs.append({'source': 'canvas_local', 'text': body, 'app': app or 'Safari',
                         'timeline': d2.get('timeline', [])})
        if not sess:
            print(f"  → 无 canvas 长文会话,全部走 AX 路")
        fusion[day] = recs
    out = os.path.join(EVAL, 'canvas_local_fusion.json')
    json.dump(fusion, open(out, 'w'), ensure_ascii=False)
    print(f"\n判别完成,写 {out}")
    print(f"汇总:{sum(len(v) for v in fusion.values())} 个 canvas 会话,"
          f"其余全部由 AX 路(faithful_v2)处理")

if __name__ == '__main__':
    main()
