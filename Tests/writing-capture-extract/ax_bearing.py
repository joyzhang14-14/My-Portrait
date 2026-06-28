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


if __name__ == '__main__':
    main()
