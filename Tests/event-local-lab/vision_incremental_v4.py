#!/usr/bin/env python3
"""视觉增量 v4(分工架构):视觉只看图,14B 汇总,各干窄活。

管线:
 0) 会话合并:A 被 <MIN_INTERRUPT_FRAMES 帧的短 session 打断后又是同 app A → 忽略
    短打断帧、两段 A 并一个;打断 ≥阈值则当真不并。
 1) 选帧两段:① 每帧 OCR 相似度去重(跟上一张留帧 Jaccard<THR_SIM 才留);
    ② 字数变化大、去重后仍多帧的段,按 coef 封顶稀疏(budget=clamp(total*COEF))。
 2) 【视觉 8B · 窄活】逐帧 **只看图** → 出 items(append-only,只加不删历史)。
 3) 【14B · 难活】汇总:吃(视觉 items)+(整段**去重 OCR 并集**,生产口径)→ 合成
    digest:用 OCR 纠正视觉看糊/读错的精确字串、补视觉漏的具体项,丢弃 OCR 乱码/chrome。
 4) 【14B】标签:从 digest 精选(沿用 v3 P_TAGS)。
分工理由:小模型干窄活(看图)更稳;对照纠错+合成本质是文本难活,交更强的 14B。
OCR 并集还白捡了"近全文字覆盖"(补上之前生产靠全量 OCR 赢的缺口)。

  python3 vision_incremental_v4.py --extract [--all]    # 选帧+OCR并集+抽帧(无模型)
  python3 vision_incremental_v4.py --model <id> --tag q3-8b   # 视觉8B 出 items
  python3 vision_incremental_v4.py --finalize --tag q3-8b     # 14B 汇总+标签
  python3 vision_incremental_v4.py --report
⚠️ --model/--finalize 跑模型;--extract/--report 不占 GPU。
"""
import argparse, collections, json, os, re, sqlite3, subprocess, time
import labdb, source
from vision_incremental_v3 import P_TAGS, SMALL_TAG_MODEL   # 标签段沿用 v3(14B)

ANCHORS = [914, 147, 38, 934, 250, 3]
# 环境变量控日/版本后缀(防覆盖冻结产物:V4_SUFFIX=b → 视觉增量v4b-<day>.md)
DAY = os.environ.get("V4_DAY", "2026-06-07")
SUFFIX = os.environ.get("V4_SUFFIX", "")
OUTDIR = f"/tmp/vision_v4{SUFFIX}_{DAY}"
FRAMES_DIR = f"/tmp/vision_frames_v4{SUFFIX}_{DAY}"
OBS = "/Users/joyzhang14/Desktop/Obsidian/event pipeline local"
MANIFEST = os.path.join(OUTDIR, "v4_manifest.json")
DEFAULT_MODEL = "mlx-community/Qwen3-VL-8B-Instruct-8bit"
MERGE_MODEL = SMALL_TAG_MODEL                     # 汇总+标签都用 14B
MAXPIX = 1_600_000
MIN_INTERRUPT_FRAMES = 3
THR_SIM = 0.7
COEF = 0.15
FLOOR, CEIL = 1, 12
# 6000(原1500):14B是32K上下文,1500字符是质量线实测"粘合剂丢失"三个口子之一
# (质量分析 7-02:因果链/hash/数字/原话 55-60% 丢在汇总层)
OCR_UNION_CAP = 6000
_WORD = re.compile(r"[A-Za-z0-9_]+|[一-鿿]")

# 视觉:只看图,出 items(append-only)
P_ITEMS_FIRST = (
    'Screenshot from a macOS work session (foreground app: {app}). List the SPECIFIC '
    'things visible / that the user is doing: exact file names, libraries, people, numbers, '
    'actions, topics. Include short quoted user-typed text and person names VERBATIM in their '
    'original script (any language). Ignore UI chrome (menu bars, clocks, sidebars). If a '
    'media app is foreground but the real content is code/terminal/docs/chat, that work is '
    'the activity. Reply ONLY JSON: {{"items":["<specific item>", ...]}}')
P_ITEMS_NEXT = (
    'Specific items ALREADY recorded for THIS SAME session (do NOT repeat any):\n{items}\n\n'
    'A LATER screenshot from the same session (app: {app}). Output ONLY NEW specific items '
    'visible now that are NOT already in the list above. Include short quoted user-typed text '
    'and person names VERBATIM (any language); prefer recall — when unsure whether an item is '
    'new or specific enough, include it. Ignore UI chrome. If nothing is genuinely new, return '
    'an empty list. Reply ONLY JSON: {{"items":["<new item>", ...]}}')

