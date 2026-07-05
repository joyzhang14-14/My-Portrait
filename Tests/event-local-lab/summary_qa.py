#!/usr/bin/env python3
"""v7 后处理 pass:mega送检 → singleton带证据归属 → 摘要QA(grep接地+品味复核+重生成)。

吃 v6 产出(/tmp/v6_local_events.json),LLM 只做窄活(采样对判/二分/单事件重写),
结构不变量(覆盖337/dup0)全程保持。全部调用+裁决落 retain。总览§7 五个 LLM stage
中的四个在此(日型分类/mega送检/孤儿归属/品味复核);锚点仲裁=影子模式只记不动 idf
(champion-challenger:idf 重标必须先对 GOLD 重放)。

  python3 summary_qa.py        # → /tmp/v7_local_events.json(+Obsidian 备份)
⚠️ 跑本地 2507(占 GPU)。
"""
import collections
import json
import re
import sys
import time

sys.path.insert(0, "/Users/joyzhang14/Projects/My-Portrait/Tests/event-local-lab")
from cluster_skeleton import load_sessions, mine_anchors, compute_idf, wjaccard, _FILE, _CAMEL, _SNAKE, _ERR
import engine
import retain
from v4_local_cluster import (DAY, MODEL, load_times, gap_min, ev_span, det_title,
                              lint_ok, TITLE_BAD, split_bucket, exactly_once)

_HASH = re.compile(r"\b[0-9a-f]{7,10}\b")
SRC = "/tmp/v6_local_events.json"
SRC_BAK = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/v6_local_events-2026-06-07.json"


def _gen(stage, msgs, max_tokens, **meta):
    t0 = time.time()
    try:
        raw = engine._generate(msgs, max_tokens=max_tokens)
        obj = engine.parse_json(raw, "object")
        retain.log_call(DAY, stage, MODEL, msgs, raw, parsed=obj,
                        ms=int((time.time() - t0) * 1000), **meta)
        return obj
    except Exception as ex:                       # noqa: BLE001
        retain.log_call(DAY, stage, MODEL, msgs, f"ERR {ex}", ok=False,
                        ms=int((time.time() - t0) * 1000), **meta)
        return None


# ---------------- STAGE 1 日型分类(1 调用,informational gate)----------------

