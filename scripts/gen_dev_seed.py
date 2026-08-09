#!/usr/bin/env python3
"""生成 ~/.portrait-dev 的演示数据(dev mode 用)。

数据本身**不进 git**(体积 + 每次改都产生二进制 diff),这个脚本进 —— 想重来
一遍就 `python3 Scripts/gen_dev_seed.py --force`。

人物是编的:Alex Rivera,产品设计师,在学 Rust、计划去日本、办读书会。
刻意跟真实用户毫无关系 —— 演示视频里出现的每一个字都可以公开。

cron_jobs 不生成 —— 定时 AI 任务永远跟真实配置跑(见 Storage.uiRootURL 注释)。

⚠️ 只写 ~/.portrait-dev,一个字节都不碰 ~/.portrait。
"""
import argparse
import json
import os
import shutil
import sqlite3
import uuid
from datetime import date, datetime, timedelta

ROOT = os.path.expanduser("~/.portrait-dev")
TODAY = date(2026, 8, 9)          # 固定"今天",让产出可复现

# ── 人物 ────────────────────────────────────────────────────────────────
PERSON = "Alex Rivera"

# folder 存活门:5 个 weight≥1.5 的核心事件。低于这个数 folder 会散架,
# 演示里就看不到分组了 —— 每个 folder 的前 6 条都给足权重。
CORE_MIN = 5

