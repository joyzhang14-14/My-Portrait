#!/usr/bin/env python3
"""阶段二 · 从活库导出完整 §3.1 fixture(脱敏、冻结、可复现)→ fixtures/cases.json。
- ts 偏移成相对 event start 的值:脱敏绝对时间、保留时间差(§3.2⑥)。
- 全文本字段逐字符类双射脱敏 → cases.json **不含真实内容,可入 git**。
- 导出时对每个 case 跑结构一致性校验(脱敏前后签名相等),不过即报错。
用法:python3 export_fixtures.py
"""
import os, json
import extract_fixtures as X
from signals_raw import box_clears_from_raw, author_evidence_from_entry, cv
from signals import (SendSignals, classify_delivery, to_delivery,
                     detect_confirmed_message_boundaries, is_chat_input_surface)
from fixtures_lib import build_mapping, deidentify_case, check_structure_preserved, validate_fixture

con = X.con
SIG_FIELDS = ("is_chat_surface", "return_key", "reset_to_known_placeholder", "reset_to_empty",
              "next_session_transition_reliable", "delete_pattern", "physical_key_support",
              "content_len", "n_nonbs_keys", "tail_backspaces", "ts")
def to_sig(s): return SendSignals(**{k: s[k] for k in SIG_FIELDS})

def event_raw(ev_id):
    """拉一个 event 的原始 edit_log + 击键窗口,ts 全偏移成相对 started_at。"""
    r = con.execute("SELECT bundle_id,started_at,edit_log FROM typing_events WHERE id=:i", {"i": ev_id}).fetchone()
    bundle, started, log = r
    arr = json.loads(log)
    ends = [e.get("ts") for e in arr if e.get("ts") is not None]
    end = max(ends) if ends else started
    ks = con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log "
                     "WHERE bundle_id=:b AND ts_ms BETWEEN :t0 AND :t1 ORDER BY ts_ms",
                     {"b": bundle, "t0": started - 8000, "t1": end + 1000}).fetchall()
    base = started
    edit_log = [{"kind": e.get("kind"), "text": e.get("text"),
                 "ts": (e.get("ts") - base if e.get("ts") is not None else None)} for e in arr]
    keystrokes = [{"ts": t - base, "char": c, "is_backspace": bool(b), "modifiers": md}
                  for t, c, b, md in ks]
    return bundle, edit_log, keystrokes, end - base

def build_case(cid, category, ev_id, content, expected_level):
    bundle, edit_log, keystrokes, end0 = event_raw(ev_id)
    sigs = box_clears_from_raw(edit_log, keystrokes, bundle, 0)
    target = next((s for s in sigs if s["content"] == content), None)
    if target is None:
        print(f"⚠️ {cid}: 在 ev{ev_id} 重derive不到 {content!r}"); return None
    classified = [(classify_delivery(to_sig(s))[0], to_sig(s)) for s in sigs]
    bounds = detect_confirmed_message_boundaries(classified)
    deliv, conf = to_delivery(classify_delivery(to_sig(target))[0])
    is_draft = expected_level == "confirmed_draft"
    return {
        "id": cid, "category": category, "deid": "bijection", "source_ev_id": ev_id,
        "app": bundle, "url": None, "surface": "chat_input" if target["is_chat_surface"] else "other",
        "time_bounds": [0, end0], "target_ts": target["ts"],
        "edit_log": edit_log, "keystroke_log": keystrokes,
        "expected_output": (None if is_draft else content),
        "must_not_exist": ([content] if is_draft else []),
        "expected_completeness": None,           # 完整性是阶段四,首版留空
        "expected_delivery": deliv.value,
        "expected_delivery_confidence": conf.value,
        "expected_author_evidence": {"physical_key_backed": True},
        "expected_boundaries": bounds,
        "expected_level": expected_level,        # 内部断言用
    }

def build_raw_case(cid, category, ev_id, target_kind, locator, *, negative, note=""):
    """非 box-clear 案例(粘贴/占位符/高频短消息):存原始事件 + 目标 entry 的作者证据。
    negative=True → 该内容禁止作为用户写作记录(must_not_exist);False → 必须保留。"""
    bundle, edit_log, keystrokes, end0 = event_raw(ev_id)
    idx = next((i for i, e in enumerate(edit_log)
                if e.get("kind") == target_kind and locator in cv(e.get("text", "") or "")), None)
    if idx is None:
        print(f"⚠️ {cid}: ev{ev_id} 找不到 {target_kind} 含 {locator!r}"); return None
    content = cv(edit_log[idx].get("text", "") or "")
    ae = author_evidence_from_entry(edit_log, idx, keystrokes)
    return {
        "id": cid, "category": category, "deid": "bijection", "source_ev_id": ev_id,
        "app": bundle, "url": None, "surface": "chat_input" if is_chat_input_surface(bundle) else "other",
        "time_bounds": [0, end0], "target_ts": None, "target_idx": idx,
        "edit_log": edit_log, "keystroke_log": keystrokes,
        "expected_output": None,
        "must_not_exist": [content] if negative else [],
        "expected_completeness": None,
        "expected_delivery": "unknown", "expected_delivery_confidence": "unknown",
        "expected_author_evidence": ae, "expected_boundaries": [],
        "expected_level": None, "note": note,
    }

