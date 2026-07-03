"""确定性特征提取 —— 本实验室的骨架。

核心理念(见 桌面·写作风格提炼审查文档 §3):把"判断"尽量下沉到纯 Python,
让本地小模型只做"给这个已经量好的信号起个名 / 确认",而不是"从原始数据里发现"。
所有函数零 LLM、纯确定性、可单测。

三组信号:
  ks_features(击键流)   —— 输入法 / 句中切换 / 打字速度 / 拼音节奏(维度③)
  text_features(终稿)   —— 句号语用 / 盘古之白 / 结构提示(维度⑤①)
  editlog_features(时序)—— 一次成稿 vs 删改 / 发送边界(维度④⑥)

击键窗口用 app(bundle_id)+ 时间窗 [start_ts,end_ts] join,
**不**用 reference_keystroke_range(实测多为 '{}',见审查文档)。
"""
import json
import re

HAN = re.compile(r"[一-鿿]")
LATIN = re.compile(r"[A-Za-z]")
_CJK = r"一-鿿぀-ヿ가-힯"      # 汉字 + 假名 + 谚文


# ---------------- 输入源 → 人类可读输入法 ----------------

def ime_human(source: str) -> str:
    if not source:
        return "unknown"
    s = source.lower()
    if "keylayout" in s and ("abc" in s or "us" in s or "british" in s):
        return "english"
    if any(k in s for k in ("itabc", "scim", "squirrel", "rime", "pinyin", "shuangpin")):
        return "pinyin"
    if "wubi" in s:
        return "wubi"
    if "keylayout" in s:
        return "keyboard-latin"
    return source.split(".")[-1]


# ---------------- 击键流特征(维度③ 输入习惯) ----------------

def ks_features(ks_rows) -> dict:
    """ks_rows: 该记录 app+时间窗内的 keystroke_log 行(按 ts 升序),
    每行需有 ts_ms / char / is_backspace / input_source。"""
    n = len(ks_rows)
    if n == 0:
        return {"ks_count": 0}

    # 输入法分布 + 句中切换次数(忽略 null 源)
    src_counts = {}
    switches = 0
    last_hu = None
    for r in ks_rows:
        hu = ime_human(r["input_source"]) if r["input_source"] else None
        if hu:
            src_counts[hu] = src_counts.get(hu, 0) + 1
            if last_hu is not None and hu != last_hu:
                switches += 1
            last_hu = hu
    total_src = sum(src_counts.values()) or 1
    ime_share = {k: round(v / total_src, 2) for k, v in
                 sorted(src_counts.items(), key=lambda kv: -kv[1])}
    ime_primary = next(iter(ime_share), "unknown") if ime_share else "unknown"

    # 打字速度:相邻击键间隔(ms)
    ts = [r["ts_ms"] for r in ks_rows]
    gaps = [b - a for a, b in zip(ts, ts[1:]) if 0 < (b - a) < 60_000]
    gaps_sorted = sorted(gaps)

    def pct(p):
        if not gaps_sorted:
            return None
        i = min(len(gaps_sorted) - 1, int(p * len(gaps_sorted)))
        return gaps_sorted[i]

    span_ms = (ts[-1] - ts[0]) or 1
    ks_per_min = round(n / (span_ms / 60_000), 1)
    pause_count = sum(1 for g in gaps if g > 1500)

    # 拼音节奏:连续拉丁 run 平均长度 + 选词数字键次数(拼音特征)
    runs, run = [], 0
    digit_picks = 0
    prev_latin = False
    bs = 0
    for r in ks_rows:
        ch = r["char"] or ""
        if r["is_backspace"]:
            bs += 1
        if ch and ch.isascii() and ch.isalpha():
            run += 1
            prev_latin = True
        else:
            if run:
                runs.append(run); run = 0
            if ch.isdigit() and prev_latin:
                digit_picks += 1
            prev_latin = False
    if run:
        runs.append(run)
    mean_latin_run = round(sum(runs) / len(runs), 1) if runs else 0.0

    # input_source 缺失时(v41 前的老击键)从节奏推断输入法:
    # 拼音特征 = 有选词数字键 + 拉丁 run 短(音节级);英文直入 = run 长且无选词。
    input_source_seen = bool(src_counts)
    n_runs = len(runs)
    if input_source_seen:
        ime_inferred = ime_primary
    elif digit_picks >= 3 and mean_latin_run <= 7:
        ime_inferred = "likely_pinyin"       # 选词数字键 = 拼音候选
    elif mean_latin_run >= 8 and digit_picks == 0:
        ime_inferred = "likely_english"
    elif n_runs == 0:
        ime_inferred = "cjk_or_nonlatin"
    else:
        ime_inferred = "unknown"

    return {
        "ks_count": n,
        "input_source_seen": input_source_seen,   # False = 只能靠 ime_inferred 启发式
        "ime_share": ime_share,          # {"pinyin":0.52,"english":0.48}(input_source 有值时)
        "ime_primary": ime_primary,
        "ime_inferred": ime_inferred,    # input_source 缺失时的节奏推断
        "ime_switches": switches,        # 句中切换输入法次数
        "ks_per_min": ks_per_min,
        "gap_median_ms": pct(0.5),
        "gap_p90_ms": pct(0.9),
        "pause_count": pause_count,      # >1.5s 停顿数(思考/回看)
        "mean_latin_run": mean_latin_run,   # 拼音音节 run 平均长(拼音≈2-6,英文更长)
        "digit_picks": digit_picks,      # 选词数字键(拼音特征)
        "backspace_ratio": round(bs / n, 2),
    }


