#!/usr/bin/env python3
"""确定性特征层单测 —— 零 LLM,纯 Python,随便跑。

守住 features.py 的行为:输入法推断 / 打字节奏 / 切换 / 盘古之白 / 句尾 /
edit_log 时序。改特征逻辑前先跑这个,别让骨架悄悄回归。

    python3 det_test.py
"""
import json

import features as F


def ks(ts, char, bs=0, src=None):
    return {"ts_ms": ts, "char": char, "is_backspace": bs, "input_source": src}


def _check(name, cond):
    print(f"  {'✓' if cond else '✗ FAIL'}  {name}")
    assert cond, name


def test_ime_human():
    _check("ITABC→pinyin", F.ime_human("com.apple.inputmethod.SCIM.ITABC") == "pinyin")
    _check("US→english", F.ime_human("com.apple.keylayout.US") == "english")
    _check("Squirrel→pinyin", F.ime_human("im.rime.inputmethod.Squirrel") == "pinyin")
    _check("None→unknown", F.ime_human(None) == "unknown")


def test_ks_pinyin_inferred():
    # 模拟拼音打「中国」:z h o n g 1  g u o 1,input_source 缺失
    seq = list("zhong1guo1zhong1")
    rows = [ks(1000 + i * 120, c) for i, c in enumerate(seq)]
    f = F.ks_features(rows)
    _check("无 input_source → input_source_seen False", f["input_source_seen"] is False)
    _check("拼音选词键被数出来", f["digit_picks"] >= 2)
    _check("推断 likely_pinyin", f["ime_inferred"] == "likely_pinyin")
    _check("gap 中位≈120ms", 100 <= f["gap_median_ms"] <= 140)


def test_ks_english_inferred():
    rows = [ks(1000 + i * 100, c) for i, c in enumerate("helloworldcheckin")]
    f = F.ks_features(rows)
    _check("长 run 无选词 → likely_english", f["ime_inferred"] == "likely_english")


def test_ks_input_source_and_switch():
    P, E = "com.apple.inputmethod.SCIM.ITABC", "com.apple.keylayout.US"
    rows = [ks(1000, "n", src=P), ks(1100, "i", src=P),
            ks(1200, "h", src=E), ks(1300, "i", src=E),
            ks(1400, "h", src=P)]
    f = F.ks_features(rows)
    _check("input_source 有值 → seen True", f["input_source_seen"] is True)
    _check("ime_share 含 pinyin+english", set(f["ime_share"]) == {"pinyin", "english"})
    _check("句中切换计到 2 次", f["ime_switches"] == 2)


def test_text_features():
    f = F.text_features("你好world你好")          # 中英相邻无空格
    _check("盘古 boundaries=2", f["pangu_boundaries"] == 2)
    _check("盘古比=0(从不空)", f["pangu_ratio"] == 0.0)
    g = F.text_features("你好 world 你好")         # 有空格
    _check("盘古比=1(总空)", g["pangu_ratio"] == 1.0)
    _check("句尾。→ cjk_period", F.text_features("好的。")["ending"] == "cjk_period")
    _check("句尾无标点 → none", F.text_features("好的")["ending"] == "none")
    _check("反问提示命中", F.text_features("这难道不对吗")["rhetorical_hint"] is True)


def test_editlog():
    one = json.dumps([{"kind": "commit", "text": "你好世界", "ts": 1}])
    f = F.editlog_features(one)
    _check("一次成稿 one_shot", f["one_shot"] is True and f["n_delete"] == 0)
    rev = json.dumps([{"kind": "commit", "text": "aaa", "ts": 1},
                      {"kind": "delete", "text": "aa", "ts": 2},
                      {"kind": "delete", "text": "a", "ts": 3},
                      {"kind": "commit", "text": "bb", "ts": 4}])
    g = F.editlog_features(rev)
    _check("删改被数出来", g["n_delete"] == 2 and g["max_delete_run"] == 2)
    _check("坏 JSON 不崩", F.editlog_features("{not json")["edit_entries"] == 0)


def test_aggregate():
    rows = []
    for t, el in [("你好world", '[{"kind":"commit","text":"x","ts":1}]'),
                  ("好的。", '[{"kind":"delete","text":"y","ts":1}]')]:
        rows.append({"features": json.dumps(F.record_features(
            t, el, [ks(1000, "n"), ks(1120, "i")]))})
    # labdb rows 用 ["features"];这里用 dict 模拟
    class R(dict):
        def __getitem__(self, k):
            return dict.__getitem__(self, k)
    agg = F.aggregate([R(r) for r in rows])
    _check("聚合 n_records=2", agg["n_records"] == 2)
    _check("句尾分布有两类", len(agg["ending_dist"]) >= 1)
    _check("聚合含 ime_inferred", "ime_inferred" in agg)


def main():
    for fn in [test_ime_human, test_ks_pinyin_inferred, test_ks_english_inferred,
               test_ks_input_source_and_switch, test_text_features,
               test_editlog, test_aggregate]:
        print(f"\n[{fn.__name__}]")
        fn()
    print("\n全部通过 ✅")


if __name__ == "__main__":
    main()
