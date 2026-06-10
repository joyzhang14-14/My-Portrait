import Foundation

/// Thread-safe snapshot of the few config fields that non-MainActor code
/// needs to read (e.g. `TimelineDB.init` deciding which DB to open).
/// Keep small — anything UI-bound stays inside the @MainActor ConfigStore.
struct ConfigSnapshot: Sendable {
    var dataDirectory: String = ""
    var retentionDays: String = "d30"
    var autoDeleteMode: String = "mediaOnly"
    /// 自动删除时未转录音频先留着(RetentionWorker 在后台 actor 读)。
    var waitForTranscription: Bool = true
    /// 转录引擎(whisper/qwen/deepgram/custom/disabled)。RetentionWorker 用来
    /// 判断「等转录」是否有意义 —— disabled = 没有可等的,到期照删,否则
    /// 引擎长期关闭时保留期对音频永久失效,磁盘无限涨。
    var audioEngine: String = "whisper"
    /// 用户锁定的输入设备 UID(empty = follow system)。AudioCaptureService
    /// 在 actor 外起 AVAudioEngine 时同步读这个,所以放进 snapshot。
    var preferredInputDeviceUID: String = ""
}