# 2b 补充案例(solo 定位 + 核实);locator = 该 entry 文本里的子串(仅导出时定位,不入 fixture)
# 候选短真发送;只保留 re-derive 为 confirmed_sent 的(短消息必保留 = 不被过滤)
SHORT_SENDS = [("short_send_ev462", 462, "谁不重要"), ("short_send_ev475", 475, "也有可能"),
               ("short_send_ev477", 477, "不过你"), ("short_send_ev529", 529, "气冲")]
PASTE_NEG = [("paste_neg_ev502", 502, "paste", "Ignored"), ("paste_neg_ev503", 503, "paste", "Update")]
PH_NEG = [("placeholder_neg_ev362", 362, "commit", "Write a message"),
          ("placeholder_neg_ev408", 408, "commit", "Write a message")]
HIGHFREQ = [("highfreq_ok_ev1033", 1033, "delete", "ok")]

def main():
    labeled = X.collect_labeled()
    negs = X.collect_draft_negatives({(c["ev_id"], c["content"]) for c in labeled})
    # ⚠️ id 必须无真实内容(会随 cases.json 入 git):用 category+level+ev+序号
    specs = [(f"labeled_{c['expected']}_ev{c['ev_id']}_{i}", "labeled", c["ev_id"], c["content"], c["expected"])
             for i, c in enumerate(labeled)]
    specs += [(f"draft_neg_ev{c['ev_id']}_{i}", "draft_negative", c["ev_id"], c["content"], "confirmed_draft")
              for i, c in enumerate(negs)]

    cases = [bc for s in specs if (bc := build_case(*s)) is not None]
    # 2b:短真发送(message型正样本)+ 粘贴/占位符负样本 + 高频短消息
    n_short = 0
    for cid, ev, content in SHORT_SENDS:
        if n_short >= 3: break
        bc = build_case(cid, "short_message", ev, content, "confirmed_sent")
        if bc and bc["expected_delivery"] == "sent" and bc["expected_delivery_confidence"] == "confirmed":
            cases.append(bc); n_short += 1
        elif bc:
            print(f"  跳过 {cid}:re-derive 非 confirmed_sent({bc['expected_delivery']})")
    for cid, ev, tk, loc in PASTE_NEG:
        if (bc := build_raw_case(cid, "paste_negative", ev, tk, loc, negative=True)): cases.append(bc)
    for cid, ev, tk, loc in PH_NEG:
        if (bc := build_raw_case(cid, "placeholder_negative", ev, tk, loc, negative=True)): cases.append(bc)
    for cid, ev, tk, loc in HIGHFREQ:
        if (bc := build_raw_case(cid, "high_freq_short", ev, tk, loc, negative=False,
                                 note="英文高频短消息;阶段一 send-evidence 只覆盖 CJK,行为断言待阶段三/四")):
            cases.append(bc)

    # 全局映射(跨 case 一致 → 保住跨 case 相等/复现)
    texts = [e["text"] for c in cases for e in c["edit_log"] if e.get("text")]
    texts += [k["char"] for c in cases for k in c["keystroke_log"] if k.get("char")]
    texts += [c["expected_output"] for c in cases if c["expected_output"]]
    mapping = build_mapping(texts)

    deid_cases = []
    for c in cases:
        errs = validate_fixture(c)
        if errs: raise SystemExit(f"{c['id']} fixture 字段缺失: {errs}")
        d = deidentify_case(c, mapping)
        ok, bad = check_structure_preserved(c, d)
        if not ok: raise SystemExit(f"{c['id']} 脱敏破坏结构不变量: {bad}")
        deid_cases.append(d)

    os.makedirs(os.path.join(os.path.dirname(__file__), "fixtures"), exist_ok=True)
    path = os.path.join(os.path.dirname(__file__), "fixtures", "cases.json")
    json.dump({"cases": deid_cases}, open(path, "w"), ensure_ascii=False, indent=1)
    import collections
    by_cat = collections.Counter(c["category"] for c in deid_cases)
    print(f"导出 {len(deid_cases)} 个脱敏 fixture → {path}")
    for cat, n in sorted(by_cat.items()): print(f"    {cat}: {n}")
    print("结构一致性校验:全部通过 ✓")

if __name__ == "__main__":
    main()
