# 只读审计 Follow-up — 三个风险点专项

审计范围：`Sources/MyPortrait/HomeView.swift`、`Sources/MyPortrait/Memory/`、`Sources/MyPortrait/Capture/`。
执行模式：只读，未修改任何代码。

---

## a. HomeView.swift 旧 schema 引用

文件实际位置：`/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/HomeView.swift`
（不是预期路径里的 `UI/` 子目录，根目录直挂。）

搜索关键词：`ocr_text`、`\bf\.timestamp\b`、`speakers`、`\ba\.transcription\b`、`\ba\.is_input_device\b`

**无发现。** 该文件没有任何旧 screenpipe schema 列名残留。

---

## b. Memory/Backfill prompt vs parser 字段名一致性

扫描了以下 LLM 调用点：

| 模块 | 文件 | prompt 行 | parser 行 |
|---|---|---|---|
| EventBuilder | `Memory/EventBuilder.swift` | 195-305 | 317-374 |
| ImpactScorer | `Memory/ImpactScorer.swift` | 178-239 | 247-274 |
| PortraitDistiller | `Memory/PortraitDistiller.swift` | 195-264 | 268-307 |

### b.1 EventBuilder

prompt 要求字段：`id` / `decision` / `event_id` / `title` / `summary` / `type` / `portrait_facets`（每个有 `facet` + `value`）/ `tags` / `reason`。
parser 读取字段：完全相同。

**无不一致。**

### b.2 ImpactScorer

prompt 要求字段（line 217）：`{"id": <int>, "evidence": "<quoted fragment>", "impact": <float>}`
parser 读取（line 265-272）：`id` (Int)、`impact` (Double|Int)、`evidence` **回退** `reason`。

**轻微宽容，不是错误**：parser 在拿不到 `evidence` 时回退读 `reason`。prompt 里没要求 `reason`，所以正常路径走 `evidence` 没问题；只是历史兼容残留。可忽略。

**真正的小问题（功能层而非字段层）**：
- 位置：`Memory/ImpactScorer.swift:236`
- 行为：prompt 给 LLM 的 meta 行里塞了 `category=\(f.category)`
- 现状：`PortraitFile.category` 已标记 **DEPRECATED**（`Memory/PortraitFile.swift:53`），新事件路径不再写入，`PortraitFileIO.swift:82-83` 写明 "category is legacy"。
- 影响：所有新事件 LLM 看到的都是 `category=`（空字符串）。不影响打分（prompt 没让 LLM 用这个信息），但属于死信息浪费 token，最好删掉这一段。
- 严重度：低（不算字段不一致 bug，只是脏数据）。

### b.3 PortraitDistiller

prompt 要求字段（line 250-255）：`action` / `slug` / `title` / `body` / `derived_from`
parser 读取（line 286-290）：`action` / `slug` / `title` / `body` / `derived_from`

**无不一致。**

### b 小结

字段名拼写层面 **三个模块全部对齐**，没有上一轮主审计里那种 prompt 要 `category` parser 读 `facet` 之类的硬 bug。
唯一可清理项是 ImpactScorer prompt 里给 LLM 显示 deprecated 的 `category` 字段，不影响功能。

---

## c. Capture/ 资源释放路径

扫描方法：先按关键词 `AVAudioEngine()` / `SCStream(` / `Timer.scheduledTimer` / `DispatchSource.make` / `AVCaptureSession()` 直接搜，再扩展到 `NSEvent` monitor / `NotificationCenter` observer。

### c.1 AVAudioEngine（命中 2 处）

| 文件:行 | 创建 | 释放 | 风险 |
|---|---|---|---|
| `Capture/Audio/AudioCaptureService.swift:23` | `private let engine = AVAudioEngine()` | `stop()` 行 78-79：`engine.inputNode.removeTap(onBus:0)` + `engine.stop()` | 类型是 **actor**。无 `deinit`。依赖外部显式调用 `stop()`。`CaptureCoordinator.stop()` 链路里有调用，正常路径没问题；但如果上层忘了显式停（比如测试环境直接释放引用），actor 被 Task 强引用时 deinit 不会触发 → engine 永不释放，麦克风指示灯不灭。**建议补 deinit 兜底**（risk: low-medium）。 |
| `Capture/Audio/SystemAudioCaptureService.swift:37` | `private let engine = AVAudioEngine()` | `stop()` 行 141-142：同上 + `cleanupCoreAudio()` 释放 CATap + aggregate device | 同上。**额外风险更高**：除 engine 外还持有 Core Audio tap 和 aggregate device。aggregate device 是系统级资源（注册到 HAL），如果 actor 被强引用且 stop 未调用，aggregate 不会从系统注销，下次启动会在 HAL 里残留同名设备。**强烈建议补 deinit 兜底 cleanupCoreAudio**（risk: medium-high）。 |