# (slug, 名字, 颜色, 描述, [(距今天数, 标题, 摘要, weight, impact, tags)])
FOLDERS = [
    ("learning-rust", "Learning Rust", "#E8843F",
     "Working through the Rust book, ownership exercises, and a first CLI project.", [
        (2,  "Rewrote the CSV parser without clones",
         "Reworked the parser to borrow slices instead of allocating a String per field. "
         "Compile errors around lifetimes took most of the session; the final version is "
         "about 40% faster on the 200MB sample file.", 4.6, 3.8, ["rust", "performance", "learning"]),
        (5,  "Read the ownership chapter twice",
         "Went through chapter 4 of the Rust book, then re-read it after the borrow checker "
         "rejected the first exercise. Took notes on when a move happens versus a copy.",
         4.1, 3.2, ["rust", "reading", "learning"]),
        (9,  "Got the CLI to read from stdin",
         "Added piped-input support so the tool works in a shell pipeline. Spent a while on "
         "the difference between BufReader and read_to_string.", 3.7, 3.0, ["rust", "cli"]),
        (14, "Fought the borrow checker over a HashMap",
         "Tried to mutate a map while iterating it. Ended up collecting the keys first — "
         "which is apparently the idiomatic answer, not a workaround.", 3.3, 2.9, ["rust", "debugging"]),
        (19, "Set up rust-analyzer and clippy",
         "Configured the editor with rust-analyzer, then ran clippy across the project and "
         "fixed the 30-odd lints it found. Most were needless borrows.", 2.6, 2.4, ["rust", "tooling"]),
        (26, "Started the Rust book",
         "Installed the toolchain with rustup and worked through the guessing-game tutorial "
         "in chapter 2.", 2.1, 2.2, ["rust", "learning"]),
        (33, "Compared Rust and Go for a side project",
         "Read a few comparison posts and skimmed both standard libraries before deciding "
         "to go with Rust for the CLI.", 1.4, 1.8, ["rust", "research"]),
        (41, "Watched a talk on zero-cost abstractions",
         "Conference talk about how iterators compile down to the same assembly as a manual "
         "loop. Rewatched the middle section.", 1.1, 1.6, ["rust", "video"]),
     ]),
    ("japan-trip", "Japan Trip 2026", "#4FB0C6",
     "Planning a two-week trip to Japan in November — flights, rail pass, and an itinerary.", [
        (1,  "Booked the Tokyo flight",
         "Compared three routings and booked the mid-November departure. Went with the "
         "overnight flight to lose less of the first day.", 4.8, 4.1, ["travel", "japan", "booking"]),
        (4,  "Drafted a 14-day itinerary",
         "Blocked out Tokyo, Kanazawa, Kyoto and Osaka with two buffer days. Moved the "
         "Kanazawa leg earlier so the rail pass covers it.", 4.3, 3.6, ["travel", "japan", "planning"]),
        (8,  "Researched the JR rail pass math",
         "Worked out whether the 14-day pass actually pays for itself. It does, but only "
         "because of the two long legs.", 3.5, 3.0, ["travel", "japan", "research"]),
        (13, "Shortlisted places to stay in Kyoto",
         "Narrowed lodging to three options near Karasuma, mostly on walking distance to "
         "the subway rather than price.", 3.0, 2.8, ["travel", "japan", "lodging"]),
        (21, "Read about November weather and packing",
         "Checked historical temperatures for the trip window and started a packing list. "
         "Layers, one rain shell, no heavy coat.", 2.4, 2.3, ["travel", "japan"]),
        (30, "Started a Japanese phrasebook",
         "Wrote down about forty phrases likely to come up — ordering, directions, "
         "checking in. Practiced the pronunciation of a handful.", 1.9, 2.0, ["travel", "japan", "language"]),
        (44, "Decided on November for the trip",
         "Compared spring and autumn. Picked November for the foliage and the thinner "
         "crowds.", 1.3, 1.7, ["travel", "japan", "planning"]),
     ]),
    ("portfolio-redesign", "Portfolio Redesign", "#B87BDC",
     "Rebuilding the personal portfolio site — layout, case studies, and a new type scale.", [
        (3,  "Rewrote the first case study",
         "Cut the project write-up roughly in half and led with the outcome instead of the "
         "process. Reads much better out loud.", 4.4, 3.7, ["design", "writing", "portfolio"]),
        (6,  "Settled on a type scale",
         "Tried three scales at real content lengths and picked the one that held up on a "
         "phone. Locked the body size at 17px.", 4.0, 3.4, ["design", "typography"]),
        (11, "Built the case study template",
         "Set up a reusable layout so each project needs only content, not layout work. "
         "Two of the four are migrated.", 3.4, 3.1, ["design", "portfolio"]),
        (17, "Audited the old site on mobile",
         "Walked through every page at 375px. Found four layouts that break and one image "
         "that was loading at full resolution.", 2.9, 2.7, ["design", "audit", "mobile"]),
        (24, "Collected reference sites",
         "Saved about a dozen portfolios worth stealing structure from. The common thread "
         "is that they all lead with one project, not a grid.", 2.2, 2.1, ["design", "research"]),
        (35, "Decided to rebuild rather than patch",
         "Looked at the effort of fixing the current site versus starting over. Starting "
         "over wins, mostly because the content model is wrong.", 1.6, 1.9, ["design", "planning"]),
        (52, "Sketched three homepage directions",
         "Rough pencil layouts for the landing page. The third one — a single case study "
         "above the fold — is the one worth building.", 0.9, 1.5, ["design", "sketching"]),
     ]),
    ("book-club", "Book Club", "#6FCF8B",
     "A monthly book club — picking titles, taking notes, and hosting the discussions.", [
        (7,  "Hosted the August discussion",
         "Ran the session for eight people. The conversation ran long on the middle "
         "chapters, which is usually a good sign.", 4.2, 3.5, ["books", "social", "hosting"]),
        (10, "Finished this month's book",
         "Read the last third in one sitting. Wrote down four questions to open the "
         "discussion with.", 3.6, 3.1, ["books", "reading"]),
        (16, "Picked September's title",
         "Put three candidates to a vote in the group chat. The short one won, which "
         "surprised nobody.", 3.1, 2.8, ["books", "social"]),
        (23, "Wrote notes on the first half",
         "Chapter-by-chapter notes down to about page 150. Mostly tracking how the "
         "narrator's reliability shifts.", 2.5, 2.4, ["books", "notes"]),
        (31, "Reorganised the reading list",
         "Cleared out titles nobody voted for in six months and added five suggestions "
         "from the group.", 2.0, 2.1, ["books", "organising"]),
        (48, "Moved the club to a monthly cadence",
         "Every two weeks was too fast for anyone with a job. Monthly it is.",
         1.2, 1.6, ["books", "social", "planning"]),
     ]),
    ("home-lab", "Home Lab", "#E86F8C",
     "A small home server — backups, a media library, and keeping the thing patched.", [
        (12, "Set up automated offsite backups",
         "Nightly encrypted sync to remote storage, with a restore test to prove it "
         "actually works. The restore test is the part people skip.", 4.5, 3.9, ["homelab", "backup"]),
        (15, "Replaced the failing drive",
         "SMART had been warning for a week. Swapped it and let the array rebuild "
         "overnight; no data lost.", 4.0, 3.6, ["homelab", "hardware"]),
        (20, "Moved services behind a reverse proxy",
         "One entry point with real certificates instead of a pile of ports. Broke "
         "two services for an hour in the process.", 3.2, 3.0, ["homelab", "networking"]),
        (28, "Wrote a patching checklist",
         "Turned the ad-hoc update routine into a written checklist so it survives "
         "being done at 11pm.", 2.7, 2.5, ["homelab", "process"]),
        (37, "Audited what's actually running",
         "Listed every service on the box and turned off three nobody had opened in "
         "months.", 2.1, 2.2, ["homelab", "cleanup"]),
        (55, "Rebuilt the media library index",
         "The index had drifted from what's on disk. Rebuilt from scratch — took four "
         "hours but it's correct now.", 0.8, 1.4, ["homelab", "media"]),
     ]),
]

