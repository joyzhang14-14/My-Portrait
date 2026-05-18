# My-Portrait

7×24 跑在本地的个人 AI 数据库：屏幕 + 麦克风 + 系统音频自动采集 → OCR / 转录 →
长期画像。**所有数据本地，永不上云**。

设计文档：`~/Desktop/Obsidian/personal_ai_design_v2.md`

## 现状

| 子系统 | 状态 |
|---|---|
| **采集层** (`Capture/`) | ✅ 完整 |
| **持久层** (`DB/`) | ✅ 完整（FTS 已通；向量待 Phase 4） |
| **Settings UI** (`Settings/`) | ✅ 完整 9 个 section |
| **Timeline / Memory / Chat / Pipes UI** | ✅ 已有（继承自旧版） |
| **画像层 / Agent 系统** (设计文档第 3-6 节) | ❌ 未开始 |

## 模块结构

```
Sources/MyPortrait/
├── App.swift / ContentView.swift                  ← AppKit 接管的主窗口
├── Services.swift                                 ← 中央服务容器
├── StatusBarMenu.swift                            ← 状态栏控制（采集 / 暂停）
│
├── Capture/                                       ← 采集层
│   ├── README.md                                  ← 模块说明 + 调用图
│   ├── CaptureError.swift / UnimplementedReporter.swift
│   ├── Coordinator/                               ← 总调度
│   ├── Screen/                                    ← ScreenCaptureKit + Vision OCR + AX
│   ├── OCR/                                       ← Vision 包装 + 缓存
│   ├── Events/                                    ← 事件驱动调度（NSWorkspace + CGEvent + ...）
│   ├── Audio/                                     ← AVAudioEngine + VAD + WhisperKit + Speaker stub
│   ├── Compaction/                                ← JPG → HEVC MP4 后台压缩
│   ├── Power/                                     ← IOKit 电源监听 (事件驱动)
│   └── DB/PortraitDB.swift                        ← 出向 DB 的 protocol
│
├── DB/                                            ← 持久层
│   ├── README.md                                  ← 模块说明 + schema + 搜索蓝图
│   ├── PortraitDBImpl.swift                       ← GRDB 7 + WAL + actor
│   ├── Schema.swift                               ← v1/v2/v3 migrations
│   ├── FoundationTokenizer.swift                  ← ICU 分词（Foundation 借道）
│   ├── RetentionWorker.swift                      ← 自动删除（24h cadence）
│   ├── Records/                                   ← GRDB Codable 结构体
│   ├── Search/                                    ← FTS（已实现）+ Hybrid 占位
│   └── Vectors/                                   ← bge-m3 下载 / 推理 stub
│
├── Settings/                                      ← Settings UI（9 个 section）
│   ├── SettingsView.swift / SettingsModel.swift   ← 路由 + AppStorage keys
│   ├── CaptureSettings.swift                      ← 后端运行时镜像（@Published + UserDefaults 双向同步）
│   ├── GeneralView / RecordingView / DisplayView / NotificationsView /
│       PrivacyView / StorageView / UsageView / SpeakersView / AIModelsView
│
├── AI/                                            ← 已有的 AI 流（Pi agent / Pipes）
├── Memory/                                        ← 已有画像层占位
├── TimelineView.swift / HomeView.swift / ...      ← UI views
└── ScreenpipeDB.swift                             ← 旧只读连接器（读 ~/.screenpipe/）
```

## 数据落地

所有运行时数据在 **`~/.portrait/`**：

```
~/.portrait/
├── portrait.sqlite        ← 主数据库（GRDB / WAL，DB 模块负责）
├── raw_data/
│   ├── frames/YYYY-MM-DD/{ts}_m{monitor}.jpg     ← 热缓存 (~10 min)
│   └── video/YYYY-MM-DD/m{id}_{start_ts}.mp4    ← HEVC 压缩后归档
├── audio_queue/
│   ├── seg_<ISO>.wav                             ← VAD 切的语音段
│   ├── seg_<ISO>.meta.json                       ← 采样率/时长/设备
│   └── seg_<ISO>.transcript.json                 ← WhisperKit 转录 (文件系统真相)
├── models/bge-m3/                                ← HuggingFace 下载缓存
├── portrait/                                     ← 画像 markdown 层（设计文档 §5）
├── events/ / logs/ / journal/                    ← 日志 + journal（设计文档 §4 §6）
└── .embeddings/                                  ← 预留向量索引 sidecar
```

**绝不动 `~/.screenpipe/`** —— 那是旧 daemon 的数据，复用只能 copy。

## 关键决策

- **GRDB 7** + 系统 sqlite3 + WAL —— 多 reader / 单 writer 不阻塞
- **ICU 分词通过 Foundation 借道** —— 系统 sqlite3 没编 ICU，但 Foundation 的
  `enumerateSubstrings(.byWords)` 在 Darwin 上本来就是 ICU
- **事件驱动调度** —— 不再定时 1fps，看 NSWorkspace + CGEventTap + 剪贴板 + 视觉差 + idle 兜底
- **两阶段屏幕存储** —— 热 JPG（10 分钟）→ 后台压成 HEVC MP4，省 100×
- **延迟转录** —— 电池模式只录音 + VAD，AC 接通才烧 Neural Engine 跑 WhisperKit
- **DB 模块抽象成两组接口** —— `PortraitDB`（读写）+ `SearchEngine`（查询）。
  UI 调 SearchEngine，将来从 FTS 换 Hybrid 时 UI 零改动

## 依赖

```swift
// Package.swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
```

## 跑起来

```bash
cd /Users/joyzhang14/Projects/My-Portrait
./scripts/make-app.sh && open MyPortrait.app
```

**首次启动**：屏幕采集 / 麦克风开关都是 **关**（避免一上来弹 4 个权限请求）。在
Settings → Recording 里手动打开。打开瞬间才弹对应权限。状态栏菜单（`🔴 / ⏸ / ○`）
是一键控制中心。

bge-m3 模型（~2.5 GB）首次启动后台自动下载到 `~/.portrait/models/bge-m3/`。
推理（Phase 4）还没接通；当前模型只是放在那里。

## 权限

首次启动会按需要弹这几个：

| 权限 | 触发时机 | 缺失后果 |
|---|---|---|
| **屏幕录制** | Settings 打开"屏幕采集" | 屏幕采集开不了 |
| **麦克风** | Settings 打开"麦克风" | 录音开不了 |
| **辅助功能** | 焦点切换（自动尝试） | 窗口标题 + URL + AX text 拿不到，OCR fallback |
| **输入监控** | 注册 `NSEvent` 全局监听器（自动） | 键盘 / 滚动 trigger 失效（其他事件源还在） |

## 文档

- [`Capture/README.md`](Sources/MyPortrait/Capture/README.md) — 采集层调用关系
- [`DB/README.md`](Sources/MyPortrait/DB/README.md) — 持久层 + 搜索蓝图
- `~/Desktop/Obsidian/personal_ai_design_v2.md` — 总设计文档
