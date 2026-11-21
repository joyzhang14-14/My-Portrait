"""EventSession 会话 → 当天 event，三步。

1. 选会话（窄题）：会话按开始时间逐个来。先单独问一次「有没有做事 + 它服务的任务叫什么」，没做事就跳过；
   再按 activity 向量把候选缩到最像的 PAIR_K 个 event ∪ 最近活跃的 1 个，按相似度逐个问「这个会话是不是这个 event 的一部分」，
   第一个答是的就并入，都不是就新开。每个 event 给模型看标题、上次活跃隔了多久 + 和当前会话最像的那个成员会话；
   答是时顺带给出整件事的新标题。屏蔽 app 的段（method='屏蔽app'，只有 app 名和起止时间）不处理。
2. 当天查重：每个 event 找向量最像的 DEDUP_K 个别的 event（不限时间），逐对问「是不是同一件事」，是就合并；
   每边只给标题 + 两边成员里最像的那一对会话；按相似度从高到低合，两组之间问过的对里有一个「不是」就不合（防连锁合并）。
3. 写 event：每个 event 按时间顺序拿全部成员会话写标题 + 叙述；会话多于 GROUP 个就每 GROUP 个一组先写摘要，
   摘要多于 GROUP 段再往上合，直到一次写得下总览。写完查出处：叙述里的数字和英文词在成员会话里找不到的，
   带着这些词重写一次，留找不到的词更少的那版。

输入：EventSession 的会话库（SQLite，表结构见 README）。
用法：python merge_day.py --db <会话库> --out <输出目录> [--llm api|mac] <天…>
产物：<输出目录>/<天>/events.json（id、标题、叙述、各层摘要、成员会话）、decisions.jsonl（每个会话的决定）、dedup.jsonl（查重的每一对）
"""
import argparse, json, re, sqlite3, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

from common import Embedder, MAX_TOKENS, make_llm, need, obj_schema

BLOCKED = "屏蔽app"
PAIR_K = 4                 # 选会话：按向量逐个问的候选数（另加最近活跃的 1 个）
DEDUP_K = 5                # 当天查重：每个 event 和几个向量最像的 event 比（不限时间）
GROUP = 10                 # 写 event：一组最多几个会话 / 几段摘要
WRITERS = 4                # 写 event：同一天并行写几个
SPECIFICS_MAX = 10
OVERVIEW_MAX_TOKENS = 2400 # 大 event 的总览：1200 会截在叙述半句

ALONE_PROMPT = """Below is one session from one person's computer use on {day}. A session is a stretch of time in one app, with a description of what was on screen.

Is anything done in it?
- "no" if nothing is done — a blank, loading or locked screen; a flash of a second or two; a launcher, switcher, notification or pop-up passed through on the way to something else; or a window that is only open, with no reading, typing or choosing shown.
- "yes" otherwise. Looking at a page, document, chat, game, list or panel whose content is described counts as reading, even with no typing. Creating, submitting, sending, typing, choosing or discussing anything is something done. An error, timeout or failed load while trying to reach something is part of doing that thing, not nothing.

Output:
- "done": "yes" or "no".
- "title": for yes, Simplified Chinese (keep names, file names and code identifiers in their original language), at most 30 characters, naming the task this session serves — the assignment, document, conversation, download, project task or thing being worked toward — not the single step, question or action seen here, and not the app. Name it by where most of the session's time goes; a brief side glance is not the main thing. For no, "".

SESSION:
{session}"""

JOIN_PROMPT = """Below are one session and one event from one person's computer use on {day}. A session is a stretch of time in one app, with a description of what was on screen. An event is ONE thing they did: one task, one conversation thread, or one piece of work with a single goal.

Is the session part of the event?
- "yes" if the session is about the same concrete object as the event — the same file, document, message thread, person, code identifier, item or thing being worked on — and serves the same goal. Coming back to the same view, page, place or item counts. Several runs, attempts or steps toward the same goal, in different apps or hours apart, are one event; so are different parts, questions, sections or stages of the same assignment, document, download or conversation, and the later steps, follow-ups or results of the same task.
- A step that leads into or follows from the event's sessions is part of it: copying something and pasting it into another app, taking a screenshot and then asking about it, editing a file and then telling an assistant it is done, being asked by someone and then doing it.
- Every step and outcome of the task belongs to it: preparing, signing in or verifying on the way to it, a failed or timed-out attempt, a retry, a fix, checking or reporting the result, undoing it, deleting or cleaning up what it made.
- A chat with the same person or group, continuing in the same conversation, is one event even when the topic moves on.
- An AI assistant or coding-agent conversation is different: one window or conversation can run for hours and hold many tasks. There, what decides is the request being worked on: the session is part of the event only if it works on the same request, its follow-ups or its results. A new request, or a different feature, bug, file, rule or question, in the same conversation, window or repository is a new task.
- "no" if they are different tasks, even within the same project, repository, codebase, folder, device, app or website, or on a similar topic. A general-purpose app or assistant conversation can hold several unrelated tasks. A word the two share is not enough; the session must be doing the event's thing, not just mentioning it.
- "who" is only a hint: an assistant or tool that shows up across many tasks says nothing about which task this is.
- If the session mixes several things, decide by its main part.

Output:
- "reason": written first, one short English sentence naming the shared object, or why there is none.
- "same": "yes" or "no".
- "title": for yes, Simplified Chinese, at most 30 characters, naming this one task (keep the event's title unless it names the task wrongly; never widen it to cover other tasks); for no, "".

SESSION:
{session}

EVENT:
{event}"""