# 没归入任何 folder 的零散事件 —— folder ≥3 个,所以这些会被收进灰色的
# Unclassified(text 列表是伪 folder,图谱是灰分区球)。
LOOSE = [
    (1,  "Renewed the domain name", "Two-year renewal on the personal domain. Turned on "
     "auto-renew so this doesn't become a yearly errand.", 2.8, 2.6, ["admin"]),
    (2,  "Compared note-taking apps", "Tried three apps against the same week of notes. "
     "None of them fixed the actual problem, which is that the notes are unstructured.",
     2.4, 2.3, ["tools", "research"]),
    (4,  "Fixed the espresso grinder", "Took the burr assembly apart, cleaned out about a "
     "year of fines, and reset the zero point.", 3.1, 2.9, ["home", "coffee"]),
    (6,  "Read about sleep and shift work", "A few papers on circadian disruption. Mostly "
     "confirmed what the sleep tracker has been saying for months.", 1.9, 2.0, ["health", "reading"]),
    (9,  "Long walk along the river", "Two hours, no podcast. Ended up thinking through the "
     "portfolio structure more clearly than at the desk.", 2.2, 2.2, ["health", "walking"]),
    (12, "Called Mom", "Long catch-up call. She's fine; the roof is not.", 3.4, 3.2, ["family"]),
    (16, "Cancelled three subscriptions", "Went through the bank statement line by line. "
     "About $40 a month of things nobody was using.", 2.0, 2.1, ["admin", "money"]),
    (18, "Tried a new bread recipe", "Higher hydration than usual. The crumb was better but "
     "the dough was miserable to shape.", 1.7, 1.9, ["cooking"]),
    (22, "Backed up the photo library", "Two years of phone photos finally off the device "
     "and into the archive.", 2.6, 2.5, ["admin", "photos"]),
    (27, "Watched a documentary on cartography", "About how projections encode political "
     "choices. Kept thinking about it for days afterwards.", 1.5, 1.8, ["film", "learning"]),
    (34, "Reorganised the desk", "Cable management, a monitor arm, and moving the lamp. "
     "Small changes, noticeably better.", 1.3, 1.7, ["home", "workspace"]),
    (39, "Signed up for a pottery class", "Six weeks, Thursday evenings. First time doing "
     "anything with my hands in a while.", 1.8, 2.0, ["hobbies", "learning"]),
    (46, "Repaired the bike's rear derailleur", "Cable had stretched. Re-indexed the gears "
     "and it shifts cleanly again.", 1.1, 1.6, ["bike", "repair"]),
    (58, "Set up a weekly review habit", "Half an hour every Sunday to look at the week. "
     "Kept it up for six weeks now.", 0.9, 1.5, ["habits", "process"]),
]

