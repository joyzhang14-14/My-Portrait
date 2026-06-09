#!/usr/bin/env python3
"""阶段四 · 局部 patch schema + 模型输出解析(规范 §5.1)。

铁律:模型**只能提 patch**(局部修改 captured 骨架),不得整条替换。
模型自报来源 ≠ 证据;每个 patch 都要过 verifier.py 的确定性验证。
本文件只负责 schema/解析,不做任何信任判断。
"""
import json
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class Patch:
    replace_range: tuple                 # (start, end) in captured 骨架(end 独占)
    replacement_text: str
    operation: str                       # "inserted"(range 空) | "replaced"
    anchor_before: str = ""              # replace_range 前的骨架锚点文本
    anchor_after: str = ""               # replace_range 后的骨架锚点文本
    source_range: Optional[tuple] = None # 证据(击键索引)区间,供"重复消费"检测
    supporting_event_ids: List[int] = field(default_factory=list)
    supporting_commits: List[int] = field(default_factory=list)
    supporting_deletes: List[int] = field(default_factory=list)
    supporting_keystrokes: List[int] = field(default_factory=list)  # group.keystrokes 索引
    # 按 replacement 里 CJK 顺序对齐的逐字候选集(librime 对本 patch 源拼音 run 的解码结果)
    pinyin_candidates: List[set] = field(default_factory=list)

    def removed_text(self, skeleton: str) -> str:
        s, e = self.replace_range
        return skeleton[s:e]


def parse_patches(model_output) -> List[Patch]:
    """把模型输出(JSON 串 或 已解析 list/dict)解析成 Patch 列表。容错:坏项跳过。
    **不信任任何字段**——只做结构解析,合法性交给 verifier。"""
    if isinstance(model_output, str):
        try:
            model_output = json.loads(model_output)
        except json.JSONDecodeError:
            return []
    if isinstance(model_output, dict):
        model_output = model_output.get("patches", [])
    out = []
    for p in model_output or []:
        if not isinstance(p, dict):
            continue
        rng = p.get("replace_range")
        if not (isinstance(rng, (list, tuple)) and len(rng) == 2):
            continue
        src = p.get("source_range")
        out.append(Patch(
            replace_range=(int(rng[0]), int(rng[1])),
            replacement_text=str(p.get("replacement_text", "")),
            operation=p.get("operation", "replaced"),
            anchor_before=str(p.get("anchor_before", "")),
            anchor_after=str(p.get("anchor_after", "")),
            source_range=(tuple(src) if isinstance(src, (list, tuple)) and len(src) == 2 else None),
            supporting_event_ids=list(p.get("supporting_event_ids", [])),
            supporting_commits=list(p.get("supporting_commits", [])),
            supporting_deletes=list(p.get("supporting_deletes", [])),
            supporting_keystrokes=list(p.get("supporting_keystrokes", [])),
            pinyin_candidates=[set(x) for x in p.get("pinyin_candidates", [])],
        ))
    return out
