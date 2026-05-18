# Power/ — 电源感知调度（P4）

待实现：监听 AC/电池切换，控制 WhisperKit 转录何时跑。

设计来源：design doc 第二节"延迟转录策略"。
**关键决策**：电池模式只录音 + VAD（< 3% CPU），不调用 Whisper。
AC 接通才批量转录待处理段。

## 待新增文件

- `PowerMonitor.swift` — IOKit `IOPSNotificationCreateRunLoopSource`
  暴露 `AsyncStream<PowerState>` 给上游
- `PowerAwareScheduler.swift` — 监听 PowerMonitor，AC 接通时拉
  `db.pendingAudioChunks` 入工作池；电池断开时停（当前段跑完即止）

## 状态

```swift
enum PowerState {
    case ac          // 接通电源 → 可跑 Whisper / Compaction
    case battery     // 电池 → 暂停 Whisper / 跳过 Compaction
}
```

## 中断恢复

最坏只丢失"当前正在转录的一段"（< 90 秒）。
段的状态以 DB `audio_chunks.status` 为准（pending/in_progress/done/failed）。
重启后扫 in_progress 视为崩溃 → 改回 pending 重跑。
