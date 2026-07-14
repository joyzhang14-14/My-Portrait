"""specifics 垃圾锚点的确定性分类器(app 条件化)。

一把尺子三处用:①lab.db 脏 digest 补救 ②v1.3 训练包锚点清洗 ③推理侧输出闸。
规则集源自 2026-07-14 五路侦察(E 路)+ 对抗核查修正,设计原则:宁可漏杀不可错杀。

⚠️ 关键修正(对抗核查抓的坑):R5 桌面文件名黑名单必须按前台 app 条件化——
前台是 Finder/QuickTime/Preview/Photos/Music 时,文件名就是用户正在操作的对象
(实锤:6-05 sk=2642 QuickTime 正在播 chapel_view_tour.mp4,是该 session 唯一锚点;
sk=3026 Finder 正在浏览 Obsidian 文件夹)。词表本身无法区分"真在用"vs"背景可见",
唯一区分信息 = 前台 app。

用法:
    from spec_junk import classify, clean_specs
    is_junk, rule = classify(s, app)          # app = 前台 app 名(可空)
    clean = clean_specs(specs, app, cap=12)   # 去垃圾 -> 截 cap

直接跑 = 自检 + lab.db 干跑;--apply 才写库(先自动备份)。
"""
import collections
import json
import re
import shutil
import sqlite3
import sys
import time

DB = '/Users/joyzhang14/Projects/My-Portrait/Tests/event-local-lab/lab.db'
SPEC_CAP = 12

# R5 不适用的前台 app:文件名/媒体名就是工作对象本身
MEDIA_FG = {'finder', 'quicktime player', 'preview', 'photos', 'music'}


def norm(s):
    s = re.sub(r'\s+', ' ', (s or '')).strip()
    s = re.sub(r'[.…]+$', '', s).strip()
    return s.casefold()


def nospace(s):
    return re.sub(r'\s+', '', (s or '')).casefold()


# ---------------------------------------------------------------- PROTECT
_HASH = re.compile(r'\b[0-9a-f]{7,40}\b')
_SRC = re.compile(r'\.(swift|py|ts|rs|c|h|m|json|toml|yml|yaml|sql|sh|db|sqlite|dmg)\b', re.I)
# paren 前不许有空格:留空格会把 'bypass permissions on (shift+tab...)' 救活
_IDENT = re.compile(r'[a-zA-Z_][a-zA-Z0-9_]*\(|[a-z][a-zA-Z0-9]+[A-Z][a-zA-Z0-9]*')
_QUOTE = re.compile(r'["“”\'`「」]')
_CJK = re.compile(r'[一-鿿]')


def _hard_protected(t):
    if '/' in t:
        return 'path'
    if _HASH.search(t):
        return 'hash'
    if _SRC.search(t):
        return 'srcfile'
    if _IDENT.search(t):
        return 'ident'
    if _QUOTE.search(t):
        return 'quote'
    return None


# ---------------------------------------------------------------- R1 系统菜单
SYS_MENU = {norm(x) for x in """
About This Mac|System Information|System Settings|App Store|Recent Items|Force Quit
Force Quit Finder|Sleep|Restart|Shut Down|Lock Screen|Log Out Joy Zhang|About Finder
Settings|Empty Trash|Services|Hide Finder|Hide Others|Show All|File|New Finder Window
New Folder|New Folder with Selection|New Smart Folder|New Tab|Open in New Tab
Open and Close Window|Open With|Always Open With|Close Window|Close All|Get Info
Show Inspector|Get Summary Info|Rename|Compress|Duplicate|Exactly|Make Alias|Quick Look
Slideshow|Print|Share|Manage Shared File|Show Original|Add to Sidebar|Add to Dock
Move to Trash|Delete Immediately|Eject|Find by Name|Edit|Undo|Move of 2 Items|Redo|Cut
Copy|Copy as Link|Paste|Move Item Here|Paste Exactly|Select All|Deselect All
Show Clipboard|Writing Tools|AutoFill|Start Dictation|Emoji & Symbols|View as Icons
as List|as Columns|as Gallery|Use Groups|Group By|Sort Groups By|Clean Up
Clean Up Selection|Clean Up By|Hide Tab Bar|Show All Tabs|Hide Sidebar|Show Preview
Hide Toolbar|Hide Path Bar|Show Status Bar|Customize Toolbar|Show View Options
Show Preview Options|Enter Full Screen|Go Back|Forward|Enclosing Folder
Enclosing Folder in New Window|Select Startup Disk|Recents|Documents|Desktop|Home
Library|Computer|AirDrop|Network|iCloud Drive|Shared|Applications|Utilities
Recent Folders|Go to Folder|Connect to Server|Window|Minimize All|Zoom All|Fill Center
Move & Resize|Full Screen|Tile|Remove Window from Set|Cycle Through Windows
Show Progress Window|Show Previous Tab|Show Next Tab|Move Tab to New Window
Merge All Windows|Bring All to Front|Arrange in Front|Help|Mac User Guide
Tips for Your Mac|Macintosh HD|Users|Public|Downloads|Movies|Music|Pictures
""".replace('\n', '|').split('|') if x.strip()}

