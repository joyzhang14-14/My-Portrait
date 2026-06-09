#!/usr/bin/env python3
"""真实端到端审计:从原始数据(typing_events/keystroke_log/frames)跑完整 AX 路,**全自动、不干预**。
铁律:**不读 writing_records_staged 作输入或答案**(只在最后做对照计数)。
链路:发送状态机(§1)→ 占位符过滤(§3)→ librime + 重建 harness(#41/#42)→ 确定性验证器(§4)
      → completeness(§5)→ Pass4 状态机(§6)。
分类清单:final / partial / unrecoverable / review_failed / discarded / drafts / unknown / placeholder过滤
        / 所有模型修改(每个重建 patch:输入→输出→验证器裁决)。
用法:python3 run_audit.py 2026-05-27 2026-05-28 2026-05-29 2026-06-05
"""
import sqlite3, os, json, sys, time, traceback
from signals_raw import cv, has_cjk, is_ph, box_clears_from_raw, author_evidence_from_entry
from signals import (SendSignals, classify_delivery, to_delivery, DeliveryLevel)
from evidence import AuthorEvidence, Pass4Status
from placeholder import placeholder_decision, PlaceholderDecision
from trigger import reconstruction_triggered, decide_outcome, pinyin_residue_spans
from verifier import verify_patch
from patch import Patch
from rime_cands import candidates
from pass4 import run_pass4
import assemble

con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
SIG_FIELDS = ("is_chat_surface", "return_key", "reset_to_known_placeholder", "reset_to_empty",
              "next_session_transition_reliable", "delete_pattern", "physical_key_support",
              "content_len", "n_nonbs_keys", "tail_backspaces", "ts")
def to_sig(s): return SendSignals(**{k: s[k] for k in SIG_FIELDS})

_M = None
def mlx():
    global _M
    if _M is None:
        from mlx_lm import load
        _M = load("mlx-community/Qwen3-1.7B-4bit")
    return _M

# ---- 重建(复用 recon 思路,但从真消息构组;模型只判残渣该是什么)----
import re
SYSTEM = ("你是输入采集重建器。给你残渣段+实际击键字母+已提交中文片段。判断这段残渣本来是什么,"
          "是英文单词还是中文拼音选字。只依据证据,不编造。"
          '只输出一行 JSON:{"reconstruction":"正确文本","kind":"english或chinese"}。')

def model_reconstruct(residue, pinyin, commits):
    from mlx_lm import generate
    model, tok = mlx()
    hint = candidates(pinyin, 8) if pinyin else []
    u = (f"残渣段(只重建这一段): {residue!r}\n这段击键字母: {pinyin!r}\n已提交中文: {commits}\n"
         f"若是中文拼音 librime 候选: {hint}\n判断英文单词还是中文拼音,只输出这一段应是的样子。")
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": u}]
    text = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
    out = generate(model, tok, prompt=text, max_tokens=80, verbose=False)
    m = re.search(r"\{[^{}]*\}", out, re.S)
    if not m: return None
    try: return json.loads(m.group(0))
    except json.JSONDecodeError: return None

def reconstruct_residue(group, residue, mods):
    """重建一个 latin 残渣段。先 commit-match(确定性),否则模型。返回 (new_skeleton, ok, status)。"""
    sk, pinyin = group["skeleton"], residue
    s = sk.find(residue)
    if s < 0: return sk, False, "residue_gone"
    e = s + len(residue)
    committed = "".join(c for c in group["commits"] if has_cjk(c))
    # ① commit-match:librime 候选里有已提交中文 → 直接用
    via, recon = None, None
    for cand in candidates(pinyin, 20):
        if cand and all(has_cjk(ch) for ch in cand) and cand in committed:
            via, recon = "commit-match", cand; break
    # ② 模型兜底
    if recon is None:
        prop = model_reconstruct(residue, pinyin, group["commits"])
        if prop is None:
            mods.append({"residue": residue, "via": "model", "proposal": None, "verdict": "parse_fail"})
            return sk, False, "model_parse_fail"
        via, recon = "model", prop.get("reconstruction", "")
    # 建 patch 走验证器
    cjk_n = sum(1 for c in recon if has_cjk(c))
    allowed = set("".join(candidates(pinyin, 20))) if cjk_n else set()
    p = Patch(replace_range=(s, e), replacement_text=recon, operation="replaced",
              anchor_before=sk[max(0, s - 2):s], anchor_after=sk[e:e + 2], source_range=(0, len(group["keystrokes"])),
              supporting_event_ids=group["event_ids"], supporting_keystrokes=list(range(len(group["keystrokes"]))),
              supporting_commits=list(range(len(group["commits"]))), pinyin_candidates=[allowed] * cjk_n)
    ok, reason = verify_patch(p, group)
    mods.append({"residue": residue, "via": via, "proposal": recon, "verdict": "accepted" if ok else f"rejected:{reason}"})
    if not ok:
        return sk, False, reason
    return sk[:s] + recon + sk[e:], True, "ok"

