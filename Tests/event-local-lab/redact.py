"""确定性 PII 脱敏闸 —— hybrid 的隐私基石。

digest 上云前过这道闸,把残留的具体敏感值掩码成占位符(保留"有个邮箱"的
语义,删掉具体值)。两道防线的第二道:
  ① clean prompt 指示"不复述消息正文/密码/个人信息"(第一道,概率性)
  ② 本道确定性闸(兜底,万一 clean 复述了原文里的 PII)

掩码而非删除:`<email>` 保留语义不泄露值。规则,模型无关,可单测。
"""
import re

# 邮箱
_EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")
# 电话:中国手机 1[3-9]xxxxxxxxx / 美国 xxx-xxx-xxxx
_PHONE_CN = re.compile(r"\b1[3-9]\d{9}\b")
_PHONE_US = re.compile(r"\b\d{3}[-.\s]\d{3}[-.\s]\d{4}\b")
# 信用卡(16 位,可空格/横线分组)
_CARD = re.compile(r"\b(?:\d[ -]?){15}\d\b")
# 中国身份证 18 位
_IDCARD = re.compile(r"\b\d{17}[\dXx]\b")
# API 密钥 / token:常见前缀 + 长串
_SECRET_PREFIX = re.compile(
    r"\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"AIza[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|pk_[A-Za-z0-9]{16,})")
# 裸长 hex/base64(≥32,疑似密钥/hash;但别误伤普通长单词 → 要求含数字+字母混合)
_LONG_TOKEN = re.compile(r"\b(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])"
                         r"[A-Za-z0-9_-]{32,}\b")
# referral / 邀请码:claude.ai/referral/CGzN8uyoKQ、invite/xxx、ref=xxx —— 可复用凭据
_REFERRAL = re.compile(r"\b(?:referral|invite|ref)[/=]\s*[A-Za-z0-9_-]{6,}", re.I)
# 货币金额:必须带货币标记(¥/$/元/RMB)或紧跟转账词才掩,避免误伤版本号(1.2.95)/
# chunk-ID(chunk 3402)/impact 分数(2.3)等普通数字。保留"谁转了账"的人名+事件,
# 只抹具体金额(对齐用户选的分级:中性事实留、敏感值掩)。
_MONEY = re.compile(
    r"(?:[¥$]|RMB|USD|US\$)\s?\d[\d,]*(?:\.\d{1,2})?"
    r"|\d[\d,]*(?:\.\d{1,2})?\s*(?:元|人民币|美元|块钱?|RMB|USD)"
    r"|(?:转账|已转账?|转了|收款|付款|红包)[^\d\n]{0,4}\d[\d,]*(?:\.\d{1,2})?", re.I)

# 顺序有讲究:先掩码强模式(secret/referral/card/id),再 email/phone/money,最后裸长
# token(避免裸 token 规则吃掉已掩码占位符里的内容 —— 占位符是 <xxx>,不匹配)
_RULES = [
    (_SECRET_PREFIX, "<secret>"),
    (_REFERRAL, "<referral>"),
    (_IDCARD, "<id>"),
    (_CARD, "<card>"),
    (_EMAIL, "<email>"),
    (_PHONE_CN, "<phone>"),
    (_PHONE_US, "<phone>"),
    (_MONEY, "<amount>"),
    (_LONG_TOKEN, "<token>"),
]


def redact(text: str):
    """脱敏 text。返回 (脱敏后文本, 命中计数 dict)。对无 PII 文本是 no-op。"""
    if not text:
        return text, {}
    out = text
    hits = {}
    for pat, repl in _RULES:
        out, n = pat.subn(repl, out)
        if n:
            hits[repl] = hits.get(repl, 0) + n
    return out, hits