# 14B 汇总:items + 去重OCR → digest(对照纠错 + 补全 + 去乱码)
P_MERGE = (
    'Summarize ONE macOS work session (foreground app: {app}) into 2-3 sentences.\n\n'
    'A vision model viewed screenshots across the session and extracted these specific '
    'items (time order):\n{items}\n\n'
    'Raw OCR text captured from the screen during the session (may contain OCR errors, '
    'garbled characters, and UI chrome — but it holds the EXACT on-screen strings):\n'
    '"""{ocr}"""\n\n'
    'Write ONE clean 2-3 sentence summary of what the user DID across the whole session.\n'
    '- LEAD with the dominant activity (what {app} was actually used for).\n'
    '- Use the OCR to CORRECT any garbled name / file / identifier in the vision items, and '
    'to ADD exact specifics (files, people, numbers) the vision missed.\n'
    '- Ignore OCR chrome / garbage; invent nothing not supported by the items or OCR.\n'
    '- Keep every real specific. Reply ONLY JSON: {{"doing":"<2-3 sentences>"}}')

# 14B 汇总 v2(质量线 7-02 定向修:粘合剂四类 55-60% 丢在此层;多part尾部整块蒸发)
P_MERGE2 = (
    'Summarize ONE macOS work session (foreground app: {app}, recorded in {nparts} '
    'consecutive window segments) into 2-5 sentences.\n\n'
    'A vision model viewed screenshots across the session and extracted these specific '
    'items (time order):\n{items}\n\n'
    'Raw OCR text captured from the screen during the session (may contain OCR errors, '
    'garbled characters, and UI chrome — but it holds the EXACT on-screen strings):\n'
    '"""{ocr}"""\n\n'
    'Write ONE clean 2-5 sentence summary of what the user DID across the WHOLE session.\n'
    '- LEAD with the dominant activity, then cover the rest — content near the END of the '
    'OCR is from LATER window segments: do not drop it.\n'
    '- PRESERVE VERBATIM when present: commit hashes / IDs, exact numbers and number pairs, '
    'version strings, person names (any language), and short quoted user text.\n'
    '- If the session shows a cause→effect chain (error → root cause → fix / decision), '
    'state the CHAIN, not just one entity from it.\n'
    '- Use the OCR to CORRECT garbled names / files / identifiers in the vision items, and '
    'to ADD exact specifics the vision missed.\n'
    '- Ignore OCR chrome / garbage; invent nothing not supported by the items or OCR.\n'
    'Reply ONLY JSON: {{"doing":"<2-5 sentences>"}}')

# R9 确定性锚点旁路:hash/百分比/版本/带单位数字直读帧OCR进kw,不经14B
# (质量线实测:hash保留23%/数字~15% → 旁路≈100%;≥2帧复现门=学习日OCR碎渣免疫,hash免复现)
_HASH_RX = re.compile(r"\b[0-9a-f]{7,10}\b")
_PCT_RX = re.compile(r"\b\d+(?:\.\d+)?%")
_VER_RX = re.compile(r"\bv?\d+\.\d+\.\d+\b")
_UNIT_RX = re.compile(r"\b\d+(?:\.\d+)?(?:ms|min|px|fps|hz|kb|mb|gb)\b")


def bypass_anchors(con_p, frame_ids, cap=8):
    # GOLD_v2:裸百分比(80%类)是连接词隐患(79/337条kw中招),不进kw;
    # 百分比的保留交给 P_MERGE2 的 doing 层(verbatim 规则),锚点层只要判别 token。
    freq, hashes = collections.Counter(), collections.Counter()
    for fid in frame_ids:
        ft = _frame_ocr(con_p, fid).lower()
        for rx in (_VER_RX, _UNIT_RX):
            for t in set(rx.findall(ft)):
                freq[t] += 1
        for h in set(_HASH_RX.findall(ft)):
            if any(c.isdigit() for c in h) and any(c.isalpha() for c in h):
                hashes[h] += 1
    out = [t for t, c in freq.most_common() if c >= 2][:cap]
    out += [h for h, _ in hashes.most_common(3) if h not in out]
    return out[:cap + 3]


# ---------------- 会话合并(已单测) ----------------

