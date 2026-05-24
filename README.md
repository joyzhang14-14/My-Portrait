# My-Portrait

7×24 跑在本地的个人 AI 数据库 —— macOS 原生 Swift app。

后台采集屏幕（截图 + OCR）、音频（Whisper 转写）、打字、焦点切换；把原始事件
蒸馏成"个人画像"（personality / portrait）；再把这份画像喂给 LLM，让 AI 真的
懂你。数据全部留在本机。

> 状态：WIP，未发布。`Capture/` 还在 P0 stub 阶段，调用会冒红点。发布前必修项
> 见 `BEFORE_SHARING.md`。

---

## 跑起来

**前置**：macOS 15+、Xcode 16+、[xcodegen](https://github.com/yonaskolb/XcodeGen)
（`brew install xcodegen`）。

```bash
xcodegen generate          # 从 project.yml 生成 .xcodeproj
./build-app.sh --run       # 编 + 独立启动 .app
```

⚠️ **必须独立启动**（不能用 Xcode ⌘R）。挂在 Xcode debugger 下时，TCC（屏幕录制 /
麦克风权限）会把请求归属到 Xcode，My Portrait 自己永远拿不到授权。`build-app.sh`
已经处理好。

日常迭代直接在 Xcode 里 ⌘B 也行，但要跑 Capture 还是得 `./build-app.sh --run`。

### 增删 `.swift` 文件后

```bash
xcodegen generate
```

SwiftPM 自动扫 `Sources/`，但 `.xcodeproj` 是静态文件列表，不重新生成 Xcode 会
`Cannot find 'Xxx' in scope`。

---

## 配置

用户配置：`~/.portrait/config.toml`（模板见 `docs/config.example.toml`）。
UI 里改和手改文件等价，互相同步。

数据存放：

- `~/.portrait/` —— 配置、cron 任务、画像、对话
- `~/Library/Application Support/MyPortrait/` —— 密钥、缓存、DB
- `~/.screenpipe/` —— **只读复用**，要拷只 copy 不 mv

---

## 代码地图

```
Sources/MyPortrait/
├── Capture/      屏幕 / 音频 / 打字 / 焦点采集（性能优先，对标 screenpipe）
├── Memory/       事件 → 画像 蒸馏管线（personality、portrait、Tier1 合并、印象 EMA）
├── AI/           多 Provider 聊天、cron 调度、Agent、PII 脱敏、OAuth、SMTP
├── DB/           GRDB + SQLite + WAL + FTS5
├── Settings/     设置面板 + TOML 配置读写
├── Typing/       打字采集与回放
├── Notifications/ 通知 / 推送
├── DesignSystem.swift   玻璃浮层 + 蓝色渐变 主题 token
├── ContentView.swift    主窗口（左侧 sidebar + 右侧 pane）
├── HomeView.swift / TimelineView.swift / ConnectionsView.swift / ...
└── App.swift            入口
```

每个子目录大都有自己的 `README.md` 讲细节（例如 `Capture/README.md` 画了完整
调用图）。

---

## 技术栈

| 用途 | 依赖 |
|---|---|
| SQLite ORM（持久化） | [GRDB.swift](https://github.com/groue/GRDB.swift) |
| 端上语音识别 | [WhisperKit](https://github.com/argmaxinc/WhisperKit) |
| 端上 LLM / 向量 | [mlx-swift](https://github.com/ml-explore/mlx-swift) + [mlx-embeddings](https://github.com/mzbac/mlx.embeddings) |
| 说话人识别（pyannote + wespeaker） | [onnxruntime](https://github.com/microsoft/onnxruntime-swift-package-manager) |
| TOML 配置 | [TOMLKit](https://github.com/LebJe/TOMLKit) |
| Tokenizer | [swift-transformers](https://github.com/huggingface/swift-transformers) |

UI：SwiftUI + `.ultraThinMaterial`（玻璃）+ `.symbolEffect(.bounce)`（图标动效）。

---

## 双轨构建

| | 用途 | 入口 |
|---|---|---|
| **SwiftPM** | `swift build` / CI / Claude 验证编译 | `Package.swift` |
| **Xcode** | 真正出签名 `.app`、跑 TCC、平时用 | `MyPortrait.xcodeproj`（XcodeGen 从 `project.yml` 生成，不手动维护） |

源码一份，两套都能 build。两者唯一的差别就是 `.xcodeproj` 不会自动感知文件
系统变化 —— 新增/删除/改名 `.swift` 必须 `xcodegen generate`。

---

## 给 Claude / 协作者

项目级约定见 `CLAUDE.md`。重点：

- 改完 `.swift` 文件结构跑 `xcodegen generate`
- `swift build` 报 `Cannot find type` 在同模块内多半是 SourceKit 误报，看 `Build complete`
- `~/.screenpipe/` 只读，永远不要 `mv`
- 仓库会有并行 Claude session 同时写入，commit 前 `git status` 两次，不动陌生 dirty 文件
