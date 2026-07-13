#!/usr/bin/env python3
"""击键锚定 OCR 对齐 —— 确定性,不跑模型(2026-07-13 用户设计的漏斗)。

**思路反转**:OCR 拍到的是**屏幕上真实显示的字**(用户上屏后的结果),它不是猜的;
librime 解码是**猜**的(候选序跟用户的输入法本来就不一样,实测 197 条只解对 62 = 31%)。
所以 OCR 该当**第一层真值**,librime 解码降级成**第二层**,只兜 OCR 抓不到的短碎片。

**但 OCR 不能单独当真值**:它拍的是"屏幕上的所有东西",不是"用户打的东西" —— canvas_B
审核栽过(把 ChatGPT 回复/网页简介/系统通知当成用户手打收进成品,违「只记手打」)。
所以必须**用击键锚定**:
  · 击键回答「用户打了什么」—— 打了哪些音节/数字/标点/英文,是不是手打
  · OCR 回答「那些字长什么样」—— 正确的汉字(治同音错字)
只有当 OCR 里存在一段文本、其**逐 token 对得上用户敲的东西**,才认定它就是用户打的那句话。
拼音 token 按**读音**匹配(`ime_schema.char_units()`,部署词库运行时提取,零硬编码,多音字=集合);
字面 token(数字/标点/英文)按**原样**匹配。宁缺毋错:匹配不上 → 返回 None,交第二层。
"""
import re
import rebuild as R
import ime_schema as SCH

HAN = re.compile(r'[一-鿿]')
MAX_GAP = 3          # 相邻 token 在 OCR 原文里的最大间隔(容 OCR 插入的空格,防跨屏乱拼)

# token: ('py', 音节) 按读音匹配 / ('lit', 字符) 按字面匹配
def event_tokens(seg):
    """击键段(已消化退格的 char 列表)→ token 序列。
    拼音 run → 逐音节 py token;英文 run / 数字 / 标点 → lit token(原样)。
    ⚠️不能只取拼音:用户打的数字(12-15)、标点(？)、英文都在屏幕上,漏掉它们就只能锚到半截
    (实测「12-15一直在客厅」只锚到「一直在客厅」)。"""
    toks, buf = [], ""
    def flush():
        nonlocal buf
        if not buf:
            return
        syls = R.commit_syls(buf)
        if syls:
            toks.extend(('py', s) for s in syls)
        else:
            toks.extend(('lit', c) for c in buf)      # 英文词 → 字面(gmail/api 屏幕上就是这样)
        buf = ""
    for ch in seg:
        if ch.isalpha():
            buf += ch
        elif ch.isdigit() and buf:
            flush()                                    # 选字数字 = 拼音收尾,数字本身不上屏
        elif ch.isdigit():
            toks.append(('lit', ch))                   # 无待选拼音 → 字面数字(12-15 / 10刀)
        elif ch.isprintable() and not ch.isspace():
            flush(); toks.append(('lit', ch))          # 标点原样上屏(？，。)
        elif ch.isspace():
            flush()                                    # 空格:不当 token(OCR 里空格不可靠)
    flush()
    return toks or None


def _match(ch, tok):
    """汉字 ch 的读音能不能对上 token。**完整音节优先:精确匹配**;只有残缺单元(简拼声母)才前缀匹配。

    ⚠️别对完整音节用前缀匹配 —— `na` 会吃掉 nai/nan/nao/nang 全家(360 个汉字),而「能」是多音字
    (有个读音 nai)→ `'nai'.startswith('na')` → 「能力」被 nali 锚中,真值「哪里」反被抢走(ev2684 实证)。
    精确匹配后 `na` 只认真读 na 的字。前缀匹配只留给简拼声母(zhongy 的 y → 要/也/一,这时确实只有声母)。"""
    kind, v = tok
    if kind == 'lit':
        return ch.lower() == v.lower()
    u = SCH.char_units().get(ch)
    if not u:
        return False
    if len(v) >= 2 and SCH.is_complete_unit(v):
        return v in u                                   # 完整音节(≥2 字母)→ **精确**
    # 单字母一律当简拼声母走前缀:`m` 虽然在词库里是个完整单元(读「呒」),但实际几乎全是简拼
    # (xiam = 下面 的 m)。若对它精确匹配 → 0 个汉字命中,整条锚不到。
    return any(r.startswith(v) for r in u)


def anchor(toks, ocr):
    """在 OCR 原文里找一段文本,**逐 token** 对上 toks。返回命中的原文(或 None)。
    token 之间允许小间隔(≤MAX_GAP,容 OCR 插的空格),不允许跨大段无关内容(防把两处屏幕文本拼一起)。"""
    if not toks or not ocr:
        return None
    n = len(toks)
    # 候选起点:能匹配第一个 token 的位置
    for i in range(len(ocr)):
        if not _match(ocr[i], toks[0]):
            continue
        j, k = 1, i                                     # k=上一个命中位置
        while j < n:
            nxt = None
            for p in range(k + 1, min(k + 2 + MAX_GAP, len(ocr))):
                # ⚠️gap 里**不许有汉字**:gap 会被一起圈进返回值,若混进没被击键匹配的汉字,
                # 就等于把「没手打的屏幕文字」捞进成品(违铁律)。gap 只容标点/空格/拉丁。
                if HAN.match(ocr[p]) and not _match(ocr[p], toks[j]):
                    break
                if _match(ocr[p], toks[j]):
                    nxt = p; break
            if nxt is None:
                break
            k = nxt; j += 1
        if j == n:
            return ocr[i:k + 1]
    return None


def resolve(con, bundle, t0, t1, seg, pad_before=3000, pad_after=15000):
    """一条消息:击键段 + 窗口 OCR → 屏幕上真实的那句话(或 None → 交第二层 librime 解码)。"""
    toks = event_tokens(seg)
    if not toks or not any(k == 'py' for k, _ in toks):
        return None                                     # 纯字面(全英文/纯数字)没必要走这条,AX/字面已够
    rows = con.execute(
        "SELECT full_text FROM frames WHERE timestamp_ms BETWEEN :a AND :b AND full_text IS NOT NULL "
        "ORDER BY timestamp_ms", {"a": (t0 or 0) - pad_before, "b": (t1 or t0 or 0) + pad_after}).fetchall()
    for (txt,) in rows:                                 # 逐帧找(别把多帧拼起来,会跨屏乱配)
        if not txt:
            continue
        m = anchor(toks, txt)
        if m:
            return m
    return None
