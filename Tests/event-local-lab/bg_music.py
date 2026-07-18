"""background 字段的确定性构造闸 v2.2(音乐提取 + 背景窗口子句级核真)。

铁律(用户 2026-07-18):**禁止硬编码任何判断**。代码只做结构性检查
(verbatim 锚定/n-gram 重合/格式模式/窗口清单查证);内容判断(是不是歌名、
是不是静态摆设、是不是播放器)一律交小模型做**判别题/选择题**——模型只回
编号或分类字母,无生成自由度,结构上不可能编造。

v2.1→v2.2 修法(独立核查判决,验收报告 2026-07-17):
  ①整条清除 → **子句级过滤**:静态摆设子句删、可核实后台子句留;
  ②bg 与 activity 高 n-gram 重合 → 前台复述,确定性删(s86 类);
  ③音乐候选带证据来源,列表行候选必须过模型裁定,禁直采(s265 类);
  ④截断改句边界(s343 类);
  ⑤拆掉全部内容词表(STATIC/UI/播放器字典)→ 模型判别。

用法: python bg_music.py --day 2026-06-05 --suffix b [--jsonl X.jsonl] [--llm]
  默认干跑打印;--jsonl 指定时闸语义写回:过闸的覆写,其余清空。
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


# ── 结构性模式(格式指纹,非内容判断)────────────────────────────
# 播放态指纹:进度时间戳对 / 播放控件符号
FINGER = re.compile(r"\d{1,2}:\d{2}\s*/\s*\d{1,2}:\d{2}|[▶⏸⏭⏮♫♪]")
# 菜单栏结构:行首 app 名 + 菜单词序(任意 app,不设白名单)
MENUBAR_ANY = re.compile(r"([A-Z][\w .&-]{1,24}?)\s+(?:File|Shell)\s+Edit\b")
# 菜单栏 Now-Playing 挂件:菜单栏末项 Help 之后紧跟的段(到桌面挂件 chrome 词为止)
NOWBAR = re.compile(r"Window\s+Help\s+(.{2,60}?)\s*(?:SUNDAY|MONDAY|TUESDAY|WEDNESDAY"
                    r"|THURSDAY|FRIDAY|SATURDAY|No Events|\d{1,3}%|$)")
# 「曲名 - 歌手」格式
DASH = re.compile(r"^([^-—·|/]{1,40})\s*[-—·]\s*([^-—·|/]{1,30})$")
BOOK = re.compile(r"《([^》]{1,40})》")
# Spotify 正在播条徽标(徽标只挂当前曲目,结构性锚点)
LOSSLESS = re.compile(r"([^\n]{4,60}?)\s*Lossless\b")
# 文件名/路径样式(结构)
FILEISH = re.compile(r"\.[A-Za-z]{1,6}\b|[/\\~]")
# 纯符号/裸数字/单字母 token(结构渣)
JUNK_TOK = re.compile(r"^(?:[\W_]+|\d{1,4}|[A-Za-z]|[A-Za-z]\d{1,2}|[a-z]{2}|[一-鿿]\d)$")


def _norm_key(s):
    """归一:只留字母数字/CJK/假名,casefold。"""
    return re.sub(r"[^0-9A-Za-z一-鿿ぁ-ヿ]+", "", s).casefold()


def good_cand(seg):
    """「曲名 - 歌手」结构闸:DASH 格式 + 非文件名 + 分隔符不是 ASCII 词内连字符。"""
    if not DASH.match(seg) or FILEISH.search(seg):
        return False
    if re.search(r"[A-Za-z0-9][-—·][A-Za-z0-9]", seg) and not re.search(r"\s[-—·]\s", seg):
        return False
    return True


def _detrash(seg):
    """剥播放列表行号/表头渣:取最后一个裸行号之后,再剥左侧结构渣 token。"""
    toks = seg.split()
    last = -1
    for i, t in enumerate(toks):
        if re.fullmatch(r"\d{1,3}|#", t):
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
        if 4 <= len(seg) <= 60 and not FILEISH.search(seg):
            out.append(seg)
        # 段内有时间戳时,最后一个时间戳之后的尾段**另出一个候选**(不替换全段——
        # 两种排版都存在:「老男孩 5:00 信仰→徽标」尾段是正在播的;
        # 「愛如潮水 4:33 Credits→徽标」尾段是面板词。哪个对交模型选。)
        parts_t = re.split(r"\d{1,2}:\d{2}", seg)
        tail = parts_t[-1].strip(" •·|<>=,,、.。") if len(parts_t) > 1 else ""
        if 4 <= len(tail) <= 60 and not FILEISH.search(tail):
            out.append(tail)
    return out


def candidates(ocr):
    """返回 (触发?, [(来源, 候选)])。候选逐字来自 OCR。
    来源标注(修法③):nowbar=挂件结构无歧义;lossless/near=可能黏列表邻曲,
    必须过模型裁定,禁直采。"""
    lines = [l.strip() for l in re.split(r"[⏎\n]", ocr) if l.strip()]
    cands, seen = [], set()

    def add(src, seg):
        if seg and seg not in seen:
            seen.add(seg)
            cands.append((src, seg))

    for l in lines:
        for m in NOWBAR.finditer(l):
            seg = m.group(1).strip(" •·|·*-—")
            if good_cand(seg):
                add("nowbar", seg)
    for seg in lossless_cands(lines):
        add("lossless", seg)
    hit = [i for i, l in enumerate(lines) if FINGER.search(l)]
    near = set()
    for i in hit:
        near.update(range(max(0, i - 3), min(len(lines), i + 4)))
    for i in sorted(near):
        l = lines[i]
        if FINGER.search(l):
            l = re.sub(r"\d{1,2}:\d{2}\s*/\s*\d{1,2}:\d{2}", "", l).strip()
            if not l:
                continue
        for m in BOOK.finditer(l):
            add("near", m.group(1).strip())
        if good_cand(l) and 4 <= len(l) <= 60:
            add("near", l)
    trig = bool(hit) or bool(cands)
    return trig, cands[:6]


def dedupe(cands):
    """同 norm 键(含互为包含、长度差≤4)的变体只留最优代表;来源取更强的
    (nowbar > lossless > near)。"""
    RANK = {"nowbar": 0, "lossless": 1, "near": 2}
    groups = {}
    for src, c in cands:
        k = _norm_key(c)
        hit = next((g for g in groups if (k in g or g in k) and abs(len(k) - len(g)) <= 4), None)
        groups.setdefault(hit or k, []).append((src, c))
    out = []
    for g in groups.values():
        g.sort(key=lambda sc: (RANK[sc[0]], 0 if good_cand(sc[1]) else 1, len(sc[1])))
        out.append(g[0])
    out.sort(key=lambda sc: len(sc[1]))   # 短而净的排前面呈现给裁定模型
    return out


def plausible_song(p):
    """pick 出口结构合理性(非内容词表):句读断片和孤立英文单词不可能是可核实歌名。"""
    if re.search(r"[.。!?]\s", p):                      # 内含句读+空格 = 句子断片
        return False
    toks = p.split()
    if len(toks) == 1 and re.fullmatch(r"[A-Za-z]+", p):  # 单个裸英文词无从核实
        return False
    return True


def polish(p):
    """pick 出口清洗(纯结构):时间戳/箭头右切,左剥符号渣(不碰数字/圆括号——
    都砍伤过真歌名)。"""
    pieces = [x.strip() for x in re.split(r"\d{1,2}:\d{2}|[>＞•｜⑦\[\]［］]", p)]
    # 首段优先;首段空(渣在开头,如「［Image #8］ Marigold…」)则取最长段
    p = pieces[0] if len(pieces[0]) >= 4 else (max(pieces, key=len) or p)
    toks = p.split()
    while len(toks) > 1 and re.fullmatch(r"[\W_]+|[A-Za-z]|[一-鿿][A-Za-z]{1,2}", toks[0]):
        toks.pop(0)
    return " ".join(toks)


# ── 小模型判别(MLX 生产栈;ollama 调试)─────────────────────────
_MLX = {}


def _mlx_gen(prompt):
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
                    "think": False,
                    "options": {"num_ctx": 2048, "temperature": 0}}).encode(),
        {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())["response"]


def _gen(prompt, engine):
    return _mlx_gen(prompt) if engine == "mlx" else _ollama_gen(prompt)


def llm_pick(cands, ocr, engine="mlx"):
    """选择题:哪个候选是**正在播放**的歌?列表邻曲不算(修法③写进题面)。
    弃权列为显式选项。失败/弃权 → None(保守)。"""
    opts = "\n".join(f"{i}. [{src}] {c}" for i, (src, c) in enumerate(cands))
    opts += f"\n{len(cands)}. 都不是/无法确定"
    wins = []
    for pat in (LOSSLESS, FINGER):
        m = pat.search(ocr)
        if m:
            wins.append(ocr[max(0, m.start() - 250):m.start() + 350])
    ctx = "\n---\n".join(wins) if wins else ocr[:600]
    prompt = (f"屏幕OCR片段(含播放证据处):\n{ctx}\n\n候选(带提取来源):\n{opts}\n\n"
              f"哪个候选是**当前正在播放**的歌曲名(或 曲名-歌手)?判断依据:紧邻播放证据"
              f"(进度条/Lossless徽标/Credits面板/菜单栏Now-Playing挂件);来源标注"
              f"[nowbar]=菜单栏挂件、[lossless]=紧邻徽标,是强证据;播放列表/队列里的邻曲、"
              f"文件名、界面文字、项目名都不算。没把握就选最后一项。"
              f'只输出 JSON:{{"pick": 编号}}')
    try:
        out = _gen(prompt, engine)
        m = re.search(r'"?pick"?\s*[:=]?\s*(-?\d+)', out) or re.search(r"-?\d+", out)
        p = int(m.group(1)) if m else -1
        return cands[p][1] if 0 <= p < len(cands) else None
    except Exception:
        return None


_PLAYER_CACHE = {}


def is_player(app, engine):
    """判别题:app 是不是音乐/媒体播放器(拆掉硬编码播放器字典)。"""
    if app in _PLAYER_CACHE:
        return _PLAYER_CACHE[app]
    try:
        out = _gen(f'「{app}」是音乐或媒体播放器 app 吗?只输出 JSON:{{"yes": true或false}}',
                   engine)
        r = bool(re.search(r'"?yes"?\s*[:=]?\s*true', out, re.I))
    except Exception:
        r = False
    _PLAYER_CACHE[app] = r
    return r


def _vote2(prompts, pat, engine):
    """双措辞共识:两个措辞变体都判 true 才 true(温度0下同题必同答,换措辞=独立票;
    共识制提精度——回归判决里 false 保留是短板,误杀已达标)。"""
    for pr in prompts:
        try:
            if not re.search(pat, _gen(pr, engine), re.I):
                return False
        except Exception:
            return False
    return True


def is_bg_task(clause, engine):
    """二元判别①:这句是不是「正在进行中的后台窗口/任务」?
    ⚠️不带 activity 参照——实测参照会把判别带偏(「文件夹不是当前操作」被推成
    「所以是后台任务」,忘了"必须正在进行中"的前提);单独判时三类样例全对。"""
    p1 = (f"待判片段:\n「{clause}」\n\n"
          f"问:这个片段描述的是不是「打开着的后台窗口或后台任务」"
          f"(背景里挂着的另一个窗口/会话/设置页/标签页,显示着具体内容或在干活)?\n"
          f"以下情况都回 false:桌面摆设(壁纸/桌面图标/日历挂件/天气/Dock/菜单栏"
          f"日期,不是窗口);音乐播放或歌词内容;无法判断。\n"
          f'只输出 JSON:{{"bg_task": true或false}}')
    p2 = (f"屏幕环境描述:「{clause}」\n\n"
          f"判断:这说的是一个**背景里开着的窗口/正在进行的后台任务**吗?"
          f"如果只是桌面陈设(图标/挂件/日历/天气/Dock)、音乐或歌词、或者你拿不准,"
          f'答 false。只输出 JSON:{{"bg_task": true或false}}')
    return _vote2([p1, p2], r'"?bg_task"?\s*[:=]?\s*true', engine)


def is_foreground(clause, activity, engine):
    """二元判别②(s86 类):片段描述的是不是**用户当前正在前台操作的那个窗口本身**。
    不问"内容重不重"——v1.2 常把背景也抄进 activity,verbatim 重复不等于前台复述。"""
    if not activity:
        return False
    prompt = (f"甲(用户当前操作):「{activity[:200]}」\n乙(待判片段):「{clause}」\n\n"
              f"问:乙描述的窗口/任务,是不是用户当前正在前台操作的那一个本身?"
              f"(是=乙就是甲正在驱动的那个窗口;否=乙是同屏环境里另外挂着的窗口/任务)\n"
              f'只输出 JSON:{{"fg": true或false}}')
    try:
        out = _gen(prompt, engine)
        return bool(re.search(r'"?fg"?\s*[:=]?\s*true', out, re.I))
    except Exception:
        return False


# ── 背景窗口子句级核真 ────────────────────────────────────────
def session_span(con_p, fids):
    if not fids:
        return None
    qs = ",".join("?" * len(fids))
    r = con_p.execute(f"SELECT MIN(timestamp_ms), MAX(timestamp_ms) FROM frames "
                      f"WHERE id IN ({qs})", fids).fetchone()
    return r if r and r[0] else None


def win_inventory(con_p, t0, t1, look_ms=900_000):
    """窗口清单:会话前 15 分钟到结束的 (app, window_name)。
    与 app 端 ACTIVE APPS 面板同源同法(frames 聚合,activeAppsAround)。"""
    return con_p.execute(
        "SELECT DISTINCT app_name, COALESCE(window_name,'') FROM frames "
        "WHERE timestamp_ms BETWEEN ? AND ? AND app_name IS NOT NULL AND app_name != ''",
        (t0 - look_ms, t1)).fetchall()


def _overlap(clause, activity, n=8):
    """结构性前台复述检测:子句归一化 n-gram 在 activity 里的包含率(修法②)。"""
    a, b = _norm_key(clause), _norm_key(activity)
    grams = [a[i:i + n] for i in range(0, max(0, len(a) - n), 2)]
    if not grams:
        return 0.0
    return sum(1 for g in grams if g in b) / len(grams)


def window_bg_gate(model_bg, activity, inv, ocr, engine):
    """子句级核真(修法①):逐子句过 结构闸(锚定/清单/复述) + 模型判别(B 类才留)。"""
    t = str(model_bg or "").strip()
    if len(t) < 8:
        return None
    corpus = _norm_key(ocr + "\n" + "\n".join(f"{a} {w}" for a, w in inv))
    inv_norm = {_norm_key(a) for a, _ in inv if len(_norm_key(a)) >= 3}
    keep = []
    for clause in re.split(r"[;；。]\s*", t):
        clause = clause.strip(" ,，、")
        if len(clause) < 8:
            continue

        # 结构闸:硬实体锚定(ASCII 词/引号原文;模型中文叙述不算锚点)
        anchors = set(re.findall(r"[A-Za-z][\w.-]{3,}", clause))
        anchors |= set(re.findall(r"[「『\"“]([^」』\"”]{2,30})[」』\"”]", clause))
        anchors = {a for a in anchors if len(a) >= 3}
        anchored = anchors and sum(1 for a in anchors if _norm_key(a) in corpus) / len(anchors) >= 0.6
        # 或:子句提到的 app 在窗口清单里(关系可查证)
        nc = _norm_key(clause)
        in_inv = any(a in nc for a in inv_norm)
        if not anchored and not in_inv:
            continue
        # 引号内容强制锚定(引号是结构信号):引文在 OCR/窗口标题里找不到 → 整句丢
        quoted = re.findall(r"[「『\"“]([^」』\"”]{2,30})[」』\"”]", clause)
        if quoted and any(_norm_key(q) not in corpus for q in quoted if len(_norm_key(q)) >= 3):
            continue
        if is_bg_task(clause, engine):
            # 整句是后台任务 → 整句保留,不絮碎(逗号下钻会把连贯长句切成
            # 无主语碎片逐片误杀——s432 微信场景就是这么丢的)
            if is_foreground(clause, activity, engine):      # s86 类:前台操作本身
                # 前台复合句抢救:里面可能连坐着真背景从句(回归判决残余误杀根因)
                if re.search(r"[,，]", clause):
                    subs = [s2.strip(" ,，、") for s2 in re.split(r"[,，]", clause)]
                    subs = [s2 for s2 in subs if len(s2) >= 6
                            and is_bg_task(s2, engine)
                            and not is_foreground(s2, activity, engine)]
                    if subs:
                        keep.append(",".join(subs))
                continue
            keep.append(clause)
        elif re.search(r"[,，]", clause):
            # 整句不是 → 逗号级**抢救**:混合句里埋着的真后台部分
            # (「桌面日历…,背景窗口挂着X」——判决点名的误杀主因)
            subs = []
            for s2 in re.split(r"[,，]", clause):
                s2 = s2.strip(" ,，、")
                if len(s2) < 6:
                    continue
                if is_bg_task(s2, engine):
                    subs.append(s2)
            if subs and not is_foreground(",".join(subs), activity, engine):
                keep.append(",".join(subs))
    if not keep:
        return None
    out = keep[0][:250]
    for c in keep[1:]:                    # 超长时整句丢弃,绝不词中硬断(判决点名)
        if len(out) + len(c) + 1 > 200:
            break
        out += ";" + c
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--suffix", default="b")
    ap.add_argument("--jsonl", help="闸语义写回:过闸的覆写,其余清空")
    ap.add_argument("--llm", action="store_true", help="启用小模型判别/选择(不开则只出 nowbar 直采)")
    ap.add_argument("--engine", default="mlx", choices=["mlx", "ollama"],
                    help="判别引擎:mlx=生产栈 Qwen3.5-9B-4bit(默认);ollama=qwen3:4b(调试)")
    args = ap.parse_args()

    man = json.load(open(f"/tmp/vision_v4{args.suffix}_{args.day}/v4_manifest.json"))
    con_l = labdb.connect()
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    rows = bg_by_key = None
    act_by_key = {}
    if args.jsonl:
        rows = [json.loads(l) for l in open(args.jsonl, encoding="utf-8")]
        bg_by_key = {str(r["key"]): (r["digest"].get("background") or "")
                     for r in rows if not r.get("stub")}
        act_by_key = {str(r["key"]): str(r["digest"].get("activity") or "")
                      for r in rows if not r.get("stub")}
    out = {}
    n_trig = n_menu = n_win = 0
    for k, b in man.items():
        fids = session_fids(con_l, b)
        ocr = session_ocr(con_p, fids)
        trig, cands = candidates(ocr)
        music = None
        if trig and cands:
            n_trig += 1
            cands = dedupe(cands)[:6]
            pick = None
            if len(cands) == 1 and cands[0][0] == "nowbar":
                pick = cands[0][1]                    # 挂件结构无歧义,唯一时直采
            elif args.llm:
                pick = llm_pick(cands, ocr, args.engine)   # 其余一律模型裁定(修法③)
            if pick and pick in ocr:                  # verbatim 铁闸
                pick = polish(pick)
                if not plausible_song(pick):
                    pick = None
            else:
                pick = None
            if pick:
                fg_player = args.llm and is_player(str(b.get("app") or ""), args.engine)
                music = (f"正在播放:{pick}" if fg_player else f"后台正在播放:{pick}")
                print(f"  s{k} [{b.get('app')}] ♪ {pick}  (候选{len(cands)})")
            elif cands:
                print(f"  s{k} [{b.get('app')}] 触发未裁定,候选: {[c for _, c in cands]}")
        if music is None and args.llm:
            # 降级:菜单栏结构捕获任意 app,是不是播放器交模型判别(拆白名单)
            mapps = {m.group(1).strip() for m in MENUBAR_ANY.finditer(ocr)}
            player = next((a for a in mapps if is_player(a, args.engine)), None)
            if player:
                n_menu += 1
                music = (f"{player} 在播放(歌名未能辨认)" if trig and cands
                         else f"{player} 在前台运行(屏幕未显示歌名)")
                print(f"  s{k} [{b.get('app')}] ▸ 菜单栏降级:{player}")
        wbg = None
        if bg_by_key and bg_by_key.get(k) and args.llm:
            span = session_span(con_p, fids)
            if span:
                inv = win_inventory(con_p, span[0], span[1])
                wbg = window_bg_gate(bg_by_key[k], act_by_key.get(k, ""), inv, ocr,
                                     args.engine)
                if wbg:
                    n_win += 1
                    print(f"  s{k} [{b.get('app')}] ▣ 背景窗口(子句级): {wbg[:80]}")
        parts = [p for p in (music, wbg) if p]
        if parts:
            out[k] = ";".join(parts)
    print(f"[bg_music] {args.day}: 音乐触发 {n_trig} / 菜单栏降级 {n_menu} / 窗口核真 {n_win}"
          f" / 共 {len(man)},裁定 {len(out)}")
    if args.jsonl:
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
        print(f"写回 {n_w} 条,清掉未过闸的模型 bg {n_wipe} 条 → {args.jsonl}")


main()
