"""EventSessionVision-1.2 全天 digest 生成(一层替掉原「视觉8B逐帧 + 9B汇总」两层)。

对每个会话:首帧图 + OCR全文(注入) → v1.2 直出 {activity, who, context_in_app,
specifics, social} → activity 当 doing、specifics+who 当 kw,写成与
`视觉增量v4-<day>.md` 同格式的 MD,供 cluster_skeleton.load_sessions 直接消费。

部署配置(验收定案):6bit MLX / 单图 / 401K px / repetition_penalty 1.05。
断点续跑:已完成的 key 跳过。

用法: python v12_day.py --day 2026-06-07 --out /tmp/v12_day_2026-06-07.md
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chrome  # noqa: E402
import labdb  # noqa: E402
import source  # noqa: E402
from t2_data_v12 import dedup_lines  # noqa: E402  训推共用同一份 OCR 去重(防 skew)

MODEL = os.path.expanduser("~/Models/EventSessionVision-1.2-6bit-mlx")
MODEL_TAG = "EventSessionVision-1.2-6bit"   # 血统戳(落库,供复用方筛版本)
OCR_CAP = 10000
SPEC_CAP = 12
WIN_CAP = 80
SPIN = re.compile(r"[✳⠀-⣿]")     # Claude Code spinner(✳ + braille);◂ 是命令分隔符,须保留
RULES = ("规则:specifics 的逐字锚点必须逐字来自上方 OCR 文本;画面负责布局与归属,"
         "OCR 负责文字转写;两处都没有的内容宁可不写;无法辨认的部分直接省略。")
SCHEMA = ('输出 JSON:\n{"activity":"2-4句中文连贯叙述用户在做什么(技术token保原文)",'
          '"who":["交互的人,排除用户自己"],"context_in_app":"app内位置:哪个对话/频道/页面/文档(别复述app名)",'
          '"specifics":["逐字锚点:文件名/hash/报错/金额/引语"],"social":"社交生活内容一句话或空"}')


def norm(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


def clean_window(w):
    """复刻训练侧窗口标题口径:剥 spinner → 收缩空格 → 截 80。已对 6-07 逐字节校验 337/337。"""
    return re.sub(r"\s{2,}", " ", SPIN.sub("", w or "")).strip()[:WIN_CAP]


DEV_APPS = {"Terminal", "iTerm2", "Xcode", "Code", "Cursor", "My Portrait", "My Meeting",
            "MyPortrait"}


def app_field(app, win, ocr_block):
    """--attr-hint:给「前台 app 不是真实工作对象」的会话补一句确定性注释。

    6-05 实测:非开发前台 + 窗口标题空 + 画面有开发信号 三条同时成立时,归属错误率
    57%,而不满足的对照组只有 5%(11 倍富集)。三条全部线上可确定性复现。

    注释形状刻意模仿教师当年的写法(训练集 51% 的 app 字段就是「名字 + 补充分句」),
    所以落在训练分布内 —— 区别是这次的内容由函数算出,不是人工解读。
    """
    if app not in DEV_APPS and not win and chrome.has_dev_signal(ocr_block):
        return f"{app}(前台但无窗口,画面实际是终端/代码内容,真实工作对象在背景)"
    return app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default="2026-06-07")
    ap.add_argument("--suffix", default="c")     # manifest 后缀:6-07 用 c,其余 b
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-pixels", type=int, default=401408)
    ap.add_argument("--rep-penalty", type=float, default=1.05)
    ap.add_argument("--ocr-cap", type=int, default=OCR_CAP)
    ap.add_argument("--max-tokens", type=int, default=1600)
    ap.add_argument("--redo-bad", action="store_true")   # 只重跑降级会话
    ap.add_argument("--dry-prompts")   # 只导题面到此 json、不加载模型(训推口径自检用)
    ap.add_argument("--model", default=MODEL)            # A/B:可指向原版底座做对照
    ap.add_argument("--model-tag", default=MODEL_TAG)    # 血统戳
    ap.add_argument("--keys")                            # 只跑这些 key(逗号分隔),抽样 A/B 用
    # vision_items 按 (day,session_key) 唯一 —— 对照组落库会覆盖生产 digest(可复用资产)。
    # 故 base 对照必须 --no-db:只写 <out>.jsonl,断点续跑也认它。
    ap.add_argument("--no-db", action="store_true")
    ap.add_argument("--attr-hint", action="store_true")  # 归属提示(确定性),默认关 —— 实验中
    args = ap.parse_args()

    manifest = json.load(open(f"/tmp/vision_v4{args.suffix}_{args.day}/v4_manifest.json"))
    frames_dir = f"/tmp/vision_frames_v4{args.suffix}_{args.day}"
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    con_l = labdb.connect()

    only = set(args.keys.split(",")) if args.keys else None
    jl_path = args.out + ".jsonl"      # 两跑各自的完整 digest 记录(评测直接吃这个)
    dry = {} if args.dry_prompts else None
    if dry is None:
        if args.no_db:                 # 对照组:断点续跑认自己的 jsonl
            done = set()
            if os.path.exists(jl_path):
                done = {int(json.loads(l)["key"]) for l in open(jl_path, encoding="utf-8")}
        else:
            have = labdb.vision_digests_for_day(con_l, args.day, model=args.model_tag)
            done = {k for k, d in have.items()
                    if not (args.redo_bad and not d.get("json_ok"))}   # --redo-bad:降级的重跑
        todo = [k for k in manifest if int(k) not in done and (only is None or k in only)]
        print(f"[v12] {args.day} · {args.model_tag}: {len(manifest)} 会话"
              f"(已完成 {len(done)},待跑 {len(todo)})", flush=True)
        from mlx_vlm import load, generate
        from mlx_vlm.prompt_utils import apply_chat_template
        model, processor = load(args.model)
        if hasattr(processor, "image_processor"):
            processor.image_processor.max_pixels = args.max_pixels
    else:
        todo = [k for k in manifest if only is None or k in only]

    out = open(args.out, "a", encoding="utf-8")
    jl = open(jl_path, "a", encoding="utf-8")
    t0 = time.time()
    n_bad = n_empty = 0
    for i, key in enumerate(todo):
        b = manifest[key]
        # OCR 块:manifest kept 帧的 full_text(行级去重 + 预算,与训练同构)
        fids, win = [], ""
        for i_p, pid in enumerate(b["parts"]):
            r = con_l.execute("SELECT frame_ids, window FROM raw_sessions WHERE id=?",
                              (pid,)).fetchone()
            row_fids, row_win = (r["frame_ids"], r["window"]) if hasattr(r, "keys") else (r[0], r[1])
            fids += json.loads(row_fids)
            if i_p == 0:                      # 训练口径:只认 parts[0] 的窗口标题(为空也写"(空)")
                win = clean_window(row_win)
        texts, seen = [], set()
        for k, _ in b["frames"]:
            if k >= len(fids):
                continue
            row = con_p.execute("SELECT COALESCE(full_text,'') FROM frames WHERE id=?",
                                (fids[k],)).fetchone()
            t = dedup_lines(chrome.strip_session_text((row[0] or "").strip())) if row else ""
            if t and t not in seen:
                seen.add(t)
                texts.append(t)
        n = max(1, len(texts))
        alloc = [min(len(t), args.ocr_cap // n) for t in texts]
        left = args.ocr_cap - sum(alloc)
        for j, t in enumerate(texts):
            if left <= 0:
                break
            add = min(left, len(t) - alloc[j])
            alloc[j] += add
            left -= add
        ocr_block = "\n".join(f"[帧{j+1}] {t[:alloc[j]]}" for j, t in enumerate(texts))
        # ⚠️ 默认 app 用裸名(raw_sessions.app)。训练题头 51% 的 app 掺了教师解读(如「Spotify(前台
        # 但仅播放音乐未操作);真实工作对象是…」)——那是线上拿不到的东西,注入即作弊。代价是模型
        # 失去归属拐杖:6-05 实测归属错误 11%(前台微信却写「在微信里开 Claude Code」)。
        # --attr-hint 用确定性检测重建这个提示(见 app_field 注释)。
        app = app_field(b["app"], win, ocr_block) if args.attr_hint else b["app"]
        q = (f"分析这段 macOS 屏幕会话的截图。已知(系统API):前台 app = {app}"
             f";窗口标题 = {win or '(空)'}。\n"
             f"已知(OCR全文,按帧,含背景窗文字):\n<<<\n{ocr_block}\n>>>\n{SCHEMA}\n{RULES}")
        corpus = norm(ocr_block + b["app"])
        if dry is not None:
            dry[key] = q
            continue

        jpg = os.path.join(frames_dir, b["frames"][0][1])   # 生产口径:单图
        formatted = apply_chat_template(processor, model.config, q, num_images=1)
        try:
            o = generate(model, processor, formatted, [jpg], max_tokens=args.max_tokens,
                         temperature=0.1, verbose=False,
                         repetition_penalty=args.rep_penalty, repetition_context_size=40)
            txt = o if isinstance(o, str) else getattr(o, "text", str(o))
        except Exception as e:
            txt = ""
            print(f"  ! s{key} GEN_ERROR {type(e).__name__}", flush=True)
        if not txt.strip():                       # mlx bug 空输出 → 重试一次
            n_empty += 1
            try:
                o = generate(model, processor, formatted, [jpg], max_tokens=args.max_tokens,
                             temperature=0.3, verbose=False,
                             repetition_penalty=args.rep_penalty, repetition_context_size=40)
                txt = o if isinstance(o, str) else getattr(o, "text", str(o))
            except Exception:
                txt = ""
        ok_json = True
        try:
            a = json.loads(txt[txt.index("{"):txt.rindex("}") + 1])
        except Exception:
            n_bad += 1
            ok_json = False
            a = {"activity": (txt[:300] or f"[空] {b['app']} 会话"), "specifics": [], "who": []}
        doing = re.sub(r"\s+", " ", str(a.get("activity") or "")).strip()[:900]
        # kw:确定性 = 校验通过的 specifics(去重、cap) + who + app
        kws, seenk = [], set()
        for s in (a.get("specifics") or []):
            k = norm(s)
            if k and k in corpus and k not in seenk:
                seenk.add(k)
                kws.append(str(s).strip()[:60])
        kws_verified = list(kws)          # 只含过了 OCR 校验的 specifics
        for w in (a.get("who") or []):
            if str(w).strip():
                kws.append(str(w).strip()[:30])
        kws = kws[:SPEC_CAP]
        # ① 落库:全量结构化 digest(可复用资产 —— event / writing-style / personality 都吃)
        digest = {"activity": doing,
                  "who": [str(w).strip()[:40] for w in (a.get("who") or []) if str(w).strip()],
                  "context_in_app": str(a.get("context_in_app") or "").strip()[:300],
                  "specifics": kws_verified,        # 已过 OCR 逐字校验
                  "social": str(a.get("social") or "").strip()[:300],
                  "specifics_raw_n": len(a.get("specifics") or []),
                  "json_ok": ok_json}
        if not args.no_db:
            labdb.save_vision_digest(con_l, args.day, int(key), b["parts"], b["app"],
                                     args.model_tag, b["total_frames"], b["kept_frames"], digest)
        # ② JSONL:两跑各自的完整记录 + 评测所需的诊断维度(OCR 长度/帧数)
        jl.write(json.dumps({"key": int(key), "app": b["app"], "model": args.model_tag,
                             "ocr_len": len(ocr_block), "n_frames": len(b["frames"]),
                             "raw_len": len(txt), "digest": digest},
                            ensure_ascii=False) + "\n")
        jl.flush()
        # ③ MD:下游 event 管线的私有视图(load_sessions 只认 doing/kw)
        out.write(f"\n## s{key} · {b['app']} · parts={b['parts']}\n")
        out.write(f"- doing: {doing}\n")
        out.write(f"- kw: {', '.join(kws)}\n")
        out.flush()
        if (i + 1) % 20 == 0:
            el = time.time() - t0
            print(f"  {i+1}/{len(todo)} · {el/(i+1):.0f}s/会话 · 剩 {(len(todo)-i-1)*el/(i+1)/60:.0f}min "
                  f"· 坏JSON {n_bad} 空重试 {n_empty}", flush=True)
    out.close()
    jl.close()
    if dry is not None:
        json.dump(dry, open(args.dry_prompts, "w"), ensure_ascii=False)
        print(f"[dry] {len(dry)} 条题面 → {args.dry_prompts}", flush=True)
        return
    print(f"[done] {len(todo)} 会话 · {time.time()-t0:.0f}s · 坏JSON {n_bad} · 空输出重试 {n_empty} "
          f"→ {args.out}", flush=True)


main()
