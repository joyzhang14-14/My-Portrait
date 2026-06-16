"""确定性技术锚点采集 —— 小模型(Qwen3-4B)抽象式摘要会丢逐字锚点
(commit 哈希/文件名/chunk-ID/行号),实测调 prompt 救不回(0/12)。

改用正则从 OCR 直接采集这些**非敏感**锚点,拼到 digest 尾部,保证不丢。
和 chrome.py(去噪)/redact.py(脱敏)同一思路:确定性、模型无关、可单测。

policy:只采集明确非敏感的技术锚点(代码符号/文件/commit/数字ID/版本)。
不碰 PII(那是 redact 的活);纯数字串(疑似地址/卡号/时间戳)不当 commit。
"""
import re

# 源码文件名:Foo.swift / bar.py / config.toml …
_FILE = re.compile(r"\b[A-Za-z_]\w*\.(?:swift|py|ts|tsx|js|rs|go|md|json|toml|sql|h|mm?)\b")
# git 短哈希:7-40 位 hex,且**同时含字母和数字**(排除纯数字时间戳/地址)
_HASH = re.compile(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b")
# 数字 ID:chunk/event/frame/line/row 3402 之类
_IDNUM = re.compile(r"\b(?:chunk|event|frame|line|row|issue|pr)\s*#?\s*\d{2,}\b", re.I)
# 语义版本:1.2.95 / v3.0.1
_VER = re.compile(r"\bv?\d+\.\d+\.\d+\b")
# CamelCase 代码符号 + 常见后缀(AnalyticsService/AudioError/TimelineSidebar…)
_SYMBOL = re.compile(r"\b[A-Z][A-Za-z0-9]*(?:Service|Worker|Agent|Manager|Model|"
                     r"View|ViewModel|Controller|Error|Store|Card|Sidebar|Header|"
                     r"Card|Pipeline|Scheduler|Handler|Provider|Engine)\b")

_PATS = [_FILE, _HASH, _IDNUM, _VER, _SYMBOL]

_HEX = re.compile(r"^[0-9a-f]{7,40}$")


def _is_hash(tok: str) -> bool:
    t = tok.lower()
    return bool(_HEX.match(t)) and any(c.isalpha() for c in t) and any(c.isdigit() for c in t)


def _twin_hashes(tokens):
    """OCR 双胞胎 hash:同一 session 里同长、且只差 1-2 位的两个 hex,必是同一
    commit 的 OCR 重影(如 6a238053/6a238853)。无法判哪个对 → 两个都删
    (发错 commit hash 比不发更坏,用户照它去 git 找会扑空)。"""
    hs = [t for t in tokens if _is_hash(t)]
    bad = set()
    for i in range(len(hs)):
        for j in range(i + 1, len(hs)):
            a, b = hs[i].lower(), hs[j].lower()
            if a != b and len(a) == len(b) and sum(x != y for x, y in zip(a, b)) <= 2:
                bad.add(hs[i]); bad.add(hs[j])
    return bad


def harvest(ocr: str, limit: int = 8):
    """从 OCR 采集去重后的技术锚点列表(保留出现顺序)。无锚点返回 []。"""
    if not ocr:
        return []
    out, seen = [], set()
    for pat in _PATS:
        for m in pat.finditer(ocr):
            tok = m.group(0).strip()
            key = tok.lower()
            if key not in seen:
                seen.add(key)
                out.append(tok)
    bad = _twin_hashes(out)
    if bad:
        out = [t for t in out if t not in bad]
    return out[:limit]