# portrait/<category>/*.md —— 每类几条,画像层的"长期结论"
PORTRAIT = {
    "personality": [
        ("Finishes things by shrinking them",
         "When a project stalls, Alex's reliable move is to cut scope rather than push "
         "harder — the portfolio rebuild, the reading list, and the book club cadence all "
         "got unstuck by removing something rather than adding effort.", 4.2, 90),
        ("Prefers understanding to shipping fast",
         "Repeatedly chooses the slower path that leaves them knowing why something works: "
         "re-reading the ownership chapter instead of copying a fix, running a restore test "
         "instead of trusting the backup log.", 3.8, 70),
        ("Thinks by walking, not at the desk",
         "Several breakthroughs — the portfolio structure, the trip itinerary — happened "
         "away from the computer. Desk time is for execution, not for deciding.", 2.9, 45),
    ],
    "skills": [
        ("Learning Rust, past the beginner wall",
         "Comfortable enough with ownership and borrowing to debug lifetime errors without "
         "reaching for clone(). Has shipped a working CLI that reads from stdin.", 4.4, 60),
        ("Interface design with a bias toward type",
         "Design decisions consistently start from the type scale and reading experience "
         "rather than from layout or colour.", 4.0, 120),
        ("Practical systems administration",
         "Runs a home server with offsite backups, a reverse proxy with real certificates, "
         "and a written patching routine — including the restore tests most people skip.",
         3.6, 80),
    ],
    "interests": [
        ("Japan — planning a first long trip",
         "Two weeks in November across Tokyo, Kanazawa, Kyoto and Osaka. The planning has "
         "been unusually thorough, including working out the rail pass economics.", 4.1, 50),
        ("Coffee, at the equipment-maintenance level",
         "Not just drinking it — dismantling and recalibrating the grinder, tracking how "
         "grind settings change over time.", 2.7, 100),
        ("Maps and how they lie",
         "A documentary on projections turned into a lasting interest in how cartographic "
         "choices encode politics.", 2.0, 30),
    ],
    "experiences": [
        ("Rebuilt the personal portfolio from scratch",
         "Decided patching the old site wasn't worth it because the content model was wrong. "
         "Rebuilt around a case-study template, leading with outcomes.", 4.3, 60),
        ("Recovered from a drive failure without data loss",
         "SMART warnings caught a failing disk a week ahead. Swapped it, rebuilt the array "
         "overnight, lost nothing.", 3.9, 20),
        ("Ran a book club through a cadence change",
         "Moved from fortnightly to monthly when attendance showed the pace was wrong, and "
         "attendance recovered.", 3.0, 55),
    ],
    "emotions": [
        ("Satisfaction comes from correctness, not completion",
         "The rebuilt media index took four hours and changed nothing visible — described as "
         "worth it purely because it's now correct.", 3.5, 65),
        ("Low-grade frustration with tooling churn",
         "Comparing note apps ended in the conclusion that the tools weren't the problem, "
         "with visible irritation at having spent the time.", 2.4, 40),
    ],
    "social": [
        ("Hosts rather than attends",
         "Runs the book club, organises the vote, opens the discussion with prepared "
         "questions. The default role in groups is organiser.", 3.7, 55),
        ("Keeps up with family by phone, not text",
         "Regular long calls rather than frequent messages.", 2.8, 45),
    ],
    "background": [
        ("Works in product design",
         "Day job is interface design; the portfolio, type-scale work and case studies are "
         "all professional practice rather than hobby projects.", 4.0, 150),
        ("Self-taught on the systems side",
         "No formal background in infrastructure — the home lab knowledge came from running "
         "one and fixing it when it broke.", 3.2, 130),
    ],
    "writing_style": [
        ("Writes short, leads with the outcome",
         "Revision habits consistently cut length and move the result to the front — the "
         "case-study rewrite halved the word count and opened with the outcome.", 4.1, 60),
        ("Plain vocabulary, concrete nouns",
         "Avoids abstraction where a specific thing will do. Prefers 'the 200MB sample file' "
         "to 'large inputs'.", 3.4, 75),
    ],
}

