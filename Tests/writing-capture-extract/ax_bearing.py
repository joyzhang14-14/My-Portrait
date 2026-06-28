#!/usr/bin/env python3
"""承载率(AX value 承载率)第1层 —— 判「这段时间用户在打字,AX 到底接没接到内容」。
路由用途:承载 → AX 路(faithful_v2);0 承载 → canvas 路(OCR / bucket B librime)。

为什么这么算(2026-06-27 实测 Google Docs 校准,详见 HANDOFF):
- **单位 = keystroke_log 的击键突发窗,不是 typing_event**。canvas 正文的 typing_event
  不可靠:测试1 正文「测试测试，canvas」的击键落在两个 event 之间的空档里,根本没有
  对应 typing_event(AX value 不变→事件机制不 fire)。keystroke_log(CGEventTap)独立于
  AX,内容一个不丢,所以拿它当骨架。
- **AX 实质内容 = edit_log 的 commit/submit 真字符**,不是 end_value。① 聊天发送后
  end_value 是占位符(`﻿⏎`,strip 完也是空),真内容在 edit_log 的 submit 里;② canvas 的
  edit_log 只有 `paste` 的 ZWSP/空格,没有任何 commit/submit(英文/拼音全在 keystroke_log,
  AX 一个字没接到)。只认 commit/submit(IME 上屏的真手打),排除 paste/delete。
- **零硬编码**:不认 URL / app / ZWSP 特例,只看「击键量 vs 窗内 AX 实质字符量」。

判据:窗内有真内容击键(≥MIN_KEYS)且窗内 AX commit/submit 实质字符 ≤ AX_EMPTY → **0 承载**。
"""
import sqlite3, os, sys, json, time, bisect

