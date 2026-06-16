"""确定性 UI-chrome 剥离 + 背景媒体/dev 信号检测。

v3 #1+#2 的核心。**全是规则,不依赖模型强度** —— 这是本地方案能逼近
sonnet 的关键:sonnet 靠世界常识认出 "Spotify File Edit View" 是菜单栏、
"Public Playlist" 是默认标签;14B 认不出,但正则能在 OCR 进 LLM 前直接
删掉,让小模型第一眼看到的就是真实内容。

真实失败样本(2026-06-07 event[18]):
  #254 "Spotify File Edit View SATURDAY JUNE S M • • My-Portrait ... 文本比对 ... Pass4"
  #265 "Spotify File Edit View Playback Window Help Sat Jun 6 10:35 PM • My-Meeting ... caffeinate"
4B 被开头的 Spotify 菜单栏带偏,写成"interacting with Spotify"。
剥掉 chrome 后第一个真 token 就是 My-Portrait / 文本比对 / Pass4。
"""
import re

# macOS 菜单栏右侧那串菜单词(File 后面)。抽出来给 File-less 分支复用。
_MENU_WORD = (r"(?:Playback|Window|Help|History|Bookmarks|Develop|Format|Go|Insert|"
              r"Selection|Find|Navigate|Editor|Product|Debug|Source\s*Control|Terminal|"
              r"Shell|Profiles|Tab|Speaker|Account)")
# macOS 应用菜单栏。两条接受路径(OCR 常把 File 漏识成 ••• / 吞掉,如 Discord
# "••• Edit View Window Help"):
#   1. (app 名 +) File Edit View ...  —— 标准三连,高精度
#   2. Edit View + 至少一个菜单词     —— File 缺失时靠尾随菜单词保精度
#      (正文里 "Edit View" 后极少紧跟 Window/Help/Format,误伤可忽略)
# app 名可选(OCR 有时漏)。
_MENUBAR = re.compile(
    r"\b([A-Z][\w.\- ]{0,20}?\s+)?"
    r"(?:File\s+Edit\s+View|Edit\s+View(?=\s+" + _MENU_WORD + r"))"
    r"(\s+" + _MENU_WORD + r")*", re.I)

# 菜单栏右侧时钟:Sat Jun 6 10:35 PM / Sat Jun 6 10:35
_CLOCK = re.compile(
    r"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+"
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+"
    r"\d{1,2}:\d{2}(\s*[AP]M)?", re.I)

# 通知中心 / 日历全大写日期:SATURDAY 6 JUNE / SATURDAY JUNE
_BIGDATE = re.compile(
    r"\b(MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SATURDAY|SUNDAY)\s+"
    r"(\d{1,2}\s+)?(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|"
    r"SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)", re.I)

# 日历星期行:S M T W T F S(连续单字母,≥3 个)/ SM JUNE 这类残片
_CALROW = re.compile(r"\b([SMTWF]\s+){2,}[SMTWF]\b")
_SM_FRAG = re.compile(r"\bS\s*M\b(\s+(JUNE|JULY|\d{1,2}))?", re.I)

# 音频输出菜单
_AUDIO = re.compile(r"\bMacBook\s+Pro\s+Speakers\b", re.I)

# Spotify / Finder 默认占位标签(短标签,非正文)——只删独立出现的。
_LABELS = [
    re.compile(r"\bPublic\s+Playlist\b", re.I),
    re.compile(r"\bLiked\s+Songs\b", re.I),
    re.compile(r"\bWhat\s+do\s+you\s+want\s+to\s+play\?", re.I),
    re.compile(r"\bYour\s+Library\b", re.I),
]

_STRIPPERS = [_MENUBAR, _CLOCK, _BIGDATE, _CALROW, _SM_FRAG, _AUDIO] + _LABELS

# dev 活动强信号(#2:媒体 app 前台但屏上是这些 → 背景音乐,真活动是 dev)。
_DEV_TOKENS = re.compile(
    r"(Sources/|/Users/|\.swift\b|\.py\b|\.ts\b|\.rs\b|caffeinate|"
    r"My-Portrait|My-Meeting|My-Orphies|Pass\d|xcodebuild|git\s|npm\s|"
    r"cargo\s|python3?\s|claude\b|文本比对|Read\s+\d+\s+file)", re.I)

# 背景音乐 app(前台 ≠ 在用)。
BG_MEDIA_APPS = {"Spotify", "Music", "iTunes"}

# 灾难性 regex bug 的安全网:剥掉 >92% 且原文很长 → 模式可能出错,保留原文
# 留审计。正常的 chrome-heavy session 剥到很短是**对的**(纯 chrome 无真信号,
# 下游 MIN_OCR_CHARS 自然丢弃,比保留误导性 chrome 强)。
_SANITY_RATIO = 0.92


def strip_chrome(text: str) -> str:
    """删高精度 UI chrome。删后塌缩多余空白。对正常正文是 no-op。
    高精度模式(菜单栏 File-Edit-View n-gram / 时钟 / 喇叭 / 全大写日期)
    定义上永不是内容,无条件剥 —— 别为"可能是音乐 session"保留误导 chrome。"""
    if not text:
        return text
    out = text
    for pat in _STRIPPERS:
        out = pat.sub(" ", out)
    out = re.sub(r"\s+", " ", out).strip()
    out = re.sub(r"^[•·\|\-\s]+", "", out).strip()
    return out


def strip_session_text(text: str) -> str:
    """单帧剥离 + 灾难安全网(防 regex bug 把长正文清空)。"""
    if not text:
        return text
    stripped = strip_chrome(text)
    if len(text) > 200 and len(stripped) < len(text) * (1 - _SANITY_RATIO):
        return text          # 剥掉 >92% 的长文 = 模式可能出错,保原文留审计
    return stripped


def has_dev_signal(text: str) -> bool:
    return bool(_DEV_TOKENS.search(text or ""))


def is_background_media(app: str, window, ocr: str) -> bool:
    """#2:媒体 app + 空 window + 屏上有 dev 信号 → 背景音乐。"""
    return (app in BG_MEDIA_APPS
            and not (window or "").strip()
            and has_dev_signal(ocr))
