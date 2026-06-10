#!/usr/bin/env python3
"""输入方案抽象层 —— 所有语言/方案特定知识从**部署的 rime 方案词库**运行时提取,代码零语言表。
换方案(五笔/双拼/日语/韩语)= 换 rime 数据目录(环境变量 PORTRAIT_RIME_DIR / PORTRAIT_RIME_DICTS),
提取逻辑不变:rime 词库统一 TSV 格式「输出词 \t 编码 \t 权重」,对任何方案都成立:
  - 编码单元表 = 第2列空格分隔单元去重(拼音音节/双拼码/五笔码/罗马字)
  - 输出字符集 = 第1列字符(汉字/假名/谚文)—— 判"这个字是不是本输入法能打出来的"
  - 单元完整性 = 是否在单元表里(替代 'aeiouv' 这类拼音硬编码)
"""
import os, glob, functools

_HERE = os.path.dirname(os.path.abspath(__file__))
RIME_DIR = os.environ.get("PORTRAIT_RIME_DIR") or os.path.join(_HERE, "rime")
DICT_GLOB = os.environ.get("PORTRAIT_RIME_DICTS") or os.path.join(RIME_DIR, "ice", "cn_dicts", "*.dict.yaml")


@functools.lru_cache(maxsize=1)
def _scan():
    units, out_chars = set(), set()
    for f in glob.glob(DICT_GLOB):
        try:
            fh = open(f, encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and parts[1]:
                word, code = parts[0], parts[1]
                if any(ch.isascii() and ch.isalpha() for ch in code):
                    out_chars.update(ch for ch in word if not ch.isascii())
                    for u in code.split():
                        if u.isalpha():
                            units.add(u.lower())
    return frozenset(units), frozenset(out_chars)


def valid_units():
    """当前方案全部合法编码单元(拼音 413 音节 / 五笔码 / 罗马字…)。"""
    return _scan()[0]

def is_output_char(ch):
    """该字符是否本输入方案能产出(汉字/假名/谚文,按词库第1列)。"""
    return ch in _scan()[1]

def is_complete_unit(s):
    """编码单元是否完整(替代拼音 'aeiouv' 硬编码:a/e/o 是合法单元,i/u/v/g/x 不是——词库说了算)。"""
    return bool(s) and s.lower() in _scan()[0]

@functools.lru_cache(maxsize=4096)
def units_with_prefix(p):
    """以 p 开头的真实编码单元(前缀松弛:yo→yo/you/yong),短的优先。"""
    return tuple(sorted((s for s in valid_units() if s.startswith(p.lower())), key=len))


@functools.lru_cache(maxsize=1)
def char_units():
    """字 → 编码单元集(单字词条提取:8105 等字表每行「字\t拼音」)。多音字=集合。
    用于拼音空间查重(肯/啃 同音双胞胎)。零硬编码,随部署方案词库走。"""
    m = {}
    for f in glob.glob(DICT_GLOB):
        try:
            fh = open(f, encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and len(parts[0]) == 1 and not parts[0].isascii() and parts[1]:
                u = parts[1].strip().lower()
                if u.isalpha():
                    m.setdefault(parts[0], set()).add(u)
    return {k: frozenset(v) for k, v in m.items()}
