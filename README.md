# Personal AI — Demo

> 📛 **占位名**：你说还在想（My-Mirror / My-Twin / My-Scribe / My-Echo / My-Assistant / My-Monitor / 自定义 …）。确定后把 `Sources/PersonalAI/` 重命名 + 改 `Package.swift` 里的 `name` 即可。

Swift 原生 macOS App，仿你给的两张 screenpipe 截图：
- 主页（AI 聊天 home，6 卡片 + 6 chip + 模型选择栏）
- Timeline（**真实数据**：直接读 `~/.screenpipe/db.sqlite`，无需任何后端运行）
- Sidebar、模型选择、ChatGPT 标签全部按截图复刻

## 怎么跑

```bash
cd /Users/joyzhang14/Projects/personal-ai-demo
swift run
```

约 3 秒后弹出 1400×880 窗口。在 Xcode 里调样式更顺手：

```bash
open Package.swift
```

## 当前已实现

### 主页（HomeView）
- 顶部 greeting + connector 图标
- 6 个 suggestion 卡片（Automate My Work / Day Recap / Standup / Top of Mind / Custom / Discover）
- "BASED ON YOUR ACTIVITY" + 6 个等宽 chip
- 底部输入栏：filter / CHATGPT 标签 / OPENAI-CHATGPT GPT-5.4 / 占位输入框 / shield / paperclip / 发送按钮

### Timeline
- **真实数据**：读 `~/.screenpipe/db.sqlite` 的 `frames` 表
- 日期导航器（左右翻日 + 刷新）
- **日历 popover**：完整月视图，可切月，点日期跳转
- 主预览：当前帧的截图 + app 名 + 窗口名 + 时间戳
- 底部活动条：每帧一道色条（颜色按 app 名 hash），粉色 playhead，**支持拖动 scrub**
- 空状态：没数据库、没数据、加载中三种

### Sidebar
- App 名 + 状态图标（display / bell+9+ / phone）
- New chat 按钮
- 6 个导航项（Pipes / Timeline / Meeting notes / Memories / Connections / Home）
- 17 条 mock recents
- 底部 Settings

### 流畅度优化
- 截图懒加载 + downsample（用 ImageIO 的 `kCGImageSourceThumbnailMaxPixelSize`，绝不加载全分辨率）
- NSCache 缓存最近 600 张缩略图
- 后台线程做图像解码，主线程零阻塞
- Activity 条用 `Canvas` 渲染，1200 条色块也丝滑
- 数据库查询限 1200 行 / 日（够用且快）

## 还没做（按需求等你确定后再补）

- ChatGPT OAuth 登录（占位标签已有，按钮真实流程待写）
- 多 provider 切换菜单（"GPT-5.4 ⌄" chevron 仅装饰）
- Pipes / Memories / Connections / Meeting notes 都是 stub
- Settings 页（只是 sidebar 按钮）
- 发送消息真的接到 LLM API

## 文件结构

```
personal-ai-demo/
├── Package.swift              # SPM 配置（链接 sqlite3）
├── README.md
└── Sources/PersonalAI/
    ├── App.swift              # @main 入口
    ├── ContentView.swift      # 根布局（sidebar + 主面板路由）
    ├── Models.swift           # 数据类型 + mock + AppColor hash
    ├── Sidebar.swift          # 左侧 sidebar 全部 UI
    ├── HomeView.swift         # 主页（chat home + 卡片 + chip + 输入栏）
    ├── TimelineView.swift     # Timeline 全部（toolbar + popover + 预览 + 活动条）
    ├── ScreenpipeDB.swift     # SQLite 只读查询（无任何 SQLite 依赖，纯 C API）
    └── ImageLoader.swift      # 异步缩略图 + NSCache + ImageIO downsample
```

**总计 ~900 行 Swift，零第三方依赖**（只链系统 `libsqlite3`）。

## 命名清理 checklist（确定名字后）

1. 改 `Package.swift` 的 `name: "PersonalAI"` 和 target name
2. 改文件夹 `Sources/PersonalAI/` → `Sources/<NewName>/`
3. 改 `App.swift` 里 `struct PersonalAIApp: App` 和 WindowGroup 标题
4. 改 `README.md` 标题
5. （后续）创建 git 仓库初始化

## 性能基准（M 系列 Mac 实测预期）

| 操作 | 预期延迟 |
|---|---|
| 冷启动到窗口出现 | < 1 秒 |
| 主页渲染 | 即时 |
| Timeline 切换日期（1000+ 帧）| < 200ms 查询 + 异步渲染 |
| 拖动 scrub | 60–120fps，无掉帧 |
| 加载单张截图缩略图 | 首次 < 50ms，缓存命中即时 |
| 内存占用 | ~120–180MB（含截图缓存）|

如果你有任何不流畅的地方，告诉我具体哪个交互卡，我针对性优化。