DB = os.path.expanduser("~/.portrait/portrait.sqlite")
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF, 0x00A0}   # ZWSP/ZWNJ/ZWJ/BOM/NBSP —— canvas 的占位字符
def strip_zw(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()

# 调参(都可调,先用 Google Docs 校准出的保守值)
BURST_GAP_MS = 60_000   # 同 app 内击键间隔 > 此 = 断成新窗(1 分钟停顿)
AX_PAD_MS    = 3000     # 逐键判覆盖:键 ±此 内有 AX commit/submit 即「覆盖」(IME commit 滞后)
GAP_KEYS     = 8        # 承载窗**内部**的短未覆盖段 < 此 = commit 时序空档(monkeytype chil/li 案),
                        # 并回承载;真 canvas 段(测试1正文 19 键)在其上。整窗全未覆盖(ok)不受此限。
BUCKET_KEYS  = 120      # B/C 分桶(用户裁定,按击键数):>120=长(C,走 OCR/canvas_merge);≤120=短(B,librime)
# 不设击键数下限(最大保留:短到「ok」也照判,噪声留给下游口3 滤)。cmd/ctrl/opt 快捷键
# (cmd+v 粘贴等)不是内容输入,在 load_keystrokes 用 modifiers&7=0 排除(shift 大写保留)。


def real_key(char, is_bs):
    """真内容击键:非退格、有字符、非纯控制符(回车/换行/Tab 不算内容)。"""
    return bool(char) and not is_bs and char not in ('\r', '\n', '\t')


def load_keystrokes(con, t0, t1):
    """按 app 分组的击键流。返回 {bundle: [(ts, char, is_bs), ...]}(已按 ts 升序)。"""
    rows = con.execute(
        "SELECT ts_ms, bundle_id, char, is_backspace FROM keystroke_log "
        "WHERE ts_ms >= :a AND ts_ms <= :b AND (modifiers & 7) = 0 ORDER BY ts_ms",
        {"a": t0, "b": t1}).fetchall()
    by_app = {}
    for ts, b, ch, bs in rows:
        by_app.setdefault(b, []).append((ts, ch, bs))
    return by_app


def load_ax_content(con, t0, t1):
    """edit_log 里 commit/submit 的真内容时间线。返回 {bundle: [(ts, n_chars), ...]}。
    只认 commit/submit(IME 上屏真手打);排除 paste/delete(canvas 的 ZWSP 占位、粘贴不算手打)。"""
    rows = con.execute(
        "SELECT bundle_id, edit_log FROM typing_events "
        "WHERE ended_at >= :a AND started_at <= :b",
        {"a": t0 - AX_PAD_MS, "b": t1 + AX_PAD_MS}).fetchall()
    by_app = {}
    for b, elog in rows:
        try: entries = json.loads(elog or '[]')
        except Exception: entries = []
        for e in entries:
            if e.get('kind') in ('commit', 'submit'):
                ts = e.get('ts'); n = len(strip_zw(e.get('text') or ''))
                if ts and n: by_app.setdefault(b, []).append((ts, n))
    return by_app


def segment_bursts(keys):
    """按 BURST_GAP_MS 把一个 app 的击键流切成突发窗。返回 [(t0, t1, [击键…]), ...]。"""
    bursts, cur = [], []
    for k in keys:
        if cur and k[0] - cur[-1][0] > BURST_GAP_MS:
            bursts.append(cur); cur = []
        cur.append(k)
    if cur: bursts.append(cur)
    return [(b[0][0], b[-1][0], b) for b in bursts]


def _near(sorted_ts, ts, pad):
    """sorted_ts(升序)里有没有点落在 [ts-pad, ts+pad]。"""
    i = bisect.bisect_left(sorted_ts, ts - pad)
    return i < len(sorted_ts) and sorted_ts[i] <= ts + pad


def analyze(con, t0, t1):
    """返回每个「同覆盖态子段」的承载判定(按时间排序)。
    不按整窗求和(会被「标题有AX + 正文无AX」混在一窗里平均掉),而是**逐键看局部**:
    这个键 ±AX_PAD_MS 内有没有 AX commit/submit → 覆盖/未覆盖;连续同态的真内容击键聚成子段。
    未覆盖子段 = 0 承载(走 canvas:OCR/librime);覆盖子段 = 承载(走 AX 路)。"""
    keys_by = load_keystrokes(con, t0, t1)
    ax_by = load_ax_content(con, t0, t1)
    out = []
    for bundle, keys in keys_by.items():
        ax_ts = sorted(ts for ts, _ in ax_by.get(bundle, []))
        for bt0, bt1, klist in segment_bursts(keys):
            runs = []   # [(covered, [(ts,ch)...]), ...]
            for ts, ch, bs in klist:
                if not real_key(ch, bs):
                    continue
                covered = _near(ax_ts, ts, AX_PAD_MS)
                if runs and runs[-1][0] == covered:
                    runs[-1][1].append((ts, ch))
                else:
                    runs.append((covered, [(ts, ch)]))
            # 承载窗内部的短未覆盖段 = commit 时序空档,并回承载(不是 canvas)。
            # 仅当窗内本就有覆盖段(AX 在这 app-会话里活跃)时才合并;整窗全未覆盖(standalone
            # canvas,如 ok)原样保留。
            if any(c for c, _ in runs):
                runs = [(True, seg) if (not c and len(seg) < GAP_KEYS) else (c, seg)
                        for c, seg in runs]
                merged = []
                for c, seg in runs:
                    if merged and merged[-1][0] == c:
                        merged[-1][1].extend(seg)
                    else:
                        merged.append((c, list(seg)))
                runs = merged
            for covered, seg in runs:
                out.append({
                    'bundle': bundle, 't0': seg[0][0], 't1': seg[-1][0],
                    'nkeys': len(seg), 'bearing': covered,
                    'typed': ''.join(ch for _, ch in seg),
                })
    out.sort(key=lambda r: r['t0'])
    return out


def _doc_url(con, bundle, t0, t1):
    """这段 0承载会话对应的文档 URL(仅供下游 canvas_merge 定位帧用,**不参与判别**——
    判别已由承载率完成,URL 不再是硬编码白名单门)。"""
    for (u,) in con.execute(
            "SELECT url FROM typing_events WHERE bundle_id=:b AND ended_at>=:a AND started_at<=:c "
            "AND url<>'' ORDER BY started_at", {"b": bundle, "a": t0, "c": t1}):
        if u:
            return u
    return ''


def canvas_spans(con, t0, t1):
    """承载率版判别(替代老 integrated_run.discriminate 的 URL白名单+整session+200键门槛):
    把逐段 0承载(canvas)按 bundle+时间相邻聚成会话,按击键数分 B/C 桶,附文档 URL。
    零硬编码:是不是 canvas 完全由承载率决定;URL 只在确定是 canvas 后用来定位 OCR 帧。"""
    spans = []
    for s in (r for r in analyze(con, t0, t1) if not r['bearing']):
        if spans and spans[-1]['bundle'] == s['bundle'] and s['t0'] - spans[-1]['t1'] < BURST_GAP_MS:
            sp = spans[-1]
            sp['t1'] = s['t1']; sp['nkeys'] += s['nkeys']; sp['typed'] += s['typed']
        else:
            spans.append(dict(s))
    # 噪声筛(承载率层唯一的内容筛):去掉「零真内容」会话——没有任何字母/汉字/数字
    # (单独的「，」、空键等,连残渣都算不上)。有实字的(ok/wis)留,价值判断交下游口3/质量门。
    spans = [sp for sp in spans if any(c.isalnum() for c in sp['typed'])]
    for sp in spans:
        sp['bucket'] = 'C' if sp['nkeys'] > BUCKET_KEYS else 'B'
        sp['url'] = _doc_url(con, sp['bundle'], sp['t0'], sp['t1'])
    return spans


def _hhmm(ts): return time.strftime('%H:%M:%S', time.gmtime(ts / 1000 - 4 * 3600))   # 本机 UTC-4
def _short(b): return b.rsplit('.', 1)[-1] if b else b


def main():
    con = sqlite3.connect(DB)
    if len(sys.argv) > 1 and len(sys.argv[1]) == 10 and sys.argv[1][4] == '-':
        d = sys.argv[1]
        (t0,) = con.execute("SELECT strftime('%s', :d) * 1000", {"d": d}).fetchone()
        (t1,) = con.execute("SELECT strftime('%s', :d, '+1 day') * 1000", {"d": d}).fetchone()
        label = f"UTC {d}"
    else:
        (tmax,) = con.execute("SELECT max(ts_ms) FROM keystroke_log").fetchone()
        t1 = tmax; t0 = tmax - 24 * 3600 * 1000
        label = "最近 24h"
    rows = analyze(con, t0, t1)
    print(f"承载率扫描 · {label} · {len(rows)} 个子段")
    print(f"{'起':>8} {'app':<16} {'键':>4}  路由          内容预览")
    print("-" * 78)
    for r in rows:
        verdict = "承载→AX路" if r['bearing'] else "0承载→canvas"
        print(f"{_hhmm(r['t0']):>8} {_short(r['bundle']):<16} {r['nkeys']:>4}  "
              f"{verdict:<12} {r['typed'][:40]}")
    n0 = sum(1 for r in rows if not r['bearing'])
    print("-" * 78)
    print(f"→AX路 {len(rows) - n0} · →canvas {n0}")

    spans = canvas_spans(con, t0, t1)
    print(f"\ncanvas 会话(替代老 discriminate) · {len(spans)} 个")
    print(f"{'起':>8} {'app':<16} {'键':>4} 桶  {'文档URL':<32} 内容预览")
    print("-" * 78)
    for sp in spans:
        bk = 'C长/OCR' if sp['bucket'] == 'C' else 'B短/librime'
        print(f"{_hhmm(sp['t0']):>8} {_short(sp['bundle']):<16} {sp['nkeys']:>4} "
              f"{bk:<11} {(sp['url'] or '-')[:32]:<32} {sp['typed'][:24]}")


if __name__ == '__main__':
    main()