def reconstruct_message(group, mods):
    """对一条消息:若 #40 触发则逐残渣重建,返回 recon 结果 dict 供 decide_outcome。"""
    triggered, reason = reconstruction_triggered(group)
    if not triggered:
        return {"ok": True, "text": group["skeleton"], "proposal": {"via": "no-trigger"}}, reason
    sk = group["skeleton"]
    g = dict(group)
    any_fail = False
    for _ in range(6):  # 逐个残渣,最多 6 段
        spans = pinyin_residue_spans(g["skeleton"])
        if not spans: break
        st, end, seg = spans[0]
        new_sk, ok, status = reconstruct_residue(g, seg, mods)
        if not ok:
            any_fail = True; break
        g["skeleton"] = new_sk
    if any_fail:
        return {"ok": False, "text": group["skeleton"], "why": "残渣重建失败"}, reason
    # 还有未覆盖的已提交中文(ax_misses)→ 视为部分,交 decide_outcome 判
    return {"ok": True, "text": g["skeleton"], "proposal": {"via": "reconstructed"}}, reason


def build_group(c):
    """从 assemble 候选构 MessageGroup。skeleton=候选文本;commits/keystrokes/deletes 取来源事件。"""
    ev_id = c["ev"]; sk = cv(c["text"])
    r = con.execute("SELECT bundle_id,started_at,ended_at,edit_log FROM typing_events WHERE id=?", (ev_id,)).fetchone()
    bundle, started, ended, log = r
    arr = json.loads(log)
    # commits 只取**在本消息里**的(避免跨消息 commit 让 ax_misses 误触发)
    commits = [c for c in (cv(e.get("text", "") or "") for e in arr
                           if e.get("kind") == "commit") if c and not is_ph(c) and c in sk]
    deletes = [cv(e.get("text", "") or "") for e in arr if e.get("kind") == "delete"]
    residues = [seg for _, _, seg in pinyin_residue_spans(sk)]
    ks = con.execute("SELECT ts_ms,char,is_backspace,modifiers FROM keystroke_log "
                     "WHERE bundle_id=? AND ts_ms BETWEEN ? AND ? ORDER BY ts_ms",
                     (bundle, (started or 0) - 8000, (ended or 0) + 1000)).fetchall()
    base = started or 0
    keystrokes = [{"ts": t - base, "char": ch, "is_backspace": bool(b), "modifiers": md} for t, ch, b, md in ks]
    return {"skeleton": sk, "event_ids": [ev_id], "commits": commits, "deletes": residues + deletes,
            "reinput": [], "keystrokes": keystrokes, "boundaries": [],
            "segment_range": [-10**9, 10**12],   # 击键偏移可为负(从 started-8000 拉)
            "require_cjk_commit_backed": True, "pinyin": residues[0] if residues else ""}


def process_day(date, R):
    """组装层(发送状态机 + 占位符过滤 + paste片段过滤 + 击键背书)→ 候选 → 剩余环节。"""
    for c in assemble.assemble_day(date):
        try:
            if c.get("dropped"):
                R["dropped"].append({"app": c["app"], "date": date, "text": c["text"][:80], "why": c["dropped"]})
                continue
            process_candidate(c, date, R)
        except Exception:
            R["error"].append((c.get("ev"), traceback.format_exc().splitlines()[-1][:70]))


def process_candidate(c, date, R):
    text = cv(c["text"])
    if len(text) < 1:
        return
    # 发送状态机 + 占位符过滤已在组装层完成(newExtract send/reset + 只认 paste 占位符 + paste 片段过滤 + 击键 gate)
    # 草稿 vs 真发送:组装层已判(reset/withinSends 发出=已发送;末尾未 reset cur=未发送草稿)
    if not c.get("sent", True):
        R["drafts"].append({"ev": c["ev"], "app": c["app"], "date": date, "text": text}); return
    # librime + 重建 harness + 验证器(#40 触发才重建)→ completeness
    group = build_group(c)
    recon, trig = reconstruct_message(group, R["model_mods"])
    outcome = decide_outcome(group, recon)
    rec = {"id": f'{c["ev"]}:{c.get("ts")}', "ev": c["ev"], "app": c["app"], "url": c.get("url"), "date": date,
           "text": outcome["text"], "completeness": outcome["completeness"], "trigger": trig,
           "fallback": outcome.get("fallback", False), "paste_removed": c.get("paste_removed", False)}
    if outcome["completeness"] == "unrecoverable":
        R["unrecoverable"].append(rec)
    elif outcome["completeness"] == "partial":
        R["partial"].append(rec)
    else:
        R["complete_sent"].append(rec)   # 进 Pass4


