# Typing Observer —— 已知问题

> **KI-1 / KI-2 已在 v14 batch 重构中 RESOLVED。** 下面的描述保留作 future
> 参考。修复见 commit `feat(typing): v14 event-log + splice`。

## KI-1：中段编辑导致 `text` 字段字符顺序错乱

**状态**：✅ **RESOLVED in v14**（splice 就地替换）。

### 描述

在文本**中段**做替换 / 修改时，`typing_events.text` 字段里新输入的字符
会被追加到末尾，而不是落在原位 —— 造成字符顺序错乱。

实测例：用户输入 `detect`（中途打成 `detest` 再改）。debounce 快照
diff 正确算出「把中段的 `s` 换成 `c`」（`prevMid="s"` / `newMid="c"`），
但 `fireDebounce` 的执行是两步：

```
handleDelete("s")      → 从 record.text 中段删掉 "s"   ✓
accumulate(["c"])      → 把 "c" append 到 record.text 末尾  ✗
```

结果 `detect` → `detetc`。

### 根因

`TypingRecordWriter.accumulate` 是 **append-only**。纯顺序前向打字没问题；
但任何「中段替换」被拆成「删中段 + 接末尾」两步，新字就跑到了末尾。

### 影响范围

- **受影响**：master record 的 `text` 字段 —— 中段编辑后字符顺序可能错。
- **不受影响**：`edit_log` —— commit / delete 流水按发生顺序如实记录，准确。
- 纯前向打字、末尾退格删除：不受影响。
- CJK 拼音采集（KI 之外）：已修复，不是本问题。

### Workaround

后续做 Speech Style / ADHD 编辑模式 / writing flow 分析时，**以
`edit_log` 为准，不要直接信 `text` 字段**。`edit_log` 是准确的事件流。

### 修复方向（splice）与待解决问题

方向：`fireDebounce` 不再拆成 `handleDelete + accumulate` 两步，而是按
`TextDiff.sandwich` 的结果对文本做 **in-place splice**（prefix 不变、
prevMid→newMid 原位替换、suffix 不变）。

实施前必须先解决三个问题：

1. **splice 位置跨 element 对齐**
   `prefix.count` 是单个 AX element 内的偏移；`record.text` 是 per-app
   master record，混合多个 element 的内容。splice 进 `record.text` 需要
   知道该 element 在 `record.text` 里的起始 offset，否则错位。可能要给
   每个 element 存起始 offset，或改成 per-element 存文本。

2. **跨 record delete（2000 字符回查）与 splice 协调**
   `handleDelete` 的跨 record 路径用 `.backwards` substring 定位；splice
   用 prefix-offset 定位。两套语义不一致。已 flush 进 DB 的内容拿不到
   有效的 prefix-offset（DB 里是别的 session 拼接的文本）。预案：
   in-progress 用 splice，cross-record fallback 仍用 substring，两种行为
   并存 —— 测试需各自 verify。

3. **跨 element 切换后历史 element 的快照**
   当前 focus 切走时 `clearElementState` 会删掉该 element 的
   `lastValueSnapshot`，切回时重新读 baseline（不存在 stale 快照）。但
   这意味着「切走再回来改中段」同样受问题 1 影响，需一并 verify。

---

## KI-2：切窗口回来后大段删除丢失

**状态**：✅ **RESOLVED in v14**（event-log + baseline 吸纳）。

### 描述

切到别的窗口再切回来后删除文本，删除不被记录、DB 不更新。

实测：删 `Test1, can u see what I `（33 字）→ `handleDelete` 走跨 record
DB 路径 → DB 文本 121 字但 `contains=false` → `NOT found, discarded`。

### 根因

切窗口会 flush 并清空 in-progress record。之后的删除只能走「跨 record
查 DB 末尾 2000 字符 + 逐字 substring 匹配」。而 DB 的 `text` 是累加文本、
跟输入框真实内容已漂移，逐字匹配大段必然失败。跟 KI-1 同根 ——
「累加文本 ≠ 输入框真实内容」。

### v14 怎么修的

KI-1 + KI-2 同根，v14 batch 重构一并解决：

- `typing_events` 改成 **append-only event log**（一条 record = 一个
  (app, element) 的一段 session），不再 master-record-per-app UPSERT。
- 每个 (app, element) 一份 in-progress record，带 `baseline` +
  `baselineOffset` + `text`；每次 value-change 经 350ms debounce 后用
  `TextDiff.sandwich` 出 delta、**就地 splice**（insert /
  removeSubrange / replaceSubrange）。
- 切窗口回来：新 session 的 `baseline` = 输入框当前内容。删除旧内容时
  `effPos < 0` 触发 baseline 吸纳，删除在新 session 里就地生效、记进
  `edit_log`。不再有「跨 record 2000 字符逐字匹配」这条脆弱路径
  （`handleDelete` 整个移除）。
- 不变量 `lastValueSnapshot == baseline + text` 保证 splice 位置永远对。
