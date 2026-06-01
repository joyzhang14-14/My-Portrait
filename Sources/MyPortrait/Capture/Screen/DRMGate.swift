import Foundation
import os

/// 屏幕采集「暂停名单」闸门。焦点落在名单里的 app(名字子串)或 URL(子串)上
/// → 停整条 SCStream(macOS 会主动黑掉受保护内容,不及时停 stream 会导致用户
/// 自己正在看的 Netflix 等播放也黑屏)。
///
/// 与 IgnoreGate 的区别:IgnoreGate 命中只把窗口遮成透明(帧照拍);DRMGate
/// 命中停整条流水线 + invalidate SCStream。
///
/// 名单从 `ConfigStore.privacy.pauseCaptureApps / pauseCaptureUrls` 来(默认预填
/// 主流流媒体,用户可在 Settings 增删),由 Services → CaptureCoordinator
/// .setPauseCaptureList 推进来。`final class` + 锁:本实例被 coordinator 与
/// DRMWatcher 共享,config 变化要同时对两边生效。匹配全小写化 + substring。
final class DRMGate: @unchecked Sendable {

    /// 出厂默认(= ConfigSchema 的默认值,小写)。Services 还没把 config 推进来
    /// 之前先用它兜底,保证启动早期也有保护。注:不含裸 "max"(子串会误伤
    /// "max headroom" 之类标题;HBO Max 走 "hbo max" + url "play.max.com")。
    private static let defaultApps: [String] = [
        "netflix", "disney+", "hulu", "prime video", "apple tv",
        "peacock", "paramount+", "hbo max", "crunchyroll", "dazn",
        "horizon client",
    ]
    private static let defaultUrls: [String] = [
        "netflix.com", "disneyplus.com", "hulu.com", "primevideo.com",
        "tv.apple.com", "peacocktv.com", "paramountplus.com",
        "play.max.com", "crunchyroll.com", "dazn.com", "amazon.com/gp/video/",
    ]

    private struct State {
        var apps: [String]
        var urls: [String]
    }
    private let state = OSAllocatedUnfairLock<State>(
        initialState: State(apps: DRMGate.defaultApps, urls: DRMGate.defaultUrls))

    /// Services 在 ConfigStore.privacy.pauseCaptureApps/Urls 变化时推。
    func setPauseList(apps: [String], urls: [String]) {
        let a = apps.map { $0.lowercased() }.filter { !$0.isEmpty }
        let u = urls.map { $0.lowercased() }.filter { !$0.isEmpty }
        state.withLock { $0 = State(apps: a, urls: u) }
    }

    /// 当前焦点是否在暂停名单内容上。`true` → 停整条采集。
    func isBlocked(_ focus: FocusInfo) -> Bool {
        let snap = state.withLock { $0 }
        let app = focus.appName.lowercased()
        for name in snap.apps where app.contains(name) { return true }
        if let url = focus.browserUrl?.lowercased() {
            for sub in snap.urls where url.contains(sub) { return true }
        }
        return false
    }
}
