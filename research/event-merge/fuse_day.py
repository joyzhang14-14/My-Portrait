"""当天 event → 长期库（跨天融库），按天顺序跑，库存在 <输出目录>/library.json。

库里一个 event = 同一件事在不同天的几段（section，各是某天的当天 event），带一个标题和一两句总述。
今天的每个 event：
1. 候选：在之前各天的段里取——向量最像的 VEC_K 段 ∪ 对象 tag 撞上的（最多 KW_K 段）∪ 前两天出现过且向量排进前 RECENT_POOL 的；
   再归到各自的库 event（同一个库 event 只问一次），按其中最像的一段排序，只问前 ASK_K 个。
2. 窄题「是不是后续」：按任务算，同一份作业 / 文档 / 功能 / bug / 下载 / 请求隔天接着做才是；同项目、同仓库、同一个人的另一件事不是。
   第一个答是的就并进去，都不是就在库里新开。今天的 event 只并进一个库 event，不当桥把之前的两件事连起来。
3. 并进去之后改写标题和总述：在原总述上接今天的进展，前面的压成半句，不越写越长。新开的库 event 先拿今天的叙述当总述。

用法：python fuse_day.py --out <输出目录> [--llm api|mac] <天…>   （天按顺序给；每天先跑 merge_day.py 和 tag_day.py）
产物：<输出目录>/library.json、<输出目录>/<天>/fuse.jsonl（今天每个 event 问过哪些库 event、答案和理由）
"""
import argparse, json
from pathlib import Path

from common import Embedder, make_llm, need, obj_schema

VEC_K, KW_K, RECENT_POOL, ASK_K = 8, 5, 30, 5
TODAY_CHARS, PART_CHARS = 1500, 800

FUSE_PROMPT = """You are keeping one person's event library up to date. An event is ONE thing they did: one task, one conversation thread, or one piece of work with a single goal. Below is an event from {day} and an event already in the library from earlier days.

Is today's event a continuation of the library event — the same task carried on to a later day?
Most events of a day are new tasks, and a library event that looks related is usually a different task. Answer "yes" only when today's event clearly picks up the same piece of work.
- "yes" if it works on the same concrete object — the same assignment, document, file, feature, bug, download or request — toward the same goal, and continues, finishes, fixes or follows up on what the library event was doing.
- "no" if it is another task in the same project, repository, course, app, website or AI conversation: another assignment, another feature, page or bug, another question. Sharing a project, repository, tool, app or topic is not enough.
- Talking with the same person or group on a later day is a continuation only if it is about the same matter; a new matter with the same person is "no".
- Coming back to the same playlist, feed, inbox, dashboard, report, profile or usage page is a routine visit and is "no", unless today clearly pushes the same unfinished goal forward.

Output:
- "reason": written first, one short English sentence naming the shared object, or why there is none.
- "same": "yes" or "no".

TODAY'S EVENT ({day}):
{today}

LIBRARY EVENT:
{lib}"""

WRITE_PROMPT = """You are keeping one person's event library up to date. An event is ONE thing they did: one task, one conversation thread, or one piece of work with a single goal. The library event below already has parts from earlier days, and today's part of the same event has just been added.

Rewrite the event's title and overview so they cover today as well.
- "title": at most 30 characters, Simplified Chinese (keep names, file names and code identifiers in their original language), naming the one thing by its goal or object. Keep the current title unless today shows it names the thing wrongly or too narrowly.
- "overview": one or two sentences in Simplified Chinese, referring to the person as 用户: what this thing is, how it has gone so far and its last state. Start from the current overview and add today's progress; shorten what came before to half a sentence, so the overview does not grow day by day.
- Use only what the current overview and today's part show; do not call something finished, fixed or successful unless today's part shows that.

CURRENT TITLE: {title}
CURRENT OVERVIEW: {overview}
EARLIER PARTS:
{parts}

TODAY'S PART ({day}):
{today}"""

FUSE_SCHEMA = {"type": "object", "properties": {"reason": {"type": "string"}, "same": {"type": "string", "enum": ["yes", "no"]}},
               "required": ["reason", "same"], "additionalProperties": False}
WRITE_SCHEMA = obj_schema(["title", "overview"])


