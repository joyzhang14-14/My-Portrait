import AppKit
import Foundation
import Sparkle

/// Sparkle 自动更新封装。
///
/// Sparkle 自己内部已经是个完整的 controller + delegate 体系,我们这里只做两件事:
///   1. 持有 SPUStandardUpdaterController 让它活着(否则 controller 销毁自动检查就停)
///   2. 把 ConfigStore.general.autoDownloadUpdates 接到 SPUUpdater 上
///      (→ updater.automaticallyDownloadsUpdates)。检查间隔写死
///      checkIntervalMinutes(10min),不再可配。
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

    /// 检查间隔(分钟)—— 写死,不再可配(原 General → Update check interval
    /// 字段已下线)。
    static let checkIntervalMinutes = 10

    /// 自己跑的 check timer。Sparkle 内部 scheduler 在 Release build 强制
    /// 最小检查间隔 1h(SPUUpdaterSettings.minimumUpdateCheckInterval 写死),
    /// 实际还是 1h 才 check。**我们关掉 Sparkle 自动 scheduler,自己驱动
    /// checkForUpdatesInBackground()**(developer-facing API 不被 minimum 拦),
    /// 按 checkIntervalMinutes 跑。
    private var checkTimer: Timer?

    private override init() {
        // startingUpdater: true → Sparkle 在 controller 构造时就开始它的
        // 周期检查;我们不需要再手动 start。
        // updaterDelegate=bannerDelegate 让 Sparkle 发现新版本时
        // (didFindValidUpdate)弹一条 in-app banner —— Sparkle 自带对话框
        // 照常弹,banner 是额外醒目入口。
        // userDriverDelegate=nil 因为 SPUStandardUserDriverDelegate 的
        // gentle reminder 路径在 automaticallyDownloadsUpdates=true 时不被
        // 触发,改用 SPUUpdaterDelegate.willInstallUpdateOnQuit(见
        // UpdateBannerDelegate 注释)。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bannerDelegate,
            userDriverDelegate: nil
        )
        super.init()

        // 把现有 config 接上。delegate 设置后调一次同步当前值,然后监听
        // config 变化(不会高频,只在用户改 toggle / TextField 时)。
        applyConfig()
        observeConfig()
    }

    /// 上次应用过的 autoDownloadUpdates 值。@Observable 追踪粒度是整个 `current`,
    /// 任意 config 变更都会触发 onChange —— 必须 diff 真值,只在它真变了才
    /// applyConfig(否则随便改个别的设置都会重建 timer + 立即触发一次检查)。
    private var observedAutoDownload: Bool = false

    /// 常驻监听 autoDownloadUpdates。之前重应用职责挂在
    /// GeneralSettingsView 的 onChange 上 —— 页面不在屏幕上就没人监听,
    /// vim 改 TOML(ConfigStore 热加载)后 SPUUpdater 和 checkTimer 仍按旧值
    /// 跑到下次重启。其它模块(ConfigApplier / Services)都用常驻
    /// withObservationTracking,updater 对齐。
    private func observeConfig() {
        observedAutoDownload = ConfigStore.shared.current.general.autoDownloadUpdates
        withObservationTracking {
            _ = ConfigStore.shared.current.general.autoDownloadUpdates
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if ConfigStore.shared.current.general.autoDownloadUpdates != self.observedAutoDownload {
                    self.applyConfig()
                }
                self.observeConfig()   // withObservationTracking 一次性,重订阅
            }
        }
    }

    /// 用户点菜单 / 设置里的 "Check Now" 按钮调这个 —— 永远走 Sparkle
    /// 原生 modal,**不受 autoDownloadUpdates toggle 影响**:用户主动点
    /// "Check now" 时想要的就是"有没有新版给我看一下",modal 给"是/否
    /// + 立刻装"的明确反馈。
    ///
    /// 之前版本 toggle on 时走 checkForUpdatesInBackground() 是错的 ——
    /// 那条 silent path 没 UI 反馈,用户点了感觉按钮"没反应"。
    /// 自动 timer 路径仍走 silent(用 applyConfig 里那条 Timer 调
    /// checkForUpdatesInBackground)。手动 ≠ 自动。
    func checkForUpdates() {
        // Sparkle 在已有更新会话进行时(canCheckForUpdates=false)会**直接吞掉**
        // checkForUpdates(nil) → 用户点 "Check now" 毫无反应。最常见:后台已发现
        // 新版、正在下载 / 等重启安装,会话还挂着。这时不静默 no-op,给个明确提示
        // 告诉用户更新已在处理 + 怎么装。
        guard controller.updater.canCheckForUpdates else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "An update is already in progress"
            alert.informativeText = "My Portrait already found a newer version and is downloading or preparing it. Quit and reopen to finish installing."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    /// 把 ConfigStore.general 里的两个字段同步到 SPUUpdater + 我们自己的
    /// checkTimer。在 init 时调一次,之后由 SettingsView 的 onChange 触发
    /// 再调一次。
    func applyConfig() {
        let g = ConfigStore.shared.current.general
        let u = controller.updater
        // **automaticallyChecksForUpdates = false** 让 Sparkle 不再自己跑
        // scheduler(那个 scheduler 被 hardcoded 1h minimum 卡死),我们用
        // 自己的 checkTimer 驱动 checkForUpdatesInBackground()。
        u.automaticallyChecksForUpdates = false
        u.automaticallyDownloadsUpdates = g.autoDownloadUpdates

        // 检查间隔写死 10 分钟(原来可配,UI 已下线)。
        checkTimer?.invalidate()
        let interval = TimeInterval(Self.checkIntervalMinutes * 60)
        // **fires=true** 立刻先 check 一次,然后每 interval 再 check
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.controller.updater.checkForUpdatesInBackground()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
        // 立刻先调一次,不用等第一个 interval 过去
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Sparkle delegate —— 实现 SPUUpdaterDelegate。
///
/// 单独对象原因:这两个 delegate 必须在 SPUStandardUpdaterController init
/// 时传进去,init 里没法引用 self(super.init 还没跑)。
/// UpdaterService 自己 strong-hold 它(Sparkle weak-refs delegate)。
///
/// 两件事:
///   1. \`didFindValidUpdate\`:Sparkle 找到新版本 → post 一条 "new version
///      available" banner(\`.appUpdate\` kind,被 notifications.appUpdates
///      toggle 控制)
///   2. \`willInstallUpdateOnQuit\`:autoDownloadUpdates toggle on + Sparkle
///      已经**下载 + 解压完新版**,**这才是真正的"download complete"
///      callback**。我们 return YES 接管 install,post 倒计时 banner
///      "Updating in 10s, click to postpone"。10s 跑完没操作 → 调
///      immediateInstallHandler(),Sparkle 立刻装新版 + relaunch app,
///      **不等用户 ⌘Q**。
///
/// 之前用过 SPUStandardUserDriverDelegate 的两个 gentle reminder 方法
/// (shouldHandleShowingScheduledUpdate / willHandleShowingUpdate)实际
/// 完全不被 \`automaticallyDownloadsUpdates=true\` 的 silent install-on-quit
/// 路径调用 —— Sparkle 在那条路径上根本不"展示"update,而是默默等 quit。
/// 必须用 SPUUpdaterDelegate 的 willInstallUpdateOnQuit。
private final class UpdateBannerDelegate: NSObject, SPUUpdaterDelegate {

    // MARK: SPUUpdaterDelegate

    /// 这些 delegate 方法 Sparkle 在 main thread 调,但 Swift 6 strict
    /// concurrency 要求 nonisolated。MainActor.assumeIsolated 同步切回。
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            NotificationCenterService.shared.post(.appUpdate(version: version))
        }
    }

    /// Sparkle 下载 + 解压完新版,准备等 quit 装。我们返回 YES 接管:
    ///   - 保存 immediateInstallHandler block
    ///   - post 10s 倒计时 banner
    ///   - 倒计时到点 → 调 handler 装 + relaunch(完全无 UI)
    ///   - 用户点 banner postpone → 不调 handler,Sparkle 还是会在用户
    ///     ⌘Q 时装(行为退化到 install-on-quit)
    ///
    /// autoDownloadUpdates toggle off 时返回 NO 让 Sparkle 走标准 modal 流程。
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let autoOn = MainActor.assumeIsolated {
            ConfigStore.shared.current.general.autoDownloadUpdates
        }
        guard autoOn else { return false }   // toggle off → 让 Sparkle 走 modal

        // Sparkle 这个 @escaping closure 不是 @Sendable,Swift 6 strict
        // concurrency 不让直接进 @MainActor Task。包一层 unchecked Sendable
        // box 显式声明"我保证 Sparkle 这条 main thread 安全"(实际上 Sparkle
        // 内部就在 main thread 调,且我们也在 main thread 调它)。
        struct HandlerBox: @unchecked Sendable { let h: () -> Void }
        let box = HandlerBox(h: immediateInstallHandler)

        let version = item.displayVersionString
        Task { @MainActor in
            NotificationCenterService.shared.post(.updateCountdown(
                version: version,
                seconds: 10,
                onPostpone: {
                    // 用户点 banner → 不调 install handler。Sparkle 后退
                    // 到 install-on-quit 默认行为(等用户自己 ⌘Q 再装)。
                },
                onTimeout: {
                    // 10s 跑完没操作 → 调 immediateInstallHandler 立刻
                    // 静默装 + relaunch。整条路径完全无 UI。
                    box.h()
                }
            ))
        }
        return true
    }
}
