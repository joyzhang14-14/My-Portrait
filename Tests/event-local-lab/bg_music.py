"""background 字段的确定性构造闸(音乐提取 + 背景窗口核真)。2026-07-17 用户定案。

三连败定论后 bg 字段的免训练落法:判断挪出模型、进代码。两条通道:
【音乐】①触发(确定性):播放器指纹/菜单栏挂件/Lossless 锚点;②候选逐字来自 OCR;
  ③裁定:唯一候选直取,多候选小模型选择题(MLX Qwen3.5-9B-4bit,只回编号)。歌词丢弃。
【背景窗口】模型零-shot 的 bg 描述只当提名,三道确定性闸核真(2026-07-17 用户拍板):
  闸A 静态桌面噪音黑名单;闸B 关系核真——提到的 app 必须真出现在窗口清单里
  (frames 表每帧都记 app_name/window_name,会话前后聚合即窗口清单,与 app 端
  ACTIVE APPS 面板同源同法),且不能只是会话自身前台;闸C 实体锚定——内容词
  逐字率过线才收。三闸全过才保留,否则清空。

用法: python bg_music.py --day 2026-06-05 --suffix b [--jsonl /tmp/xxx.jsonl] [--llm]
  默认干跑打印;--jsonl 指定时闸语义写回:触发/核真的覆写,其余清空。
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


def session_fids(con_l, b):
    """会话全部帧 id(parts→raw_sessions.frame_ids)。"""
    fids = []
    for pid in b["parts"]:
        r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=:id",
                          {"id": pid}).fetchone()
        if r:
            fids += json.loads(r[0])
    return fids


def session_ocr(con_p, fids):
    """读会话**全帧** OCR。不继承 v12_day 的选帧预算:确定性扫描不吃上下文,
    证据帧被选帧丢掉会漏歌(6-05 s2770 的正在播条就在被丢的帧里)。"""
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


# ── 背景窗口核真闸 ──────────────────────────────────────────────
# 闸A:静态桌面噪音(用户点名要杀的类)
STATIC_NOISE = re.compile(r"桌面|日历|文件夹|图标|挂件|小组件|壁纸|Dock|菜单栏|天气|电量"
                          r"|通知|提醒|截图|屏保|Bedtime|Reminder")
# 锚定提取时排除的关系/方位虚词(模型描述背景关系用的词,不算内容证据)
REL_CJK = {"背景窗口", "标签页", "背景里", "屏幕右侧", "屏幕左侧", "屏幕底部", "屏幕右上",
           "另一个", "显示多个", "正在进行", "内容涉及", "以及一个", "还有一个"}


def session_span(con_p, fids):
    """会话时间范围(ms):首末帧时间戳。"""
    if not fids:
        return None
    qs = ",".join("?" * len(fids))
    r = con_p.execute(f"SELECT MIN(timestamp_ms), MAX(timestamp_ms) FROM frames "
                      f"WHERE id IN ({qs})", fids).fetchone()
    return r if r and r[0] else None


def win_inventory(con_p, t0, t1, look_ms=900_000):
    """窗口清单:会话前 15 分钟到会话结束的 (app, window_name) 集合。
    与 app 端 ACTIVE APPS 面板同源同法(frames 表聚合,PortraitDBImpl.activeAppsAround)。"""
    return con_p.execute(
        "SELECT DISTINCT app_name, COALESCE(window_name,'') FROM frames "
        "WHERE timestamp_ms BETWEEN ? AND ? AND app_name IS NOT NULL AND app_name != ''",
        (t0 - look_ms, t1)).fetchall()


def window_bg_gate(model_bg, sess_app, inv, ocr):
    """模型零-shot bg 只当提名,三道闸核真;全过返回裁剪后的 bg,否则 None。"""
    t = str(model_bg or "").strip()
    if len(t) < 8 or STATIC_NOISE.search(t):                     # 闸A
        return None
    nt = _norm_key(t)
    sa = _norm_key(sess_app or "")
    mentioned = {a for a, _ in inv if len(_norm_key(a)) >= 3 and _norm_key(a) in nt}
    others = {a for a in mentioned if _norm_key(a) != sa}
    # 同 app 多窗口/标签页(「另一个 Terminal 窗口」「Safari 后台标签页」):
    # 关系词在场即交给闸C 拿实体说话;纯他述而清单查无此 app 才拒。
    if not others and not (mentioned and re.search(r"另一|背景|后台|标签页", t)):
        return None                                              # 闸B 关系核真
    # 闸C 实体锚定:只认硬实体(ASCII 词≥4 / 引号内原文)。模型的中文叙述
    # ("背景窗口是…")不算锚点——那是它自己的话,不是屏上的字。
    # 语料 = 全帧 OCR + 窗口标题(frames.window_name 是系统级真值,
    # sourcekit-lsp 这类实体常在标题里而不在 OCR 里)。
    anchors = set(re.findall(r"[A-Za-z][\w.-]{3,}", t))
    anchors |= {q for q in re.findall(r"[「『\"“]([^」』\"”]{2,30})[」』\"”]", t)}
    anchors = {a for a in anchors if len(a) >= 3}
    if len(anchors) < 2:
        return None
    corpus = _norm_key(ocr + "\n" + "\n".join(f"{a} {w}" for a, w in inv))
    hit = sum(1 for a in anchors if _norm_key(a) in corpus)
    if hit / len(anchors) < 0.6:
        return None
    return t[:200]


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
    rows = bg_by_key = None
    if args.jsonl:
        rows = [json.loads(l) for l in open(args.jsonl, encoding="utf-8")]
        bg_by_key = {str(r["key"]): (r["digest"].get("background") or "")
                     for r in rows if not r.get("stub")}
    out = {}
    n_trig = n_menu = n_win = 0
    for k, b in man.items():
        fids = session_fids(con_l, b)
        ocr = session_ocr(con_p, fids)
        trig, cands = candidates(ocr)
        music = None
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
                music = f"后台正在播放:{pick}"
                print(f"  s{k} [{b.get('app')}] ♪ {pick}"
                      + (f"  (候选{len(cands)})" if len(cands) > 1 else ""))
            elif cands:
                print(f"  s{k} [{b.get('app')}] 一级触发但未裁定,候选: {cands}")
        if music is None:
            # 二级:菜单栏归属但歌名没裁定 → 降级产出(诚实上限,不猜歌名)。
            # 有候选=播放态确凿(进度条/正在播条真在屏上),只是歌名认不出;无候选=只知在前台。
            player = menubar_player(ocr)
            if player:
                n_menu += 1
                music = (f"{player} 在播放(歌名未能辨认)" if trig and cands
                         else f"{player} 在前台运行(屏幕未显示歌名)")
                print(f"  s{k} [{b.get('app')}] ▸ 菜单栏降级:{player}"
                      + ("(有候选未裁定)" if trig and cands else ""))
        # 背景窗口通道:模型零-shot bg 提名 → 三闸核真
        wbg = None
        if bg_by_key and bg_by_key.get(k):
            span = session_span(con_p, fids)
            if span:
                inv = win_inventory(con_p, span[0], span[1])
                wbg = window_bg_gate(bg_by_key[k], b.get("app"), inv, ocr)
                if wbg:
                    n_win += 1
                    print(f"  s{k} [{b.get('app')}] ▣ 背景窗口核真: {wbg[:80]}")
        parts = [p for p in (music, wbg) if p]
        if parts:
            out[k] = ";".join(parts)
    print(f"[bg_music] {args.day}: 一级触发 {n_trig} / 菜单栏降级 {n_menu} / 窗口核真 {n_win}"
          f" / 共 {len(man)},裁定 {len(out)}")
    if args.jsonl:
        # bg 闸语义:bg 只能来自确定性通道(音乐提取/窗口核真)。触发的覆写,
        # 没过闸的清空(v1.2 没训过 bg 却会零-shot 发挥,大头是桌面静态噪音)。
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
