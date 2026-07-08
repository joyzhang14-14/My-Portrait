#!/usr/bin/env python3
"""本地事件聚类 v6:时间感知分桶 + 2507 逐桶切分 + exactly-once + rescue(覆盖 by construction)。

v2→v6(路线图 T0/T1;gold/取证见 fixtures/2026-06-07/GOLD.md):
  分桶   aff = 0.85*(0.7cos+0.3wjaccard) + 0.15*exp(-gap分钟/120)   ← F5 时间加法项(全表最硬)
  护栏   skipped 不算 covered / 缺字段确定性修补不丢成员 / 标题黑名单 / 整桶失败 retry→时间切分
  去重   exactly-once 三层裁决:壳→锚点门(mean wjaccard≥0.06 且比率≥1.1)→末现  ← F2 gold 38/42
  覆盖   orphan 池 rescue:同桶attach(60min+wj≥0.12)→跨桶(≥0.15)→5min同app→singleton ← F1
  留存   retain.py 全调用+确定性裁决落 JSONL(R8,数据飞轮)

⚠️ 阈值为 6-07(冻结 idf)标定;换日先用稳健档(EO_RATIO=1.5);idf 重标后必须对 GOLD.md 重放。

  python3 v4_local_cluster.py --dry   # 只跑确定性分桶+实锤C团块自检(不占 GPU)
  python3 v4_local_cluster.py         # 全链 → /tmp/v6_local_events.json(+Obsidian 备份)
⚠️ 全链跑本地 2507(占 GPU)。
"""
import collections
import json
import math
import re
import sys
import time

import numpy as np

sys.path.insert(0, "/Users/joyzhang14/Projects/My-Portrait/Tests/event-local-lab")
from cluster_skeleton import load_sessions, mine_anchors, compute_idf, wjaccard, complete_linkage
import engine
import retain

DAY = "2026-06-07"
# 16GB硬约束(7-08选型):2507-4bit实测17.2GB出局;9B全链A/B F1 0.388≈2507的
# 0.397(体积1/3,24min跑完),verbatim略逊(hash 2 vs 7)靠REGEN prompt调回。
MODEL = "mlx-community/Qwen3.5-9B-MLX-4bit"
LAB = "/Users/joyzhang14/Projects/My-Portrait/Tests/event-local-lab"
EMB = f"{LAB}/fixtures/{DAY}/v4_emb.npy"
TIMES = f"{LAB}/fixtures/{DAY}/sessions_time.json"

ALPHA, TAU, CAP = 0.7, 0.30, 30                 # 底层亲和(0.7cos+0.3wj)与 complete-linkage 不动
BASE_W, TIME_W, T_HALF = 0.85, 0.15, 120.0      # F5 时间加法项(宽平台 60-180min × 0.15-0.25)
EO_MIN, EO_RATIO = 0.06, 1.1                    # exactly-once 锚点门(6-07 调优档;换日稳健档 1.5)
RS_GATE_MIN, RS_IN, RS_X, RS_NEAR = 60.0, 0.12, 0.15, 5.0  # rescue 时间门/同桶/跨桶/近邻(分钟)
GAP_SPLIT = 30.0                                # 整桶失败兜底的时间断裂切分(分钟)
TITLE_BAD = ("skip-permissions", "caffeinate", "sourcekit-lsp")  # 标题黑名单(day-0 种子)

PROMPT = """These activity sessions form ONE related cluster (same sub-system/topic area).
Split them into semantic EVENTS.

These sessions are ALREADY one related cluster — usually they are ONE or just a FEW events.
PREFER FEWER events. Create a separate event ONLY for a CLEARLY DIFFERENT specific task.
MERGE near-identical sessions (same bug/feature worked on across several sessions) into ONE
event — do NOT emit near-duplicate events. Only split off a genuinely distinct small activity
(a brief chat, a quick check) if it truly does not belong.

Sessions (id · app — activity digest), in time order:
{cards}

HARD RULES:
- EVERY id {ids} appears EXACTLY ONCE: in some event's "session_ids" OR in "skipped".
- "title": <=60 chars, what the user was DOING (never "App — Window").
- "summary": 2-4 sentences, third person, cite the concrete technical anchors in the digests
  (file/function names, error strings, numbers, people). Invent nothing.
- "tags": 3-6 lowercase keywords.
Answer ONLY: {{"events":[{{"title":"...","summary":"...","tags":[...],"session_ids":[...]}}],"skipped":[...]}}"""


