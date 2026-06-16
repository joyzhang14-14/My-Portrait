# v22 · 指令/碎片过滤问题 · 调研与解决方案

> 用户在 `5.30-6.2-本地新pipeline产出.md` 标 ❓ 的「该丢弃」项调研。
> 两类非消息内容漏入成品:**① Discord 斜杠命令**、**② 浏览器地址栏/搜索栏碎片**。
> 本文档只做调研 + 方案,**未改代码**(下一步实施前给用户确认)。

---

## 问题 ① Discord 斜杠命令漏入成品

### 现象(用户标 ❓:#73 / #75 / #76 / #78 / #79,均 5/30 Discord)

成品里出现 bot 命令,不是真消息:

| 事件  | AX end_value             | 击键数 |
| ----- | ------------------------ | ------ |
| ev826 | `/play  url  …  +2 more` | 2      |
| ev833 | `/play  url  …  +2 more` | 7      |
| ev838 | `/play  url  …  +2 more` | 7      |
| ev829 | `/s`                     | 6      |
| ev840 | `/play`                  | 7      |

`/play url … +2 more` 是 Discord **斜杠命令自动补全 UI** 被 AX 整块记进 end_value;`/s`、`/stop`、`/play` 是命令本体。都不是用户「发出的消息」。

### 发生位置

`faithful_v2.py:322-325` 的 **slash gate**:

```python
kst = ks_full.replace("<CR>", "").replace("<BS>", "").strip()
if kst.startswith("/"):                                     # slash gate
    for a, t, s, evid, t0, t1, b in grp:
        drops.append(("slash gate", a, t, evid, t0, t1, "组击键以/开头(命令输入)"))
    continue
```

### 根因

**slash gate 是「组级击键」判断,不是「逐条文本」判断**:

1. 它看的是**整组的合并击键** `ks_full` 是否以 `/` 开头。一旦该组里 `/play` 前面还有别的消息(自家分组把同 bundle+10min 的事件并成一桶),`kst` 就不以 `/` 开头 → 整组放行 → `/play` 混进成品。
2. `/play url … +2 more` 这串文本来自 **AX end_value(自动补全 UI 渲染)**,不是逐字击键;就算单看击键也只有 `/p`/`/play` 几个键,组级合并后被淹没。

→ **组级、击键侧的闸,拦不住「逐条、AX 侧」的斜杠命令。**

### 解决方案

加一道**逐条文本** slash 过滤(和组级 gate 并存,不替换):在成品入册前,对每条记录的**文本**判断:

```python
# 逐条 slash 过滤:Discord 斜杠命令(命令本体 + 自动补全 UI)不是消息
def is_slash_command(t):
    s = cv(t).lstrip()
    if not s.startswith('/'):
        return False
    # 形态1:命令本体 /play /s /stop …(/ + 字母,首段无空格汉字)
    # 形态2:自动补全 UI:/cmd 后跟 'url' / '+N more' / 多行选项
    head = s.split()[0] if s.split() else ''
    return bool(re.fullmatch(r'/[a-zA-Z]{1,20}', head)) and (
        len(s) <= 30 or 'more' in s or '\n' in t or 'url' in s.lower())
```

**落点**:在 `is_residue`/`is_ph` 同级的丢弃闸里加一条(`faithful_v2.py` line ~321 附近的 dedup/丢弃段),命中 → `drops.append(("slash命令", …))`,不入成品。

**护栏(防误伤)**:

- 只命中 `/` 开头 + 首段是 `/字母`(纯命令形态);正常消息以 `/` 开头极罕见(用户真发「/」当内容的话,后面通常跟空格/汉字,可放过)。
- `+N more` / `url` / 多行 是 Discord 补全 UI 的强特征,可加权。
- ⚠️ 不要误杀文件路径(`/Users/…`)——但那类已被 `组级击键gate`(纯粘贴)/URL 闸处理;且 `/Users` 首段含大写+长,上面正则 `/[a-zA-Z]{1,20}` 对 `/Users/joyzhang14/…` 整串不 fullmatch(有 `/` 分隔),天然不命中命令形态。需实测确认。

---

## 问题 ② 浏览器地址栏 / 搜索栏 / 表单碎片漏入成品

### 现象(用户标 ❓:#2 `ad min`、#26 `s c`;同族还有 `dreamhouse`/`1.2.0`/`wispr`/`screen`)

| 事件  | AX end_value | url                                        |
| ----- | ------------ | ------------------------------------------ |
| ev913 | `ad min`     | `http://localhost:5173/admin/login`        |
| ev967 | `s c`        | `https://github.com/joyzhang14-14?tab=sta` |

`ad min` = 在 localhost 后台 **登录表单**敲 "admin";`s c` = 在 **GitHub 搜索/导航**敲字。都是浏览器里的**搜索/地址/表单输入**,不是聊天消息。

### 发生位置

**没有专门的过滤** —— 这类记录是合法的 typing_event(浏览器里确实在输入框打字),AX 抓到就进了管线;短 latin 残渣被标 `~residue` 保留展示,于是落进成品。

### 根因

**采集层无法区分「浏览器里的聊天输入」和「浏览器里的搜索/地址/表单输入」** —— 两者都是 Safari/Chrome 的 AX typing_event。实验线也没有据 url/字段类型做过滤。于是地址栏/搜索框/登录框的零碎输入,和网页聊天一样被当消息。

### 解决方案(两个方向,建议组合)

**方向 A:url 黑名单(精准,低误伤)**
浏览器记录,若 url 命中**非聊天**模式 → 该条进未定区/丢弃:

- `…/login`、`…/admin`、`…/signin`、`…/auth`(登录/后台表单)
- `localhost:…`、`127.0.0.1`(本地开发页)
- 搜索类 query(`?q=` / `?tab=` / `/search`)

**方向 B:浏览器短碎片闸(兜底)**
浏览器(Safari/Chrome)app 的记录,若是**短 latin 残渣**(≤2 段、纯字母、无汉字、`~residue`)→ 大概率搜索/地址栏碎片 → 进未定区(展示不入册,不是直接丢——宁可人工看见)。

**落点**:同上,`faithful_v2.py` 丢弃/未定区段;需要 url(记录已带 `evid` → 查 `typing_events.url`,管线里 line ~483 已有取 url 的代码可复用)。

**护栏**:

- 方向 A 的 url 黑名单要保守(只列明确的登录/本地/搜索),别误杀真网页聊天(如网页版 Discord/Gemini)。
- 方向 B 进**未定区**而非直接丢(用户原则:宁缺毋错、可见 > 静默丢)。

---

## 实施顺序建议

1. **先做问题 ①(斜杠命令)**:逻辑清晰、误伤面小(`/cmd` 形态很独特),收益直接(5/30 五条 ❓ 全清)。
2. **再做问题 ②(浏览器碎片)**:先上**方向 A(url 黑名单)**(精准),方向 B(短碎片进未定区)作为兜底,逐案验证别误杀网页聊天。
3. 每步:加闸 → 离线在 5/30-6/2 验证 ❓ 项被拦 + gold 41✓ 不回归 → commit(可单独回滚)。

## 关联

- 这是 HANDOFF 修复清单的 **类5(过度捕获)**,任务 #34。
- 与已修的 OCR 取帧(url 同站 `6f82a5c` / 6 级降级链 `dd811fa`)正交,互不影响。