def merge_sessions(rows):
    sess = [{"id": r["id"], "app": r["app"], "frames": json.loads(r["frame_ids"])}
            for r in rows]
    merged, consumed = [], set()
    i = 0
    while i < len(sess):
        if i in consumed:
            i += 1; continue
        cur = {"parts": [sess[i]["id"]], "app": sess[i]["app"],
               "frames": list(sess[i]["frames"])}
        j = i + 1
        while j + 1 < len(sess):
            mid, nxt = sess[j], sess[j + 1]
            if len(mid["frames"]) < MIN_INTERRUPT_FRAMES and nxt["app"] == cur["app"]:
                cur["frames"] += nxt["frames"]; cur["parts"].append(nxt["id"])
                consumed.add(j); consumed.add(j + 1); j += 2
            else:
                break
        merged.append(cur)
        i = j if j > i + 1 else i + 1
    return merged


# ---------------- 选帧 + OCR 并集 ----------------

def _frame_ocr(con_p, fid):
    r = con_p.execute("SELECT full_text FROM frames WHERE id=?", (fid,)).fetchone()
    return r["full_text"] if r and r["full_text"] else ""


def _words(ft):
    return set(_WORD.findall((ft or "").lower()))


def select_frames(con_p, frame_ids):
    """① OCR 相似度去重 → ② coef 封顶稀疏。返回 [(原序号, fid)]。"""
    total = len(frame_ids)
    dedup, last = [], None
    for k, fid in enumerate(frame_ids):
        w = _words(_frame_ocr(con_p, fid))
        if last is None or (len(w & last) / (len(w | last) or 1)) < THR_SIM:
            dedup.append((k, fid)); last = w
    budget = max(FLOOR, min(CEIL, round(total * COEF)))
    if len(dedup) <= budget:
        return dedup
    if budget == 1:
        return [dedup[len(dedup) // 2]]
    return [dedup[round(i * (len(dedup) - 1) / (budget - 1))] for i in range(budget)]


def build_ocr_union(con_p, frame_ids, cap=OCR_UNION_CAP):
    """整段所有帧 full_text 的**词级去重并集**(full_text 是无换行 blob,按词去重才
    能跨帧真覆盖)。按出现序保留每个没见过的词,累计到 cap。给 14B 汇总当近全文字覆盖。"""
    seen, out, total = set(), [], 0
    for fid in frame_ids:
        for tok in _frame_ocr(con_p, fid).split():
            key = tok.lower()
            if len(tok) < 2 or key in seen:
                continue
            seen.add(key); out.append(tok); total += len(tok) + 1
            if total >= cap:
                return " ".join(out)
    return " ".join(out)


def _frame_mp4(con_p, fid):
    r = con_p.execute("SELECT vc.file_path, f.offset_ms FROM frames f JOIN video_chunks "
                      "vc ON f.video_chunk_id=vc.id WHERE f.id=?", (fid,)).fetchone()
    if not r or not r[0]:
        return None
    mp4 = os.path.join(os.path.expanduser("~/.portrait"), r[0])
    return (mp4, r[1] or 0) if os.path.exists(mp4) else None


def do_extract(all_day=False):
    con = labdb.connect()
    con_p = sqlite3.connect(f"file:{source.PORTRAIT_DB}?mode=ro", uri=True)
    con_p.row_factory = sqlite3.Row
    rows = con.execute("SELECT id, app, frame_ids, start_ms FROM raw_sessions "
                       "WHERE day=? AND digest IS NOT NULL ORDER BY start_ms",
                       (DAY,)).fetchall()
    if not rows:   # 新日没跑过老管线 Phase-B(无 digest)→ 用 pending 全量(digest 只是对照字段)
        rows = con.execute("SELECT id, app, frame_ids, start_ms FROM raw_sessions "
                           "WHERE day=? AND status='pending' ORDER BY start_ms",
                           (DAY,)).fetchall()
    merged = [m for m in merge_sessions(rows) if len(m["frames"]) >= 3]
    if not all_day:
        picked, seen = [], set()
        for ms in merged:
            if any(a in ms["parts"] for a in ANCHORS) and tuple(ms["parts"]) not in seen:
                seen.add(tuple(ms["parts"])); picked.append(ms)
        merged = picked
    os.makedirs(FRAMES_DIR, exist_ok=True)
    manifest = {}
    for ms in merged:
        key = next((a for a in ANCHORS if a in ms["parts"]), ms["parts"][0])
        sel = select_frames(con_p, ms["frames"])
        frames = []
        for k, fid in sel:
            mp = _frame_mp4(con_p, fid)
            if not mp:
                continue
            jpg = os.path.join(FRAMES_DIR, f"s{key}_{k:05d}.jpg")
            cp = subprocess.run(["ffmpeg", "-y", "-ss", str(max(0, mp[1] / 1000.0)),
                                 "-i", mp[0], "-frames:v", "1", "-q:v", "2", jpg],
                                capture_output=True)
            if cp.returncode == 0 and os.path.exists(jpg):
                frames.append([k, os.path.basename(jpg)])
        if frames:
            ocr_d = con.execute("SELECT digest FROM raw_sessions WHERE id=?",
                                (ms["parts"][0],)).fetchone()
            manifest[str(key)] = {"key": key, "parts": ms["parts"], "app": ms["app"],
                                  "ocr": (ocr_d["digest"] if ocr_d else "") or "",
                                  "ocr_union": build_ocr_union(con_p, ms["frames"]),
                                  "bypass": bypass_anchors(con_p, ms["frames"]),
                                  "total_frames": len(ms["frames"]),
                                  "kept_frames": len(frames), "frames": frames}
    os.makedirs(OUTDIR, exist_ok=True)
    json.dump(manifest, open(MANIFEST, "w"), ensure_ascii=False, indent=2)
    tot = sum(b["kept_frames"] for b in manifest.values())
    print(f"[extract] {'全天' if all_day else '锚点'} · {len(manifest)} 会话 · 选 {tot} 帧 "
          f"→ {MANIFEST} (帧在 {FRAMES_DIR})")


# ---------------- 视觉 8B:只看图,append-only items ----------------

def _vask(model, processor, apply_ct, generate, prompt, jpg):
    import engine
    formatted = apply_ct(processor, model.config, prompt, num_images=1)
    out = generate(model, processor, formatted, [jpg], max_tokens=380,
                   temperature=0.1, verbose=False)
    txt = out if isinstance(out, str) else getattr(out, "text", str(out))
    try:
        return engine.parse_json(txt, "object").get("items") or []
    except Exception:
        return re.findall(r'"([^"\\]{2,})"', txt)[:12]


def _norm(s):
    return re.sub(r"\s+", " ", str(s)).strip().lower()


def do_run(model_id, tag, maxpix=MAXPIX):
    manifest = json.load(open(MANIFEST))
    fp = os.path.join(OUTDIR, f"inc_v4_{tag}.json")
    done = {}
    if os.path.exists(fp):                        # 断点续跑(链被杀过三次的教训)
        try:
            done = {r["key"]: r for r in json.load(open(fp))["results"]}
        except Exception:
            done = {}
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    print(f"[run:{tag}] loading {model_id} (maxpix={maxpix}) · {len(manifest)} 会话"
          f"(已完成 {len(done)},续跑)…")
    model, processor = load(model_id)
    if hasattr(processor, "image_processor"):
        processor.image_processor.max_pixels = maxpix

    results = list(done.values())
    for key, b in manifest.items():
        if int(key) in done:
            continue
        app = b["app"]; t0 = time.time()
        items, seen = [], set()
        for i, (k, jpg_name) in enumerate(b["frames"]):
            jpg = os.path.join(FRAMES_DIR, jpg_name)
            p = (P_ITEMS_FIRST.format(app=app) if i == 0
                 else P_ITEMS_NEXT.format(app=app, items="\n".join(f"- {x}" for x in items)))
            for it in _vask(model, processor, apply_chat_template, generate, p, jpg):
                kk = _norm(it)
                if kk and kk not in seen:
                    seen.add(kk); items.append(str(it).strip())
        lat = int((time.time() - t0) * 1000)
        results.append({"key": int(key), "app": app, "parts": b["parts"],
                        "total_frames": b["total_frames"], "kept_frames": b["kept_frames"],
                        "ocr": b["ocr"], "items": items, "doing": "", "kw": [], "lat_ms": lat})
        json.dump({"model": model_id, "tag": tag, "results": results},
                  open(fp, "w"), ensure_ascii=False, indent=2)   # 每会话checkpoint
        print(f"  ✓ s{key} [{app}] {b['kept_frames']}帧 {lat/1000:.0f}s · {len(items)}项")
    json.dump({"model": model_id, "tag": tag, "results": results},
              open(fp, "w"), ensure_ascii=False, indent=2)
    print(f"[run:{tag}] → inc_v4_{tag}.json")


# ---------------- 14B:汇总(items+OCR)→ digest → 标签 ----------------

def do_finalize(tag, model_id=MERGE_MODEL, pv=2):
    """pv=1 旧prompt(2-3句,A/B对照用);pv=2 新prompt(保粘合剂+多part覆盖,默认)。"""
    import engine
    manifest = json.load(open(MANIFEST))
    fp = os.path.join(OUTDIR, f"inc_v4_{tag}.json")
    d = json.load(open(fp))
    print(f"[finalize] loading {model_id} · {len(d['results'])} 会话(汇总+标签,pv{pv})…")
    engine.load(model_id)
    for r in d["results"]:
        b = manifest.get(str(r["key"]), {})
        items_txt = "\n".join(f"- {x}" for x in r["items"]) or "(none)"
        # ① 汇总:items + 去重OCR → doing
        if pv == 1:
            content = P_MERGE.format(app=r["app"], items=items_txt,
                                     ocr=b.get("ocr_union", "")[:OCR_UNION_CAP])
            mt = 300
        else:
            content = P_MERGE2.format(app=r["app"], nparts=len(b.get("parts", [1])),
                                      items=items_txt,
                                      ocr=b.get("ocr_union", "")[:OCR_UNION_CAP])
            mt = 480
        m1 = [{"role": "system", "content": "You output one JSON object only."},
              {"role": "user", "content": content}]
        try:
            doing = engine.parse_json(engine._generate(m1, max_tokens=mt), "object").get("doing", "")
        except Exception:
            doing = ""
        r["doing"] = doing or "; ".join(r["items"])
        # ② 标签:从 doing 精选 + R9 旁路锚点直入(不经模型)
        m2 = [{"role": "system", "content": "You output concise tags as one JSON object."},
              {"role": "user", "content": P_TAGS.format(doing=r["doing"])}]
        try:
            kws = engine.parse_json(engine._generate(m2, max_tokens=160), "object").get("keywords") or []
        except Exception:
            kws = []
        kw = [str(k) for k in kws][:8]
        low = {k.lower() for k in kw}
        kw += [t for t in b.get("bypass", []) if t.lower() not in low][:6]
        r["kw"] = kw
        print(f"  ✓ s{r['key']} | {r['doing'][:70]} | kw: {', '.join(r['kw'])}")
    json.dump(d, open(fp, "w"), ensure_ascii=False, indent=2)
    print(f"[finalize] → {fp}")


def do_report():
    import glob
    runs = {}
    for fp in sorted(glob.glob(os.path.join(OUTDIR, "inc_v4_*.json"))):
        dd = json.load(open(fp)); runs[dd["tag"]] = {r["key"]: r for r in dd["results"]}
    manifest = json.load(open(MANIFEST))
    tags = list(runs.keys())
    L = [f"# 视觉增量 v4(分工:视觉看图 + 14B汇总)· {DAY}", "",
         f"**视觉**: {', '.join(tags)} · **汇总+标签**: {MERGE_MODEL.split('/')[-1]} · "
         f"选帧 thr{THR_SIM}/coef{COEF}/ceil{CEIL}", ""]
    for key, b in manifest.items():
        k = int(key)
        L += [f"\n---\n\n## s{k} · {b['app']} · parts={b['parts']} · "
              f"{b['total_frames']}帧→选 {b['kept_frames']}", "",
              f"**OCR digest(对照)**: {b['ocr'].splitlines()[0] if b['ocr'] else '—'}", ""]
        for tag in tags:
            r = runs[tag].get(k)
            if not r:
                continue
            L += [f"**[{tag}]** ({r['lat_ms']/1000:.0f}s · {len(r['items'])}项)",
                  f"- doing: {r['doing']}", f"- kw: {', '.join(r['kw'])}", ""]
    out = os.path.join(OBS, f"视觉增量v4{SUFFIX}-{DAY}.md")
    open(out, "w").write("\n".join(L) + "\n")
    print(f"[report] → {out}  (帧图在 {FRAMES_DIR})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", action="store_true")
    ap.add_argument("--all", action="store_true", help="extract 跑全天(默认只锚点)")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--tag", default="q3-8b")
    ap.add_argument("--finalize", action="store_true", help="14B 汇总+标签")
    ap.add_argument("--pv", type=int, default=2, help="汇总prompt版本(1旧/2新)")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--maxpix", type=int, default=MAXPIX)
    args = ap.parse_args()
    if args.extract:
        do_extract(args.all)
    elif args.finalize:
        do_finalize(args.tag, pv=args.pv)
    elif args.report:
        do_report()
    else:
        do_run(args.model, args.tag, args.maxpix)


if __name__ == "__main__":
    main()