# ---------------- 确定性基础 ----------------

def load_times():
    t = json.load(open(TIMES))
    return {int(k): (v["start_ms"], v["end_ms"]) for k, v in t.items()}


def gap_min(a, b):
    """两时间区间的分钟距离(重叠=0)。"""
    if a[0] <= b[1] and b[0] <= a[1]:
        return 0.0
    return (max(a[0], b[0]) - min(a[1], b[1])) / 60000.0


def ev_span(e, T):
    ss = [T[k] for k in e["session_ids"]]
    return (min(s[0] for s in ss), max(s[1] for s in ss))


def build_buckets(sess, idf, T):
    E = np.load(EMB)
    E = E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-9)
    N = len(sess)
    A = [s["anchors"] for s in sess]
    iv = [T[s["key"]] for s in sess]
    aff = [[0.0] * N for _ in range(N)]
    for i in range(N):
        for j in range(i + 1, N):
            base = ALPHA * float((E[i] * E[j]).sum()) + (1 - ALPHA) * wjaccard(A[i], A[j], idf)
            v = BASE_W * base + TIME_W * math.exp(-gap_min(iv[i], iv[j]) / T_HALF)
            aff[i][j] = aff[j][i] = v
    buckets = complete_linkage(aff, TAU, CAP)
    key = [s["key"] for s in sess]
    return [sorted(key[i] for i in b) for b in buckets]


def det_title(sids, by, idf):
    """G4/G5:确定性标题 = 多数app + top-2 高IDF锚点。"""
    anch = {}
    for k in sids:
        for a in by[k]["anchors"]:
            anch[a] = max(anch.get(a, 0.0), idf.get(a, 0.0))
    top = [a for a, _ in sorted(anch.items(), key=lambda x: -x[1])[:2]]
    app = collections.Counter(by[k]["app"] for k in sids).most_common(1)[0][0]
    return f"{app}: {', '.join(top) if top else 'activity'}"[:60]


def lint_ok(title):
    t = title.lower()
    return not any(b in t for b in TITLE_BAD)


# ---------------- 桶内切分(唯一 LLM 步)+ 护栏 ----------------