SAME_PROMPT = """You are checking one person's computer use on {day} for events that were split by mistake. An event is ONE thing they did: one task, one conversation thread, or one piece of work with a single goal. The two events below are from the same day.

Are they the same event, so they should be one?
- "yes" only if they are about the same concrete object — the same file, document, message thread, person, code identifier, item or thing being worked on — and serve the same goal.
- "no" if they are different tasks, even within the same project, repository, codebase, app or website, or on a similar topic.

Output:
- "reason": written first, one short English sentence naming the shared object, or why there is none.
- "same": "yes" or "no".

EVENT A:
{a}

EVENT B:
{b}"""

WRITE_RULES = """- Simplified Chinese; keep names, file names, code identifiers and quoted text in their original language; refer to the person as 用户.
- Summarize what was done, with which concrete objects, files or people, and how it turned out. Do not retell it session by session.
- Mention each thing, object or idea once; do not restate a point in other words.
- Describe only what the material shows: nothing about what it says about the person, and no plan the material does not show.
- Every statement must come from a specific session. Report each outcome only as far as the sessions show it: do not call something finished, fixed or successful unless a session shows that.
- Name who did each thing. What an AI assistant, agent, tool or another person did, wrote, ran, proposed or reported is theirs; the user is the one who typed, sent, clicked, chose or asked. Reading or viewing something is reading it, not writing, recording, organizing or confirming it.
- A request, plan, proposal, prompt, open dialog or half-made selection is not its result: being asked to check is not confirming, a confirm dialog is not a confirmed action, a selection box is not a screenshot taken, text still sitting in an input box is not a message sent. End with the last state the sessions show.
- Do not join facts with "because", "so" or "which led to" unless a session states that cause.
- Leave out what belongs to other work that happens to be visible in a session (another window, a terminal or chat in the background, a notification).
- Keep the order in which the sessions show things, and keep each detail with the item it belongs to; do not move a name, number or file from one item to another.
- As short as the content allows."""

WRITE_PROMPT = """Below are all the sessions of one event from one person's computer use on {day}, in time order. Working title: {title}

Write the event.
- "title": the final title, at most 30 characters, naming the one thing by its goal or object.
- "narrative": a short account of what happened in this event.
""" + WRITE_RULES + """

SESSIONS:
{items}"""

GROUP_PROMPT = """Below are {what} of one event from one person's computer use on {day}, in time order — part {part} of {parts}. Working title: {title}

Summarize this part so that an overview of the whole event can be written from the part summaries later.
- "summary": keep the concrete facts — what was done, objects, files, people, decisions, results — in their order.
""" + WRITE_RULES + """

{label}:
{items}"""

OVERVIEW_PROMPT = """Below are summaries of the consecutive parts of one event from one person's computer use on {day}, in time order. Working title: {title}

Write the event from them.
- "title": the final title, at most 30 characters, naming the one thing by its goal or object.
- "narrative": a short account of the whole event, from the first part to the last: how it started, the main steps and how it ended. Every part must be covered, not only the last one. Merge what the parts share; do not go part by part.
""" + WRITE_RULES + """

PART SUMMARIES:
{items}"""

WRITE_SCHEMA = obj_schema(["title", "narrative"])
GROUP_SCHEMA = obj_schema(["summary"])
ALONE_SCHEMA = {"type": "object", "properties": {"done": {"type": "string", "enum": ["yes", "no"]}, "title": {"type": "string"}},
                "required": ["done", "title"], "additionalProperties": False}