CHATS = [
    ("Rust lifetimes, plainly", [
        ("user", "explain rust lifetimes like i already know pointers but not rust"),
        ("assistant",
         "A lifetime is a compile-time label on *how long a reference is valid*. It's not a "
         "pointer's type and it doesn't exist at runtime — the compiler erases it.\n\n"
         "The rule the borrow checker enforces is: a reference may never outlive the thing it "
         "points at. `'a` in a signature is you telling the compiler how the input and output "
         "lifetimes relate, so it can check callers.\n\n"
         "Your HashMap error was a different rule: you can't hold a shared borrow (the "
         "iterator) and take a mutable borrow at the same time. Collecting the keys first ends "
         "the first borrow before the second begins."),
        ("user", "so collecting keys isn't a hack"),
        ("assistant",
         "Right — it's the intended shape. You're separating 'decide what to change' from "
         "'change it', which is also what makes the code easier to read."),
    ]),
    ("Two weeks in Japan — sanity check", [
        ("user", "here's my 14 day itinerary, tokyo 4 / kanazawa 2 / kyoto 4 / osaka 2 + 2 buffer. too much?"),
        ("assistant",
         "That's a reasonable pace — four cities in fourteen days with two buffer days is on "
         "the calm side of typical.\n\n"
         "One thing to check: Kanazawa at two nights means one full day, and the garden plus "
         "the samurai district plus Omicho market is already a full day. If anything gets cut "
         "on the trip it'll be that one.\n\n"
         "Moving the Kanazawa leg earlier was the right call for the rail pass — the two long "
         "legs are what make the 14-day pass pay off."),
        ("user", "what would you drop if a day disappears"),
        ("assistant",
         "Osaka. It's the closest to Kyoto and the easiest to do as a day trip if you end up "
         "with a spare afternoon."),
    ]),
    ("Case study: cut this in half", [
        ("user", "this case study is 1400 words and nobody finishes it. what do i cut"),
        ("assistant",
         "Cut the process narrative. Right now the first 600 words are how you got to the "
         "answer, and the answer arrives at word 900.\n\n"
         "Structure that tends to survive: outcome in the first two sentences, then the one "
         "constraint that made it hard, then two or three decisions that followed from it. "
         "Everything else is evidence you can put behind a link.\n\n"
         "Your instinct to read it out loud is a good filter — anything you skip while reading "
         "aloud is a candidate."),
    ]),
]



# ── 写盘 ────────────────────────────────────────────────────────────────

def d(days_ago):
    return TODAY - timedelta(days=days_ago)