def split_bucket(bi, bk, by, idf, T):
    """返回 (events, 未分配ids)。G2 skipped不算covered;G4字段修补;失败retry→时间切分兜底。"""
    cards = "\n".join(f"[{k}] {by[k]['app']} - {by[k]['doing']}" for k in bk)
    msgs = [{"role": "system", "content": "You output ONE JSON object only."},
            {"role": "user", "content": PROMPT.format(cards=cards, ids=bk)}]
    bset = set(bk)
    obj = None
    for attempt in range(2):                     # 整桶失败先 retry 一次
        t0 = time.time()
        try:
            raw = engine._generate(msgs, max_tokens=2200)
            obj = engine.parse_json(raw, "object")
            retain.log_call(DAY, "bucket_split", MODEL, msgs, raw, parsed=obj,
                            ms=int((time.time() - t0) * 1000), bucket=bi, attempt=attempt)
            break
        except Exception as ex:                  # noqa: BLE001 实验线粗放兜
            retain.log_call(DAY, "bucket_split", MODEL, msgs, f"ERR {ex}", ok=False,
                            ms=int((time.time() - t0) * 1000), bucket=bi, attempt=attempt)
            retain.log_verdict(DAY, f"bucket{bi}", "bucket_retry", attempt=attempt, err=str(ex)[:200])
            msgs = msgs + [{"role": "user",
                            "content": "Output ONLY the JSON. No prose, no markdown fence."}]
    evs, pending = [], []                        # pending=有标题但 sids 解析失败的事件
    if obj:
        for e in (obj.get("events") or []):
            sids = []
            for x in e.get("session_ids", []):   # 桶外/非数字过滤 + 同事件内去重
                if str(x).isdigit() and int(x) in bset and int(x) not in sids:
                    sids.append(int(x))
            if not sids:
                if (e.get("title") or "").strip():
                    pending.append(e)            # GOLD_v2 bucket18 塌缩教训:模型切对了,别丢
                continue
            title = (e.get("title") or "").strip()
            if not title or not lint_ok(title):
                if title:
                    retain.log_verdict(DAY, title[:60], "rejected_by_lint", bucket=bi)
                title = det_title(sids, by, idf)
            summary = (e.get("summary") or "").strip() \
                or "; ".join(by[k]["doing"][:80] for k in sids[:3])
            evs.append({"title": title[:80], "summary": summary,
                        "tags": e.get("tags") or [], "session_ids": sids, "bucket": bi})
    if pending:                                  # sids 解析失败 → 标题实词对未覆盖成员模糊重配
        covered0 = {x for e in evs for x in e["session_ids"]}
        claims = {}
        for k in bk:
            if k in covered0:
                continue
            scored = [(_title_hooks((p.get("title") or ""), by[k]["doing"]), pi)
                      for pi, p in enumerate(pending)]
            h, pi = max(scored)
            if h >= 1:
                claims.setdefault(pi, []).append(k)
        for pi, sids in claims.items():
            p = pending[pi]
            title = p["title"].strip()
            if not lint_ok(title):
                title = det_title(sids, by, idf)
            evs.append({"title": title[:80],
                        "summary": (p.get("summary") or "").strip()
                        or "; ".join(by[k]["doing"][:80] for k in sids[:3]),
                        "tags": p.get("tags") or [], "session_ids": sids, "bucket": bi,
                        "dirty": True})          # 模糊重配的成员集,摘要待刷新
            retain.log_verdict(DAY, title[:60], "pending_title_reassign", n=len(sids))
    if not evs:                                  # retry 仍失败 → 确定性时间断裂切分
        retain.log_verdict(DAY, f"bucket{bi}", "bucket_fallback_split", size=len(bk))
        order = sorted(bk, key=lambda k: T[k][0])
        seg = [[order[0]]]
        for k in order[1:]:
            if gap_min(T[seg[-1][-1]], T[k]) > GAP_SPLIT:
                seg.append([k])
            else:
                seg[-1].append(k)
        for sids in seg:
            evs.append({"title": det_title(sids, by, idf),
                        "summary": "; ".join(by[k]["doing"][:80] for k in sids[:3]),
                        "tags": [], "session_ids": sids, "bucket": bi, "misc": True})
    covered = {x for e in evs for x in e["session_ids"]}   # G2/G3:只按最终保留事件算
    return evs, [k for k in bk if k not in covered]


# ---------------- exactly-once(F2 gold 38/42;GOLD_v2 加不对称证据否决)----------------

_TITLE_STOP = {"user", "with", "from", "that", "this", "into", "using", "implement",
               "implementing", "improve", "improved", "update", "updated", "manage",
               "managing", "multiple", "various", "settings", "portrait", "myportrait",
               "system", "session", "sessions", "work", "working", "macos", "terminal"}


def _title_hooks(title, doing):
    """标题实词在 doing 的逐字命中数。GOLD_v2:36 条裁反全部=loser 命中而 winner 零钩子。
    中文按二元组匹配(整段连读串几乎不可能逐字命中)。"""
    t = title.lower()
    words = [w for w in re.findall(r"[a-z]{4,}", t) if w not in _TITLE_STOP]
    for run in re.findall(r"[一-鿿]{2,}", t):
        words += [run[i:i + 2] for i in range(len(run) - 1)]
    d = doing.lower()
    return sum(1 for w in set(words) if w in d)


def _eo_llm_vote(k, A, B, by):
    """模糊区分歧升级(R12):K=3 带证据二分,多数票;平票回 B(末现)。"""
    def side(e):
        ms = [m for m in e["session_ids"] if m != k][:2]
        return f"«{e['title']}»\n" + "\n".join(f"  - {by[m]['doing'][:150]}" for m in ms)
    q = (f"Session S was claimed by BOTH events. Which one does it belong to "
         f"(same specific task thread)?\nS: {by[k]['doing'][:260]}\n\n"
         f"Event A: {side(A)}\n\nEvent B: {side(B)}\n\n"
         f'Answer ONLY JSON: {{"belongs":"A" or "B"}}')
    votes = 0
    for _ in range(3):
        try:
            r = engine.parse_json(engine._generate(
                [{"role": "user", "content": q}], max_tokens=16), "object").get("belongs")
            votes += 1 if r == "A" else 0
        except Exception:
            pass
    return votes >= 2


