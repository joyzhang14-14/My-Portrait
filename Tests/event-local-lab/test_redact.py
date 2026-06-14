"""redact.py 单测。python3 test_redact.py"""
import redact
def _g(text, gone, keep=None, hit=None):
    out, hits = redact.redact(text)
    for x in gone: assert x not in out, f"未脱敏 {x!r}: {out}"
    for x in (keep or []): assert x in out, f"误删 {x!r}: {out}"
    if hit: assert hit in hits, f"未命中 {hit}: {hits}"
def test_pii():
    _g("发邮件 1735443634lbwnb@gmail.com", ["1735443634lbwnb@gmail.com"], ["发邮件"], "<email>")
    _g("电话 13812345678", ["13812345678"], ["电话"], "<phone>")
    _g("call 415-555-0123", ["415-555-0123"], ["call"], "<phone>")
    _g("KEY=sk-proj-abc123XYZdef456ghi789jkl", ["sk-proj-abc123XYZdef456ghi789jkl"], None, "<secret>")
    _g("card 4111 1111 1111 1111", ["4111 1111 1111 1111"], ["card"], "<card>")
    _g("身份证 11010519900307123X", ["11010519900307123X"], ["身份证"], "<id>")
    _g("commit a1b2c3d4e5f6789012345678901234567890abcd", ["a1b2c3d4e5f6789012345678901234567890abcd"], ["commit"], "<token>")
def test_noop():
    n = "The user was debugging My-Meeting speaker recognition in Terminal."
    out, h = redact.redact(n); assert out == n and not h
    out2, _ = redact.redact("internationalization counterproductivity")
    assert out2 == "internationalization counterproductivity"
if __name__ == "__main__":
    test_pii(); test_noop(); print("✅ redact 2 tests passed")
