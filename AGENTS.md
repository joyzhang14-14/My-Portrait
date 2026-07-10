# My-Portrait 项目说明

macOS 原生 Swift app（个人 AI 记忆系统）。

## 写作采集 LLM 模型: 用小模型，尽量不要用好的模型比如说sonnet

## 构建系统：双轨

项目同时有两套构建：

- **SwiftPM**（`Package.swift`）：`swift build` 用。会自动扫描 `Sources/` 下所有
  `.swift` 文件，新增文件无需任何登记。
- **Xcode**（`MyPortrait.xcodeproj`）：用户在 Xcode 里 build & run 用。`.xcodeproj`
  是 **XcodeGen 从 `project.yml` 生成的产物**，不手动维护。

### ⚠️ 新增 / 删除 / 重命名 `.swift` 文件后必须跑 `xcodegen generate`

`.xcodeproj` 不会自动感知文件系统变化。新建一个 `.swift` 文件后：

- `swift build` 立刻能用（SwiftPM 自动扫）
- 但 Xcode build 会报 `Cannot find 'Xxx' in scope` —— 因为旧的 `.xcodeproj`
  没收录新文件

**所以：每次增删 `.swift` 文件后，执行 `xcodegen generate` 重新生成
`.xcodeproj`**，否则用户在 Xcode 里 build 必然失败。改 `project.yml` 配置后同理。

改完别忘了提醒用户在 Xcode 里重新打开项目（或让它重新加载）。

## 验证改动

- 我（Codex）这边用 `swift build` 验证编译。SourceKit 的 `Cannot find type`
  之类报错在同模块内常是误报，以 `Build complete` 为准。
- 用户在 Xcode 里 build & run 跑真正的 `.app`。代码改动需用户重新 build；
  纯数据改动（`~/.portrait/` 下的文件）只需 app 内 reload 或重开。

## ⚠️ Commit 只 add 自己改的文件,绝不 `git add -A` / `-a`

本仓库**经常有多个 Codex session 并行在改不同文件**。提交时:

- **每次完成修改后立即执行一次 `git commit`**,不要只把改动留在工作区。
- **只 `git add <你这次改的具体文件>`**,一个个列出来。
- **绝对禁止** `git add -A`、`git add .`、`git commit -a` —— 这些会把**别的
  session 还没提交的改动**一起卷进你的 commit。

**真实事故**:一个 session 改了 `WritingCaptureWorker.swift` 还没提交,另一个
session 用 `git add -A` 提交自己的 scheduler 改动,把前者**没写完的实验代码**
一起提交了;原 session 后来 `git revert` 自己的 commit 也删不掉(因为代码在别人
的 commit 里),留下半残状态,线上炸了才发现。

**commit 前两次 `git status`**:确认 staged 里只有你这次碰过的文件;看到陌生的
dirty 文件**别动、别 add**,那是别的 session 在写。

## ⚠️ GRDB `arguments:` 必须用 dict 形式,不要用数组字面量

```swift
// ❌ 错误 —— 偶发死锁
try Row.fetchAll(db, sql: "... WHERE a = ? AND b = ?", arguments: [v1, v2])

// ✅ 正确
try Row.fetchAll(db, sql: "... WHERE a = :a AND b = :b",
                 arguments: ["a": v1, "b": v2])
```

**为什么**:数组字面量 `[v1, v2]` 会被隐式转成
`[any DatabaseValueConvertible]`,Swift runtime 在 `_getWitnessTable` 查
protocol conformance 时**偶发死循环**(libswiftCore 已知 edge case,
跟 GRDB 无关)。

**症状**:GRDB reader 线程 100% 卡在
`StatementArguments.append(contentsOf:)` → `Array.append` →
`swift::_getWitnessTable` → `<deduplicated_symbol>` 死循环,主线程跟着
卡 SwiftUI 更新,整个 app 假死。Activity Monitor → Sample 才能抓到。

**约束**:
- 所有 `arguments: [...]` 一律用 dict
- `Int` 显式 cast 成 `Int64`(dict 形式无隐式 Int→Int64 转换):
  `["limit": Int64(limit)]`
- 动态变长 IN 子句必须保留数组时,显式用 `StatementArguments(args)` 包装
  (不是字面量,走另一条 API)
- 全工程已批量修过一次(48 处),新代码别走回头路

如果将来遇到「app 莫名卡死」,优先怀疑这条路径漏网。
