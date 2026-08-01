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
/// ⚠️ 屏幕那一路要留意语义:`IgnoreGate` 命中是把**该窗口**从帧里抠成透明,
/// 帧本身照拍(桌面/其它窗口仍在)。所以紫灯灭 = "你当前这个 app 没被记录",
/// **不等于**"屏幕采集停了"。tooltip 里如实写清楚,别让用户读成后者。
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
    private var frontmostApp: NSRunningApplication?
    /// 两个信号源都是 Services 持有的实例(不是单例),起来之后 attach 进来。
    /// **没 attach 之前权限当未授** —— 三灯全灭。宁可该亮时灭。
    private weak var permissions: PermissionMonitor?
    private weak var musicMonitor: MusicPlaybackMonitor?

    private init() {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        // 前台 app 一变就重算 —— 这是"切到 1Password 灯就灭"的触发点。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // 不从 notification.userInfo 取 app —— Notification 不是 Sendable,
            // 跨隔离域传会报 data race。队列已是 .main,直接问系统当前前台是谁,
            // 结果一样(通知刚投递时 frontmostApplication 已更新)。
            MainActor.assumeIsolated {
                self?.frontmostApp = NSWorkspace.shared.frontmostApplication
                self?.recompute()
            }
        }
        recompute()
        startPolling()
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
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
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
        let app = frontmostApp
        let appName = app?.localizedName ?? ""
        let bundleId = app?.bundleIdentifier ?? ""

        // ---- 屏幕(紫) ----
        var s = Lamp(on: true, reason: nil)
        if !cfg.capture.screen.enabled {
            s = Lamp(on: false, reason: "screen capture is off")
        } else if !granted(\.screenRecording) {
            s = Lamp(on: false, reason: "no screen-recording permission")
        } else if pause.screenAsleep {
            s = Lamp(on: false, reason: "display is asleep")
        } else if pause.drmActive {
            s = Lamp(on: false, reason: "paused — protected or paused-list content in front")
        } else if let hit = Self.ignoredAppHit(appName: appName, cfg: cfg) {
            s = Lamp(on: false, reason: "\(appName) is in Ignored apps (“\(hit)”) — its window is cut out of the frame")
        }
        if screen != s { screen = s }        // 只在真变了才发通知,见 Lamp 的告警

        // ---- 音频(黄) ----
        var a = Lamp(on: true, reason: nil)
        if !cfg.capture.audio.enabled {
            a = Lamp(on: false, reason: "audio capture is off")
        } else if !granted(\.microphone) {
            a = Lamp(on: false, reason: "no microphone permission")
        } else if musicMonitor?.musicDetected == true {
            a = Lamp(on: false, reason: "paused — an app on your pause list is playing audio")
        }
        if audio != a { audio = a }

        // ---- 打字(蓝) ----
        var t = Lamp(on: true, reason: nil)
        if !cfg.capture.typingCaptureEnabled {
            t = Lamp(on: false, reason: "typing capture is off")
        } else if !granted(\.accessibility) {
            t = Lamp(on: false, reason: "no accessibility permission")
        } else if !bundleId.isEmpty, TypingPrivacyFilter.isBlacklisted(bundleId: bundleId) {
            t = Lamp(on: false, reason: "\(appName) is on the typing blacklist — nothing is read here")
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
        func line(_ dot: String, _ name: String, _ l: Lamp) -> String {
            l.on ? "\(dot) \(name): recording" : "○ \(name): off — \(l.reason ?? "")"
        }
        return [
            line("●", "Screen", screen),
            line("●", "Audio", audio),
            line("●", "Typing", typing),
        ].joined(separator: "\n")
    }
}