def exactly_once(events, by, idf, llm_escalate=False):
    """五层裁决:壳(纯子集,多成员壳赢/单例壳死)→不对称证据否决(GOLD_v2 标定 R5:
    hl≥hw+2 或 hl>0∧hw=0)→锚点决定门→模糊区 LLM 升级(K=3,可选)→末现。空壳消亡。"""
    claims = {}
    for ei, e in enumerate(events):
        for k in e["session_ids"]:
            claims.setdefault(k, []).append(ei)
    for k, eis in claims.items():
        while len(eis) > 1:
            a_i, b_i = eis[0], eis[1]
            A, B = events[a_i], events[b_i]
            xa = [m for m in A["session_ids"] if m != k and m not in B["session_ids"]]
            xb = [m for m in B["session_ids"] if m != k and m not in A["session_ids"]]
            ha = _title_hooks(A["title"], by[k]["doing"])
            hb = _title_hooks(B["title"], by[k]["doing"])
            if not xa and xb:                     # A 是 B 的纯子集壳
                win = a_i if len(A["session_ids"]) > 1 else b_i
            elif not xb and xa:
                win = b_i if len(B["session_ids"]) > 1 else a_i
            elif not xa and not xb:
                win = b_i                         # 双壳:末现
            elif hb >= ha + 2 or (hb > 0 and ha == 0):   # 不对称证据否决(R5)
                win = b_i
            elif ha >= hb + 2 or (ha > 0 and hb == 0):
                win = a_i
            else:
                sa = sum(wjaccard(by[k]["anchors"], by[m]["anchors"], idf) for m in xa) / len(xa)
                sb = sum(wjaccard(by[k]["anchors"], by[m]["anchors"], idf) for m in xb) / len(xb)
                if max(sa, sb) >= EO_MIN and sa != sb and \
                        (min(sa, sb) == 0 or max(sa, sb) / min(sa, sb) >= EO_RATIO):
                    win = a_i if sa > sb else b_i
                elif llm_escalate:                # 模糊区:字面/锚点都不判 → K=3 带证据
                    win = a_i if _eo_llm_vote(k, A, B, by) else b_i
                    retain.log_verdict(DAY, f"s{k}", "eo_llm_escalate",
                                       winner=events[win]["title"][:50])
                else:
                    win = b_i                     # 末现后备(挂模型版本的软信号,R11 后退役)
            lose = a_i if win == b_i else b_i
            events[lose]["session_ids"].remove(k)
            events[lose]["dirty"] = True          # 摘要仍描述被移走成员,待重生成(T2)
            retain.log_verdict(DAY, f"s{k}", "overruled_by_exactly_once",
                               winner=events[win]["title"][:50],
                               loser=events[lose]["title"][:50])
            eis = [ei for ei in eis if k in events[ei]["session_ids"]]
    return [e for e in events if e["session_ids"]]


# ---------------- rescue(F1,覆盖 by construction)----------------