### c.2 SCStream

**真正构造**：未发现 `SCStream(...)` 直接 init。
- `Capture/Screen/ScreenCaptureService.swift:40` 用的是 `SCStreamConfiguration()`（配置对象，无生命周期）。
- 截屏走的是 `SCScreenshotManager.captureImage(...)` 单帧路径（不是常驻 stream）。
- `ScreenCaptureService.invalidateStream()` 行 74 是预留 API，没有真 stream 要 invalidate。

**无发现。**

### c.3 Timer.scheduledTimer / DispatchSource.make

整个 `Capture/` 下 **零命中**。该项目避开了这两类 API，全部用 `Task { ... }` + `Task.cancel()` 模式。
对应的 cancel 调用都齐全：

| 文件:行 | 创建 (Task) | 释放 (.cancel()) |
|---|---|---|
| `Capture/Events/IdleScheduler.swift` | `task = Task {...}` | line 43 `task?.cancel()` |
| `Capture/Events/InputWatcher.swift` | `typingDebounceTask` / `scrollDebounceTask` | line 55-56 + 66 + 78 |
| `Capture/Events/PasteboardWatcher.swift` | `pollTask = Task {...}` | line 42 |
| `Capture/Screen/DRMWatcher.swift` | `task` | line 45 |
| `Capture/Compaction/CompactionWorker.swift` | `task` | line 64 |
| `Capture/Coordinator/CaptureCoordinator.swift` | `captureTask` / `drmTask` / `sleepWakeTask` | line 135-137 |
| `Capture/Audio/TranscriptionScheduler.swift` | 4 个 Task | line 117-120 全部 cancel |
| `Capture/Audio/AudioCaptureService.swift` | `samplesTask` | line 83 |
| `Capture/Audio/SystemAudioCaptureService.swift` | `samplesTask` | line 146 |

**无发现。**

### c.4 AVCaptureSession

`Capture/` 下 **零命中**。项目音频走 `AVAudioEngine + CATap`，未使用 AVFoundation 的 capture session。

**无发现。**

### c.5 顺便扫到的 observer/monitor 配对

| 文件 | 创建点 | 释放点 |
|---|---|---|
| `Capture/Events/WorkspaceWatcher.swift:22,31` `addObserver` ×2 | line 42-43 `removeObserver` ×2 | 配对 OK |
| `Capture/Events/InputWatcher.swift:41` `NSEvent.addGlobalMonitorForEvents` | line 53 `NSEvent.removeMonitor(m)` | 配对 OK |
| `Capture/Screen/SleepWakeWatcher.swift:30,38,46,54` `addObserver` ×4 | line 67-68 循环 `removeObserver` | 配对 OK |
| `Capture/Screen/FocusProbe.swift:78,88` `addObserver` ×2 | line 102-103 `removeObserver` ×2 | 配对 OK |

**无发现。**

### c 小结

唯一两个值得在下一次清理时补的点：
1. `AudioCaptureService` 加 `deinit { engine.inputNode.removeTap(onBus:0); if engine.isRunning { engine.stop() } }` 兜底。
2. `SystemAudioCaptureService` 加 `deinit` 调 `cleanupCoreAudio()`（注意 actor 的 deinit 是 nonisolated，需要 cleanup 路径不依赖 actor 状态；当前 `cleanupCoreAudio` 用 `AudioHardwareDestroyAggregateDevice` + `AudioHardwareDestroyProcessTap` 是 C API，可直接调）。

两条都只是"兜底"，正常的 `CaptureCoordinator.stop()` 链路已经覆盖。Risk: low-medium / medium-high（前者只是麦克风灯，后者会污染系统 HAL 注册表）。

---

## 总结

- **a 节**：无发现。HomeView 已彻底脱离旧 schema。
- **b 节**：三个 LLM 模块字段名 prompt↔parser 全部对齐，无硬 bug。仅一处 ImpactScorer prompt 给 LLM 看 deprecated 的 `category` 是脏数据，建议清理。
- **c 节**：Timer / DispatchSource / AVCaptureSession / SCStream 均无泄漏点；两个 audio actor 缺 deinit 兜底，建议补上但非紧急。