def lib_text(parts):
    """库 event 给模型看：各段日期 + 标题，最近一段给经过。"""
    head = "\n".join(f"- {p['day']} {p['title']}" for p in parts)
    last = parts[-1]
    return f"Parts so far:\n{head}\nLatest part ({last['day']}): {last['narrative'][:PART_CHARS]}"


def load_day(out: Path, day: str) -> list[dict]:
    evs = json.loads((out / day / "events.json").read_text())
    tags = json.loads((out / day / "tags.json").read_text())
    for e in evs:
        e["key"], e["day"] = f"{day}/{e['id']}", day
        e["objects"] = [o.lower().replace(" ", "") for o in tags.get(e["id"], {}).get("objects", [])]
    return evs


def fuse_day(out: Path, day: str, emb, llm, vec: dict):
    path = out / "library.json"
    lib = json.loads(path.read_text()) if path.exists() else []
    prior = [s for x in lib for s in x["sections"] if s["day"] < day]
    if any(s["day"] >= day for x in lib for s in x["sections"]):
        raise SystemExit(f"{day} 或之后的天已经融过库：天要按顺序跑")
    owner = {s["key"]: x for x in lib for s in x["sections"]}
    recent = set(sorted({s["day"] for s in prior})[-2:])
    for s in prior:
        if s["key"] not in vec:
            vec[s["key"]] = emb.doc(s["title"], s["narrative"][:1500])
    log = []
    for e in load_day(out, day):
        v = emb.doc(e["title"], e["narrative"][:1500])
        sims = sorted(prior, key=lambda p: -float(vec[p["key"]] @ v))
        kw = sorted((p for p in prior if set(p["objects"]) & set(e["objects"])),
                    key=lambda p: -len(set(p["objects"]) & set(e["objects"])))
        pick = sims[:VEC_K] + kw[:KW_K] + [p for p in sims[:RECENT_POOL] if p["day"] in recent]
        order = {p["key"]: j for j, p in enumerate(sims)}
        cands = []                                   # 归到库 event，按其中最像的一段排
        for k in sorted(dict.fromkeys(p["key"] for p in pick), key=order.get):
            if owner[k] not in cands:
                cands.append(owner[k])
        today = f"{e['title']}\n{e['narrative'][:TODAY_CHARS]}"
        asked, hit = [], None
        for x in cands[:ASK_K]:
            parts = sorted(x["sections"], key=lambda s: (s["day"], s["first_ms"]))
            r = llm(FUSE_PROMPT.format(day=day, today=today, lib=lib_text(parts)), FUSE_SCHEMA,
                    lambda r: "" if r.get("same") in ("yes", "no") else "same 不对", f"{e['key']}-{x['id']}")
            asked.append({"lib": x["id"], "same": r["same"] if r else "error", "reason": r["reason"] if r else ""})
            if r and r["same"] == "yes":
                hit = x
                break
        sec = {k: e[k] for k in ("key", "day", "title", "narrative", "first_ms", "objects")}
        if hit:
            parts = "\n".join(f"- {s['day']} {s['title']}" for s in sorted(hit["sections"], key=lambda s: (s["day"], s["first_ms"])))
            w = llm(WRITE_PROMPT.format(title=hit["title"], overview=hit["overview"], parts=parts, day=day,
                                        today=f"{e['title']}\n{e['narrative']}"),
                    WRITE_SCHEMA, need("title", "overview"), f"{e['key']}-{hit['id']}-write")
            hit["sections"].append(sec)
            if w:
                hit["title"], hit["overview"] = w["title"].strip().split("\n")[0], w["overview"].strip()
        else:
            lib.append({"id": f"L{len(lib) + 1}", "title": e["title"], "overview": e["narrative"], "sections": [sec]})
        log.append({"event": e["key"], "asked": asked, "joined": hit["id"] if hit else None})
    path.write_text(json.dumps(lib, ensure_ascii=False, indent=1))
    (out / day / "fuse.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in log))
    print(f"{day} 今天 {len(log)} 个 event，并进库里已有的 {sum(1 for x in log if x['joined'])} 个，库里共 {len(lib)} 个", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--llm", choices=["api", "mac"], default="api")
    ap.add_argument("days", nargs="+")
    a = ap.parse_args()
    emb, llm, vec = Embedder(), make_llm(a.llm, a.out), {}
    for day in sorted(a.days):
        fuse_day(a.out, day, emb, llm, vec)


if __name__ == "__main__":
    main()