# ---------------------------------------------------------------- R2 Claude TUI chrome
TUI = [re.compile(p, re.I) for p in [
    r'bypass permissions on', r'shift\+tab to cycle', r'esc to interrupt',
    r'How is Claude doing this session', r'Can Anthropic look at your session transcript',
    r'Press up to edit queued messages', r'Tip: Run tasks in the cloud',
    r'Relaunch to update', r'Your plan ends in \d+ days',
    r"You've used \d+% of your weekly limit", r'Claude is A[Il] ?and can make mistakes',
    r"^y: Yes n: No d: Don't ask again$", r'^Opus [\d.]+ (High|Low|Medium)$',
    r'^Claude Code v[\d.]+$', r'code\.claude\.com/docs', r'^/goal active',
]]
# 转圈状态行。大小写敏感:re.I 会误吃 'Duration 56s'(真·会议时长)
SPINNER = re.compile(r'^[A-Z][a-z]+(\.|ed|ing)?\s*(for\s+\d+[hms]|[\(（]\s*\d+[hms])')

# ---------------------------------------------------------------- R3 天气/日历 widget
WIDGET = [
    re.compile(r'Precipitation|Wind\s+\d+\s*km/h|No Events Today', re.I),
    re.compile(r'^\s*(MON|TUE|WED|THU|FRI|SAT|SUN)[A-Z]*\s+\d{1,2}\b.*\b\d+%', re.I),
    re.compile(r'Chapel Hill\s+\d+°', re.I),
]

# ---------------------------------------------------------------- R4 Finder 列头倾泻
FINDER_META = [
    re.compile(r'^(Date Modified|Size|Kind)\b.{20,}', re.I),
    re.compile(r'^\s*\d+(\.\d+)?\s*(KB|MB|GB)\b.*\b(KB|MB|GB)\b', re.I),
]

# ---------------------------------------------------------------- R5 背景桌面文件簇
# ⚠️ 只在前台 app ∉ MEDIA_FG 时生效(见文件头)。curated 词表,唯一有误杀风险的部分。
BG_DESKTOP_EXACT = {nospace(x) for x in [
    '声音训练素材', '高音训练素材', '南音训练素材',
    'Personal ai meeting 1.m4a', 'Personal ai meeting 1',
    'Games on Mac', 'IMG_9095.HEIC', 'School Calendar 25_26 v2.pdf',
    'HC schedule.png', 'UNC演唱会', 'claude-code-sourcemap',
    'F-1签证&大学', 'E-1签证8大学', 'a la poubelle', 'ala poubelle',
    'Contracts', 'video.mp4', 'valis-logo.png',
    'chapel_view_tour.mp4', 'text_overlay_demo.mp4',
    'Obsidian', 'Machine Learning', 'prectice-and-learn',
    # 'My-Orphies' 不在表里:是用户在写的真项目,列进来就是误杀
]}

BARE_APP = {norm(x) for x in ['Finder', 'Safari', 'Terminal', 'Xcode', 'Spotify',
                              'Sourcetree', 'Preview', 'Messages', 'QuickTime Player']}


