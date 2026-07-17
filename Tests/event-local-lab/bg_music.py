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
    """与 v12_day 同路径:parts→frame_ids→frames.full_text(kept 帧)。"""
    fids = []
    for pid in b["parts"]:
        r = con_l.execute("SELECT frame_ids FROM raw_sessions WHERE id=:id",
                          {"id": pid}).fetchone()
        if r:
            fids += json.loads(r[0])
    texts = []
    for k, _ in b.get("frames") or []:
        if k >= len(fids):
            continue
        row = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=:id",
                            {"id": fids[k]}).fetchone()
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


def good_cand(seg):
    """「曲名 - 歌手」结构闸:DASH 格式 + 非文件名 + 分隔符不是 ASCII 词内连字符。"""
    if not DASH.match(seg) or FILEISH.search(seg) or UI.search(seg):
        return False
    if re.search(r"[A-Za-z0-9][-—·][A-Za-z0-9]", seg) and not re.search(r"\s[-—·]\s", seg):
        return False   # My-Meetin 这种词内连字符,且全串无带空格的真分隔符 → 不是歌名
    return True


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


def llm_pick(cands, ctx):
    """小模型选择题(qwen3:4b/ollama):只准回编号或 none。失败/不可用 → None(保守)。"""
    # 「都不是」列成显式选项:1.7b 对 -1 这种带外弃权几乎不选,列进去才会选
    opts = "\n".join(f"{i}. {c}" for i, c in enumerate(cands))
    opts += f"\n{len(cands)}. 都不是(以上是文件名/界面文字/项目名,没有歌曲名)"
    prompt = (f"屏幕OCR片段:\n{ctx[:600]}\n\n候选:\n{opts}\n\n"
              f"哪个候选是正在播放的歌曲名(或 曲名-歌手)?文件名/界面文字/菜单项/代码项目名都不算。"
              f'只输出 JSON:{{"pick": 编号}}')
    try:
        req = urllib.request.Request(
            "http://localhost:11434/api/generate",
            json.dumps({"model": "qwen3:4b", "prompt": prompt, "stream": False,
                        "think": False,   # qwen3 思考模式与 format 强制打架(4b 直接空响应),关掉弃权才正常
                        "format": {"type": "object", "properties": {"pick": {"type": "integer"}},
                                   "required": ["pick"]},
                        "options": {"num_ctx": 2048, "temperature": 0}}).encode(),
            {"Content-Type": "application/json"})
        r = json.loads(urllib.request.urlopen(req, timeout=60).read())
        p = json.loads(r["response"]).get("pick", -1)
        return cands[p] if 0 <= p < len(cands) else None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", required=True)
    ap.add_argument("--suffix", default="b")
    ap.add_argument("--jsonl", help="把音乐 bg 写回此 jsonl(原 bg 为空才写)")
    ap.add_argument("--llm", action="store_true", help="多候选时用 qwen3:4b 选择(默认只采唯一候选)")
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
            pick = None
            if len(cands) == 1:
                pick = cands[0]
            elif len(cands) > 1 and args.llm:
                pick = llm_pick(cands, ocr)
            if pick and pick in ocr:              # verbatim 铁闸
                out[k] = f"后台正在播放:{pick}"
                print(f"  s{k} [{b.get('app')}] ♪ {pick}"
                      + (f"  (候选{len(cands)})" if len(cands) > 1 else ""))
                continue
            elif cands:
                print(f"  s{k} [{b.get('app')}] 一级触发但未裁定,候选: {cands}")
        # 二级:菜单栏归属但歌名不在屏上 → 降级产出(诚实上限,不猜歌名)
        player = menubar_player(ocr)
        if player:
            n_menu += 1
            out[k] = f"{player} 在前台运行(屏幕未显示歌名)"
            print(f"  s{k} [{b.get('app')}] ▸ 菜单栏降级:{player}")
    print(f"[bg_music] {args.day}: 一级触发 {n_trig} / 菜单栏降级 {n_menu} / 共 {len(man)},裁定 {len(out)}")
    if args.jsonl and out:
        rows = [json.loads(l) for l in open(args.jsonl, encoding="utf-8")]
        n_w = 0
        for r in rows:
            k = str(r["key"])
            if k in out and not (r["digest"].get("background") or "").strip():
                r["digest"]["background"] = out[k]
                n_w += 1
        with open(args.jsonl, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"写回 {n_w} 条 → {args.jsonl}")


main()
