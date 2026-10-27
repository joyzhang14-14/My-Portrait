import Foundation

/// Thread-safe snapshot of the few config fields that non-MainActor code
/// needs to read (e.g. `TimelineDB.init` deciding which DB to open).
/// Keep small — anything UI-bound stays inside the @MainActor ConfigStore.
struct ConfigSnapshot: Sendable {
    var dataDirectory: String = ""
    var retentionDays: String = "d30"
    var autoDeleteMode: String = "mediaOnly"
    /// 用户锁定的输入设备 UID(empty = follow system)。AudioCaptureService
    /// 在 actor 外起 AVAudioEngine 时同步读这个,所以放进 snapshot。
    var preferredInputDeviceUID: String = ""
    /// Local Model 卡片的地址 / 模型名。`Provider.localModel` 在任意线程同步读。
    var localModelBaseURL: String = ""
    var localModelName: String = ""
    /// Personal Info 里填了的 first / last / preferred name。Premium 每次请求都带上,
    /// 服务器核对其中有一个等于密钥登记的名字(`PremiumRemote.HTTPTransport`)。
    var personalNames: [String] = []
}
