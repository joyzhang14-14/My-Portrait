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

# ---- T0 verbatim 硬校验:引语/commit hash 必须 exact-match 上游,否则剥离(宁剥不留错) ----
_QUOTE_RX = re.compile(r"[「‘“']([^」’”']{2,40})[」’”']")


def strip_unverifiable(e, by):
    corpus = " ".join(by[k]["doing"] + " " + " ".join(by[k]["kw"])
                      for k in e["session_ids"]).lower()
    s = e["summary"]; stripped = []
    for h in set(_HASH.findall(s.lower())):
        if h not in corpus:
            s = re.sub(re.escape(h), "", s, flags=re.I); stripped.append(f"hash:{h}")
    for m in list(_QUOTE_RX.finditer(s)):
        if m.group(1).lower() not in corpus:
            s = s.replace(m.group(0), ""); stripped.append(f"quote:{m.group(1)[:20]}")
    # 审计修复:纯数字被当 commit hash 写进摘要(实锤'1054'=session id)。
    # hash 语境里的 3-6 位十进制一律剥(真 hash 是 7+ 位含字母 hex,不会误伤)。
    for m in list(re.finditer(r"hash(?:es)?[^.\n]{0,24}?\b(\d{3,6})\b", s, re.I)):
        s = s.replace(m.group(1), ""); stripped.append(f"fakehash:{m.group(1)}")
    # 中文化翻译失真防线(实锤'$6m'→'600万美元'):金额的数字部分必须逐字在
    # 上游出现(前后非数字防 1600 误配),否则整个金额表述剥掉。宁剥不留错。
    for m in list(re.finditer(
            r"(?:[$¥€]\s?\d+(?:\.\d+)?\s?[mkMK万]?|\d+(?:\.\d+)?\s*(?:万|百万|亿)?\s*(?:美元|美金|人民币|元|刀))",
            s)):
        tok = m.group(0)
        num = re.search(r"\d+(?:\.\d+)?", tok).group(0)
        if not re.search(rf"(?<![\d.]){re.escape(num)}(?![\d])", corpus):
            s = s.replace(tok, ""); stripped.append(f"money:{tok[:15]}")
    if stripped:
        e["summary"] = re.sub(r"\s{2,}", " ", s).strip()
        retain.log_verdict(DAY, e["title"][:60], "verbatim_stripped", items=stripped[:8])
    return len(stripped)


# ---- T0 全局 merge pass v9:纯确定性平均连接凝聚(零 LLM) ----
# 演进史(gold 对照,全部零 GPU 留存重放实验,7-07):
#  v8a LLM自由提案+单链union-find:127个≥2票对仅19真(15%),链成56成员嵌合体,
#      B³ P 0.589→0.310 负优化;
#  v8b 确定性kNN提案+LLM二分3/3全票验证:temp0.2下三票完美相关(K=3投票失效,
#      142拒里141个首票no),通过71对里52错(误收73%),F1 0.277 更差;拒掉的也有
#      21%是好对=LLM的yes/no对"同项目不同任务线vs同任务线"零判别力。
#  → 结论:成对merge判断超出2507能力,是T2 merge-judge adapter的活(213对gold
#    标注判例已在留存,kind=merge_verified/merge_rejected,即其训练评测集)。
#  v9 纯确定性:事件级 aff=0.7*质心cos+0.3*锚点wj,平均连接凝聚 τ0.55,合并后
#     规模cap60(gold最大事件54;无cap时τ0.55会糊出168成员巨簇,F1 0.441是R
#     通胀假象),chat/dev异质否决。6-07:88→52事件,F1 0.395(现产线0.326,
#     merge前0.332),嵌合体0,最大簇59。神谕上限0.547,差距在88分区纯度+merge
#     判断,均为T2蒸馏目标。
MERGE_ALPHA, MERGE_TAU, MERGE_CAP = 0.7, 0.55, 60
# v10(7-09审计四修其二):项目硬边界+单帧碎片吸收。
# 审计实锤:3个purity 0.27巨型抽屉唯一共性=同Terminal界面,跨project糊死;
# 65事件里34个n=1单帧(gold把它们收进复合事件)。项目标签=window首段归一化
# (My-Portrait 198/My-Meeting 104,数据驱动非硬编码),两侧都有标签且不同→禁合;
# 吸收=n=1事件并入时间最近的同app同项目事件(gap≤45min),宁不吸不误吸。
ABSORB_GAP = 45.0