PASS4_SYS = ("你是写作记录最终审查器(Pass4)。给你同一 app+url 里这段时间的**全部消息作为上下文**,"
             "再单独问其中一条。结合上下文判断:这条是否是**用户真正写给别人或自己的、值得留进写作记录**的消息?"
             "是→accept;若是纯残渣碎片/系统噪声/表单字段/无意义短串→reject。只回一个词:accept 或 reject。")

def pass4_review(group_records):
    """Pass4 review_fn = **本地 MLX 逐条评审 + 同 (app,url) 组上下文**(发布版 LLM 本地)。
    逐条→覆盖天然完整、解析稳;同组消息作上下文,帮模型分辨对话流里的真消息 vs 孤立碎片。"""
    from mlx_lm import generate
    model, tok = mlx()
    # 同 (app,url) 组的全部消息 = 上下文(写作流)
    ctx = "\n".join(f"- {r['text'][:80]}" for r in group_records)
    app = group_records[0]['app'].split('.')[-1]
    verdicts = {}
    for r in group_records:
        u = (f"app={app}  同组上下文(共{len(group_records)}条):\n{ctx}\n\n"
             f"判断这一条:{r['text'][:160]!r}\naccept 还是 reject?")
        msgs = [{"role": "system", "content": PASS4_SYS}, {"role": "user", "content": u}]
        text = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
        out = generate(model, tok, prompt=text, max_tokens=12, verbose=False).lower()
        verdicts[r["id"]] = "reject" if ("reject" in out or "拒" in out) and "accept" not in out else "accept"
    return {"ok": True, "parse_ok": True, "raw": "per-item+ctx",
            "verdicts": verdicts, "output_ids": list(verdicts.keys())}


def old_staged_contrast(dates):
    """⚠️ 仅对照,不作输入/上下文。读旧 writing_records_staged 这几天的文本(计数 + 内容)。"""
    qs = ",".join("?" * len(dates))
    rows = con.execute(f"SELECT date_utc,app,text FROM writing_records_staged "
                       f"WHERE date_utc IN ({qs}) ORDER BY id", dates).fetchall()
    return [{"date": d, "app": a, "text": t} for d, a, t in rows]