# ---------------- 终稿文本特征(维度⑤ 标点 · ① 结构提示) ----------------

def text_features(text: str) -> dict:
    t = text or ""
    stripped = t.rstrip()
    ending = "none"
    if stripped:
        last = stripped[-1]
        ending = {"。": "cjk_period", ".": "latin_period", "！": "cjk_bang",
                  "!": "latin_bang", "？": "cjk_q", "?": "latin_q",
                  "…": "ellipsis", "，": "comma", "~": "tilde",
                  "、": "dun"}.get(last, "other")

    # 盘古之白:CJK↔ASCII 词/数 边界,有多少插了空格
    boundaries = re.findall(rf"([{_CJK}])([A-Za-z0-9])|([A-Za-z0-9])([{_CJK}])", t)
    n_bound = len(boundaries)
    spaced = len(re.findall(rf"[{_CJK}] +[A-Za-z0-9]|[A-Za-z0-9] +[{_CJK}]", t))
    pangu_ratio = round(spaced / n_bound, 2) if n_bound else None

    han = len(HAN.findall(t))
    latin = len(LATIN.findall(t))

    # 结构轻提示(只给线索,判断交给 LLM):句尾语气词 / 反问词
    final_particles = len(re.findall(r"[啊呀吧呢嘛哈嘞噢喔]\s*$", t, re.M))
    rhetorical_hint = bool(re.search(r"(难道|岂|何必|不是.*吗|还能|谁|凭啥|凭什么)", t))

    return {
        "char_len": len(t),
        "han": han, "latin": latin,
        "ending": ending,
        "pangu_ratio": pangu_ratio,      # None=无中英边界;0=从不空;1=总空
        "pangu_boundaries": n_bound,
        "final_particles": final_particles,
        "rhetorical_hint": rhetorical_hint,
    }


# ---------------- edit_log 时序特征(维度④⑥ 修改/写作节奏) ----------------

