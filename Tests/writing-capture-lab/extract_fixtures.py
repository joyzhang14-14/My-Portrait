#!/usr/bin/env python3
"""阶段一 · 从真库逐「框清空」提取发送信号,用 OCR 真值打标,冻结成 fixture。
⚠️ 不脱敏(脱敏 + 结构一致性校验是阶段二);本文件只为阶段一状态机验证导原始信号。
真值预言机 = OCR 帧:发送→留在对话区(清空后仍出现);草稿→蒸发(清空后消失)。
信号窗口口径(规范 §2.3 校准):
  - return_key: 宽窗 [clear-3000, clear+500](容忍事件清空 ts 滞后真 Enter ~2.7s,且不串下条消息回车)
  - tail_backspaces: 紧贴 clear 的尾部连续退格(抹除动作)
  - delete_pattern: classify_delete_pattern(content_len, tail_backspaces)
输出:fixtures/send_signals.json
用法:python3 extract_fixtures.py
"""
import sqlite3, os, json
from signals import (is_chat_input_surface, has_sufficient_physical_key_support,
                     classify_delete_pattern)

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def has_cjk(s): return any('一' <= c <= '鿿' for c in s)
KNOWN_PH = ("Write a message", "Type / for commands", "Describe a task or ask a question")
def is_ph(t): return any(p in (t or "") for p in KNOWN_PH)

def app_pat(bundle):
    b = bundle.lower()
    if "claude" in b: return "%laude%"
    if "discord" in b: return "%iscord%"
    if "wechat" in b: return "%eChat%"
    return "%" + bundle.split(".")[-1] + "%"

def keys(bundle, t0, t1):
    return con.execute("SELECT char,is_backspace,modifiers FROM keystroke_log "
                       "WHERE bundle_id=:b AND ts_ms BETWEEN :t0 AND :t1 ORDER BY ts_ms",
                       {"b": bundle, "t0": t0, "t1": t1}).fetchall()

def return_in_window(bundle, clear_ts):
    # 纯回车(modifiers==0)才是发送。Shift+Return(md=8)=消息内换行,Cmd+Return(md=1)另算,均排除。
    for c, b, md in keys(bundle, clear_ts - 3000, clear_ts + 500):
        if (not b) and c in ("\n", "\r") and md == 0:
            return True
    return False

def tail_backspaces(bundle, clear_ts):
    """紧贴 clear 的尾部连续退格数(从最近一个键往前数,遇非退格实质键停)。"""
    ks = keys(bundle, clear_ts - 8000, clear_ts + 200)
    n = 0
    for c, b, md in reversed(ks):
        if b: n += 1
        elif c: break
    return n

def nonbs_keys(bundle, t0, t1):
    return sum(1 for c, b, md in keys(bundle, t0, t1) if (not b) and c and (md & 7) == 0)

def ocr_label(bundle, content, clear_ts):
    """OCR 真值:sent(清空后留对话区) / draft(清空后蒸发) / unknown(太短或 OCR 盲)。"""
    c = cv(content)
    if len(c) < 4: return "unknown"          # 短词污染严重,OCR 不可信
    probe = c if len(c) <= 10 else c[:7]
    pat = app_pat(bundle)
    post = con.execute("SELECT 1 FROM frames WHERE app_name LIKE :a AND timestamp_ms "
                       "BETWEEN :t0 AND :t1 AND full_text LIKE :p LIMIT 1",
                       {"a": pat, "t0": clear_ts + 5000, "t1": clear_ts + 150000,
                        "p": f"%{probe}%"}).fetchone()
    if post: return "sent"
    pre = con.execute("SELECT 1 FROM frames WHERE app_name LIKE :a AND timestamp_ms "
                      "BETWEEN :t0 AND :t1 AND full_text LIKE :p LIMIT 1",
                      {"a": pat, "t0": clear_ts - 60000, "t1": clear_ts,
                       "p": f"%{probe}%"}).fetchone()
    return "draft" if pre else "unknown"

def _sig(bundle, ev_id, content, ts, prev_clear, nxt_txt, nxt_exists, pattern_tbs):
    clen = len(content)
    tbs = pattern_tbs
    nbs = nonbs_keys(bundle, prev_clear, ts)
    return {
        "is_chat_surface": is_chat_input_surface(bundle),
        "return_key": return_in_window(bundle, ts),
        "reset_to_known_placeholder": is_ph(nxt_txt),
        "reset_to_empty": (not nxt_exists) or (cv(nxt_txt) == ""),
        "next_session_transition_reliable": not nxt_exists,   # event 末尾 = 会话切换边界
        "delete_pattern": classify_delete_pattern(clen, tbs),
        "physical_key_support": has_sufficient_physical_key_support(clen, nbs),
        "content_len": clen, "n_nonbs_keys": nbs, "tail_backspaces": tbs, "ts": ts,
        "content": content, "ev_id": ev_id, "bundle": bundle,
        "ocr_label": ocr_label(bundle, content, ts),
    }

