import AppKit
import Combine
import Foundation

/// 菜单栏三盏采集灯的实时状态。
///
/// **这是一盏隐私指示灯,不是装饰** —— 有用户反馈"我不信 ignored app 真的生效"。
/// 所以规则只有一条:**灯亮 ⇔ 此时此刻这一路真的在记当前这个 app**。任何一个
/// 环节被挡住(功能关 / 没权限 / 前台 app 在忽略名单 / 各路自己的暂停)灯就灭。
/// 宁可该亮时灭,绝不该灭时亮。
///
/// 三路的"挡住"机制**各不相同**,不能一套逻辑套三次:
///
/// | 灯 | 功能开关 | 权限 | 前台 app 排除 | 其它暂停 |
/// |----|---------|------|--------------|---------|
/// | 屏幕(紫) | `capture.screen.enabled` | 录屏 | `IgnoreGate`:app 名/标题子串 | `DRMGate`(pausedApps / 受保护视频) |
/// | 音频(黄) | `capture.audio.enabled`  | 麦克风 | —— 音频不认 app | 暂停名单 app 正在出声(`MusicPlaybackMonitor`) |
/// | 打字(蓝) | `capture.typingCaptureEnabled` | 辅助功能 | `TypingPrivacyFilter`:bundle id 黑名单 | —— |
///
/// ⚠️ 屏幕那一路的语义:名单命中的 app **在前台**时整帧不拍(紫灯灭);
/// 它只在后台露一角时帧照拍、那个窗口渲染成黑(紫灯照亮 —— 你当前用的
/// 这个 app 确实在被记)。判据与 `IgnoreGate.shouldSkipFrame` 必须一致,
/// 两边各写一份必然走偏。
@MainActor
final class CaptureLampState: ObservableObject {
    static let shared = CaptureLampState()

    /// 一盏灯:亮 / 灭 + 灭的原因(tooltip 用)。
    ///
    /// ⚠️ **必须 Equatable** —— `@Published` 每次赋值都发 objectWillChange,
    /// 不管值变没变。订阅方(StatusBarMenu)收到又会回头刷新,不做变化检测就是
    /// 一个无条件死循环,主线程 100% CPU、UI 冻死(08-01 真炸过一次)。
    struct Lamp: Equatable {
        var on: Bool
        /// 灭的原因;亮着时为 nil。
        var reason: String?
    }

    @Published private(set) var screen = Lamp(on: false, reason: "off")
    @Published private(set) var audio = Lamp(on: false, reason: "off")
    @Published private(set) var typing = Lamp(on: false, reason: "off")

    /// 三盏灯的组合 → 资源名 `MenuBarLamp-S1-A0-T1`。
    var assetName: String {
        "MenuBarLamp-S\(screen.on ? 1 : 0)-A\(audio.on ? 1 : 0)-T\(typing.on ? 1 : 0)"
    }

    private var cancellables = Set<AnyCancellable>()
    /// 前台 app 的三个标量(名字 / bundle id / pid)。**不存 NSRunningApplication**
    /// —— 它不是 Sendable,跨隔离域传会报 data race;而且只用得到这三样。
    private var frontName = ""
    private var frontBundleId = ""
    private var frontPid: pid_t = 0
    /// 前台浏览器当前标签页的 URL(非浏览器 = nil)。屏幕的 `ignoredUrls` 和打字的
    /// URL 级黑名单都按它判 —— 只看 bundle id 会漏掉"同一个浏览器,这个站屏蔽、
    /// 那个站不屏蔽"的情况。
    ///
    /// ⚠️ 不能读 `FocusProbe.snapshot().browserUrl`:那个缓存只在**切 app** 时刷新,
    /// **换标签页不刷**。从屏蔽站切到普通站时它还停在旧 URL → 灯说没记、实际在记,
    /// 正是最危险的那个方向。所以这里自己做一次窄读(只取 URL,不走 AX 全树)。
    private var browserUrl: String?
    /// 两个信号源都是 Services 持有的实例(不是单例),起来之后 attach 进来。
    /// **没 attach 之前权限当未授** —— 三灯全灭。宁可该亮时灭。
    private weak var permissions: PermissionMonitor?
    private weak var musicMonitor: MusicPlaybackMonitor?