def slugify(title):
    out = []
    for ch in title.lower():
        if ch.isalnum():
            out.append(ch)
        elif ch in " -_":
            out.append("_")
    s = "".join(out)
    while "__" in s:
        s = s.replace("__", "_")
    return s.strip("_")[:60]


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def write_event(days_ago, title, summary, weight, impact, tags, frame_id):
    day = d(days_ago)
    rel = f"{day}/{day}_{slugify(title)}.md"
    path = os.path.join(ROOT, "events", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    body = (
        "---\n"
        f"created: {day}\n"
        f"impact: {impact}\n"
        f"raw_impact: {impact}\n"
        "rebalance_count: 0\n"
        "impact_source: llm:demo\n"
        f"weight: {weight}\n"
        f"occurrences: [{day}]\n"
        f'event_title: "{esc(title)}"\n'
        f'event_summary: "{esc(summary)}"\n'
        "type: experience\n"
        f"member_frame_ids: [{frame_id}]\n"
        "distilled_into: []\n"
        'source: "timeline:event"\n'
        f"tags: [{', '.join(tags)}]\n"
        "superseded_by: null\n"
        "pinned: false\n"
        "archived_at: null\n"
        "---\n"
        f"{summary}\n"
    )
    with open(path, "w") as f:
        f.write(body)
    return rel


def write_portrait(category, title, summary, weight, span_days):
    path = os.path.join(ROOT, "portrait", category, f"{slugify(title)}.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    first = d(span_days)
    last = d(max(1, span_days // 4))
    with open(path, "w") as f:
        f.write(
            "---\n"
            f"created: {first}\n"
            "raw_impact: 3\n"
            "rebalance_count: 0\n"
            "impact_source: unscored\n"
            f"weight: {weight}\n"
            f"occurrences: [{first}, {last}]\n"
            f'event_title: "{esc(title)}"\n'
            f'event_summary: "{esc(summary)}"\n'
            "type: experience\n"
            f"category: {category}\n"
            "distilled_into: []\n"
            'source: "distilled"\n'
            f"tags: [{category}, portrait]\n"
            "superseded_by: null\n"
            "pinned: false\n"
            "archived_at: null\n"
            "merge_count: 2\n"
            "---\n"
            f"{summary}\n"
        )


def write_chat_db():
    path = os.path.join(ROOT, "chat.sqlite")
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY, title TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY, conv_id TEXT NOT NULL,
            role TEXT NOT NULL, text TEXT NOT NULL,
            parts_json TEXT, time REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS messages_conv_time ON messages(conv_id, time);
    """)
    for i, (title, msgs) in enumerate(CHATS):
        cid = str(uuid.uuid5(uuid.NAMESPACE_URL, "portrait-dev/conv/" + title)).upper()
        t0 = datetime.combine(d(2 + i * 5), datetime.min.time()).timestamp() + 15 * 3600
        con.execute("INSERT INTO conversations VALUES (?,?,?,?,?)",
                    (cid, title, 0, t0, t0 + 60 * len(msgs)))
        for j, (role, text) in enumerate(msgs):
            mid = str(uuid.uuid5(uuid.NAMESPACE_URL,
                                 f"portrait-dev/msg/{title}/{j}")).upper()
            con.execute("INSERT INTO messages VALUES (?,?,?,?,?,?)",
                        (mid, cid, role, text, None, t0 + j * 60))
    con.commit()
    con.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true",
                    help="先删掉现有 ~/.portrait-dev/{events,portrait} 再生成")
    ap.add_argument("--folders", type=int, default=len(FOLDERS),
                    metavar="N",
                    help="只保留前 N 个 folder(0…%d,默认全部)。事件全都照写,"
                         "第 N 个之后那些 folder 的 json 不生成 —— 它们的事件就成了"
                         "未分类。用来试 GraphConstants.unclassifiedFolderMin(=3)那条"
                         "规则:N<3 时未分类事件直连主球、不立 Unclassified 分区球;"
                         "N>=3 才立。" % len(FOLDERS))
    args = ap.parse_args()
    keep = max(0, min(args.folders, len(FOLDERS)))

    assert ROOT.endswith(".portrait-dev"), "安全阀:只允许写 ~/.portrait-dev"
    if args.force:
        for sub in ["events", "portrait"]:
            shutil.rmtree(os.path.join(ROOT, sub), ignore_errors=True)
    os.makedirs(ROOT, exist_ok=True)

    frame = 1000
    n_events = 0

    n_folders = 0
    n_loose_from_dropped = 0
    for idx, (slug, name, color, desc, items) in enumerate(FOLDERS):
        rels = []
        core = 0
        for days_ago, title, summary, weight, impact, tags in items:
            frame += 7
            rels.append(write_event(days_ago, title, summary, weight, impact, tags, frame))
            if weight >= 1.5:
                core += 1
            n_events += 1
        assert core >= CORE_MIN, f"{slug} 只有 {core} 个核心事件,folder 会散架"
        # 超出 --folders N 的:事件已经写进磁盘了,只是不给它建 _folders json,
        # 于是这些事件在 app 眼里就是「没归任何 folder」。
        if idx >= keep:
            n_loose_from_dropped += len(rels)
            continue
        n_folders += 1
        fdir = os.path.join(ROOT, "events", "_folders")
        os.makedirs(fdir, exist_ok=True)
        created_ms = int(datetime.combine(d(90), datetime.min.time()).timestamp() * 1000)
        updated_ms = int(datetime.combine(d(1), datetime.min.time()).timestamp() * 1000)
        with open(os.path.join(fdir, f"{slug}.json"), "w") as f:
            json.dump({
                "slug": slug, "name": name, "description": desc,
                "events": rels, "createdAtMs": created_ms,
                "updatedAtMs": updated_ms, "colorHex": color,
            }, f, indent=2, sort_keys=True)

    for days_ago, title, summary, weight, impact, tags in LOOSE:
        frame += 7
        write_event(days_ago, title, summary, weight, impact, tags, frame)
        n_events += 1

    n_portrait = 0
    for category, items in PORTRAIT.items():
        for title, summary, weight, span in items:
            write_portrait(category, title, summary, weight, span)
            n_portrait += 1

    write_chat_db()

    print(f"写到 {ROOT}")
    loose = len(LOOSE) + n_loose_from_dropped
    print(f"  events    {n_events} 条 / {n_folders} 个 folder + {loose} 条未分类")
    # 图谱口径(08-09 二稿):有 folder 就立分区球,0 个才直连主球。
    # Text 列表仍是三档(0 平铺 / 1-2 粗线 / >=3 收成组),两边有意不同。
    if n_folders >= 1:
        print(f"  → 图谱:有 folder → {loose} 条未分类收成灰色 Unclassified 分区球")
    else:
        print(f"  → 图谱:0 个 folder → {loose} 条未分类**直连主球**")
    print(f"  portrait  {n_portrait} 条 / {len(PORTRAIT)} 个类别")
    print(f"  chat      {len(CHATS)} 段对话")
    print("config.toml 不在这里生成 —— app 首次进 dev mode 时自己从真实 config 拷一份。")


if __name__ == "__main__":
    main()