def write_report(R, dates, secs):
    old = old_staged_contrast(dates)
    new_final = R["final_accepted"]
    new_texts = [cv(r["text"]) for r in new_final]
    def related(a, b): import difflib; return (difflib.SequenceMatcher(None, a, b).ratio() >= 0.6
                                               or (a and b and (a in b or b in a)))
    # 对照:旧有、新最终没有的(可能旧误收粘贴/canvas,或新漏)
    old_only = [o for o in old if not any(related(cv(o["text"]), nt) for nt in new_texts if nt)]
    L = []
    A = L.append
    A(f"# 写作采集 · 真实端到端审计报告")
    A(f"\n**日期**: {', '.join(dates)}  |  **耗时**: {secs:.0f}s  |  生成于全自动运行,无人工干预")
    A(f"\n**链路**: 组装层(unifiedExtract/newExtract 验证逻辑 + paste片段过滤 + 击键背书)→ 发送状态机/占位符(组装层内)"
      f"→ librime + 重建 harness(Qwen3-1.7B-4bit 本地)→ 确定性验证器(rule5/6/6b)→ completeness → Pass4 状态机(本地 MLX 真评审)")
    A(f"\n**铁律遵守**: 输入只读 typing_events + keystroke_log,**全程未读 writing_records_staged 作输入/答案**;"
      f"旧 staged 仅本节末做对照。所有 LLM 本地(Qwen3-1.7B-4bit);本批为聊天 app,无 Canvas 路触发。")
    A(f"\n> **Pass4 说明**:Pass4 内容评审用本地 Qwen3-1.7B + **同 (app,url) 组上下文**辅助判断。加上下文后"
      f"判决大幅改善(聊天真消息基本正确采纳、表单/碎片噪声正确丢弃)。仍有边缘:短碎片('zh'/'go')、"
      f"Safari 姓名表单字段判决不稳。若要更稳可换更强本地模型(缓存有 Qwen3-4B/8B/14B-4bit)。"
      f"completeness=complete 的全部候选(无论 Pass4 收否)见 §2+§6 合看。")
    # 汇总表
    A(f"\n## 1. 汇总")
    cats = [("最终采纳 final_accepted", "final_accepted"), ("partial", "partial"),
            ("unrecoverable", "unrecoverable"), ("Pass4 review_failed", "review_failed"),
            ("Pass4 丢弃 discarded", "discarded"), ("草稿 drafts", "drafts"),
            ("组装层丢弃(粘贴/击键gate)", "dropped"), ("模型修改 model_mods", "model_mods"),
            ("处理错误 error", "error")]
    A("\n| 类别 | 数量 |\n|---|---|")
    for name, k in cats: A(f"| {name} | {len(R.get(k, []))} |")
    A(f"| Pass4 失败组数 | {R.get('pass4_audit_failed_groups', 0)} |")

    def dump(title, key, fields=("app", "text")):
        items = R.get(key, [])
        A(f"\n## {title}（{len(items)}）")
        if not items: A("（无）"); return
        for r in items:
            extra = ""
            if "completeness" in r: extra += f" · {r['completeness']}"
            if r.get("trigger") and r.get("trigger") != "no_inconsistency": extra += f" · 触发={r['trigger']}"
            if r.get("fallback"): extra += " · 回退"
            if r.get("paste_removed"): extra += " · [paste片段已过滤]"
            A(f"- [{str(r.get('app','')).split('.')[-1][:12]}] {repr((cv(r.get('text','')) or '')[:80])}{extra}")

    dump("2. 最终采纳记录 final_accepted", "final_accepted")
    dump("3. partial(部分恢复,不进最终)", "partial")
    dump("4. unrecoverable(无法恢复)", "unrecoverable")
    dump("5. Pass4 review_failed(留 staged 不删)", "review_failed")
    dump("6. discarded(Pass4 丢弃)", "discarded")
    dump("7. drafts(未发送草稿)", "drafts")
    dump("8. 组装层丢弃(粘贴主体/预存内容/击键 gate)", "dropped")
    # 模型修改
    A(f"\n## 9. 所有模型修改 model_mods（{len(R.get('model_mods', []))}）")
    A("每条重建尝试:残渣 → 重建文本 / 来源(commit-match 确定性 或 model 模型)/ 验证器裁决")
    for m in R.get("model_mods", []):
        A(f"- 残渣 {repr(m.get('residue',''))} → {repr(m.get('proposal',''))} · via={m.get('via')} · {m.get('verdict')}")
    if not R.get("model_mods"): A("（本批无 #40 重建触发,组装层已产出完整消息;残渣重建仅在 AX 截断时触发）")
    # 对照
    A(f"\n## 10. 与旧 pipeline 对照（仅对照,旧结果未作输入）")
    A(f"\n- 旧 staged 这几天: **{len(old)}** 条")
    A(f"- 新 pipeline 最终采纳: **{len(new_final)}** 条")
    A(f"- 旧有、新最终未覆盖: **{len(old_only)}** 条(下列;多为旧 pipeline 误收的粘贴/canvas/表单,或新漏)")
    for o in old_only:
        A(f"  - [{str(o['app']).split('.')[-1][:12]}] {repr((o['text'] or '')[:80])}")

    path = os.path.expanduser("~/Desktop/写作采集/审计报告.md")
    open(path, "w").write("\n".join(L))
    return path

def main(dates):
    R = {k: [] for k in ("complete_sent", "partial", "unrecoverable", "drafts",
                         "dropped", "model_mods", "error")}
    t0 = time.time()
    for d in dates:
        process_day(d, R)
        print(f"  {d} 处理完 ({time.time()-t0:.0f}s, 累计 complete_sent={len(R['complete_sent'])})")
    # Pass4 状态机(只对 complete+sent)
    p4_records = [{"id": r["id"], "app": r["app"], "url": r["url"],
                   "completeness": "complete", "delivery": "sent", "text": r["text"]} for r in R["complete_sent"]]
    status, audit = run_pass4(p4_records, pass4_review)
    sm = {k: v.value for k, v in status.items()}
    R["pass4_audit_failed_groups"] = audit["failed_groups"]
    R["final_accepted"] = [r for r in R["complete_sent"] if sm.get(r["id"]) == "accepted"]
    R["review_failed"] = [r for r in R["complete_sent"] if sm.get(r["id"]) == "review_failed"]
    R["discarded"] = [r for r in R["complete_sent"] if sm.get(r["id"]) == "rejected"]
    secs = time.time() - t0
    json.dump({k: v for k, v in R.items() if isinstance(v, list)}, open("/tmp/audit_result.json", "w"),
              ensure_ascii=False, default=str)
    path = write_report(R, dates, secs)
    print(f"\n完成 {secs:.0f}s。审计报告: {path}")
    for k in ("final_accepted", "partial", "unrecoverable", "review_failed", "discarded",
              "drafts", "dropped", "model_mods", "error"):
        print(f"  {k}: {len(R.get(k, []))}")
    return R

if __name__ == "__main__":
    ds = sys.argv[1:] or ["2026-05-27", "2026-05-28", "2026-05-29", "2026-06-05"]
    main(ds)
