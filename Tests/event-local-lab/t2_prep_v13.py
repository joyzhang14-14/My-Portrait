"""v1.3 数据手术 —— 确定性预处理(不用 LLM 的部分)。

产出 work_v13.json:每条样本带上【新题头】+【教师原始锚点】+【三个缺陷的标记】,
供 sonnet workflow 做需要判断的那部分(归属/social/锚点重选)。

四个缺陷(诊断见 handoff §32):
  D1 题头泄题:51% 样本的「已知(系统API):前台 app」是教师改写的解读,线上拿不到
              → 确定性重建为【裸 app 名,零提示】(用户 2026-07-14 拍板;
              --attr-hint 注释被对抗核查否掉:判别力实测仅 1.67x,且陷阱会话里
              多数前台 app 本来就是真工作对象,注入即是往题面塞经常为假的前提)。
  D2 归属错误:16% 答案写「用户在<非开发app>里…跑 Claude Code」→ 标记,交 LLM。
  D3 social 污染:非空 social 里 30% 是天气/日历/桌面 → 标记,交 LLM。
  D4 锚点硬 cap:36% 答案正好 12 个 specifics(截断堆积,模型学不到"何时停")
              → 附上教师原始锚点全集,交 LLM 按相关性自然重选。
"""
import argparse
import json
import os
import re
import sqlite3

LAB_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lab.db")
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
DEV_APPS = {"Terminal", "iTerm2", "Xcode", "Code", "Cursor", "My Portrait", "My Meeting",
            "MyPortrait"}
NOISE = re.compile(r"天气|降水|风速|°C|℃|日历|桌面|文件夹|电量|菜单栏|图标|壁纸|Dock|widget")
DEVTXT = re.compile(r"Claude Code|终端|Terminal|命令行|claude --")
IMG = re.compile(r"(\d{4}-\d{2}-\d{2})_s(\d+)_")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkg", default="/tmp/t2v3/t2_pkg_v3")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    con = sqlite3.connect(LAB_DB)
    gold = {}
    for day in os.listdir(FIXTURES):
        p = os.path.join(FIXTURES, day, "sonnet_vision_gold.jsonl")
        if os.path.exists(p):
            for l in open(p, encoding="utf-8"):
                d = json.loads(l)
                gold[(day, str(d["key"]))] = d

    work, mix = [], []
    for split in ("train", "valid"):
        for i, l in enumerate(open(os.path.join(args.pkg, f"{split}.jsonl"), encoding="utf-8")):
            r = json.loads(l)
            q = r["question"]
            if "已知(OCR" not in q:          # 混练短题:原样保留(防塌缩用,不动)
                mix.append({"split": split, **r})
                continue
            m = IMG.search(r["images"][0])
            day, key = m.group(1), m.group(2)
            ocr = q.split("<<<\n", 1)[1].split("\n>>>", 1)[0]
            head_old = q.split("\n已知(OCR", 1)[0]
            schema_rules = q.split("\n>>>\n", 1)[1]     # SCHEMA + 规则行(三变体轮换,原样留用)
            win = head_old.split(";窗口标题 = ", 1)[1].rstrip("。")
            win = "" if win == "(空)" else win
            row = con.execute("SELECT app FROM raw_sessions WHERE id=?", (int(key),)).fetchone()
            bare = row[0] if row else ""
            # D1:确定性新题头 —— 裸 app 名,零提示(与 v12_day.py 默认口径逐字一致)
            head_new = (f"分析这段 macOS 屏幕会话的截图。已知(系统API):前台 app = "
                        f"{bare};窗口标题 = {win or '(空)'}。")
            ans = json.loads(r["answer"])
            act = ans.get("activity") or ""
            soc = str(ans.get("social") or "").strip()
            specs = ans.get("specifics") or []
            g = gold.get((day, key), {})
            work.append({
                "day": day, "key": key, "split": split,
                "app_bare": bare,
                "app_teacher": head_old.split("前台 app = ", 1)[1].split(";窗口标题", 1)[0],
                "head_old": head_old, "head_new": head_new, "schema_rules": schema_rules,
                "images": r["images"], "image_first": r["images"][0],
                "ocr": ocr, "answer": ans,
                "teacher_specifics_raw": [str(x) for x in (g.get("specifics") or [])],
                # 三个缺陷的标记(供 LLM 优先处理,但每条都要过一遍)
                "flag_attr": bool(bare and bare not in DEV_APPS
                                  and re.search(rf"在\s*{re.escape(bare)}\s*(里|中|内|上)", act)
                                  and DEVTXT.search(act)),
                "flag_social": bool(soc and NOISE.search(soc)),
                "flag_speccap": len(specs) == 12,
                "flag_headleak": len(row_app := (head_old.split("前台 app = ", 1)[1]
                                                 .split(";窗口标题", 1)[0])) > 25,
                "n_spec": len(specs),
            })
    json.dump({"work": work, "mix": mix}, open(args.out, "w"), ensure_ascii=False)
    n = len(work)
    print(f"[prep] {n} 真样本 + {len(mix)} 混练短题 → {args.out}")
    for f, lbl in [("flag_headleak", "D1 题头泄题"), ("flag_attr", "D2 归属错误"),
                   ("flag_social", "D3 social 污染"), ("flag_speccap", "D4 锚点撞 cap")]:
        c = sum(1 for w in work if w[f])
        print(f"  {lbl}: {c} 条 ({c/n*100:.0f}%)")
    hg = sum(1 for w in work if w["teacher_specifics_raw"])
    print(f"  有教师原始锚点(供 D4 重选): {hg} 条 ({hg/n*100:.0f}%)")


main()
