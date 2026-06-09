#!/usr/bin/env python3
"""阶段三 · 占位符规则(规范 §4)。

§4.1 两级:
  - known_placeholder:明确配置/人工确认的占位符。
  - learned_placeholder:自动发现的候选。**第一版只审计,不参与发送/删除/最终记录判断**。
§4.2 known 规则:
  - 占位符 + 无物理击键 + app 注入态 → 删(delete_placeholder)
  - 占位符 + 有物理击键 + 有发送证据 → 保留为用户真实输入(keep_user_input)【例外保护】
  - 证据冲突 → unknown,留 staged 待审计(unknown_audit)
#44/#45 修复:占位符检测**靠"是占位符串 + 无物理击键"判 app 注入,不分 commit/paste**
  (旧 bug:phMarkers 只认 paste,漏了 commit 注入的占位符 → 泄漏);
  且占位符**整体删或整体留,绝不剥前缀造「他说X」**。
"""
from enum import Enum
from evidence import AuthorEvidence

# §4.1 known 占位符配置(权威来源)
KNOWN_PLACEHOLDERS = (
    "Write a message",
    "Type / for commands",
    "Describe a task or ask a question",
    "Reply to",                       # 常见聊天占位
    "Message",
)

def is_known_placeholder(text: str) -> bool:
    """文本是否命中 known 占位符(子串匹配——占位符常带省略号/换行尾巴)。"""
    t = (text or "")
    return any(p in t for p in KNOWN_PLACEHOLDERS)


class PlaceholderDecision(str, Enum):
    not_placeholder = "not_placeholder"      # 不是占位符串 → 正常走发送判定
    delete_placeholder = "delete_placeholder"  # app 注入占位符 → 删除,不记录
    keep_user_input = "keep_user_input"      # 用户真打了占位符串并发送 → 保留(例外)
    unknown_audit = "unknown_audit"          # 证据冲突 → 留 staged 待审计,不删


def placeholder_decision(text: str, author: AuthorEvidence, has_send_evidence: bool) -> PlaceholderDecision:
    """§4.2 known 占位符决策。author 来自 author_evidence_from_entry。"""
    if not is_known_placeholder(text):
        return PlaceholderDecision.not_placeholder
    # 是 known 占位符串:
    if author.app_injected and not author.physical_key_backed:
        return PlaceholderDecision.delete_placeholder       # 无击键的注入态 → 删
    if author.physical_key_backed and has_send_evidence:
        return PlaceholderDecision.keep_user_input          # 例外:用户真打 + 发送 → 留
    return PlaceholderDecision.unknown_audit                # 冲突/不足 → 待审计


def apply_placeholder_filter(text: str, decision: PlaceholderDecision) -> str:
    """#44/#45 不变量:占位符**整体删或整体留**,绝不剥前缀造「他说X」。
    返回最终文本:删→空串;留/非占位符→原文(逐字不动);待审计→原文(标记另行处理,不在此改文)。"""
    if decision == PlaceholderDecision.delete_placeholder:
        return ""                       # 整体删除,不留任何片段、不造「他说」
    return text                         # keep/unknown/not_placeholder:原文不动(绝不剥前缀)


# ---- learned placeholder:第一版只审计,不改判定 ----
def learned_placeholder_candidates(injected_texts) -> list:
    """从"无击键注入态文本"中发现疑似占位符候选(复现 ≥2 次、非 known)。
    **纯审计输出**:返回候选列表,不喂给 placeholder_decision、不影响任何最终结果。
    injected_texts: 各事件里 app 注入(无击键)的文本列表。"""
    import collections
    cnt = collections.Counter(t for t in injected_texts if t and not is_known_placeholder(t))
    return sorted([{"text": t, "count": n} for t, n in cnt.items() if n >= 2],
                  key=lambda x: -x["count"])
