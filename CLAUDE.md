# My-Portrait 项目说明

macOS 原生 Swift app（个人 AI 记忆系统）。

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

- 我（Claude）这边用 `swift build` 验证编译。SourceKit 的 `Cannot find type`
  之类报错在同模块内常是误报，以 `Build complete` 为准。
- 用户在 Xcode 里 build & run 跑真正的 `.app`。代码改动需用户重新 build；
  纯数据改动（`~/.portrait/` 下的文件）只需 app 内 reload 或重开。
