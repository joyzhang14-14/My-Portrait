import AppKit
import Combine
import Foundation

/// 菜单栏三盏采集灯的实时状态。
///
/// 规则:**灯亮 ⇔ 此时此刻这一路真的在记当前这个 app**。任何一个
/// 环节被挡住(功能关 / 没权限 / 前台 app 在忽略名单 / 各路自己的暂停)灯就灭。
/// 宁可该亮时灭,绝不该灭时亮。
///
/// 三路的"挡住"机制**各不相同**,不能一套逻辑套三次:
///
/// | 灯 | 功能开关 | 权限 | 前台 app 排除 | 其它暂停 |
/// |----|---------|------|--------------|---------|
/// | 屏幕(紫) | `capture.screen.enabled` | 录屏 | `IgnoreGate.shouldMaskWindow`(和抓帧同一个函数) | `DRMGate`(pausedApps / 受保护视频) |
/// | 音频(黄) | `capture.audio.enabled`  | 麦克风 | —— 音频不认 app | 暂停名单 app 正在出声(`MusicPlaybackMonitor`) |
/// | 打字(蓝) | `capture.typingCaptureEnabled` | 辅助功能 | `TypingPrivacyFilter`:bundle id / URL 黑名单 | —— |
///
/// 「当前这个 app」和采集同一口径:Spotlight、Bob 这类面板拿着键盘焦点时是面板的 app,否则是前台 app。
///
/// ⚠️ 屏幕那一路要留意语义:`IgnoreGate` 命中是把**该窗口**从帧里抠掉,
/// 帧本身照拍(桌面/其它窗口仍在,时间轴不断)。所以紫灯灭 = "你当前这个
/// app 没被记录",**不等于**"屏幕采集停了"。文案里如实写清楚,别让用户
/// 读成后者。
@MainActor
final class CaptureLampState: ObservableObject {
    static let shared = CaptureLampState()

    /// 一盏灯:亮 / 灭 + 灭的原因(tooltip 用)。
    ///
    /// ⚠️ **必须 Equatable** —— `@Published` 每次赋值都发 objectWillChange,
    /// 不管值变没变。订阅方(StatusBarMenu)收到又会回头刷新,不做变化检测会
    /// 无条件死循环,主线程 100% CPU、UI 冻死。
    struct Lamp: Equatable {
        var on: Bool
        /// 灭的原因;亮着时为 nil。
        var reason: String?
    }

    @Published private(set) var screen = Lamp(on: false, reason: "off")
    @Published private(set) var audio = Lamp(on: false, reason: "off")
    @Published private(set) var typing = Lamp(on: false, reason: "off")
    /// 全局采集总开关(capture.screen.enabled)关着(= 暂停)—— 整个图标变红。
    @Published private(set) var masterOff = false

    /// 三盏灯的组合 → 资源名 `MenuBarLamp-S1-A0-T1`;总开关关掉 → `MenuBarLamp-Off`
    /// (三个环全红)。
    var assetName: String {
        masterOff ? "MenuBarLamp-Off"
                  : "MenuBarLamp-S\(screen.on ? 1 : 0)-A\(audio.on ? 1 : 0)-T\(typing.on ? 1 : 0)"
    }

    private var cancellables = Set<AnyCancellable>()
    /// 前台 app 的三个标量(名字 / bundle id / pid)。**不存 NSRunningApplication**
    /// —— 它不是 Sendable,跨隔离域传会报 data race;而且只用得到这三样。
    private var frontName = ""
    private var frontBundleId = ""
    private var frontPid: pid_t = 0
    /// 当前 app 焦点窗口的标题。屏幕灯拿它和 app 名一起问 IgnoreGate,跟抓帧逐窗口判同一口径。
    private var windowTitle: String?
    /// 前台浏览器当前标签页的 URL(非浏览器 = nil)。打字的 URL 级黑名单按它判 ——
    /// 只看 bundle id 会漏掉"同一个浏览器,这个站屏蔽、那个站不屏蔽"的情况。
    /// 击键写入也读这一份(`typingURLBlocked`),灯和采集不会各说各的。
    ///
    /// 标题和 URL 都是自己做的窄读(不走 AX 全树):切 app、2s tick、FocusProbe 的
    /// 标题变化回调(换标签页 / 跳页)都会刷。
    private var browserUrl: String?
    /// 信号源都是 Services 持有的实例(不是单例),起来之后 attach 进来。
    /// **没 attach 之前权限当未授** —— 三灯全灭。宁可该亮时灭。
    private weak var permissions: PermissionMonitor?
    private weak var musicMonitor: MusicPlaybackMonitor?
    private var ignoreGate: IgnoreGate?

