#!/usr/bin/env python3
"""双 return 英文检测器(中英文判别地基,2026-06-13 用户 case 驱动)。

用户逻辑:**中文输入法下打英文 = 字母 + return(把组合区上屏成字面) + return(发送) = 双 return**。
第一个 return 不发送(只上屏字面),第二个才发送。所以击键里"拉丁 run 紧跟 <CR><CR>"= 英文字面。
英文键盘则单 return 直接发送,无此模式;纯拼音紧跟的是选字数字/空格,不是 return。

⚠️ 历史数据 input_source 为 NULL,这个信号专治历史数据的中英文判别(input_source 只对新采集生效)。

验证(已通过,见本文件 __main__):
  gmail 案 ev1132「g mai l」残渣 → 击键 `geBmail<CR><CR>` → 抓出 ['notebookLM','gmail'] ✓
  英文 bug/sparkle/doc/icon → 各自抓出 ✓
  纯拼音 记得/压缩/美丽/长文 → 全空,零误抓 ✓

⏳ 待接(下一 session,需完整上下文 + 14B 全量验证):
  在 faithful_v2 reconstruct 之后,对 ~residue 记录:取该事件击键跑 double_return_eng,
  若残渣的字母序列 == 某个双 return 英文词(去空格小写) → **直接用击键字面替换**
  (gmail 不需要 LLM,击键 g-m-a-i-l 就是字面;Librime+LLM 只在多词/有歧义时才需要合并)。
  约束:只改 ~residue 且匹配双 return 英文的记录 → 天然"不影响其他结果"。
  验证:gmail 案翻成 'gmail' + 38 gold 零回归(跑 faithful_v2 全量,结果放 Pipeline成品归档)。
"""
import re


def double_return_eng(ks_encoded):
    """ks_encoded: 击键串,return='\\n'(非字母,别用'R'——会和大写字母 R 撞),退格='\\x08'。
    返回:双 return 之前的拉丁 run 列表(= 中文输入法下打的英文字面词)。"""
    buf = []
    for ch in ks_encoded:
        if ch == '\x08':
            if buf:
                buf.pop()
        else:
            buf.append(ch)
    return [m.group(1) for m in re.finditer(r'([a-zA-Z]{2,})\n\n', ''.join(buf))]


def encode_keys(rows):
    """rows: [(char, is_backspace)] → 编码串(return='\\n', 退格='\\x08')。"""
    return ''.join('\x08' if bs else ('\n' if (c and c in '\r\n') else (c or ''))
                   for c, bs in rows)


if __name__ == '__main__':
    import sqlite3
    import os
    con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))

    def ksof(eid):
        r = con.execute("SELECT bundle_id,started_at,ended_at FROM typing_events WHERE id=?",
                        (eid,)).fetchone()
        rows = con.execute(
            "SELECT char,is_backspace FROM keystroke_log WHERE bundle_id=? "
            "AND ts_ms BETWEEN ? AND ? AND (modifiers&7)=0 ORDER BY ts_ms",
            (r[0], r[1] - 2000, r[2] + 2000)).fetchall()
        return encode_keys(rows)

    print("gmail案 ev1132:", double_return_eng(ksof(1132)))
    print("英文:", [double_return_eng(ksof(e)) for e in (531, 513, 554, 506)])
    print("纯拼音(应全空):", [double_return_eng(ksof(e)) for e in (522, 543, 523, 504)])
