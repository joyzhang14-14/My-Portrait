"""给当天 event 打 tag：所有 event 写完之后，一个 event 一次调用，只看标题和叙述。一个 event 出三栏，拼起来就是 tags：
- 领域：画像的类别（DOMAINS）里选，至少 1 个，一个 event 可以进几个类别；
- 对象：原文里的专名照抄（课程、项目、仓库、文件、人、游戏、网站），程序核对必须在标题或叙述里出现，对不上的丢掉；
- 主题：1–3 个内容领域的词。
app 名不进 tag（会话里本来就有）。对象 tag 是跨天融库的检索钥匙之一（fuse_day.py）。

用法：python tag_day.py --out <输出目录> [--llm api|mac] <天…>
      读 <输出目录>/<天>/events.json，写 <输出目录>/<天>/tags.json：{event id: {domains, objects, topics, tags, dropped}}
"""
import argparse, json
from pathlib import Path

from common import make_llm

DOMAINS = ["experiences", "skills", "social", "interests", "background"]     # 画像的类别名

TAG_RULES = """- "domains": which parts of a personal portrait this event is evidence for; one or more of:
  - experiences: something the person did or went through (default; almost every event is one).
  - skills: the person practises or uses a capability themselves — coding, math, writing, design, a language, a tool — shown by their own work, not by an assistant's.
  - social: the person interacts with specific other people (chatting, messaging, meeting); an AI assistant or bot is not a person.
  - interests: a subject the person engages with by choice — music, games, a field they read about — not coursework or a chore.
  - background: objective personal facts — school, courses taken, location, job, family, accounts, money, housing.
  List only what the account shows.
- "objects": up to 5 specific named things the event is about — a course code, project, repository, file, person, game, song, product or website — copied exactly as written in the title or account. Only names that the event is about, not every name mentioned. No app names (Safari, Discord, VS Code, Claude Code, ChatGPT…) unless the app itself is what the event is about. [] if none.
- "topics": 1 to 3 short subject words for what the content is about (in Simplified Chinese; keep technical terms in their original language), such as 线性代数, prefix caching, bossa nova. Not a domain, not an object, not an action."""

TAG_PROMPT = """Below is one event from one person's computer use: its title and an account of what happened. Tag it.

Output:
""" + TAG_RULES + """

Title: {title}

Account:
{narrative}"""

TAG_SCHEMA = {"type": "object", "properties": {
    "domains": {"type": "array", "items": {"type": "string", "enum": DOMAINS}},
    "objects": {"type": "array", "items": {"type": "string"}},
    "topics": {"type": "array", "items": {"type": "string"}}},
    "required": ["domains", "objects", "topics"], "additionalProperties": False}


def valid(r):
    if not isinstance(r.get("domains"), list) or not r["domains"] or any(d not in DOMAINS for d in r["domains"]):
        return "domains 为空或不在类别里"
    if not isinstance(r.get("objects"), list) or not isinstance(r.get("topics"), list) or not r["topics"]:
        return "objects / topics 不是列表或 topics 为空"
    return ""


def tag_event(day, e, llm):
    r = llm(TAG_PROMPT.format(title=e["title"], narrative=e["narrative"]), TAG_SCHEMA, valid, f"{day}-{e['id']}-tag")
    if r is None:
        return {"domains": [], "objects": [], "topics": [], "tags": [], "dropped": [], "error": True}
    return clean(r, e)


def clean(r, e):
    """对象必须在标题或叙述里出现（对不上的进 dropped），去重、限量，拼出 tags。"""
    text = (e["title"] + " " + e["narrative"]).lower()
    objs, dropped = [], []
    for o in dict.fromkeys(str(x).strip() for x in r["objects"]):
        (objs if o and o.lower() in text else dropped).append(o)
    topics = [t for t in dict.fromkeys(str(x).strip() for x in r["topics"]) if t and t not in objs][:3]
    domains = [d for d in DOMAINS if d in r["domains"]]
    return {"domains": domains, "objects": objs[:5], "topics": topics,
            "tags": domains + objs[:5] + topics, "dropped": dropped}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--llm", choices=["api", "mac"], default="api")
    ap.add_argument("days", nargs="+")
    a = ap.parse_args()
    llm = make_llm(a.llm, a.out)
    for day in a.days:
        d = a.out / day
        out = {e["id"]: tag_event(day, e, llm) for e in json.loads((d / "events.json").read_text())}
        (d / "tags.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
        print(day, len(out), "个 event，丢掉对不上原文的对象", sum(len(x["dropped"]) for x in out.values()), "个", flush=True)


if __name__ == "__main__":
    main()
