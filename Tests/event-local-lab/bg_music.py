"""background 音乐字段的确定性提取(+可选小模型辅助判断)。2026-07-17 用户定案。

三连败定论后 bg 字段的免训练落法:判断挪出模型、进代码。
  ①触发(确定性):OCR 命中播放器指纹(进度时间戳/Now Playing/播放控件)才处理,否则 bg 留空。
  ②候选(确定性):指纹行邻近的「曲名 - 歌手」格式行 / 《曲名》/ 短独立行,全部逐字来自 OCR。
  ③裁定:唯一候选直接采;多候选时小模型做**选择题**(qwen3:4b via ollama,只准回
    候选编号或 none)—— 模型无生成自由度,结构上不可能编造歌名。歌词原文丢弃(用户定案)。

用法: python bg_music.py --day 2026-06-05 --suffix b [--jsonl /tmp/xxx.jsonl] [--llm]
  默认干跑打印;--jsonl 指定时把 bg 写回该文件对应行(仅音乐类,原 bg 为空才写)。
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import labdb  # noqa: E402
import source  # noqa: E402


def session_ocr(con_l, con_p, b):
    """读会话**全帧** OCR(parts→frame_ids→frames.full_text)。
    不继承 v12_day 的选帧预算:确定性扫描不吃上下文,证据帧被选帧丢掉会漏歌
    (6-05 s2770 的正在播条就在被丢的帧里)。"""
    fids = []
    for pid in b["parts"]:
        r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=:id",
                          {"id": pid}).fetchone()
        if r:
            fids += json.loads(r[0])
    texts = []
    for fid in fids:
        row = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=:id",
                            {"id": fid}).fetchone()
        if row and row[0]:
            texts.append(row[0])
    return "\n".join(texts)

# ① 播放器指纹(任一命中即触发,一级=屏幕真显示播放态,可提歌名)
FINGER = re.compile(r"\d{1,2}:\d{2}\s*/\s*\d{1,2}:\d{2}|Now Playing|正在播放|单曲循环|随机播放"
                    r"|Shuffle|[▶⏸⏭⏮♫♪]")
# ①b 二级触发:播放器菜单栏签名(播放器是前台归属项但歌名不在屏上)→ 降级产出不带歌名。
#    6-05 实测 Spotify 会话 OCR 只有菜单栏行,谁都提不出屏上没有的歌名,这是诚实上限。
MENUBAR = {
    "Spotify": re.compile(r"Spotify\b.{0,120}\bPlayback\b.{0,40}\bWindow\b"),
    "Music": re.compile(r"\bMusic\s+File\s+Edit\s+Song\b"),
}
# UI 词(候选黑名单)
UI = re.compile(r"播放|暂停|循环|随机|歌词|列表|队列|音量|Play|Pause|Next|Previous|Shuffle|Repeat"
                r"|Queue|Volume|Lyrics|Search|Home|Library|Premium|分钟|小时|次播放", re.I)
# 「曲名 - 歌手」/「曲名 — 歌手」格式
DASH = re.compile(r"^([^-—·|/]{1,40})\s*[-—·]\s*([^-—·|/]{1,30})$")
BOOK = re.compile(r"《([^》]{1,40})》")
# ①a 零级触发:菜单栏 Now-Playing 挂件 —— 菜单栏末项 Help 之后紧跟「曲名 - 歌手」段
#    (6-07 s1175 实测形态:"Shell Edit View Window Help 一点 - Muyoi SUNDAY, JUN 14")
#    捕获段到第一个桌面挂件 chrome 词(星期/电量%/No Events)为止,再过 DASH 格式闸。
NOWBAR = re.compile(r"Window\s+Help\s+(.{2,60}?)\s*(?:SUNDAY|MONDAY|TUESDAY|WEDNESDAY"
                    r"|THURSDAY|FRIDAY|SATURDAY|No Events|\d{1,3}%|$)")
# 文件名/路径样式(窗口标题 "MyMeeting - AnalyticsService.swift" 不是歌名)
FILEISH = re.compile(r"\.[A-Za-z]{1,6}\b|[/\\~]")
# ①c Lossless 锚点:Spotify 只给**正在播的曲目**挂 Lossless 徽标,徽标左侧就是曲名段
#    (6-05 s2770 实测:"…24 MAISONdes，花... （10 years after Ver. 知利子（CV.早見沙織） Lossless K 5:47")
#    左边界脏(黏着播放列表行):先按省略号切最后一段,再剥行首的列表行号。
LOSSLESS = re.compile(r"([^\n]{4,60}?)\s*Lossless\b")
# 播放列表表头/行号渣(黏在 Lossless 段左边):逐 token 剥,遇到第一个"像内容"的词停
JUNK_TOK = re.compile(r"^(?:[\W_]+|\d{1,4}|[A-Za-z]|[A-Za-z]\d{1,2}|[a-z]{2}|[一-鿿]\d"
                      r"|Title|Add|Mix|Name|details)$")


def _detrash(seg):
    toks = seg.split()
    # 播放列表行号/表头永远夹在左侧 chrome 和歌名之间:取最后一个裸行号/表头 token 之后
    last = -1
    for i, t in enumerate(toks):
        if re.fullmatch(r"\d{1,3}|#|Title|Dismiss", t):
            last = i
    if last >= 0:
        toks = toks[last + 1:]
    while toks and JUNK_TOK.match(toks[0]):
        toks.pop(0)
    return " ".join(toks)


def lossless_cands(lines):
    out = []
    for l in lines:
        m = LOSSLESS.search(l)
        if not m:
            continue
        seg = _detrash(re.split(r"\.{3}|…", m.group(1))[-1].strip(" •·|<>="))
        if 4 <= len(seg) <= 60 and not UI.search(seg) and not FILEISH.search(seg):
            out.append(seg)
    return out


def good_cand(seg):
    """「曲名 - 歌手」结构闸:DASH 格式 + 非文件名 + 分隔符不是 ASCII 词内连字符。"""
    if not DASH.match(seg) or FILEISH.search(seg) or UI.search(seg):
        return False
    if re.search(r"[A-Za-z0-9][-—·][A-Za-z0-9]", seg) and not re.search(r"\s[-—·]\s", seg):
        return False   # My-Meetin 这种词内连字符,且全串无带空格的真分隔符 → 不是歌名
    return True


def _norm_key(s):
    """近重复候选归一(OCR 同段多帧微差):只留字母数字/CJK,casefold。"""
    return re.sub(r"[^0-9A-Za-z一-鿿ぁ-ヿ]+", "", s).casefold()


def dedupe(cands):
    """同 norm 键的变体只留最优代表(优先 DASH 格式,再取最短)。
    键互为包含且长度差≤4 也算同组(「三 一点 - Muyoi」的前缀渣会改变键)。"""
    groups = {}
    for c in cands:
        k = _norm_key(c)
        hit = next((g for g in groups if (k in g or g in k) and abs(len(k) - len(g)) <= 4), None)
        groups.setdefault(hit or k, []).append(c)
    out = []
    for g in groups.values():
        g.sort(key=lambda c: (0 if good_cand(c) else 1, len(c)))
        out.append(g[0])
    return out


def polish(p):
    """pick 出口清洗:时间戳/箭头右侧全砍(队列黏连渣),再剥一遍左侧渣 token。
    圆括号不能当切点:歌名里合法出现(「11 （with Hooleeger）- 隊長」)。"""
    cut = re.split(r"\d{1,2}:\d{2}|[>＞•｜⑦\[\]［］]", p)[0].strip()
    if cut:
        p = cut
    toks = p.split()
    # 左剥只碰符号/单字母/CJK黏字母渣,**不碰数字**——行号渣候选层已剥,
    # 到这里的数字是歌名的一部分(「11 （with Hooleeger）- 隊長」)
    while len(toks) > 1 and re.fullmatch(r"[\W_]+|[A-Za-z]|[一-鿿][A-Za-z]{1,2}", toks[0]):
        toks.pop(0)
    return " ".join(toks)


def menubar_player(ocr):
    """二级触发:返回命中的播放器名(如 'Spotify'),没有则 None。"""
    for name, pat in MENUBAR.items():
        if pat.search(ocr):
            return name
    return None


def candidates(ocr):
    """返回 (触发?, [候选行])。候选逐字来自 OCR 行。"""
    lines = [l.strip() for l in re.split(r"[⏎\n]", ocr) if l.strip()]
    cands, seen = [], set()
    # 零级:菜单栏 Now-Playing 挂件(结构最确定,直接出候选)
    for l in lines:
        for m in NOWBAR.finditer(l):
            seg = m.group(1).strip(" •·|·*-—")
            if good_cand(seg) and seg not in seen:
                seen.add(seg)
                cands.append(seg)
    # Lossless 锚点(Spotify 正在播条,不要求 DASH 格式)
    for seg in lossless_cands(lines):
        if seg not in seen:
            seen.add(seg)
            cands.append(seg)
    hit = [i for i, l in enumerate(lines) if FINGER.search(l)]
    if not hit:
        return bool(cands), cands
    near = set()
    for i in hit:
        near.update(range(max(0, i - 3), min(len(lines), i + 4)))
    for i in sorted(near):
        l = lines[i]
        if UI.search(l) or FINGER.search(l):
            # 指纹行自身可能内嵌「曲名 - 歌手 3:39/3:49」:剥掉时间戳后再试
            l2 = re.sub(r"\d{1,2}:\d{2}\s*/\s*\d{1,2}:\d{2}", "", l).strip()
            if not l2 or UI.search(l2):
                continue
            l = l2
        for m in BOOK.finditer(l):
            c = m.group(1).strip()
            if c and c not in seen:
                seen.add(c)
                cands.append(c)
        if good_cand(l) and l not in seen and 4 <= len(l) <= 60:
            seen.add(l)
            cands.append(l)
    return True, cands[:6]


_MLX = {}


def _mlx_gen(prompt):
    """生产栈文本模型(Qwen3.5-9B-MLX-4bit,与 v4 汇总层同款)做裁定,贴近生产。"""
    if not _MLX:
        from mlx_lm import load
        _MLX["m"], _MLX["t"] = load("mlx-community/Qwen3.5-9B-MLX-4bit")
    from mlx_lm import generate
    msgs = [{"role": "user", "content": prompt}]
    try:
        p = _MLX["t"].apply_chat_template(msgs, add_generation_prompt=True,
                                          enable_thinking=False)
    except TypeError:
        p = _MLX["t"].apply_chat_template(msgs, add_generation_prompt=True)
    return generate(_MLX["m"], _MLX["t"], prompt=p, max_tokens=48)


def _ollama_gen(prompt):
    req = urllib.request.Request(
        "http://localhost:11434/api/generate",
        json.dumps({"model": "qwen3:4b", "prompt": prompt, "stream": False,
                    "think": False,   # qwen3 思考模式与 format 强制打架(4b 直接空响应),关掉弃权才正常
                    "format": {"type": "object", "properties": {"pick": {"type": "integer"}},
                               "required": ["pick"]},
                    "options": {"num_ctx": 2048, "temperature": 0}}).encode(),
        {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())["response"]


def llm_pick(cands, ctx, engine="mlx"):
    """小模型选择题:只准回候选编号。失败/不可用/弃权 → None(保守)。"""
    # 「都不是」列成显式选项:小模型对 -1 这种带外弃权几乎不选,列进去才会选
    opts = "\n".join(f"{i}. {c}" for i, c in enumerate(cands))
    opts += f"\n{len(cands)}. 都不是(以上是文件名/界面文字/项目名,没有歌曲名)"
    # 全帧 OCR 很长,截候选出现处的邻域当上下文(而不是开头 600 字)
    i = ctx.find(cands[0])
    if i >= 0:
        ctx = ctx[max(0, i - 250):i + 350]
    prompt = (f"屏幕OCR片段:\n{ctx[:600]}\n\n候选:\n{opts}\n\n"
              f"哪个候选是正在播放的歌曲名(或 曲名-歌手)?文件名/界面文字/菜单项/代码项目名都不算。"
              f'只输出 JSON:{{"pick": 编号}}')
    try:
        out = _mlx_gen(prompt) if engine == "mlx" else _ollama_gen(prompt)
        m = re.search(r'"?pick"?\s*[:=]?\s*(-?\d+)', out) or re.search(r"-?\d+", out)
        p = int(m.group(1)) if m else -1
        return cands[p] if 0 <= p < len(cands) else None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--suffix", default="b")
    ap.add_argument("--jsonl", help="把音乐 bg 写回此 jsonl(原 bg 为空才写)")
    ap.add_argument("--llm", action="store_true", help="多候选时用小模型选择(默认只采唯一候选)")
    ap.add_argument("--engine", default="mlx", choices=["mlx", "ollama"],
                    help="裁定引擎:mlx=生产栈 Qwen3.5-9B-4bit(默认);ollama=qwen3:4b(调试)")
    args = ap.parse_args()

    man = json.load(open(f"/tmp/vision_v4{args.suffix}_{args.day}/v4_manifest.json"))
    con_l = labdb.connect()
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    out = {}
    n_trig = 0
    n_menu = 0
    for k, b in man.items():
        ocr = session_ocr(con_l, con_p, b)
        trig, cands = candidates(ocr)
        if trig:
            n_trig += 1
            cands = dedupe(cands)
            pick = None
            if len(cands) == 1:
                pick = cands[0]
            elif len(cands) > 1 and args.llm:
                pick = llm_pick(cands, ocr, args.engine)
            if pick and pick in ocr:              # verbatim 铁闸(polish 只取其子串,不破闸)
                pick = polish(pick)
                out[k] = f"后台正在播放:{pick}"
                print(f"  s{k} [{b.get('app')}] ♪ {pick}"
                      + (f"  (候选{len(cands)})" if len(cands) > 1 else ""))
                continue
            elif cands:
                print(f"  s{k} [{b.get('app')}] 一级触发但未裁定,候选: {cands}")
        # 二级:菜单栏归属但歌名没裁定 → 降级产出(诚实上限,不猜歌名)。
        # 有候选=播放态确凿(进度条/正在播条真在屏上),只是歌名认不出;无候选=只知在前台。
        player = menubar_player(ocr)
        if player:
            n_menu += 1
            out[k] = (f"{player} 在播放(歌名未能辨认)" if trig and cands
                      else f"{player} 在前台运行(屏幕未显示歌名)")
            print(f"  s{k} [{b.get('app')}] ▸ 菜单栏降级:{player}"
                  + ("(有候选未裁定)" if trig and cands else ""))
    print(f"[bg_music] {args.day}: 一级触发 {n_trig} / 菜单栏降级 {n_menu} / 共 {len(man)},裁定 {len(out)}")
    if args.jsonl:
        # bg 闸语义:bg 只能来自确定性通道。触发的覆写(模型零-shot 填的噪音让位),
        # 没触发的清空(v1.2 没训过 bg 却会自己发挥,填的全是桌面日历/文件夹静态噪音)。
        rows = [json.loads(l) for l in open(args.jsonl, encoding="utf-8")]
        n_w = n_wipe = 0
        for r in rows:
            k = str(r["key"])
            old = (r["digest"].get("background") or "").strip()
            if k in out:
                if old != out[k]:
                    n_w += 1
                r["digest"]["background"] = out[k]
            elif old:
                r["digest"]["background"] = ""
                n_wipe += 1
        with open(args.jsonl, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"写回 {n_w} 条,清掉未触发的模型 bg {n_wipe} 条 → {args.jsonl}")


main()
