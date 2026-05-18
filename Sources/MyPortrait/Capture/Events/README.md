# Events/ — 事件驱动调度（P2）

待实现：把"定时 1fps 截图"升级为事件驱动 —— 焦点切换、键盘停顿、
鼠标点击、滚动停止、剪贴板变化、视觉差检测、idle 兜底。

## 待新增文件

- `EventSources.swift` — 统一注册多个事件源，输出统一 `CaptureTrigger`
- `WorkspaceWatcher.swift` — `NSWorkspace.didActivateApplicationNotification`
- `KeyboardWatcher.swift` — `CGEventTap`，500ms 打字停顿后触发
- `MouseWatcher.swift` — 点击 + 滚动停止 300ms
- `PasteboardWatcher.swift` — `NSPasteboard.changeCount` 轮询
- `VisualChangeWatcher.swift` — 3 秒一次背景 Hellinger 检测

## 阈值（抄 My-Orphies）

| 参数 | 值 |
|---|---|
| 事件轮询 | 50ms |
| 最小帧间隔（防抖） | 200ms |
| idle 兜底 | 30s |
| 打字停顿延迟 | 500ms |
| 滚动停顿延迟 | 300ms |
| 视觉差检测周期 | 3s |
| 视觉差触发阈值 | 0.05 |
