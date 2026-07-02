"""R8 留存:所有 LLM 调用 + 下游确定性裁决落 JSONL(数据飞轮,只攒不训)。

⚠️ schema 必须在攒数据前定型(伪标签确认偏差:单一管线裁决当 gold 喂微调会继承规则盲区)。
三种记录(每行一条,type 区分):
  {"type":"call","id","ts","day","stage","model","messages","raw","parsed","ok","ms","meta"}
      stage: vision / summarize / bucket_split / naming / binary / anchor_arbiter / daytype / summary_qa
  {"type":"verdict","ref","ts","kind","detail"}
      kind: overruled_by_exactly_once / rescued_attach / rescued_singleton / rejected_by_lint /
            bucket_retry / bucket_fallback_split / consensus_minority / conflict_rule_vs_llm
      —— 被规则推翻的 LLM 输出 = 免费负例,但含 ~10% 错标,入训练集前必须过抽查
  {"type":"gold","ref","ts","corrected","note"}
      人工抽查修正回写(必须回写,否则前期数据废一半);低置信+conflict = 抽查优先采样池
落盘 retention/YYYY-MM-DD.jsonl(目录 .gitignore,数据不进 git)。
"""
import json
import os
import threading
import time
import uuid

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "retention")
_lock = threading.Lock()


def _append(day, obj):
    os.makedirs(DIR, exist_ok=True)
    with _lock, open(os.path.join(DIR, f"{day}.jsonl"), "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def log_call(day, stage, model, messages, raw, parsed=None, ok=True, ms=0, **meta):
    """LLM 调用留存,返回 id 供 verdict/gold 回指。"""
    cid = uuid.uuid4().hex[:12]
    _append(day, {"type": "call", "id": cid, "ts": time.time(), "day": day,
                  "stage": stage, "model": model, "messages": messages, "raw": raw,
                  "parsed": parsed, "ok": ok, "ms": ms, "meta": meta or {}})
    return cid


def log_verdict(day, ref, kind, **detail):
    """下游确定性裁决留存(ref=call id 或 's<sid>'/事件标题)。"""
    _append(day, {"type": "verdict", "ref": ref, "ts": time.time(),
                  "kind": kind, "detail": detail})


def log_gold(day, ref, corrected, note=""):
    """人工抽查修正回写。corrected=修正后的正确答案。"""
    _append(day, {"type": "gold", "ref": ref, "ts": time.time(),
                  "corrected": corrected, "note": note})
