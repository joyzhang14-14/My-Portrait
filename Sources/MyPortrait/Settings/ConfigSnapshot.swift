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
    /// 用户锁定的输入设备 UID(empty = follow system)。AudioCaptureService
    /// 在 actor 外起 AVAudioEngine 时同步读这个,所以放进 snapshot。
    var preferredInputDeviceUID: String = ""
}
