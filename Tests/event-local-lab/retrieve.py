"""无 LLM 候选检索 —— "当天全量搜索"的替身。

14B 看不下全天上下文,全局视野交给词法检索:CJK 按字、ASCII 按词切 token,
IDF 加权重叠打分,top-K 进 LLM prompt。召回错了 LLM 救不了,所以
finalize 的 merge 兜底负责收漏网的重复事件。
"""
import json
import math
import re

_TOKEN = re.compile(r"[a-zA-Z0-9_]+|[一-鿿]")


def tokens(text: str):
    return set(t.lower() for t in _TOKEN.findall(text or ""))


def session_tokens(row):
    return tokens(f"{row['app']} {row['window']} {row['url']} {row['ocr']}")


def event_tokens(row):
    tags = " ".join(json.loads(row["tags"])) if isinstance(row["tags"], str) else ""
    return tokens(f"{row['title']} {row['summary']} {tags}")


def hist_tokens(card):
    return tokens(f"{card['title']} {card['summary']} {' '.join(card['tags'])}")


def build_idf(token_sets):
    n = max(1, len(token_sets))
    df = {}
    for ts in token_sets:
        for t in ts:
            df[t] = df.get(t, 0) + 1
    return {t: math.log(1 + n / c) for t, c in df.items()}


def score(q, c, idf):
    inter = q & c
    if not inter:
        return 0.0
    s = sum(idf.get(t, 1.0) for t in inter)
    return s / math.sqrt(max(1, len(q)) * max(1, len(c)))


def top_k(query_tokens, candidates, idf, k=6, floor=0.05):
    """candidates: list[(key, token_set)] → [(key, score)] 降序,过地板分。"""
    scored = [(key, score(query_tokens, ts, idf)) for key, ts in candidates]
    scored = [x for x in scored if x[1] >= floor]
    scored.sort(key=lambda x: -x[1])
    return scored[:k]