def classify_daytype(sess):
    step = max(1, len(sess) // 30)
    sample = "\n".join(f"- {s['app']}: {s['doing'][:80]}" for s in sess[::step][:30])
    obj = _gen("daytype", [{"role": "user", "content":
        f"""One day of a user's computer activity, 30 evenly-sampled sessions:
{sample}
Classify the day. Answer ONLY JSON:
{{"daytype":"coding|study|social|meeting|life|mixed","coding_fraction":0.0}}"""}], 48)
    dt = (obj or {}).get("daytype", "unknown")
    print(f"[daytype] {dt} (coding_fraction={((obj or {}).get('coding_fraction'))})")
    return dt


# ---------------- STAGE 2 mega 送检(size>12:采样对判,mixed→时间切分)----------------

def mega_review(events, by, idf, T):
    """size>12 送检:采样对判 mixed → 窄 LLM 重切(≤15卡 mini-bucket,复用 split_bucket;
    实测这些抽屉时间连续、内容混杂,时间刀切不动,内容刀才行)。余量成 remainder 保覆盖。"""
    out = []
    for e in events:
        n = len(e["session_ids"])
        if n <= 12:
            out.append(e)
            continue
        order = sorted(e["session_ids"], key=lambda k: T[k][0])
        idx = [0, n // 4, n // 2, 3 * n // 4, n - 1]
        pairs = [(order[idx[i]], order[idx[j]])
                 for i, j in ((0, 2), (0, 4), (1, 3), (2, 4), (0, 3), (1, 4))]
        diff = 0
        for a, b in pairs:
            obj = _gen("mega_review", [{"role": "user", "content":
                f"""Two work sessions from ONE candidate event. Same SPECIFIC task thread
(same bug/feature/topic)? Different features/topics even in the same app = no. Unsure = no.
A: {by[a]['doing'][:220]}
B: {by[b]['doing'][:220]}
Answer ONLY JSON: {{"same": true or false}}"""}], 16, event=e["title"][:40])
            if obj is not None and obj.get("same") is False:
                diff += 1
        if diff >= len(pairs) / 2:                # mixed → 窄 LLM 重切
            retain.log_verdict(DAY, e["title"][:60], "mega_resplit", size=n, diff_votes=diff)
            evs, un = split_bucket(e.get("bucket"), order, by, idf, T)
            if un:                                # 余量 remainder,保覆盖,走 QA 重生成
                evs.append({"title": det_title(un, by, idf),
                            "summary": "; ".join(by[k]["doing"][:80] for k in un[:3]),
                            "tags": [], "session_ids": un, "bucket": e.get("bucket"),
                            "dirty": True, "misc": True})
            if len(evs) <= 1:                     # 重切仍一个 → 尊重,保留原事件
                retain.log_verdict(DAY, e["title"][:60], "mega_resplit_single", size=n)
                out.append(e)
            else:
                print(f"[mega] «{e['title'][:44]}»({n}) mixed {diff}/{len(pairs)} → 重切 {len(evs)} 个")
                out.extend(evs)
        else:
            retain.log_verdict(DAY, e["title"][:60], "mega_coherent", size=n, diff_votes=diff)
            out.append(e)
    return out


# ---------------- STAGE 3 singleton 带证据归属(K=3,≥2/3 才并)----------------

def singleton_attach(events, by, idf, T):
    keep = []
    for e in events:
        if not (e.get("misc") and len(e["session_ids"]) == 1):
            keep.append(e)
            continue
        k = e["session_ids"][0]
        cands = []
        for o in events:
            if o is e or not o["session_ids"]:
                continue
            g = gap_min(T[k], ev_span(o, T))
            if g > 60.0:
                continue
            sc = max((wjaccard(by[k]["anchors"], by[m]["anchors"], idf)
                      for m in o["session_ids"]), default=0.0)
            cands.append((sc, -g, o))
        if not cands:
            keep.append(e)
            continue
        _, negg, best = max(cands, key=lambda x: (x[0], x[1]))
        ms = sorted(best["session_ids"], key=lambda m: gap_min(T[k], T[m]))[:2]
        ev_doing = "\n".join(f"- {by[m]['doing'][:180]}" for m in ms)
        yes = 0
        for _ in range(3):
            obj = _gen("orphan_binary", [{"role": "user", "content":
                f"""Does session S belong to event E (same specific task thread)? Unsure = no.
S ({by[k]['app']}, {-negg:.0f}min away): {by[k]['doing'][:220]}
E «{best['title']}»: {best['summary'][:180]}
E member samples:
{ev_doing}
Answer ONLY JSON: {{"belongs": true or false}}"""}], 16, sid=k)
            if obj is not None and obj.get("belongs") is True:
                yes += 1
        if yes >= 2:
            best["session_ids"].append(k)
            best["dirty"] = True
            retain.log_verdict(DAY, f"s{k}", "singleton_llm_attach", votes=yes,
                               event=best["title"][:50])
            print(f"[singleton] s{k} {yes}/3 → 并入 «{best['title'][:44]}»")
        else:
            retain.log_verdict(DAY, f"s{k}", "singleton_llm_keep", votes=yes)
            keep.append(e)
    return keep


# ---------------- STAGE 4 摘要 QA:grep 接地 + 品味复核 + 重生成 ----------------

def harvest(text):
    toks = set()
    for rx in (_FILE, _CAMEL, _SNAKE, _ERR, _HASH):
        for m in rx.findall(text):
            if len(m) > 2:
                toks.add(m.lower())
    return toks


def violations(e, by):
    corpus = " ".join(by[k]["doing"] + " " + " ".join(by[k]["kw"])
                      for k in e["session_ids"]).lower()
    ungrounded = sorted(t for t in harvest(e["summary"]) if t not in corpus)
    residue = [b for b in TITLE_BAD if b in (e["summary"] + " " + e["title"]).lower()]
    return ungrounded, residue


REGEN = """Rewrite the title and summary of ONE event from its member session digests.

Member sessions (time order):
{doings}

RULES:
- "title": <=60 chars, verb-first, what the user was DOING. Never terminal flags, never "App — Window".
- "summary": 2-5 sentences, third person. Cite ONLY concrete anchors that literally appear in the
  digests (file/function names, commit hashes, numbers, error strings). Invent nothing.
- MUST keep person names, quoted user text, and social/personal content if present in the digests.
  Keep names in their ORIGINAL script — NEVER romanize Chinese names (何成 stays 何成, not He Cheng).
- If there are 8+ member sessions, make sure EVERY distinct member topic is covered by at least
  one clause — do not summarize only the dominant thread.
- NEVER mention: --dangerously-skip-permissions, caffeinate, sourcekit-lsp (terminal noise).
- "tags": 3-6 lowercase keywords.
Answer ONLY: {{"title":"...","summary":"...","tags":[...]}}"""


def qa_pass(events, by, idf):
    stats = collections.Counter()
    for e in events:
        ung, res = violations(e, by)
        need = bool(e.get("dirty") or e.get("misc") or ung or res)
        stats["viol_before"] += len(ung) + len(res)
        if not need:
            continue
        stats["regen"] += 1
        doings = "\n".join(f"- [{k}] {by[k]['doing'][:350]}" for k in e["session_ids"][:15])
        best, best_v = None, 10 ** 9
        for attempt in range(2):
            obj = _gen("summary_qa", [{"role": "user",
                       "content": REGEN.format(doings=doings)}], 500,
                       event=e["title"][:40], attempt=attempt)
            if not obj or not obj.get("title") or not obj.get("summary"):
                continue
            cand = {"title": str(obj["title"])[:80], "summary": str(obj["summary"]),
                    "tags": obj.get("tags") or e["tags"]}
            u2, r2 = violations({**e, **cand}, by)
            v = len(u2) + len(r2) + (0 if lint_ok(cand["title"]) else 5)
            if v < best_v:
                best, best_v = cand, v
            if v == 0:
                break
        if best:
            e.update(best)
            e.pop("dirty", None)
            u3, r3 = violations(e, by)
            stats["viol_after"] += len(u3) + len(r3)
            if not lint_ok(e["title"]):
                e["title"] = det_title(e["session_ids"], by, idf)
        else:
            stats["regen_failed"] += 1
            retain.log_verdict(DAY, e["title"][:60], "summary_regen_failed")
    return stats


# ---------------- STAGE 5 锚点仲裁(影子模式:只记不动 idf)----------------

def anchor_arbiter_shadow(sess, idf):
    df = collections.Counter()
    for s in sess:
        for a in s["anchors"]:
            df[a] += 1
    suspects = [a for a, c in df.most_common(40) if c >= 8]
    env = []
    for a in suspects[:30]:
        ctx = [s["doing"][:100] for s in sess if a in s["anchors"]][:3]
        obj = _gen("anchor_arbiter", [{"role": "user", "content":
            f"""Anchor token: "{a}" (appears in {df[a]} sessions of one day).
Sample contexts:
{chr(10).join('- ' + c for c in ctx)}
Is it a TASK anchor (identifies one specific task/project thread) or ENVIRONMENT noise
(tool/app/boilerplate that appears across unrelated tasks)? Answer ONLY JSON:
{{"kind":"task" or "environment"}}"""}], 24, anchor=a)
        if obj and obj.get("kind") == "environment":
            env.append(a)
            retain.log_verdict(DAY, a, "anchor_env_shadow", df=df[a])
    print(f"[arbiter/shadow] 判环境词 {len(env)}/{len(suspects[:30])}: {env[:12]}")
    return env


def main():
    try:
        events = json.load(open(SRC))["events"]
    except FileNotFoundError:
        events = json.load(open(SRC_BAK))["events"]
    sess = load_sessions()
    for s in sess:
        s["anchors"] = mine_anchors(s)
    idf, _ = compute_idf(sess)
    by = {s["key"]: s for s in sess}
    T = load_times()
    print(f"[v7] 载入 {len(events)} 事件 · load {MODEL} ...")
    engine.load(MODEL)
    t0 = time.time()
    classify_daytype(sess)
    events = mega_review(events, by, idf, T)
    events = exactly_once(events, by, idf, llm_escalate=True)  # 重切输出同样双分配,必须再过
    events = singleton_attach(events, by, idf, T)
    stats = qa_pass(events, by, idf)
    anchor_arbiter_shadow(sess, idf)
    import labdb
    from session_context import enrich_events   # 确定性附加 app/who/where + app/人名进 tags
    enrich_events(events, labdb.connect(), DAY)
    allc = [x for e in events for x in e["session_ids"]]
    assert len(allc) == len(set(allc)), "dup != 0"
    assert len(set(allc)) == len(sess), f"覆盖 {len(set(allc))}/{len(sess)}"
    json.dump({"model": MODEL, "events": events},
              open("/tmp/v7_local_events.json", "w"), ensure_ascii=False, indent=2)
    import shutil
    shutil.copy("/tmp/v7_local_events.json",
                "/Users/joyzhang14/Desktop/Obsidian/event pipeline local/v7_local_events-2026-06-07.json")
    print(f"[done] {len(events)} events · 覆盖 {len(set(allc))}/{len(sess)} · dup 0 · "
          f"重生成 {stats['regen']}(违规 {stats['viol_before']}→{stats['viol_after']},"
          f"失败 {stats['regen_failed']}) · {time.time()-t0:.0f}s -> /tmp/v7_local_events.json")


if __name__ == "__main__":
    main()