JOIN_SCHEMA = {"type": "object", "properties": {"reason": {"type": "string"}, "same": {"type": "string", "enum": ["yes", "no"]},
                                              "title": {"type": "string"}},
               "required": ["reason", "same", "title"], "additionalProperties": False}
SAME_SCHEMA = {"type": "object", "properties": {"reason": {"type": "string"}, "same": {"type": "string", "enum": ["yes", "no"]}},
               "required": ["reason", "same"], "additionalProperties": False}


def load_sessions(db: Path, day: str) -> tuple[list[dict], timezone]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    tz = json.loads(con.execute("SELECT tz FROM days WHERE day=:d", {"d": day}).fetchone()[0])
    h, m = tz["utc_offset"].split(":")
    off = timedelta(hours=int(h), minutes=int(m) if not h.startswith("-") else -int(m))
    rows = con.execute("SELECT * FROM sessions WHERE day=:d ORDER BY start_ms, key", {"d": day}).fetchall()
    return [dict(r) for r in rows], timezone(off)


def hm(ms: int, tz) -> str:
    return datetime.fromtimestamp(ms / 1000, tz).strftime("%H:%M")


def session_text(s: dict, tz) -> str:
    focus = round((s["focus_ms"] or 0) / 1000)
    head = f"[{hm(s['start_ms'], tz)}–{hm(s['end_ms'], tz)}, 前台 {focus}s] {s['app']}"
    if s["window"]:
        head += f" — {s['window']}"
    if s["url"]:
        head += f" ({s['url']})"
    lines = [head, "activity: " + (s["activity"] or "").strip()]
    if s["context_in_app"]:
        lines.append("context: " + s["context_in_app"])
    who = json.loads(s["who_json"] or "[]")
    if who:
        lines.append("who: " + json.dumps(who, ensure_ascii=False))
    spec = json.loads(s["specifics_json"] or "[]")[:SPECIFICS_MAX]
    if spec:
        lines.append("specifics: " + " | ".join(str(x) for x in spec))
    return "\n".join(lines)


def pick_pair(day, sessions, tz, emb, llm, log):
    """选会话：每个会话先问有没有做事，再和向量最像的几个 event 逐个比「是不是同一件事」。回 events 和成员会话的向量。"""
    by_key = {s["key"]: s for s in sessions}
    events: list[dict] = []
    svec: dict[int, np.ndarray] = {}
    t0 = time.time()

    def shown(e, s, q):
        """event 给模型看：标题 + 和当前会话最像的那个成员会话。"""
        keys = e["sessions"]
        pick = max(keys, key=lambda k: float(svec[k] @ q))
        gap = (s["start_ms"] - e["last_ms"]) / 60000
        when = "still active when this session starts" if gap <= 0 else f"last active {gap:.0f} min before this session"
        head = f"{e['title']} ({hm(e['first_ms'], tz)}–{hm(e['last_ms'], tz)}, {len(keys)} sessions; {when})"
        return head + "\n  session:\n    " + session_text(by_key[pick], tz).replace("\n", "\n    ")

    for n, s in enumerate(sessions, 1):
        stext = session_text(s, tz)
        a = llm(ALONE_PROMPT.format(day=day, session=stext), ALONE_SCHEMA,
                lambda r: "" if r.get("done") == "no" or (r.get("done") == "yes" and str(r.get("title") or "").strip()) else "done 或标题不对",
                f"{day}-{s['key']}-alone")
        if a is None or a["done"] == "no":
            log.append({"session": s["key"], "decision": "error" if a is None else "skip", "event": "",
                        "reason": "模型输出连续坏掉" if a is None else "没有做事"})
        else:
            q = emb.query(s["activity"] or "")
            score = {e["id"]: max(float(svec[k] @ q) for k in e["sessions"]) for e in events}
            cand = sorted(events, key=lambda e: -score[e["id"]])[:PAIR_K]
            if events:
                last = max(events, key=lambda e: e["last_ms"])
                cand += [last] if last not in cand else []
            asked, e = [], None
            for c in cand:
                r = llm(JOIN_PROMPT.format(day=day, session=stext, event=shown(c, s, q)), JOIN_SCHEMA,
                        lambda r: "" if r.get("same") in ("yes", "no") else "same 不对", f"{day}-{s['key']}-{c['id']}")
                asked.append(f"{c['id']}:{r['same'] if r else 'error'}")
                if r and r["same"] == "yes":
                    e = c
                    if str(r.get("title") or "").strip():
                        e["title"] = str(r["title"]).strip().split("\n")[0]
                    break
            if e is None:
                e = {"id": f"E{len(events) + 1}", "title": str(a["title"]).strip().split("\n")[0], "sessions": [],
                     "first_ms": s["start_ms"], "last_ms": s["end_ms"]}
                events.append(e)
            e["sessions"].append(s["key"])
            e["first_ms"] = min(e["first_ms"], s["start_ms"])
            e["last_ms"] = max(e["last_ms"], s["end_ms"])
            svec[s["key"]] = emb.doc("none", s["activity"] or "")
            log.append({"session": s["key"], "decision": "join" if len(e["sessions"]) > 1 else "new", "event": e["id"],
                        "reason": "逐个问 " + (" ".join(asked) or "（没有候选）")})
        if n % 20 == 0 or n == len(sessions):
            print(f"{day} 选会话 {n}/{len(sessions)} → {len(events)} event，{time.time() - t0:.0f}s", flush=True)
    for e in events:
        e["sessions"].sort(key=lambda k: by_key[k]["start_ms"])
    return events, svec


