import Foundation

/// 一次"应该抓帧"的语义事件。EventSources 把多源事件合流后
/// 统一以 `CaptureTrigger` 发给 CaptureCoordinator。
///
/// 名字落进 `frames.capture_trigger` 列，便于事后分析"用户做了什么导致这一帧被存"。
public enum CaptureTrigger: String, Sendable {
    /// 焦点 app 切换。
    case appSwitch = "app_switch"

    /// 焦点窗口标题变（同一 app 内换 tab/document）。
    case windowFocus = "window_focus"

    /// 鼠标点击。
    case click

    /// 用户按下 Return / Enter 的瞬间(发消息 / 换行 / 提交 = 一个动作完成)。
    /// rawValue 仍叫 typing_pause —— DB capture_trigger 列向后兼容,不改字符串。
    case typingPause = "typing_pause"

    /// 滚动停止 N ms。
    case scrollStop = "scroll_stop"

    /// 剪贴板内容变化。
    case clipboard

    /// idle 兜底：超过 30s 没其他 trigger，强制抓一帧。
    case idle

    /// 周期性视觉差检测命中（P2.1 留位，本期未实现）。
    case visualChange = "visual_change"

    /// 手动 (`captureOnce()` 调用)。
    case manual
}
