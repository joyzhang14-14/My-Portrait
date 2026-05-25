import Foundation
import Sparkle

/// Sparkle 自动更新封装。
///
/// Sparkle 自己内部已经是个完整的 controller + delegate 体系,我们这里只做两件事:
///   1. 持有 SPUStandardUpdaterController 让它活着(否则 controller 销毁自动检查就停)
///   2. 把 ConfigStore.general 里的两个用户设置接到 SPUUpdater 上:
///        - autoDownloadUpdates → updater.automaticallyDownloadsUpdates
///        - updateCheckMinutes  → updater.updateCheckInterval(秒)
///
/// 启动检查 + 后台轮询都由 Sparkle 自己跑(automaticallyChecksForUpdates=true)。
/// 用户点 "Check for Updates" 菜单 → updater.checkForUpdates()。
///
/// appcast 公开 URL 写死在 Info.plist `SUFeedURL`(GitHub Pages),公钥
/// `SUPublicEDKey` 同。运行时不需要从 config 读。
@MainActor
final class UpdaterService: NSObject, SPUUpdaterDelegate {

    static let shared = UpdaterService()

    /// 持久持有 —— controller 一释放就不再后台检查了。
    let controller: SPUStandardUpdaterController

    private override init() {
        // startingUpdater: true → Sparkle 在 controller 构造时就开始它的
        // 周期检查;我们不需要再手动 start。delegate=self 让我们能 hook
        // 比如「更新前/后做点事」(目前没用)。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        // 把现有 config 接上。delegate 设置后调一次同步当前值,然后监听
        // config 变化(不会高频,只在用户改 toggle / TextField 时)。
        applyConfig()
    }

    /// 用户点菜单 / 设置里的 "Check Now" 按钮调这个。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 把 ConfigStore.general 里的两个字段同步到 SPUUpdater。
    /// 在 init 时调一次,之后由 SettingsView 的 onChange 触发再调一次。
    func applyConfig() {
        let g = ConfigStore.shared.current.general
        let u = controller.updater
        u.automaticallyChecksForUpdates = true
        u.automaticallyDownloadsUpdates = g.autoDownloadUpdates
        // ConfigStore 限制 1...1440 分钟,这里 max 当 1440 兜底。
        let clamped = max(1, min(1440, g.updateCheckMinutes))
        u.updateCheckInterval = TimeInterval(clamped * 60)
    }
}