def classify(s, app=None):
    """返回 (是否垃圾, 规则名)。app = 前台 app 名,决定 R5 是否生效。"""
    t = (s or '').strip()
    if not t:
        return True, 'EMPTY'
    n = norm(t)
    # 精确匹配规则最优先(逐字等于已知 UI 词条,精度最高,不给启发式护栏救活)
    if n in SYS_MENU:
        return True, 'R1_SYS_MENU'
    if n in BARE_APP:
        return True, 'R7_BARE_APP'
    if (app or '').strip().casefold() not in MEDIA_FG and nospace(t) in BG_DESKTOP_EXACT:
        return True, 'R5_BG_DESKTOP'
    hp = _hard_protected(t)
    if hp:
        return False, 'PROTECT:' + hp
    # chrome 恒为英文;成片 CJK = 用户原话粘在 chrome 前,放过(writing-style 要)
    if len(_CJK.findall(t)) < 4:
        if any(r.search(t) for r in TUI):
            return True, 'R2_TUI_CHROME'
        if SPINNER.match(t):
            return True, 'R2_SPINNER'
    if any(r.search(t) for r in WIDGET):
        return True, 'R3_WIDGET'
    if any(r.search(t) for r in FINDER_META):
        return True, 'R4_FINDER_META'
    if len(t) >= 25:
        return False, 'PROTECT:prose'
    # 长度规则绝不杀 CJK(「王昱」「挂断」是 who/social 的命根子),
    # 也不杀带分隔符的数字(电话/版本/价格/时间戳)
    if _CJK.search(t):
        return False, 'KEEP'
    if (len(t) <= 1 or re.fullmatch(r'[?？!！.。,，、:：;；•·\-—_]+', t)
            or re.fullmatch(r'\d{1,4}', t) or re.fullmatch(r'\d{1,3}%', t)):
        return True, 'R6_JUNK_TOKEN'
    return False, 'KEEP'


def clean_specs(specs, app=None, cap=SPEC_CAP):
    """去垃圾 -> 去重 -> 截 cap。保序。"""
    out, seen = [], set()
    for s in specs or []:
        if classify(s, app)[0]:
            continue
        k = nospace(s)
        if k in seen:
            continue
        seen.add(k)
        out.append(s)
    return out[:cap]


# ---------------------------------------------------------------- 误杀回归测试
# (锚点, 前台app) -> 必须存活
MUST_KEEP = [
    ('claude --dangerously-skip-permissions', 'Terminal'), ('My-Portrait', 'Terminal'),
    ('caffeinate', 'Terminal'), ('/Users/joyzhang14/Projects/My-Portrait', 'Terminal'),
    ('HomeView.swift', 'Terminal'), ('submitRaceBurst', 'Terminal'),
    ('Sources/MyPortrait/Memory/MemoriesView.swift', 'Terminal'),
    ('f1a4f79', 'Terminal'), ('MyPortrait_1.2.89_intel.dmg', 'Terminal'),
    ('recomputePowerProfile', 'Terminal'), ('writing-capture-researcher', 'Terminal'),
    ('BUILD SUCCEEDED', 'Xcode'), ('Build complete', 'Terminal'),
    ('王昱', 'WeChat'), ('挂断', 'WeChat'), ('先别和blair说我实习的事', 'WeChat'),
    ('我知道 没问题 卖个惨 你发烧', 'WeChat'),
    ('GitHub上优秀的会议转译项目', 'Safari'), ('苹果API能否监听输入法', 'Safari'),
    ('834-420-2000', 'Safari'), ('$14+', 'Safari'), ('1.2.95', 'Terminal'),
    ('2026-06-05 06:30:16', 'Terminal'), ('Duration 56s', 'My Meeting'),
    ('两条路，你定： • Can Anthropic look at your session transcript to h', 'Terminal'),
    ('My-Orphies', 'Terminal'),
    # app 条件化的核心判例:媒体前台时文件名是工作对象本身
    ('chapel_view_tour.mp4', 'QuickTime Player'),
    ('Obsidian', 'Finder'), ('Contracts', 'Finder'), ('UNC演唱会', 'Finder'),
    ('School Calendar 25_26 v2.pdf', 'Finder'),
]
# (锚点, 前台app) -> 必须杀掉
MUST_KILL = [
    ('About This Mac', 'Finder'), ('Force Quit…', 'Terminal'), ('Empty Trash', 'Finder'),
    ('Bring All to Front', 'Finder'),
    ('bypass permissions on (shift+tab to cycle)', 'Terminal'),
    ('Cogitated for 1m 21s', 'Terminal'),
    ('How is Claude doing this session? (optional) 1: Bad 2: Fine', 'Terminal'),
    ('Opus 4.8 High', 'Terminal'), ('Relaunch to update v1.11187.1', 'Terminal'),
    ('AutoFill', 'Safari'), ('AirDrop', 'Finder'), ('Finder', 'Finder'),
    # 非媒体前台时,桌面文件名是背景噪声
    ('IMG_9095.HEIC', 'Terminal'), ('声音训练素材', 'Terminal'),
    ('a la poubelle', 'Safari'), ('Games on Mac', 'Terminal'),
    ('Personal ai meeting 1.m4a', 'Terminal'), ('chapel_view_tour.mp4', 'Terminal'),
]