def _proj_labels(by):
    """session→项目标签:window 首段(' — '前)归一化小写字母数字。空=无信号。"""
    import labdb
    con = labdb.connect()
    part_win = dict(con.execute(
        "SELECT id, COALESCE(window,'') FROM raw_sessions WHERE day = :d", {"d": DAY}))
    lab = {}
    for k, s in by.items():
        c = collections.Counter()
        for p in s["parts"]:
            seg = part_win.get(p, "").split(" — ")[0]
            seg = re.sub(r"[^a-z0-9]", "", seg.lower())
            if seg:
                c[seg] += 1
        lab[k] = c.most_common(1)[0][0] if c else ""
    return lab


def _ev_proj(e, lab):
    """事件项目标签:成员众数,支持数≥3 才算有标签(弱信号不投票)。"""
    c = collections.Counter(lab.get(k, "") for k in e["session_ids"])
    c.pop("", None)
    top = c.most_common(1)
    return top[0][0] if top and top[0][1] >= 3 else ""


_CHAT_APPS = {"微信", "wechat", "discord", "messages", "信息", "mail", "telegram"}


def eject_chat_from_dev(events, by):
    """成员级 chat/dev 贯彻(v10):dev 主导事件里的 chat-app 会话弹出成单帧,
    交给 absorb 归回社交事件。实锤:s432(微信,gold G26)被埋进 62 人 Terminal
    事件,转账 120.56 从摘要蒸发。宁分不误合。"""
    ejected = []
    for e in events:
        apps = collections.Counter(by[k]["app"].lower() for k in e["session_ids"] if k in by)
        top = apps.most_common(1)
        if not top or top[0][0] in _CHAT_APPS:
            continue                              # chat 主导事件不动
        chat_ks = [k for k in e["session_ids"] if by[k]["app"].lower() in _CHAT_APPS]
        if not chat_ks or len(chat_ks) == len(e["session_ids"]):
            continue
        for k in chat_ks:
            e["session_ids"].remove(k)
            e["dirty"] = True
            ejected.append({"title": by[k]["doing"][:60], "summary": by[k]["doing"][:300],
                            "tags": [], "session_ids": [k], "dirty": True})
            retain.log_verdict(DAY, f"s{k}", "chat_ejected_from_dev",
                               host=e["title"][:50])
    if ejected:
        print(f"[eject] chat会话弹出dev事件 {len(ejected)} 个")
    return [e for e in events if e["session_ids"]] + ejected


def absorb_singletons(events, by, T, lab):
    """审计修复:n=1 单帧事件吸收进时间最近的同app同项目事件(两轮,防链式漂移)。"""
    _CHAT = {"微信", "wechat", "discord", "messages", "信息", "mail", "telegram"}
    def app_of(e):
        return collections.Counter(
            by[k]["app"] for k in e["session_ids"] if k in by).most_common(1)[0][0]
    absorbed = 0
    for _ in range(2):
        singles = [e for e in events if len(e["session_ids"]) == 1]
        for e in singles:
            if len(e["session_ids"]) != 1:
                continue                      # 已被别人吸进成员(当了宿主),不再按单帧处理
            k = e["session_ids"][0]
            cands = []
            for o in events:
                if o is e or not o["session_ids"]:
                    continue
                if app_of(o) != by[k]["app"]:
                    continue
                pe, po = lab.get(k, ""), _ev_proj(o, lab)
                if pe and po and pe != po:
                    continue                      # 项目硬边界同样约束吸收
                g = gap_min(T[k], ev_span(o, T))
                if g <= ABSORB_GAP:
                    cands.append((g, len(o["session_ids"]), o))
            if not cands:
                continue
            _, _, host = min(cands, key=lambda x: (x[0], -x[1]))
            host["session_ids"].append(k)
            host["dirty"] = True
            e["session_ids"] = []
            absorbed += 1
            retain.log_verdict(DAY, f"s{k}", "singleton_absorbed",
                               host=host["title"][:50])
        events = [e for e in events if e["session_ids"]]
    if absorbed:
        print(f"[absorb] 单帧吸收 {absorbed} 个 → {len(events)} 事件")
    return events


