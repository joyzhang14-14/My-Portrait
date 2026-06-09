#!/usr/bin/env python3
"""阶段二 · fixture 脱敏 + 结构一致性校验 + 读取器。

脱敏(§3.2):逐字符类**双射**——CJK→CJK、拼音/英文小写→小写、大写→大写、数字→数字;
占位符(KNOWN_PH)、标点、空白、操作 kind、时间戳一律**保留**。全局一份映射(跨 case 一致),
故相同文本映射相同 → 保住相等关系/复现次数/前缀/长度/字母顺序/拼音-汉字结构。

结构一致性(§3.2 八类不变量)由 structure_signature 落成可比签名;脱敏前后签名必须相等。
优先非敏感真实案例 as_is 原样保存;仅敏感 case 走 bijection。
"""
import json

ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
KNOWN_PH = ("Write a message", "Type / for commands", "Describe a task or ask a question")
def is_ph(t): return any(p in (t or "") for p in KNOWN_PH)

def char_class(c):
    o = ord(c)
    if '一' <= c <= '鿿': return "C"          # CJK
    if 'a' <= c <= 'z': return "l"            # 小写(拼音/英文)
    if 'A' <= c <= 'Z': return "U"
    if c.isdigit(): return "d"
    if c.isspace() or o in ZW: return "s"
    return "p"                                # 标点/其它(保留)

# ---- 脱敏:逐字符类双射 ----
# 字母/数字用固定置换(rot13 / +5),与数据无关、绝不退化成 identity('gmail' 不泄漏);
# CJK 字符多,用数据驱动的排序索引映射到 '一'+i(紧凑乱码、保证单射)。
def _rot13(c): return chr((ord(c) - 97 + 13) % 26 + 97) if 'a' <= c <= 'z' else \
                      (chr((ord(c) - 65 + 13) % 26 + 65) if 'A' <= c <= 'Z' else c)
def _shift_digit(c): return chr((ord(c) - 48 + 5) % 10 + 48) if c.isdigit() else c

def build_mapping(texts):
    """只为 CJK 构造数据驱动双射(字母/数字走固定 rot,不需映射表)。"""
    cjk = set()
    for t in texts:
        for c in (t or ""):
            if char_class(c) == "C": cjk.add(c)
    return {c: chr(ord('一') + (i % 0x4000)) for i, c in enumerate(sorted(cjk))}

def deidentify_char(c, mapping):
    cl = char_class(c)
    if cl == "C": return mapping.get(c, c)
    if cl in ("l", "U"): return _rot13(c)
    if cl == "d": return _shift_digit(c)
    return c                                   # 标点/空白/ZW 保留

def deidentify_text(t, mapping):
    if t is None: return None
    for ph in KNOWN_PH:
        if ph in t: return t                   # 含 known 占位符整串保留(占位符是结构,非敏感)
    return ''.join(deidentify_char(c, mapping) for c in t)

def deidentify_case(case, mapping):
    """对一个 case 的所有文本字段做双射脱敏(ts/kind/app 分组结构不动,app/url 单独处理)。"""
    if case.get("deid") == "as_is":
        return dict(case)
    out = json.loads(json.dumps(case))   # deep copy
    for e in out.get("edit_log", []):
        e["text"] = deidentify_text(e.get("text"), mapping)
    for k in out.get("keystroke_log", []):
        if k.get("char"):
            k["char"] = deidentify_char(k["char"], mapping)
    for fld in ("expected_output",):
        if out.get(fld): out[fld] = deidentify_text(out[fld], mapping)
    out["must_not_exist"] = [deidentify_text(x, mapping) for x in out.get("must_not_exist", [])]
    return out

# ---- 结构签名(§3.2 八类不变量)----
def _cover_ratio(deleted, commits_concat):
    import difflib
    if not deleted or not commits_concat: return 0.0
    m = difflib.SequenceMatcher(None, deleted, commits_concat, autojunk=False)
    return round(sum(b.size for b in m.get_matching_blocks()) / len(deleted), 3)

def structure_signature(case):
    """返回不依赖具体字符、只反映结构的签名(脱敏前后应相等)。"""
    arr = case.get("edit_log", [])
    texts = [cv(e.get("text", "") or "") for e in arr]
    kinds = [e.get("kind") for e in arr]
    # ④ 相等关系 + 复现次数:文本按首现编号(同文→同号)
    ids, idmap = [], {}
    for t in texts:
        if t not in idmap: idmap[t] = len(idmap)
        ids.append(idmap[t])
    # ①②③ 拼音-汉字候选/字母顺序/长度前缀:每条文本的字符类掩码 + 长度;前缀对矩阵
    classmask = ["".join(char_class(c) for c in t) for t in texts]
    lens = [len(t) for t in texts]
    distinct = sorted(idmap, key=lambda t: idmap[t])
    prefix_pairs = sorted((idmap[a], idmap[b]) for a in distinct for b in distinct
                          if a != b and b.startswith(a) and a)
    # ⑤ 操作结构 + 覆盖比例(排除占位符 entry——app 注入标记,deid 保留原样,不参与内容覆盖)
    commits_concat = "".join(t for t, k in zip(texts, kinds) if k == "commit" and not is_ph(t))
    covers = [_cover_ratio(t, commits_concat) for t, k in zip(texts, kinds)
              if k == "delete" and not is_ph(t)]
    # ⑥ 事件时间差
    tss = [e.get("ts") for e in arr if e.get("ts") is not None]
    deltas = [tss[i] - tss[i - 1] for i in range(1, len(tss))]
    # ⑦ app/url/输入框分组(身份本身可脱敏,但分组结构=是否同组要保;此处记类别串)
    grouping = (bool(case.get("app")), bool(case.get("url")), case.get("surface"))
    # ⑧ 跨事件状态演进:box 值长度演进(commit 加、delete 抹的长度序列)
    evolution = []
    box = 0
    for t, k in zip(texts, kinds):
        if k == "commit": box += len(t)
        elif k == "delete": box = max(0, box - len(t))
        evolution.append(box)
    return {
        "kinds": kinds, "ids": ids, "classmask": classmask, "lens": lens,
        "prefix_pairs": prefix_pairs, "covers": covers, "deltas": deltas,
        "grouping": list(grouping), "evolution": evolution,
    }

def check_structure_preserved(original, deid):
    """脱敏前后结构签名必须逐项相等。返回 (ok, 第一处不一致的键 或 None)。"""
    so, sd = structure_signature(original), structure_signature(deid)
    for key in so:
        if so[key] != sd[key]:
            return False, key
    return True, None

# ---- fixture 读取器 / 校验器 ----
REQUIRED_FIELDS = ("id", "category", "deid", "app", "surface", "time_bounds",
                   "edit_log", "keystroke_log", "expected_delivery",
                   "expected_delivery_confidence", "expected_boundaries", "must_not_exist")

def validate_fixture(case):
    """检查 fixture 含 §3.1 最低字段;缺失返回错误列表。"""
    errs = []
    for f in REQUIRED_FIELDS:
        if f not in case: errs.append(f"缺字段 {f}")
    if "edit_log" in case and not isinstance(case["edit_log"], list):
        errs.append("edit_log 必须是列表")
    return errs

def load_fixtures(path):
    data = json.load(open(path))
    return data["cases"] if isinstance(data, dict) and "cases" in data else data
