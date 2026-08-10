#!/usr/bin/env python3
"""修复 dev mode 造成的 cron 会话错位(一次性数据手术)。

病因(已修,见 commit dc22ac37):`cron_jobs/` 不跟 dev mode 走,`chat.sqlite`
跟着走 —— dev mode 开着时两者错配,产生两类脏数据:

  A. **泄露**:超 cap 裁剪时 deleteConversation 打在 dev 库上(影响 0 行),
     真实库里那条会话活了下来,但 convId 已不在 runs.json → sidebar 反查不到
     它是 cron run → 回弹到 RECENTS,混在普通聊天里。

  B. **悬空**:dev mode 期间跑的 cron,会话写进了 dev 库,run 却记在真实
     runs.json → 真实侧 CRON JOB HISTORY 里那几条点开是空的。

修法(都不删真实数据):
  A → 把这些 convId 补记回 runs.json。它们立刻回到 CRON JOB HISTORY;
      下次 cron 跑 appendRun 时按原设计(超 cap 自动 GC)由**已修好的**代码
      正常清理掉,不需要在这里删。
  B → 把 dev 库里那几条会话(含 messages)搬回真实库,补上缺失的行。
      dev 库那边的副本另外处理 —— 见 --purge-dev。

默认 dry-run,加 --apply 才写。--purge-dev 额外把 dev 库里的 cron 会话删掉
(它们是**真实**内容,留在演示库里就是录屏时的泄露源)。
"""
import argparse
import json
import os
import shutil
import sqlite3
import datetime

REAL = os.path.expanduser("~/.portrait")
DEV = os.path.expanduser("~/.portrait-dev")
APPLE_EPOCH = 978307200


def stamp(apple_ts):
    return datetime.datetime.fromtimestamp(apple_ts + APPLE_EPOCH).strftime("%m-%d %H:%M")


def conv_ids(db_path):
    if not os.path.exists(db_path):
        return {}
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return {r[0].upper(): r[1] for r in con.execute("SELECT id,title FROM conversations")}
    finally:
        con.close()


def load_runs():
    """→ {job_dir: (sidecar_path, sidecar_dict)}"""
    out = {}
    root = os.path.join(REAL, "cron_jobs")
    if not os.path.isdir(root):
        return out
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name, "runs.json")
        if os.path.exists(p):
            out[name] = (p, json.load(open(p)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真的写盘(默认只打印)")
    ap.add_argument("--purge-dev", action="store_true",
                    help="搬回真实库后,把 dev 库里的 cron 会话删掉")
    args = ap.parse_args()

    real_db = os.path.join(REAL, "chat.sqlite")
    dev_db = os.path.join(DEV, "chat.sqlite")
    real = conv_ids(real_db)
    dev = conv_ids(dev_db)
    runs = load_runs()

    known = set()
    for _, (_, side) in runs.items():
        for r in side.get("runs", []):
            known.add(r["convId"].upper())

    # ── A. 真实库里有 cron 标题、但不在任何 runs.json 里的会话
    leaked = {cid: t for cid, t in real.items() if "🛰" in t and cid not in known}

    # ── B. runs.json 指向真实库不存在的会话(会话在 dev 库里)
    dangling = []
    for job, (_, side) in runs.items():
        for r in side.get("runs", []):
            cid = r["convId"].upper()
            if cid not in real:
                dangling.append((job, cid, r.get("startedAt", 0), cid in dev))

    print(f"真实库 {len(real)} 条会话 · dev 库 {len(dev)} 条")
    print(f"\nA. 泄露到 RECENTS(补记回 runs.json): {len(leaked)} 条")
    for cid, t in sorted(leaked.items(), key=lambda kv: kv[1]):
        print(f"   {cid[:8]}  {t}")
    print(f"\nB. runs.json 悬空(会话在 dev 库,搬回真实库): {len(dangling)} 条")
    for job, cid, ts, in_dev in dangling:
        print(f"   {job:22} {stamp(ts)}  {cid[:8]}  {'可搬' if in_dev else '★ 两边都没有,只能剔除 run'}")

    if not args.apply:
        print("\n(dry-run —— 加 --apply 才写盘)")
        return

    # ── 备份
    for p in (real_db, dev_db):
        if os.path.exists(p):
            bak = p + ".bak-cronfix"
            shutil.copy2(p, bak)
            print(f"\n备份 {bak}")
    for job, (p, _) in runs.items():
        shutil.copy2(p, p + ".bak-cronfix")

    # ── A. 补记回 runs.json。按标题里的时间猜 job:🛰️ <job name> · HH:MM
    name_to_job = {}
    for job, (_, side) in runs.items():
        name_to_job[job] = job
    added = 0
    for cid, title in leaked.items():
        body = title.split("🛰️", 1)[-1].strip()
        job_name = body.split("·")[0].strip()
        slug = job_name.lower().replace(" ", "-")
        if slug not in runs:
            print(f"   ! 认不出 job:{title} —— 跳过")
            continue
        path, side = runs[slug]
        con = sqlite3.connect(f"file:{real_db}?mode=ro", uri=True)
        upd = con.execute("SELECT updated_at FROM conversations WHERE id=?",
                          (cid,)).fetchone()
        con.close()
        started = (upd[0] if upd else 0) - APPLE_EPOCH
        side.setdefault("runs", []).append(
            {"convId": cid, "startedAt": started, "preview": ""}
        )
        added += 1
    for slug, (path, side) in runs.items():
        side["runs"].sort(key=lambda r: r.get("startedAt", 0), reverse=True)
        json.dump(side, open(path, "w"), indent=2)
    print(f"\nA. 已补记 {added} 条 run")

    # ── B. dev 库 → 真实库
    moved = 0
    if dev_db and os.path.exists(dev_db):
        src = sqlite3.connect(f"file:{dev_db}?mode=ro", uri=True)
        dst = sqlite3.connect(real_db)
        for job, cid, ts, in_dev in dangling:
            if not in_dev:
                continue
            row = src.execute("SELECT * FROM conversations WHERE id=?", (cid,)).fetchone()
            cols = [d[0] for d in src.execute("SELECT * FROM conversations LIMIT 0").description]
            dst.execute(
                f"INSERT OR REPLACE INTO conversations({','.join(cols)}) "
                f"VALUES({','.join('?' * len(cols))})", row)
            mcols = [d[0] for d in src.execute("SELECT * FROM messages LIMIT 0").description]
            for m in src.execute("SELECT * FROM messages WHERE conv_id=?", (cid,)):
                dst.execute(
                    f"INSERT OR REPLACE INTO messages({','.join(mcols)}) "
                    f"VALUES({','.join('?' * len(mcols))})", m)
            moved += 1
        dst.commit()
        dst.close()
        src.close()
    print(f"B. 已搬回 {moved} 条会话")

    if args.purge_dev and os.path.exists(dev_db):
        con = sqlite3.connect(dev_db)
        ids = [cid for cid, t in dev.items() if "🛰" in t]
        for cid in ids:
            con.execute("DELETE FROM messages WHERE conv_id=?", (cid,))
            con.execute("DELETE FROM conversations WHERE id=?", (cid,))
        con.commit()
        con.close()
        print(f"已从 dev 库清掉 {len(ids)} 条 cron 会话")


if __name__ == "__main__":
    main()