def editlog_features(edit_log_json: str) -> dict:
    try:
        arr = json.loads(edit_log_json) if edit_log_json else []
        if not isinstance(arr, list):
            arr = []
    except Exception:
        arr = []
    n_commit = n_delete = n_send = 0
    del_chars = com_chars = 0
    max_delete_run = cur = 0
    for e in arr:
        k = (e.get("kind") or "") if isinstance(e, dict) else ""
        txt = (e.get("text") or "") if isinstance(e, dict) else ""
        if k == "commit":
            n_commit += 1; com_chars += len(txt); cur = 0
        elif k == "delete":
            n_delete += 1; del_chars += len(txt); cur += 1
            max_delete_run = max(max_delete_run, cur)
        elif k in ("send", "submit"):
            n_send += 1; cur = 0
    total = n_commit + n_delete or 1
    return {
        "edit_entries": len(arr),
        "n_commit": n_commit, "n_delete": n_delete, "n_send": n_send,
        "delete_ratio": round(n_delete / total, 2),
        "deleted_chars": del_chars, "committed_chars": com_chars,
        "one_shot": n_delete == 0 and n_commit > 0,   # 一次成稿
        "max_delete_run": max_delete_run,             # 连删爆发(批量纠错信号)
    }


def record_features(text, edit_log_json, ks_rows) -> dict:
    return {**text_features(text),
            **editlog_features(edit_log_json),
            **ks_features(ks_rows)}


# ---------------- 组级聚合(喂 prompt 用) ----------------

def _avg(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def aggregate(records) -> dict:
    """把一个 app-group 内多条 record 的特征聚合成组级摘要,喂给维度 agent。
    records: labdb rows(含 features json 列)。"""
    feats = [json.loads(r["features"]) for r in records]
    n = len(feats)
    # 输入法总体分布
    ime_tot = {}
    for f in feats:
        for k, v in (f.get("ime_share") or {}).items():
            ime_tot[k] = ime_tot.get(k, 0) + v
    s = sum(ime_tot.values()) or 1
    ime_share = {k: round(v / s, 2) for k, v in
                 sorted(ime_tot.items(), key=lambda kv: -kv[1])}
    # input_source 缺失时的推断输入法(取组内多数)
    inf = {}
    for f in feats:
        v = f.get("ime_inferred")
        if v and v not in ("unknown",):
            inf[v] = inf.get(v, 0) + 1
    ime_inferred = max(inf, key=inf.get) if inf else "unknown"
    any_src = any(f.get("input_source_seen") for f in feats)
    # 句尾分布
    endings = {}
    for f in feats:
        endings[f.get("ending", "none")] = endings.get(f.get("ending", "none"), 0) + 1
    return {
        "n_records": n,
        "ks_total": sum(f.get("ks_count", 0) for f in feats),
        "ime_share": ime_share,
        "ime_inferred": ime_inferred,      # input_source 缺失时的节奏推断
        "input_source_seen": any_src,      # False = ime_share 空,靠 ime_inferred
        "ime_switches_total": sum(f.get("ime_switches", 0) for f in feats),
        "ks_per_min_avg": _avg([f.get("ks_per_min") for f in feats]),
        "gap_median_ms_avg": _avg([f.get("gap_median_ms") for f in feats]),
        "pause_count_total": sum(f.get("pause_count", 0) for f in feats),
        "mean_latin_run_avg": _avg([f.get("mean_latin_run") for f in feats]),
        "digit_picks_total": sum(f.get("digit_picks", 0) for f in feats),
        "backspace_ratio_avg": _avg([f.get("backspace_ratio") for f in feats]),
        "ending_dist": dict(sorted(endings.items(), key=lambda kv: -kv[1])),
        "pangu_ratio_avg": _avg([f.get("pangu_ratio") for f in feats]),
        "one_shot_rate": round(sum(1 for f in feats if f.get("one_shot")) / (n or 1), 2),
        "delete_ratio_avg": _avg([f.get("delete_ratio") for f in feats]),
        "max_delete_run": max([f.get("max_delete_run", 0) for f in feats], default=0),
        "send_total": sum(f.get("n_send", 0) for f in feats),
    }