def dedup_events(day, events, by_key, tz, svec, llm, dlog):
    """当天查重：每个 event 取向量最像的 DEDUP_K 个别的 event，逐对问是不是同一件事，是就合并（并查集）。"""
    def sim(a, b):
        return max(float(svec[x] @ svec[y]) for x in a["sessions"] for y in b["sessions"])
    pairs = set()
    for a in events:
        for b in sorted((b for b in events if b is not a), key=lambda b: -sim(a, b))[:DEDUP_K]:
            pairs.add(tuple(sorted((a["id"], b["id"]), key=lambda i: int(i[1:]))))
    by_id = {e["id"]: e for e in events}

    def one(e, k):
        head = f"{e['title']} ({hm(e['first_ms'], tz)}–{hm(e['last_ms'], tz)}, {len(e['sessions'])} sessions)"
        return head + "\n  session:\n    " + session_text(by_key[k], tz).replace("\n", "\n    ")

    def ask(pair):
        a, b = by_id[pair[0]], by_id[pair[1]]
        x, y = max(((x, y) for x in a["sessions"] for y in b["sessions"]), key=lambda t: float(svec[t[0]] @ svec[t[1]]))
        r = llm(SAME_PROMPT.format(day=day, a=one(a, x), b=one(b, y)), SAME_SCHEMA,
                lambda r: "" if r.get("same") in ("yes", "no") else "same 不对", f"{day}-{pair[0]}-{pair[1]}")
        return pair, r
    parent = {e["id"]: e["id"] for e in events}

    def root(i):
        while parent[i] != i:
            i = parent[i]
        return i
    with ThreadPoolExecutor(WRITERS) as ex:
        results = list(ex.map(ask, sorted(pairs, key=lambda p: (int(p[0][1:]), int(p[1][1:])))))
    said = {}
    for (x, y), r in results:
        said[(x, y)] = said[(y, x)] = r["same"] if r else "error"
        dlog.append({"a": x, "b": y, "same": r["same"] if r else "error", "reason": r["reason"] if r else "模型输出连续坏掉"})
    # 按相似度从高到低合并；两组之间问过的对里只要有一对答了「不是」就不合（不让 A=B、B=C 把 A、C 连上）
    for x, y in sorted((p for p in pairs if said[p] == "yes"), key=lambda p: -sim(by_id[p[0]], by_id[p[1]])):
        rx, ry = root(x), root(y)
        if rx == ry:
            continue
        gx = [i for i in parent if root(i) == rx]
        gy = [i for i in parent if root(i) == ry]
        if any(said.get((i, j)) == "no" for i in gx for j in gy):
            next(d for d in dlog if (d["a"], d["b"]) == (x, y))["blocked"] = True
            continue
        parent[max(rx, ry, key=lambda i: int(i[1:]))] = min(rx, ry, key=lambda i: int(i[1:]))
    groups: dict[str, list[dict]] = {}
    for e in events:
        groups.setdefault(root(e["id"]), []).append(e)
    merged = []
    for rid, es in groups.items():
        keep = by_id[rid]
        if len(es) > 1:
            keep["title"] = max(es, key=lambda e: len(e["sessions"]))["title"]
            keep["merged_from"] = [e["id"] for e in es if e is not keep]
            keep["sessions"] = sorted((k for e in es for k in e["sessions"]), key=lambda k: by_key[k]["start_ms"])
            keep["first_ms"] = min(e["first_ms"] for e in es)
            keep["last_ms"] = max(e["last_ms"] for e in es)
        merged.append(keep)
    merged.sort(key=lambda e: e["first_ms"])
    print(f"{day} 查重 {len(pairs)} 对 → {len(events)} → {len(merged)} event", flush=True)
    return merged