    private init() {
        adoptFrontmost(NSWorkspace.shared.frontmostApplication)
        // 前台 app 一变就重算 —— 这是"切到 1Password 灯就灭"的触发点。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // ⚠️ **必须用通知里带的那个 app**,不能回头查
            // `NSWorkspace.shared.frontmostApplication` —— 通知投递的那一刻
            // 那个系统属性**还没 settle**,查到的常常是上一个 app。症状:切到
            // 微信,灯还停在 Terminal 的状态,得再切第三个 app 才更新,而且
            // 时灵时不灵(08-01 实测)。
            // 先把三个标量取出来再进 MainActor —— Notification / NSRunningApplication
            // 都不是 Sendable,整个传进去编译器会报 data race。
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? ""
            let bid = app?.bundleIdentifier ?? ""
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frontName = name
                self.frontBundleId = bid
                self.frontPid = pid
                self.recompute()
                self.refreshBrowserURL()
            }
        }
        recompute()
        startPolling()
    }

    /// 把 NSRunningApplication 拆成三个标量存下来。
    private func adoptFrontmost(_ app: NSRunningApplication?) {
        frontName = app?.localizedName ?? ""
        frontBundleId = app?.bundleIdentifier ?? ""
        frontPid = app?.processIdentifier ?? 0
    }

    /// 窄读前台浏览器的当前 URL —— **只取 URL**,不做 FocusProbe 那种 AX 全树遍历。
    ///
    /// AX 调用一律走 `AXSerialQueue`(全 app 唯一那条串行队列):AX 的 C API 并发
    /// 调用会让框架内部状态打架,历史上炸出过主线程死锁和后台队列崩溃。
    /// 读完跳回 MainActor,URL 变了才重算。
    private func refreshBrowserURL() {
        let pid = frontPid
        let bid = frontBundleId
        guard pid > 0, FocusProbe.browserBundleIds.contains(bid)
        else {
            if browserUrl != nil { browserUrl = nil; recompute() }
            return
        }
        AXSerialQueue.shared.async { [weak self] in
            let appEl = AXUIElementCreateApplication(pid)
            var winRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
                CFGetTypeID(winRef) == AXUIElementGetTypeID()
            else { return }
            let url = FocusProbe.extractBrowserURL(focusedWindow: winRef as! AXUIElement)
            Task { @MainActor in
                guard let self, self.browserUrl != url else { return }
                self.browserUrl = url
                self.recompute()
            }
        }
    }

    /// 外部信号源接线。Services 起来之后调一次 —— MusicPlaybackMonitor 是
    /// 运行期才有的实例,拿不到就只是少一个刷新触发点,不影响正确性
    /// (recompute 读的是它的当前值)。
    func attach(musicMonitor: MusicPlaybackMonitor?, permissions: PermissionMonitor?) {
        self.musicMonitor = musicMonitor
        self.permissions = permissions
        musicMonitor?.$musicDetected
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.recompute() } }
            .store(in: &cancellables)
        // 订阅三个值发布器,**不是** objectWillChange —— 后者在值改变**之前**触发,
        // 那一刻读到的还是旧权限,灯会慢一拍。
        if let p = permissions {
            Publishers.CombineLatest3(
                p.$screenRecording, p.$microphone, p.$accessibility
            )
            .sink { [weak self] _, _, _ in Task { @MainActor in self?.recompute() } }
            .store(in: &cancellables)
        }
        recompute()
    }

    /// DRM / 睡眠 / 配置改动没有 Combine 出口(都是 CaptureCoordinator 直接写
    /// `IntentionalPauseState` 的普通属性),只能轮询。2s 一次,recompute 本身
    /// 只读内存 + 几个子串比较,可忽略;有变化才发通知。
    ///
    /// ⚠️ **绝不要反过来让 StatusBarMenu 在 refreshIcon 里调 recompute** ——
    /// 它订阅了本类的变化,那样就是自激死循环(08-01 炸过)。
    private func startPolling() {
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // **自愈**:重读一次前台 app。通知那条路万一漏了/读早了,
                    // 这里最多 2s 就纠正回来(此刻系统属性一定已 settle)。
                    self.adoptFrontmost(NSWorkspace.shared.frontmostApplication)
                    self.recompute()
                    // 换标签页不发任何系统通知,只能靠这个 tick 兜 —— 所以浏览器里
                    // 切到/切离屏蔽站,灯最多滞后一个 tick。
                    self.refreshBrowserURL()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 计算

    private func recompute() {
        let cfg = ConfigStore.shared
        let pause = IntentionalPauseState.shared
        // 没 attach 到 PermissionMonitor 时一律当"未授权" → 灯灭。
        func granted(_ kp: KeyPath<PermissionMonitor, PermissionMonitor.Status>) -> Bool {
            permissions?[keyPath: kp].isGranted ?? false
        }
        let appName = frontName
        let bundleId = frontBundleId

        // ---- 屏幕(紫) ----
        var s = Lamp(on: true, reason: nil)
        if !cfg.capture.screen.enabled {
            s = Lamp(on: false, reason: "Screen capture is switched off.")
        } else if !granted(\.screenRecording) {
            s = Lamp(on: false, reason: "No screen-recording permission — nothing can be captured.")
        } else if pause.screenAsleep {
            s = Lamp(on: false, reason: "The display is asleep — nothing to capture.")
        } else if pause.drmActive {
            s = Lamp(on: false, reason: "Paused — protected video is playing on screen.")
        } else if let hit = Self.ignoredAppHit(appName: appName, cfg: cfg) {
            s = Lamp(on: false, reason: "“\(hit)” is on your Ignored apps list — no screenshot is taken while it's in front.")
        } else if let url = browserUrl,
                  let hit = cfg.privacy.ignoredUrls.first(where: {
                      !$0.isEmpty && url.lowercased().contains($0.lowercased())
                  }) {
            // 跟 IgnoreGate.shouldSkipFrame 同口径:前台 app 名 + 当前页面 URL。
            s = Lamp(on: false, reason: "“\(hit)” is on your Ignored URLs list — no screenshot is taken while you're on it.")
        }
        if screen != s { screen = s }        // 只在真变了才发通知,见 Lamp 的告警

        // ---- 音频(黄) ----
        var a = Lamp(on: true, reason: nil)
        if !cfg.capture.audio.enabled {
            a = Lamp(on: false, reason: "Audio capture is switched off.")
        } else if !granted(\.microphone) {
            a = Lamp(on: false, reason: "No microphone permission — nothing can be recorded.")
        } else if musicMonitor?.musicDetected == true {
            a = Lamp(on: false, reason: "Paused — an app on your pause list is playing sound.")
        }
        if audio != a { audio = a }

        // ---- 打字(蓝) ----
        var t = Lamp(on: true, reason: nil)
        if !cfg.capture.typingCaptureEnabled {
            t = Lamp(on: false, reason: "Typing capture is switched off.")
        } else if !granted(\.accessibility) {
            t = Lamp(on: false, reason: "No accessibility permission — keystrokes can't be read.")
        } else if !bundleId.isEmpty,
                  TypingPrivacyFilter.exclusionReason(bundleId: bundleId) != nil {
            // 判据跟 TypingObserver.attach 共用同一个函数,不重写一份。
            // 终端不单独报一句 —— 它本来就在 defaultBlacklist 里(设置页
            // 灰显那截),对用户就是"黑名单里的 app",没必要区分两种说法。
            t = Lamp(on: false, reason: "\(appName) is on your typing blacklist — nothing you type here is saved.")
        } else if !bundleId.isEmpty, let url = browserUrl,
                  TypingPrivacyFilter.isBlacklisted(bundleId: bundleId, url: url) {
            // 打字还有一道 **URL 级**闸(TypingRecordWriter.persist 落库时判)。
            // 只按 bundle id 判会漏掉"这个浏览器里,这个站屏蔽、那个站不屏蔽"。
            t = Lamp(on: false, reason: "This page is on your typing blacklist — nothing you type here is saved.")
        }
        if typing != t { typing = t }
    }

    /// 前台 app 名是否命中 ignoredApps —— 跟 `IgnoreGate` 同口径:**小写子串**匹配。
    /// 返回命中的那条名单项(给 tooltip 说明"因为哪条规则灭的")。
    private static func ignoredAppHit(appName: String, cfg: ConfigStore) -> String? {
        guard !appName.isEmpty else { return nil }
        let lower = appName.lowercased()
        return cfg.privacy.ignoredApps.first { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    /// 三行说明,菜单栏 tooltip 用。
    var tooltip: String {
        // reason 现在本身就是完整句子(带大写开头 + 句号),不再往前面
        // 拼 "off —",否则读出来是 "off — Screen capture is switched off."
        func line(_ dot: String, _ name: String, _ l: Lamp) -> String {
            l.on ? "\(dot) \(name): recording this app"
                 : "○ \(name): \(l.reason ?? "off")"
        }
        return [
            line("●", "Screen", screen),
            line("●", "Audio", audio),
            line("●", "Typing", typing),
        ].joined(separator: "\n")
    }
}
