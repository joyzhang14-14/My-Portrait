# Capture/ — 屏幕 / 音频 / 焦点 采集层

7×24 运行的采集模块。性能优先（见 memory: feedback-capture-performance-first）。

## 当前阶段：P0 — 脚手架

所有函数体都是 stub，调用会通过 `UnimplementedReporter` 上报并 throw
`CaptureError.notImplemented`。状态栏会冒红点。

## 调用关系图（P1 目标）

```
                CaptureCoordinator (actor)
                       │
       ┌───────────────┼────────────────┐
       │ 定时触发      │ FocusProbe (app/window/url)
       ▼               ▼
ScreenCaptureService ─► CGImage
       │
       ├──► FrameComparer.shouldKeep ── false ──► 丢弃
       │   true
       ▼
SnapshotWriter.enqueue ─► JPG URL (立即返回)
       │
       │ 并发：
       ├──► PortraitDB.insertFrameWithOCR
       │
       └──► OCRService.recognize ─► OCRResult
                                       │
                                       ▼
                              （若先 insertFrame 占位）
                              PortraitDB.updateFrameOCR
                                       │
                                       ▼
                      Coordinator 通过 frameEvents AsyncStream
                      把 FrameEvent 推给订阅方（日志 Agent / UI / 画像距离器）
```

## 各文件职责

| 文件 | 职责 | 阶段 |
|---|---|---|
| `CaptureError.swift` | 统一错误类型（含 notImplemented） | P0 |
| `UnimplementedReporter.swift` | stub 命中上报中枢（log + 状态栏 + 计数） | P0 |
| `Coordinator/CaptureCoordinator.swift` | actor 总调度 + `frameEvents: AsyncStream<FrameEvent>` | P0 |
| `Coordinator/CaptureConfig.swift` | 所有阈值/参数中心配置 | P0 |
| `Screen/ScreenCaptureService.swift` | ScreenCaptureKit 单帧抓取 | P0 |
| `Screen/FrameComparer.swift` | Hellinger 直方图去重 | P0 |
| `Screen/SnapshotWriter.swift` | JPG 异步落盘（ImageIO） | P0 |
| `Screen/FocusProbe.swift` | actor，监听 NSWorkspace，热路径只读缓存 | P0 |
| `Screen/DRMGate.swift` | 黑名单 app 跳过这一帧 | P0 |
| `OCR/OCRService.swift` | Vision OCR + 灰度 + UTF-16 bbox | P0 |
| `OCR/OCRCache.swift` | `(app::title, imgHash)` LRU + TTL | P0 |
| `DB/PortraitDB.swift` | 出向 DB 的 protocol + Record 类型 | P0 |
| `DB/StubPortraitDB.swift` | P0 用，所有方法 throw notImplemented | P0 |
| `Events/` | 事件驱动调度（NSWorkspace / CGEventTap / Pasteboard） | P2 |
| `Compaction/` | JPG → MP4 后台压缩 | P3 |
| `Audio/` | AVAudioEngine + VAD + WhisperKit | P4 |
| `Power/` | IOKit AC/电池监听 + 延迟转录调度 | P4 |

## TODO（后续阶段升级时一并处理）

- [ ] P1：Records 类型超过 3 个后，拆 `DB/Records/` 子目录
- [ ] P1：建 `Tests/MyPortraitTests/Capture/` target，加 `testMainCaptureFlowHasNoUnimplementedStubs`
- [ ] P5：focus tracker 修 monitor-id 映射 bug，恢复 Warm/Cold 状态机

## 性能基准

单帧端到端 < 200ms 中位 / 稳态 RSS < 300MB（不含 WhisperKit 模型）/ 平均 CPU < 5%。
