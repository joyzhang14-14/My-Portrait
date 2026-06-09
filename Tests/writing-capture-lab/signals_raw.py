#!/usr/bin/env python3
"""阶段二 · 纯函数信号提取(不碰 DB)。
从一个 case 的原始 edit_log + 击键窗口重建 SendSignals,供离线 fixture 测试 + 活库导出共用,
保证「测试不依赖活数据库」且导出/测试两路逻辑不分叉。
击键 keystrokes = [{ts, char, is_backspace, modifiers}, ...](同一 bundle,event 附近窗口)。
"""
import json
from signals import (is_chat_input_surface, has_sufficient_physical_key_support,
                     classify_delete_pattern)

ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def has_cjk(s): return any('一' <= c <= '鿿' for c in s)
KNOWN_PH = ("Write a message", "Type / for commands", "Describe a task or ask a question")
def is_ph(t): return any(p in (t or "") for p in KNOWN_PH)


def _win(keystrokes, t0, t1):
    return [k for k in keystrokes if t0 <= k["ts"] <= t1]

def return_in_window(keystrokes, clear_ts):
    # 纯回车(modifiers==0)才是发送;Shift+Return(md=8)=换行、Cmd+Return(md=1)另算,均排除。
    for k in _win(keystrokes, clear_ts - 3000, clear_ts + 500):
        if (not k["is_backspace"]) and k["char"] in ("\n", "\r") and k["modifiers"] == 0:
            return True
    return False

def tail_backspaces(keystrokes, clear_ts):
    ks = _win(keystrokes, clear_ts - 8000, clear_ts + 200)
    n = 0
    for k in reversed(ks):
        if k["is_backspace"]: n += 1
        elif k["char"]: break
    return n

def nonbs_keys(keystrokes, t0, t1):
    return sum(1 for k in _win(keystrokes, t0, t1)
               if (not k["is_backspace"]) and k["char"] and (k["modifiers"] & 7) == 0)


def _sig(app, content, ts, prev_clear, nxt_txt, nxt_exists, tbs, keystrokes):
    clen = len(content)
    nbs = nonbs_keys(keystrokes, prev_clear, ts)
    return {
        "is_chat_surface": is_chat_input_surface(app),
        "return_key": return_in_window(keystrokes, ts),
        "reset_to_known_placeholder": is_ph(nxt_txt),
        "reset_to_empty": (not nxt_exists) or (cv(nxt_txt) == ""),
        "next_session_transition_reliable": not nxt_exists,
        "delete_pattern": classify_delete_pattern(clen, tbs),
        "physical_key_support": has_sufficient_physical_key_support(clen, nbs),
        "content_len": clen, "n_nonbs_keys": nbs, "tail_backspaces": tbs, "ts": ts,
        "content": content,
    }

def box_clears_from_raw(edit_log, keystrokes, app, started):
    """纯函数版 box_clears(见 extract_fixtures.box_clears 注释)。
    两类边界:A 显式 CJK 清空(退格删=草稿 或 AX 抓到的发送清空);B event 末尾隐式 clean 发送。"""
    arr = edit_log
    out = []
    prev_clear = started
    acc = ""
    for i, e in enumerate(arr):
        kind = e.get("kind"); content = cv(e.get("text", "") or "")
        if kind == "commit":
            if is_ph(content): acc = ""
            else: acc += "".join(c for c in content if has_cjk(c) or c in "，。！？、…+")
            continue
        if kind != "delete": continue
        if has_cjk(content) and len(content) >= 2 and not is_ph(content):
            ts = e.get("ts")
            if ts is not None:
                nxt = arr[i + 1] if i + 1 < len(arr) else None
                nxt_txt = cv(nxt.get("text", "") or "") if nxt else ""
                out.append(_sig(app, content, ts, prev_clear, nxt_txt, nxt is not None,
                                tail_backspaces(keystrokes, ts), keystrokes))
                prev_clear = ts
            acc = ""
    if arr and arr[-1].get("kind") == "commit" and not is_ph(cv(arr[-1].get("text", ""))) and len(acc) >= 2:
        ts = arr[-1].get("ts")
        if ts is not None:
            out.append(_sig(app, acc, ts, prev_clear, "", False, 0, keystrokes))
    return out