def box_clears(ev_id):
    """一个 typing_event 的所有「消息边界」及其 SendSignals(dict)。两类边界:
    A 显式清空:delete 掉 ≥2 字 CJK 实质内容(用户退格删=草稿,或 AX 抓到的发送清空)。
    B 隐式发送:event 末尾仍停在 CJK commit(IME 回车竞速截断,框未被退格→clean 发送)。"""
    r = con.execute("SELECT bundle_id,started_at,edit_log FROM typing_events WHERE id=:i",
                    {"i": ev_id}).fetchone()
    if not r: return []
    bundle, started, log = r
    arr = json.loads(log)
    out = []
    prev_clear = started
    acc = ""                       # 自上次 box-reset 起累积的 CJK 内容(供 type-B)
    for i, e in enumerate(arr):
        kind = e.get("kind"); content = cv(e.get("text", "") or "")
        if kind == "commit":
            if is_ph(content): acc = ""               # 占位符回归 = 框被重置
            else: acc += "".join(c for c in content if has_cjk(c) or c in "，。！？、…+")
            continue
        if kind != "delete": continue
        # type-A:CJK 实质内容被删(真清空)。拼音预编辑 delete(latin)不算清空、不重置累积。
        if has_cjk(content) and len(content) >= 2 and not is_ph(content):
            ts = e.get("ts")
            if ts is not None:
                nxt = arr[i + 1] if i + 1 < len(arr) else None
                nxt_txt = cv(nxt.get("text", "") or "") if nxt else ""
                out.append(_sig(bundle, ev_id, content, ts, prev_clear,
                                nxt_txt, nxt is not None, tail_backspaces(bundle, ts)))
                prev_clear = ts
            acc = ""                                   # 真清空才重置累积
    # type-B:event 末尾仍有未清空的 CJK 累积,且最后动作是 commit(非 delete/占位符)
    if arr and arr[-1].get("kind") == "commit" and not is_ph(cv(arr[-1].get("text", ""))) and len(acc) >= 2:
        ts = arr[-1].get("ts")
        if ts is not None:
            out.append(_sig(bundle, ev_id, acc, ts, prev_clear, "", False, 0))
    return out

def pick(ev_id, content):
    for c in box_clears(ev_id):
        if c["content"] == content: return c
    return None

# ---- 标注用例(三分判据,期望等级)----
#  · confirmed_sent:有回车的真发送(Discord 我今天早上5;claude RET 发送)
#  · probable_sent: clean 一次性清空、无回车的真发送(IME 回车竞速,OCR 已证发送)
#  · confirmed_draft:退格抹除的草稿(OCR 已证蒸发,可以试试/删老/你跳过)
LABELED = [
    ("sent_RET_discord_我今天早上5", 523, "我今天早上5", "confirmed_sent"),
    ("draft_可以试试", 641, "可以试试", "confirmed_draft"),
    ("draft_删老", 635, "删老", "confirmed_draft"),
    ("draft_你跳过", 635, "你跳过", "confirmed_draft"),
]
# clean-clear 真发送正样本:取各 event 最长内容那条框清空(=主消息发送)
CLEAN_SENT_EVENTS = [907, 423, 790]

out = {"labeled": [], "draft_negatives": []}
for name, ev, content, exp in LABELED:
    c = pick(ev, content)
    if c: out["labeled"].append(dict(c, name=name, expected=exp))
    else: print(f"⚠️ 没找到 {name} ({content!r} in ev{ev})")

for ev in CLEAN_SENT_EVENTS:
    cs = box_clears(ev)
    cs = [c for c in cs if c["ocr_label"] == "sent" or has_cjk(c["content"])]
    if not cs: print(f"⚠️ ev{ev} 无框清空"); continue
    c = max(cs, key=lambda x: x["content_len"])
    out["labeled"].append(dict(c, name=f"clean_sent_ev{ev}", expected="probable_sent"))

# ---- 草稿负样本:全库 claude 扫,OCR 确认 draft 且 delete_pattern=backspace_erase ----
seen = {(c["ev_id"], c["content"]) for c in out["labeled"]}
neg = []
for (ev,) in con.execute("SELECT id FROM typing_events WHERE bundle_id='com.anthropic.claudefordesktop' ORDER BY id"):
    for c in box_clears(ev):
        if c["ocr_label"] != "draft": continue
        if c["delete_pattern"] != "backspace_erase": continue
        k = (c["ev_id"], c["content"])
        if k in seen: continue
        seen.add(k); neg.append(c)
out["draft_negatives"] = neg

os.makedirs(os.path.join(os.path.dirname(__file__), "fixtures"), exist_ok=True)
path = os.path.join(os.path.dirname(__file__), "fixtures", "send_signals.json")
json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
print(f"导出:labeled {len(out['labeled'])} 条,draft_negatives {len(out['draft_negatives'])} 条 → {path}")
for c in out["labeled"]:
    print(f"  {c['name']}: pattern={c['delete_pattern']} return={c['return_key']} "
          f"ph={c['physical_key_support']} ocr={c['ocr_label']} 期望={c['expected']}")