def selftest():
    bad = 0
    for s, app in MUST_KEEP:
        g, r = classify(s, app)
        if g:
            print(f'  !! 误杀 {s!r} (app={app})  被 {r}')
            bad += 1
    for s, app in MUST_KILL:
        g, r = classify(s, app)
        if not g:
            print(f'  ?? 漏杀 {s!r} (app={app})  判为 {r}')
            bad += 1
    print(f'自检: KEEP {len(MUST_KEEP)} / KILL {len(MUST_KILL)} -> '
          + ('全部通过 ✅' if bad == 0 else f'{bad} 条不合格 ❌'))
    return bad


def repair(apply=False):
    """lab.db 已落库 digest 的补救:去垃圾 -> 去重 -> cap 12,带审计痕迹。"""
    con = sqlite3.connect(DB if apply else f'file:{DB}?mode=ro', uri=not apply)
    rows = con.execute("SELECT day,session_key,app,digest FROM vision_items "
                       "WHERE digest IS NOT NULL AND digest!='' "
                       "ORDER BY day,session_key").fetchall()
    plan, rule_stat = [], collections.Counter()
    emptied = []
    for day, sk, app, dg in rows:
        d = json.loads(dg)
        sp = d.get('specifics') or []
        for s in sp:
            rule_stat[classify(s, app)[1]] += 1
        new = clean_specs(sp, app)
        if new != sp:
            nd = dict(d)
            nd['specifics'] = new
            nd['specifics_cleaned'] = True
            nd['specifics_before_n'] = len(sp)
            plan.append((day, sk, app, len(sp), len(new),
                         json.dumps(nd, ensure_ascii=False)))
            if sp and not new:
                emptied.append((day, sk, app, len(sp)))
    killed = sum(c for r, c in rule_stat.items() if not (r == 'KEEP' or r.startswith('PROTECT')))
    total = sum(rule_stat.values())
    print(f'digest {len(rows)} 条 / specifics {total} 条 / 判垃圾 {killed} ({killed/max(1,total)*100:.1f}%)')
    print(f'要改写的 digest: {len(plan)} 条;清成空壳的: {len(emptied)} 个')
    for day, sk, app, n in emptied:
        print(f'  -> 空壳 {day} sk={sk} app={app} (原 {n} 条)')
    for r, c in rule_stat.most_common():
        print(f'  {r:18s} {c}')
    if not apply:
        print('\n[dry-run] 未写库。--apply 才写(自动先备份)。')
        return
    bak = DB + '.bak.' + time.strftime('%Y%m%d-%H%M%S')
    shutil.copyfile(DB, bak)
    print(f'\n备份 -> {bak}')
    with con:
        for day, sk, _app, _b, _a, nd in plan:
            con.execute('UPDATE vision_items SET digest=:d WHERE day=:day AND session_key=:sk',
                        {'d': nd, 'day': day, 'sk': sk})
    print(f'已写库: UPDATE {len(plan)} 条 ✅')


if __name__ == '__main__':
    if selftest():
        print('自检未通过,拒绝出数。')
        sys.exit(1)
    repair(apply='--apply' in sys.argv)
