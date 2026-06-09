#!/usr/bin/env python3
"""阶段六 · Canvas 约束(规范 §7.2)。Canvas 是唯一允许云端的路径,但约束严格。

- 跨 app 合池**只用于候选发现**,不能当文本来源。
- 新增内容需要:帧间连续编辑演进 + 对应击键/编辑行为 + 可靠文档身份(三者齐)。
- **不用最长 OCR 帧直接补尾**。
- **不绕过 Canvas 专用 Pass4**。
- 使用与 AX 一致的 `EvidenceResult` 数据契约。
- 架构:AX 稳定后再处理 Canvas,Canvas 不混入 AX 修复(本模块独立于 signals/recon)。
"""

def canvas_new_content_allowed(evidence: dict) -> bool:
    """Canvas 新增内容的证据门槛:帧间编辑演进 + 击键/编辑行为 + 可靠文档身份,三者缺一不可。"""
    return bool(evidence.get("frame_evolution")
                and evidence.get("keystroke_or_edit")
                and evidence.get("reliable_doc_identity"))

def validate_canvas_record(record: dict):
    """对一条 Canvas 记录做约束校验。返回 (ok: bool, violations: [str])。"""
    v = []
    if record.get("source_method") == "longest_ocr_frame":
        v.append("禁止用最长 OCR 帧直接补尾")
    if record.get("cross_app_pool_role") not in (None, "candidate_discovery"):
        v.append("跨 app 合池只能做候选发现,不能当文本来源")
    if record.get("is_new_content") and not canvas_new_content_allowed(record.get("evidence", {})):
        v.append("新增内容缺证据(帧演进/击键/文档身份 三者需齐)")
    if not record.get("canvas_pass4_done"):
        v.append("未经 Canvas 专用 Pass4(不得绕过)")
    if not record.get("uses_evidence_result_contract"):
        v.append("未用统一 EvidenceResult 数据契约")
    return (len(v) == 0, v)