def unsupported(narrative: str, source: str) -> list[str]:
    """叙述里的数字和英文词（3 个字符以上）在成员会话里找不到的。"""
    toks = dict.fromkeys(re.findall(r"[A-Za-z][A-Za-z0-9_.\-]{2,}|\d+(?:\.\d+)?", narrative))
    return [t for t in toks if t.lower().rstrip(".") not in source]


def write_event(day, e, by_key, tz, llm):
    """会话 ≤ GROUP 个一次写成；多了每 GROUP 个一组写摘要，摘要再按 GROUP 往上合，最后写总览。"""
    items = [session_text(by_key[k], tz) for k in e["sessions"]]
    levels = []
    what, label = "consecutive sessions", "SESSIONS"
    while len(items) > GROUP:
        chunks = [items[i:i + GROUP] for i in range(0, len(items), GROUP)]
        summaries = []
        for i, ch in enumerate(chunks, 1):
            r = llm(GROUP_PROMPT.format(what=what, day=day, part=i, parts=len(chunks), title=e["title"], label=label,
                                        items="\n\n".join(ch)),
                    GROUP_SCHEMA, need("summary"), f"{day}-{e['id']}-L{len(levels) + 1}-{i}")
            summaries.append(r["summary"].strip() if r else "(this part could not be summarized)")
        levels.append(summaries)
        items = [f"[part {i}] {x}" for i, x in enumerate(summaries, 1)]
        what, label = "summaries of consecutive parts", "PART SUMMARIES"
    prompt = (OVERVIEW_PROMPT if levels else WRITE_PROMPT).format(day=day, title=e["title"], items="\n\n".join(items))
    max_tokens = OVERVIEW_MAX_TOKENS if levels else MAX_TOKENS
    r = llm(prompt, WRITE_SCHEMA, need("title", "narrative"), f"{day}-{e['id']}-final", max_tokens=max_tokens)
    if r:
        source = " ".join([day] + [session_text(by_key[k], tz) for k in e["sessions"]]).lower()
        miss = unsupported(r["narrative"], source)
        if miss:
            r2 = llm(prompt + "\n\nA draft of this narrative used these words, which appear nowhere in the sessions: "
                     + ", ".join(miss) + ". Write it again using only what the sessions show.",
                     WRITE_SCHEMA, need("title", "narrative"), f"{day}-{e['id']}-fix", max_tokens=max_tokens)
            if r2 and len(m2 := unsupported(r2["narrative"], source)) < len(miss):
                r, miss = r2, m2
        e["unsupported"] = miss
    if r:
        e["title"] = r["title"].strip().split("\n")[0]
        e["narrative"] = r["narrative"].strip()
    else:
        e["narrative"] = "(写作输出连续坏掉)"
        print(f"  ⚠ {day} {e['id']} 写作输出连续坏掉", flush=True)
    e["summaries"] = levels


def merge_day(db: Path, out_root: Path, day: str, emb, llm):
    sessions, tz = load_sessions(db, day)
    sessions = [s for s in sessions if s["method"] != BLOCKED]      # 屏蔽 app 的段不处理
    out = out_root / day
    out.mkdir(parents=True, exist_ok=True)
    log, dlog = [], []
    by_key = {s["key"]: s for s in sessions}
    events, svec = pick_pair(day, sessions, tz, emb, llm, log)
    (out / "decisions.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in log))
    events = dedup_events(day, events, by_key, tz, svec, llm, dlog)
    (out / "dedup.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in dlog))
    t0 = time.time()
    with ThreadPoolExecutor(WRITERS) as ex:
        for done, _ in enumerate(ex.map(lambda e: write_event(day, e, by_key, tz, llm), events), 1):
            if done % 5 == 0 or done == len(events):
                print(f"{day} 写 event {done}/{len(events)}，{time.time() - t0:.0f}s", flush=True)
    (out / "events.json").write_text(json.dumps(events, ensure_ascii=False, indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--llm", choices=["api", "mac"], default="api")
    ap.add_argument("days", nargs="+")
    a = ap.parse_args()
    emb, llm = Embedder(), make_llm(a.llm, a.out)
    with ThreadPoolExecutor(len(a.days)) as ex:
        list(ex.map(lambda d: merge_day(a.db, a.out, d, emb, llm), a.days))


if __name__ == "__main__":
    main()