def rescue(orphans, events, by, idf, T):
    """orphan=(sid,bucket)。attach 只加成员并标 dirty(摘要待刷新),绝不改文案。"""
    new_events = []
    for k, bi in sorted(orphans, key=lambda x: T[x[0]][0]):
        cands = []
        for e in events + new_events:
            g = gap_min(T[k], ev_span(e, T))
            if g > RS_GATE_MIN:
                continue
            sc = max((wjaccard(by[k]["anchors"], by[m]["anchors"], idf)
                      for m in e["session_ids"]), default=0.0)
            cands.append((e, g, sc))
        pick, kind = None, None
        same = [(e, g, sc) for e, g, sc in cands if e.get("bucket") == bi]
        if same:
            e, g, sc = max(same, key=lambda x: x[2])
            if sc >= RS_IN:
                pick, kind = e, "attach_in_bucket"
        if pick is None and cands:
            e, g, sc = max(cands, key=lambda x: x[2])
            if sc >= RS_X:
                pick, kind = e, "attach_cross_bucket"
        if pick is None:
            near = [(e, g, sc) for e, g, sc in cands if g <= RS_NEAR and collections.Counter(
                by[m]["app"] for m in e["session_ids"]).most_common(1)[0][0] == by[k]["app"]]
            if near:
                pick, kind = min(near, key=lambda x: x[1])[0], "attach_near_app"
        if pick is not None:
            pick["session_ids"].append(k)
            pick["dirty"] = True                  # 被扩事件标脏,摘要待刷新(T2 合并重生成同机制)
            retain.log_verdict(DAY, f"s{k}", "rescued_attach", tier=kind, event=pick["title"][:50])
        else:                                     # singleton 兜底(misc,呈现层可折叠)
            clause = re.split(r"[.;。;]", by[k]["doing"])[0][:60]
            new_events.append({"title": f"{by[k]['app']}: {clause}",
                               "summary": by[k]["doing"][:200], "tags": [],
                               "session_ids": [k], "bucket": bi, "misc": True})
            retain.log_verdict(DAY, f"s{k}", "rescued_singleton")
    return events + new_events


# ---------------- 主流程 ----------------

def main(dry=False):
    sess = load_sessions()
    for s in sess:
        s["anchors"] = mine_anchors(s)
    idf, _ = compute_idf(sess)
    by = {s["key"]: s for s in sess}
    T = load_times()
    buckets = build_buckets(sess, idf, T)
    print(f"[buckets] {len(buckets)} 桶(base a{ALPHA}/t{TAU} + time w{TIME_W}/T{T_HALF:.0f}min)")
    if dry:                                       # 实锤C六团块自检(GOLD.md §3)
        BLOBS = [[212, 239, 277], [388, 397, 411, 416, 422, 431], [516],
                 [937, 966, 977, 988, 1000, 1014, 1018], [1079, 1085, 1091],
                 [1189, 1190, 1193, 1198]]
        k2b = {k: bi for bi, bk in enumerate(buckets) for k in bk}
        ok = 0
        for i, blob in enumerate(BLOBS):
            dist = collections.Counter(k2b[k] for k in blob)
            pure = dist.most_common(1)[0][1] / len(blob)
            ok += pure >= 0.9
            print(f"  blob{i+1} {len(blob)}段 → 桶{dict(dist)} 纯度{pure:.2f}")
        print(f"[dry] blob 对齐 {ok}/6(目标≥5;各 blob 应各自集中,团块间应分开)")
        return
    print(f"[load] {MODEL} ...")
    engine.load(MODEL)
    events, orphans, t0 = [], [], time.time()
    for bi, bk in enumerate(buckets):
        evs, un = split_bucket(bi, bk, by, idf, T)
        events.extend(evs)
        orphans.extend((k, bi) for k in un)
        if bi % 5 == 0:
            print(f"  bucket{bi}/{len(buckets)} · {len(events)} events · "
                  f"orphans {len(orphans)} · {time.time()-t0:.0f}s")
    n0 = len(events)
    events = exactly_once(events, by, idf, llm_escalate=True)
    events = rescue(orphans, events, by, idf, T)
    allc = [x for e in events for x in e["session_ids"]]
    assert len(allc) == len(set(allc)), "dup != 0"
    assert set(allc) == {s["key"] for s in sess}, f"覆盖 {len(set(allc))}/{len(sess)}"
    json.dump({"model": MODEL, "n_buckets": len(buckets), "events": events},
              open("/tmp/v6_local_events.json", "w"), ensure_ascii=False, indent=2)
    import shutil
    shutil.copy("/tmp/v6_local_events.json",
                "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/v6_local_events-2026-06-07.json")
    print(f"[done] {len(events)} events(切分{n0}→去重→rescue) · 覆盖 {len(set(allc))}/{len(sess)} · "
          f"dup 0 · {time.time()-t0:.0f}s -> /tmp/v6_local_events.json (+Obsidian备份)")


if __name__ == "__main__":
    main(dry="--dry" in sys.argv)
