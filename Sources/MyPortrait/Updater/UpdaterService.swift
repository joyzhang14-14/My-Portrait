import AppKit
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
final class UpdaterService: NSObject {

    static let shared = UpdaterService()

    /// 持久持有 —— controller 一释放就不再后台检查了。
    let controller: SPUStandardUpdaterController

    /// Sparkle delegate(必须 strong 持有 —— Sparkle weak-ref delegate)。
    private let bannerDelegate = UpdateBannerDelegate()

    private override init() {
        // startingUpdater: true → Sparkle 在 controller 构造时就开始它的
        // 周期检查;我们不需要再手动 start。
        // updaterDelegate=bannerDelegate 让 Sparkle 发现新版本时
        // (didFindValidUpdate)弹一条 in-app banner —— Sparkle 自带对话框
        // 照常弹,banner 是额外醒目入口。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bannerDelegate,
            userDriverDelegate: bannerDelegate   // 同一个对象,两套 delegate
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

/// Sparkle delegate —— 同时实现 SPUUpdaterDelegate(发现新版本回调)和
/// SPUStandardUserDriverDelegate(替 Sparkle 决定 UI 怎么呈现 update)。
///
/// 拆成独立小对象是因为这两个 delegate 都必须在 SPUStandardUpdaterController
/// init 时传进去,init 里没法引用 self(super.init 还没跑)。
/// UpdaterService 自己 strong-hold 它(Sparkle weak-refs delegate)。
///
/// 两件事:
///   1. Sparkle 发现新版本 → post 一条 in-app "new version available" banner
///      (走 .appUpdate kind,被 notifications.appUpdates toggle 控制)
///   2. **autoDownloadUpdates toggle 开 + Sparkle 已经后台下完新版** →
///      不让 Sparkle 弹标准 modal,改 post 倒计时 banner "Updating in 10s,
///      click to postpone"。倒计时跑完 NSApp.terminate(),Sparkle 的
///      install-on-quit 接管 → 装新版 → 重启 app。toggle 关时走 Sparkle
///      原生 modal 流程不动。
private final class UpdateBannerDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    // MARK: SPUUpdaterDelegate

    /// 这些 delegate 方法 Sparkle 在 main thread 调,所以全部标 nonisolated
    /// + 内部 Task { @MainActor } 跳进 MainActor 读 ConfigStore / post 通知。
    /// 不标 nonisolated 的话 Swift 6 strict concurrency 报"conformance crosses
    /// into main actor-isolated code"。
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            NotificationCenterService.shared.post(.appUpdate(version: version))
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// 告诉 Sparkle 我们支持"温和提醒"(scheduled update 用 delegate 自己
    /// 的 UI 而不是 Sparkle 的 modal)。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle 准备好要让用户看到 scheduled update 时问的:
    ///   - true(default)  → Sparkle 弹自己的 modal
    ///   - false           → delegate 自己处理 UI
    /// autoDownloadUpdates toggle on 时返回 false —— 我们用 banner 倒计时。
    ///
    /// Sparkle 调这条在 main thread,MainActor.assumeIsolated 同步读 config。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            !ConfigStore.shared.current.general.autoDownloadUpdates
        }
    }

    /// Sparkle 已经决定要把 update 呈现给用户时调。`handleShowingUpdate`
    /// false 表示 delegate 接管 UI(对应上面那条返回 false 的分支)。
    /// state.userInitiated true 表示用户手动 Check now 触发的,这种**不要**
    /// 走静默路径,他想看 modal 看到。
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        guard !state.userInitiated else { return }

        let version = update.displayVersionString
        Task { @MainActor in
            NotificationCenterService.shared.post(.updateCountdown(
                version: version,
                seconds: 10,
                onPostpone: {
                    // 用户点了 banner → 取消这次自动 install。Sparkle 下个
                    // 检查周期(默认 60min)如果新版还在,会再次触发整个
                    // 流程。不主动 cancel Sparkle 的下载产物,留着下次复用。
                },
                onTimeout: {
                    // 倒计时跑完用户没操作 → NSApp.terminate 退出。Sparkle
                    // 因为 automaticallyDownloadsUpdates=true 且已经下完新版,
                    // 退出时它的 installer 自动接管:装新版 → relaunch。
                    NSApp.terminate(nil)
                }
            ))
        }
    }
}