def global_merge_pass(events, by, idf, T):
    import numpy as np
    import v4_local_cluster as _vc
    E = np.load(_vc.EMB)
    E = E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-9)
    row = {k: i for i, k in enumerate(by)}          # by 保持 load_sessions 插入序
    n = len(events)

    def ev_anch(e):
        a = collections.Counter()
        for k in e["session_ids"]:
            for t in by[k]["anchors"]:
                a[t] += 1
        return a

    def ev_cent(e):
        v = E[[row[k] for k in e["session_ids"] if k in row]].mean(axis=0)
        return v / (np.linalg.norm(v) + 1e-9)

    EA = [ev_anch(e) for e in events]
    EC = [ev_cent(e) for e in events]
    _CHAT = {"微信", "wechat", "discord", "messages", "信息", "mail", "telegram"}

    def _chatty(e):
        apps = collections.Counter(by[k]["app"].lower() for k in e["session_ids"] if k in by)
        top = apps.most_common(1)
        return bool(top) and top[0][0] in _CHAT

    A = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1, n):
            A[i, j] = A[j, i] = (MERGE_ALPHA * float((EC[i] * EC[j]).sum())
                                 + (1 - MERGE_ALPHA) * wjaccard(EA[i], EA[j], idf))
    lab = _proj_labels(by)
    comp = [[i] for i in range(n)]
    csz = [len(e["session_ids"]) for e in events]
    ch = [_chatty(e) for e in events]

    def comp_proj(c):
        cnt = collections.Counter()
        for i in c:
            for k in events[i]["session_ids"]:
                if lab.get(k):
                    cnt[lab[k]] += 1
        top = cnt.most_common(1)
        return top[0][0] if top and top[0][1] >= 3 else ""

    vetoed_proj = 0
    while True:
        best = None
        for i in range(len(comp)):
            for j in range(i + 1, len(comp)):
                if ch[comp[i][0]] != ch[comp[j][0]]:
                    continue                            # chat/dev 异质否决
                if csz[i] + csz[j] > MERGE_CAP:
                    continue                            # 规模护栏:禁产巨簇
                pi, pj = comp_proj(comp[i]), comp_proj(comp[j])
                if pi and pj and pi != pj:
                    vetoed_proj += 1                    # 项目硬边界(治跨project抽屉)
                    continue
                vals = [A[x][y] for x in comp[i] for y in comp[j]]
                d = sum(vals) / len(vals)               # 平均连接(单链=嵌合体放大器)
                if d >= MERGE_TAU and (best is None or d > best[0]):
                    best = (d, i, j)
        if not best:
            break
        _, i, j = best
        comp[i] += comp[j]
        csz[i] += csz[j]
        del comp[j], csz[j]
    out = []
    for mem in comp:
        if len(mem) == 1:
            out.append(events[mem[0]])
            continue
        mem.sort(key=lambda i: -len(events[i]["session_ids"]))
        surv = dict(events[mem[0]])
        sids = sorted({s for i in mem for s in events[i]["session_ids"]})
        surv["session_ids"] = sids
        surv["dirty"] = True                            # 合并后摘要必须重生成
        out.append(surv)
        retain.log_verdict(DAY, surv["title"][:60], "global_merged",
                           n_from=len(mem), titles=[events[i]["title"][:40] for i in mem[1:]])
    print(f"[global_merge] {len(events)}→{len(out)} 事件(确定性平均连接 "
          f"τ{MERGE_TAU}/cap{MERGE_CAP},项目否决 {vetoed_proj},零LLM)")
    out = eject_chat_from_dev(out, by)
    out = absorb_singletons(out, by, T, lab)
    return out


# ---- T0 impact 打分步(0-5,rubric+gold few-shot,先理由后分) ----
_IMPACT_RUBRIC = """Score this event's IMPACT for a personal memory system, 0-5:
5=identity-shaping or THE day's core work — a typical day has only 1-2 of these
4=important development (significant bug root-caused & fixed, architecture design) — a few per day
3=regular development work (DEFAULT for most dev tasks: a fix, a feature tweak, an investigation)
2=minor task/config/short investigation  1=casual browsing/entertainment/quick chat  0=background noise
BE STRICT: most events are 2-3. Reserve 4-5 for work that dominated hours or changed the project.
Examples: "重写写作采集提取为统一field-state timeline"(42 sessions, commit 00b07be)=5;
"Fixed light mode divider color"(3 sessions)=3; "Played music on Spotify"=1;
"Notification Center glance"=0.
Event: «{title}» ({n} sessions) — {summary}
"reason" must cite THIS event's concrete content (what was done/found), not its importance.
FORBIDDEN in reason: critical, significant, "This event represents", restating the rubric.
Answer ONLY JSON: {{"reason":"<one specific sentence>","impact":<0-5>}}"""


