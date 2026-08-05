import Foundation
import os

/// 屏幕采集「暂停名单」闸门。焦点落在名单里的 app(名字子串)或 URL(子串)上
/// → 停整条 SCStream(macOS 会主动黑掉受保护内容,不及时停 stream 会导致用户
/// 自己正在看的 Netflix 等播放也黑屏)。
///
/// 与 IgnoreGate 的区别:IgnoreGate 命中只把窗口遮成透明(帧照拍);DRMGate
/// 命中停整条流水线 + invalidate SCStream。
///
/// **名单写死在这里,用户不可改** —— 只有一个总开关
/// `ConfigStore.privacy.pauseForProtectedVideo` 决定这道闸开不开(关掉时
/// Services 推空名单)。由 Services → CaptureCoordinator.setPauseCaptureList
/// 推进来。`final class` + 锁:本实例被 coordinator 与 DRMWatcher 共享,
/// 开关变化要同时对两边生效。匹配全小写化 + substring。
final class DRMGate: @unchecked Sendable {

    /// 固定名单。设置页 ⓘ 浮窗只读展示的也是这两份(单一事实来源)。
    /// 注:不含裸 "Max"(子串会误伤 "max headroom" 之类标题;HBO Max 走
    /// "HBO Max" + url "play.max.com")。
    static let pausedApps: [String] = [
        "Netflix", "Disney+", "Hulu", "Prime Video", "Apple TV",
        "Peacock", "Paramount+", "HBO Max", "Crunchyroll", "DAZN",
        "Horizon Client",
    ]
    static let pausedUrls: [String] = [
        "netflix.com", "disneyplus.com", "hulu.com", "primevideo.com",
        "tv.apple.com", "peacocktv.com", "paramountplus.com",
        "play.max.com", "crunchyroll.com", "dazn.com", "amazon.com/gp/video/",
    ]

    private struct State {
        var apps: [String]
        var urls: [String]
    }
    /// Services 还没推进来之前先按"开"兜底,保证启动早期也有保护。
    private let state = OSAllocatedUnfairLock<State>(
        initialState: State(apps: DRMGate.pausedApps.map { $0.lowercased() },
                            urls: DRMGate.pausedUrls.map { $0.lowercased() }))

    /// Services 在 privacy.pauseForProtectedVideo 变化时推(开=固定名单,关=空)。
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
