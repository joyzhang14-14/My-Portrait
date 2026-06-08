#!/usr/bin/env python3
"""阶段零 · 最终数据契约(EvidenceResult / AuthorEvidence)+ 各状态固定下游行为。

规范来源:`~/Desktop/写作采集/算法-改进版.md`(v5 执行规范)§1。
铁律:
- text 可选:complete/partial 必有证据文本;unrecoverable 必为空(不生成正文)。
- verification_passed ≠ completeness(分别计算)。
- author_evidence 多信号共存(不用单选枚举丢证据)。
- delivery_confidence 保留 confirmed/probable/unknown 强弱(不把 probable 压成 sent)。
- pass4_status 含 review_failed / not_applicable;失败不误收、不删 staged。
"""
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, List


class Completeness(str, Enum):
    complete = "complete"            # 有完整性证据
    partial = "partial"              # 真内容,但有缺失/只部分过验证
    unrecoverable = "unrecoverable"  # 证实发生写作,但无足够文本(text 必空)


class Delivery(str, Enum):
    sent = "sent"
    draft = "draft"
    unknown = "unknown"


class DeliveryConfidence(str, Enum):
    confirmed = "confirmed"
    probable = "probable"
    unknown = "unknown"


class Pass4Status(str, Enum):
    accepted = "accepted"
    rejected = "rejected"
    review_failed = "review_failed"      # 调用/解析失败/记录未覆盖
    not_applicable = "not_applicable"


@dataclass
class AuthorEvidence:
    """作者证据:多信号共存。commit 不等于作者(占位符也是 commit)。"""
    physical_key_backed: bool = False   # 足够物理击键 = 强用户输入证据
    commit_backed: bool = False         # 有 commit,但来源仍需判
    paste_detected: bool = False
    app_injected: bool = False          # 占位符/无击键整块跳变 → 倾向 app 注入
    unknown_origin: bool = False

    def is_user_authored(self) -> bool:
        """能否作为"用户亲手写"保留:physical_key_backed 强证据,或 commit 但非 app 注入。"""
        if self.app_injected:
            return False
        if self.physical_key_backed:
            return True
        # 只 commit 缺物理击键 → 不能单独证明是用户写作
        return False


@dataclass
class EvidenceResult:
    completeness: Completeness
    delivery: Delivery
    delivery_confidence: DeliveryConfidence
    author_evidence: AuthorEvidence
    text: Optional[str] = None                       # 可选!见 __post_init__
    delivery_evidence: List[str] = field(default_factory=list)
    verification_passed: bool = False                # ≠ completeness
    pass4_status: Pass4Status = Pass4Status.not_applicable
    confidence: float = 0.0
    evidence_event_ids: List[int] = field(default_factory=list)
    evidence_key_ranges: List = field(default_factory=list)
    missing_reason: Optional[str] = None

    def __post_init__(self):
        # 铁律:unrecoverable 不生成正文;complete/partial 必有证据文本
        t = (self.text or "").strip()
        if self.completeness == Completeness.unrecoverable:
            if t:
                raise ValueError("unrecoverable 必须 text 为空(不生成正文)")
            self.text = None
        else:
            if not t:
                raise ValueError(f"{self.completeness.value} 必须有证据文本")


@dataclass
class Downstream:
    """一条记录的固定下游行为(§1.1 状态固定行为表)。"""
    in_staged: bool          # 是否留在 staged
    eligible_final: bool     # 是否有资格进入最终 writing_records(approve 后)
    pass4_action: str        # 'review' | 'not_applicable' | 'review_failed'
    in_style_analysis: bool  # 是否进入写作风格分析
    display_label: str       # 展示文案


def downstream_behavior(r: EvidenceResult) -> Downstream:
    """实现 §1.1 状态固定行为表。第一版保守,无"降权/排除"二选一、无"按产品规则"。"""
    # Pass4 失败:留 staged,标 review_failed,不进最终,不删
    if r.pass4_status == Pass4Status.review_failed:
        return Downstream(in_staged=True, eligible_final=False,
                          pass4_action="review_failed", in_style_analysis=False,
                          display_label="审查失败")

    if r.completeness == Completeness.unrecoverable:
        return Downstream(in_staged=True, eligible_final=False,
                          pass4_action="not_applicable", in_style_analysis=False,
                          display_label="发生过写作但无法恢复")

    if r.delivery == Delivery.draft:
        return Downstream(in_staged=True, eligible_final=False,
                          pass4_action="not_applicable", in_style_analysis=False,
                          display_label="草稿")

    if r.delivery == Delivery.unknown:
        return Downstream(in_staged=True, eligible_final=False,
                          pass4_action="not_applicable", in_style_analysis=False,
                          display_label="待确认")

    # 到这里 delivery == sent
    if r.completeness == Completeness.partial:
        return Downstream(in_staged=True, eligible_final=True,   # 进入但标记 partial
                          pass4_action="not_applicable",          # 不因残缺/不连贯删
                          in_style_analysis=False,                # partial 不进风格分析
                          display_label="不完整")

    # complete + sent:正常审查;只有 Pass4 accepted 才真正有资格进最终 + 风格分析
    accepted = (r.pass4_status == Pass4Status.accepted)
    return Downstream(in_staged=True, eligible_final=accepted,
                      pass4_action="review",
                      in_style_analysis=accepted,
                      display_label="正常")