    private init() {
        adoptFrontmost(NSWorkspace.shared.frontmostApplication)
        // 前台 app 一变就重算。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // ⚠️ **必须用通知里带的那个 app**,不能回头查
            // `NSWorkspace.shared.frontmostApplication` —— 通知投递的那一刻
            // 那个系统属性**还没 settle**,查到的常常是上一个 app。
            // 先把三个标量取出来再进 MainActor —— Notification / NSRunningApplication
            // 都不是 Sendable,整个传进去编译器会报 data race。
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.cleanName ?? ""
            let bid = app?.bundleIdentifier ?? ""
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if let panel = FocusProbe.focusedPanelApp() {
                    self.adoptFrontmost(panel)
                } else {
                    self.frontName = name
                    self.frontBundleId = bid
                    self.frontPid = pid
                }
                self.recompute()
                self.refreshFocusedWindow()
            }
        }
        recompute()
        startPolling()
    }

    /// 把 NSRunningApplication 拆成三个标量存下来。
    private func adoptFrontmost(_ app: NSRunningApplication?) {
        frontName = app?.cleanName ?? ""
        frontBundleId = app?.bundleIdentifier ?? ""
        frontPid = app?.processIdentifier ?? 0
    }

    /// 窄读当前 app 焦点窗口的标题和(浏览器的)URL,不做 FocusProbe 那种 AX 全树遍历。
    ///
    /// AX 调用一律走 `AXSerialQueue`(全 app 唯一那条串行队列):AX 的 C API 并发
    /// 调用会让框架内部状态打架,历史上炸出过主线程死锁和后台队列崩溃。
    /// 读完跳回 MainActor,变了才重算。
    func refreshFocusedWindow() {
        let pid = frontPid
        let isBrowser = FocusProbe.browserBundleIds.contains(frontBundleId)
        guard pid > 0 else {
            if windowTitle != nil || browserUrl != nil { windowTitle = nil; browserUrl = nil; recompute() }
            return
        }
        AXSerialQueue.shared.async { [weak self] in
            let appEl = AXUIElementCreateApplication(pid)
            var winRef: CFTypeRef?
            var title: String?
            var url: String?
            if AXUIElementCopyAttributeValue(
                appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               CFGetTypeID(winRef) == AXUIElementGetTypeID() {
                let win = winRef as! AXUIElement
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success {
                    title = titleRef as? String
                }
                if isBrowser { url = FocusProbe.extractBrowserURL(focusedWindow: win) }
            }
            Task { @MainActor in
                guard let self, self.frontPid == pid,
                      self.windowTitle != title || self.browserUrl != url else { return }
                self.windowTitle = title
                self.browserUrl = url
                self.recompute()
            }
        }
    }

    /// 当前浏览器页面是否在打字 URL 黑名单里。KeystrokeCharLogger 写每颗键前问它,和打字灯同一份 URL。
    func typingURLBlocked(bundleId: String) -> Bool {
        guard bundleId == frontBundleId, let url = browserUrl else { return false }
        return TypingPrivacyFilter.isBlacklisted(bundleId: bundleId, url: url)
    }

    /// 外部信号源接线。Services 起来之后调一次;MusicPlaybackMonitor 拿不到
    /// 只是少一个刷新触发点,不影响正确性(recompute 读的是它的当前值)。
    func attach(musicMonitor: MusicPlaybackMonitor?, permissions: PermissionMonitor?, ignoreGate: IgnoreGate) {
        self.musicMonitor = musicMonitor
        self.permissions = permissions
        self.ignoreGate = ignoreGate
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
    /// 它订阅了本类的变化,那样会自激死循环。
    private func startPolling() {
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // **自愈**:重读一次前台 app。通知那条路万一漏了/读早了,
                    // 这里最多 2s 就纠正回来(此刻系统属性一定已 settle)。
                    self.adoptFrontmost(FocusProbe.focusedPanelApp() ?? NSWorkspace.shared.frontmostApplication)
                    self.recompute()
                    // 标题变化回调只在屏幕采集跑着时挂着,这个 tick 兜底,最多滞后一个 tick。
                    self.refreshFocusedWindow()
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
        // capture.screen.enabled 是**全局采集总开关**:关了三路全停。
        let master = cfg.capture.screen.enabled
        if masterOff != !master { masterOff = !master }

        // ---- 屏幕(紫) ----
        var s = Lamp(on: true, reason: nil)
        if !master {
            s = Lamp(on: false, reason: "Switched off by the All Capture switch.")
        } else if !granted(\.screenRecording) {
            s = Lamp(on: false, reason: "No screen-recording permission — nothing can be captured.")
        } else if pause.screenAsleep {
            s = Lamp(on: false, reason: "The display is asleep — nothing to capture.")
        } else if pause.drmActive {
            s = Lamp(on: false, reason: "Paused — protected video is playing on screen.")
        } else if !appName.isEmpty,
                  ignoreGate?.shouldMaskWindow(appName: appName, bundleId: bundleId.isEmpty ? nil : bundleId,
                                               title: windowTitle) == true {
            // 抓帧逐窗口问的就是这个函数(app 名 / 标题 / 类别 / 遮罩总开关),灯不另写一份。
            s = Lamp(on: false, reason: "This window matches your Ignored apps, URLs or categories — the screenshot is still taken, but this window is blanked out of it.")
        }
        if screen != s { screen = s }        // 只在真变了才发通知

        // ---- 音频(黄) ----
        var a = Lamp(on: true, reason: nil)
        if !master {
            a = Lamp(on: false, reason: "Switched off by the All Capture switch.")
        } else if !cfg.capture.audio.enabled {
            a = Lamp(on: false, reason: "Audio capture is switched off.")
        } else if !granted(\.microphone) {
            a = Lamp(on: false, reason: "No microphone permission — nothing can be recorded.")
        } else if musicMonitor?.musicDetected == true {
            a = Lamp(on: false, reason: "Paused — an app on your pause list is playing sound.")
        }
        if audio != a { audio = a }

        // ---- 打字(蓝) ----
        var t = Lamp(on: true, reason: nil)
        if !master {
            t = Lamp(on: false, reason: "Switched off by the All Capture switch.")
        } else if !cfg.capture.typingCaptureEnabled {
            t = Lamp(on: false, reason: "Typing capture is switched off.")
        } else if !granted(\.accessibility) {
            t = Lamp(on: false, reason: "No accessibility permission — keystrokes can't be read.")
        } else if !bundleId.isEmpty,
                  TypingPrivacyFilter.exclusionReason(bundleId: bundleId) == .blacklisted {
            // 判据跟 TypingObserver.attach 共用同一个函数,不重写一份。
            // 终端只是不读 AX,击键照记,灯照亮。
            t = Lamp(on: false, reason: "\(appName) is on your typing blacklist — nothing you type here is saved.")
        } else if !bundleId.isEmpty, typingURLBlocked(bundleId: bundleId) {
            // URL 级闸:KeystrokeCharLogger 写键时问同一个函数。
            // 只按 bundle id 判会漏掉"这个浏览器里,这个站屏蔽、那个站不屏蔽"。
            t = Lamp(on: false, reason: "This page is on your typing blacklist — nothing you type here is saved.")
        }
        if typing != t { typing = t }
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
