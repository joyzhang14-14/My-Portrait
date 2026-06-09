#!/usr/bin/env python3
"""阶段一 · 发送证据与消息边界状态机。

规范:`算法-改进版.md` §2(2026-06 对抗工作流校准版)。
核心判据 = **清空机制三分**(不是占位符 reset,草稿退光也出占位符):
  - return_key(宽窗)           → confirmed_sent
  - backspace_erase(整条退光)  → confirmed_draft
  - clean_clear(一次性清空)    → probable_sent(IME 回车竞速的无回车真发送兜底,§4.3)
判据由 461 条真发送 OCR 验证 + 8 例 head-to-head 坐实(见规范 §2.3 / 阻塞与决策)。
第一版不用语义模型判边界。
"""
from dataclasses import dataclass
from enum import Enum
from typing import List, Optional
from evidence import Delivery, DeliveryConfidence


# ---- 内部发送等级 ----
class DeliveryLevel(str, Enum):
    confirmed_sent = "confirmed_sent"
    probable_sent = "probable_sent"
    confirmed_draft = "confirmed_draft"
    unknown = "unknown"


# ---- 原始信号(可序列化,便于 fixture 断言)----
@dataclass
class SendSignals:
    is_chat_surface: bool
    return_key: bool                          # 宽窗[clear-3s, clear+0.5s]内有 plain 回车
    reset_to_known_placeholder: bool          # 清空后紧邻 known 占位符
    reset_to_empty: bool                      # 框变空
    next_session_transition_reliable: bool    # 下一事件从空框/占位符开始
    delete_pattern: str                       # backspace_erase | clean_clear(见 classify_delete_pattern)
    physical_key_support: bool                # 足够物理击键 = 用户输入
    content_len: int = 0
    n_nonbs_keys: int = 0
    tail_backspaces: int = 0                  # 紧贴清空时刻的尾部连续退格数(抹除动作)
    ts: Optional[int] = None


# ---- 术语落成函数(规范 §2.4,fixture 校准)----
CHAT_BUNDLE_KEYWORDS = ("discord", "slack", "messages", "mobilesms", "ichat",
                        "claudefordesktop", "wechat", "telegram", "whatsapp", "qq")

def is_chat_input_surface(bundle_id: str) -> bool:
    """聊天输入框(发送=框清空)。首版:已知聊天 app bundle 关键词匹配。"""
    b = (bundle_id or "").lower()
    return any(k in b for k in CHAT_BUNDLE_KEYWORDS)

def has_sufficient_physical_key_support(content_len: int, n_nonbs_keys: int) -> bool:
    """够多物理击键 = 用户亲手打(区别 app 注入/粘贴 ≈ 0 击键)。
    CJK 走拼音通常 ≥ 字数;占位符/粘贴 ≈ 0 → 失败。AX 截断时 content_len 偏小,故只要求 ≥ content_len。"""
    if content_len <= 0:
        return n_nonbs_keys >= 2
    return n_nonbs_keys >= content_len

def classify_delete_pattern(content_len: int, tail_backspaces: int) -> str:
    """规范 §2.3/§2.4:区分「连续退格抹除」与「一次性整框清空」。
    - backspace_erase:尾部连续退格数 ≥ 被清空内容长度(用户把整条手动退光)→ 草稿
    - clean_clear:    内容凭空消失(尾部退格 < 内容长,app 发送时清空了框)→ 发送
    校准:可以试试 bs5/len4、删老 bs3/2、你跳过 bs3/3 = erase;ev907/423/790 tail_bs0 = clean。"""
    if content_len <= 0:
        return "backspace_erase" if tail_backspaces >= 2 else "clean_clear"
    return "backspace_erase" if tail_backspaces >= content_len else "clean_clear"

def is_reliable_session_transition(next_session_start_empty: bool,
                                   next_session_start_is_known_ph: bool) -> bool:
    """下一事件起始是否构成可靠边界。首版:下一事件从空框 或 known 占位符开始。"""
    return bool(next_session_start_empty or next_session_start_is_known_ph)


# ---- 状态机(纯函数 of signals)----
def classify_delivery(s: SendSignals) -> (DeliveryLevel, List[str]):
    """规范 §2.3 三分决策规则。返回 (等级, 触发的证据信号名列表)。"""
    ev = []
    if s.is_chat_surface: ev.append("is_chat_surface")
    if s.return_key: ev.append("return_key")
    if s.reset_to_known_placeholder: ev.append("reset_to_known_placeholder")
    if s.reset_to_empty: ev.append("reset_to_empty")
    if s.next_session_transition_reliable: ev.append("next_session_transition_reliable")
    if s.physical_key_support: ev.append("physical_key_support")
    ev.append(f"delete_pattern={s.delete_pattern}")

    reset_ok = (s.reset_to_known_placeholder or s.reset_to_empty
                or s.next_session_transition_reliable)
    # ① confirmed_sent:聊天框 + 击键背书 + 回车(宽窗) + 框被重置
    if s.is_chat_surface and s.physical_key_support and s.return_key and reset_ok:
        return DeliveryLevel.confirmed_sent, ev
    # ② confirmed_draft:无回车 + 退格抹除(整条退光)。占位符出不出都不影响。
    #    (保证「24 草稿误收=0」:删老退光后也出占位符,但 delete_pattern=backspace_erase → draft)
    if (not s.return_key) and s.delete_pattern == "backspace_erase":
        return DeliveryLevel.confirmed_draft, ev
    # ③ probable_sent(无回车兜底,§4.3):无回车 + clean 一次性清空 + 击键背书 + 框被重置
    if ((not s.return_key) and s.delete_pattern == "clean_clear"
            and s.physical_key_support
            and (s.reset_to_known_placeholder or s.reset_to_empty)):
        return DeliveryLevel.probable_sent, ev
    return DeliveryLevel.unknown, ev


def to_delivery(level: DeliveryLevel) -> (Delivery, DeliveryConfidence):
    """对外映射,保留强弱(probable 不压成 confirmed)。"""
    return {
        DeliveryLevel.confirmed_sent:  (Delivery.sent,  DeliveryConfidence.confirmed),
        DeliveryLevel.probable_sent:   (Delivery.sent,  DeliveryConfidence.probable),
        DeliveryLevel.confirmed_draft: (Delivery.draft, DeliveryConfidence.confirmed),
        DeliveryLevel.unknown:         (Delivery.unknown, DeliveryConfidence.unknown),
    }[level]


def detect_confirmed_message_boundaries(classified: List[tuple]) -> List[int]:
    """已确认消息边界 = confirmed_sent 的 ts(供 §四 验证器「不跨边界」)。
    classified: [(level, SendSignals)]。仅 confirmed_sent 构成边界,probable/draft/unknown 不构成。"""
    out = []
    for level, sig in classified:
        if level == DeliveryLevel.confirmed_sent and sig.ts is not None:
            out.append(sig.ts)
    return sorted(out)