# gold 6-07 的 impact 形状(31事件 {5:2,4:5,3:12,2:8,1:3,0:1})→ 累计占比封顶。
# v7d 实锤:rubric 文字压不住 2507 打分通胀({5:12,4:13});配额只封顶不抬底
# (impact=min(原始分,配额档)),安静日 LLM 全给低分时分布不受配额影响。
_IMPACT_QUOTA = [(5, 2 / 31), (4, 7 / 31), (3, 19 / 31), (2, 27 / 31), (1, 30 / 31), (0, 1.0)]


def impact_pass(events, T):
    for e in events:
        obj = _gen("impact", [{"role": "user", "content": _IMPACT_RUBRIC.format(
            title=e["title"], n=len(e["session_ids"]), summary=e["summary"][:400])}],
            256, event=e["title"][:40])   # 120 时 9B 有 11/51 条 reason 词中截断
        try:
            e["impact"] = max(0, min(5, int((obj or {}).get("impact", 2))))
            e["impact_reason"] = str((obj or {}).get("reason", ""))[:320]  # 200切片曾腰斩9B长reason
        except Exception:
            e["impact"] = 2
    raw = collections.Counter(e["impact"] for e in events)
    # 排序键:原始分 > 成员数 > 时长(LLM 平局多,确定性信号决胜)
    def dur(e):
        s = ev_span(e, T)
        return s[1] - s[0]
    order = sorted(range(len(events)),
                   key=lambda i: (-events[i]["impact"],
                                  -len(events[i]["session_ids"]), -dur(events[i])))
    for rank, i in enumerate(order):
        frac = (rank + 1) / len(events)
        tier = next(t for t, cap in _IMPACT_QUOTA if frac <= cap)
        if tier < events[i]["impact"]:
            retain.log_verdict(DAY, events[i]["title"][:60], "impact_capped",
                               raw=events[i]["impact"], capped=tier)
            events[i]["impact"] = tier
    dist = collections.Counter(e["impact"] for e in events)
    print(f"[impact] 原始 {dict(sorted(raw.items(), reverse=True))} → "
          f"封顶 {dict(sorted(dist.items(), reverse=True))}")


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


# 7-09 审计:全英文 Git-commit 式短标题信息量比 gold 中文叙事句差一个量级,且用户
# 中文工作;中文决策原话≈0 是与 gold 最系统的忠实度差距。改中文叙事+强制逐字引语
# (strip_unverifiable 的引语 exact-match 校验兜底防编造)。
REGEN = """用成员会话摘要重写这一个事件的标题和总结。用户是中文使用者,这是他的个人记忆系统。

成员会话(时间序):
{doings}

规则:
- "title": 中文叙事句,≤40字,格式=项目/场景+关键动作(例:「打磨My-Portrait侧栏UI:右键菜单+蓝框高亮」
  「排查写作采集IME尾巴丢字并验证librime」)。技术名词/文件名/App名保留原文不翻译。禁终端旗标、禁"App — Window"。
- "summary": 2-5句中文,第三人称。只引用摘要里逐字出现的锚点(文件/函数名、commit hash、数字、报错原文),
  技术 token 保持原文。禁止编造。
- 摘要里若有用户说的话/拍板决策,必须用「」逐字引用原句,一字不改。
- 人名保持原文(何成就是何成,绝不罗马化);人物/社交/生活内容必须保留。
- 成员≥8段时,每个不同话题至少一个分句覆盖,不许只写主线。
- 绝不提: --dangerously-skip-permissions、caffeinate、sourcekit-lsp(终端噪声)。
- "tags": 3-6个小写关键词(技术词保英文)。
只回答: {{"title":"...","summary":"...","tags":[...]}}"""


def qa_pass(events, by, idf):
    stats = collections.Counter()
    for e in events:
        ung, res = violations(e, by)
        # 7-09 中文化:v6 层标题是英文,非中文标题也触发重生成(REGEN 已出中文叙事句)
        need = bool(e.get("dirty") or e.get("misc") or ung or res
                    or not re.search(r"[一-鿿]", e["title"]))
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
    events = global_merge_pass(events, by, idf, T)   # T0:全局一次看全,共识合并(治碎片化)
    stats = qa_pass(events, by, idf)                 # 合并后 dirty 在此重生成
    nstrip = sum(strip_unverifiable(e, by) for e in events)   # T0:引语/hash 硬校验剥离
    if nstrip:
        print(f"[verbatim] 剥离未验证引语/hash {nstrip} 处")
    impact_pass(events, T)                           # T0:impact 0-5 打分+配额封顶
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
