import Combine
import Foundation
import SwiftUI

/// 采集层用户开关 — SwiftUI Settings UI 与后端 Services 之间的桥。
///
/// **三个 capture 开关 (screen / audio / systemAudio) 的单一真相在 ConfigStore
/// (~/.myportrait/config.toml)**，本类是它的镜像 + Combine 适配层。原因：
///   - Settings UI (RecordingView) 直接绑定 `ConfigStore.recording.xxx.enabled`
///   - Services 用 Combine sink 订阅 @Published，要桥到 Observation 框架
///   - vim 改 TOML 也要 live reload（ConfigStore 已经实现 DispatchSource 监听）
///
/// 双向同步：
///   - UI / TOML / 状态栏 → ConfigStore.mutate → withObservationTracking 触发
///     → applyFromConfig → @Published → Services sink
///   - 程序化 settings.xxx = true → didSet → ConfigStore.mutate → 走上面这一路
///
/// `ignoredAppNames` / `ignoredUrlPatterns` / `pauseUntil` 仍走 UserDefaults
/// （它们暂时不在 TOML schema 里；可以以后单独迁移）。
@MainActor
final class CaptureSettings: ObservableObject {

    // MARK: - 用户可改字段

    /// 屏幕采集总开关。镜像 `ConfigStore.shared.recording.screen.enabled`。
    @Published var screenCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.recording.screen.enabled, screenCaptureEnabled) }
    }

    /// 麦克风采集总开关。镜像 `ConfigStore.shared.recording.audio.enabled`。
    @Published var audioCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.recording.audio.enabled, audioCaptureEnabled) }
    }

    /// 系统音频采集开关。镜像 `ConfigStore.shared.recording.audio.captureSystemAudio`。
    @Published var systemAudioCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.recording.audio.captureSystemAudio, systemAudioCaptureEnabled) }
    }

    /// 屏蔽 app 名单（不区分大小写整名匹配）。对应 `SettingsKeys.ignoredApps`。
    @Published var ignoredAppNames: Set<String> {
        didSet {
            guard !isLoading, !isReloadingFromDefaults else { return }
            UserDefaults.standard.set(Array(ignoredAppNames), forKey: SettingsKeys.ignoredApps)
        }
    }

    /// 屏蔽 URL pattern 列表（glob，NSPredicate LIKE[c]）。对应 `SettingsKeys.ignoredURLs`。
    @Published var ignoredUrlPatterns: [String] {
        didSet {
            guard !isLoading, !isReloadingFromDefaults else { return }
            UserDefaults.standard.set(ignoredUrlPatterns, forKey: SettingsKeys.ignoredURLs)
        }
    }

    // MARK: - 运行时状态（不在 SettingsKeys，仍走自家 key）

    /// "暂停到何时"。非 nil 且未过期 → 屏幕/音频采集都暂停。到期后 Task 自动清回 nil。
    /// 运行时状态，不属于"用户偏好"，UI 走状态栏菜单设置。
    @Published var pauseUntil: Date? {
        didSet {
            guard !isLoading else { return }
            let defaults = UserDefaults.standard
            if let d = pauseUntil {
                defaults.set(d, forKey: PrivateKeys.pauseUntil)
                scheduleAutoResume(at: d)
            } else {
                defaults.removeObject(forKey: PrivateKeys.pauseUntil)
                autoResumeTask?.cancel()
                autoResumeTask = nil
            }
        }
    }

    /// 派生：当前是否处于"暂停"状态。
    var isPaused: Bool {
        guard let d = pauseUntil else { return false }
        return d > Date()
    }

    /// 是否有 stub 路径被命中。镜像 UnimplementedReporter.hasUnimplementedStubs。
    @Published private(set) var hasUnimplementedStubs: Bool = false

    // MARK: - 内部 key（不出现在 SettingsKeys）

    private enum PrivateKeys {
        static let pauseUntil = "MyPortrait.capture.pauseUntil.v1"
    }

    // MARK: - 私有状态

    /// init 期间临时为 true，防止 didSet 把 default 写回 UserDefaults。
    private var isLoading = true

    /// reloadFromDefaults 期间临时为 true，防止 didSet 触发 UserDefaults 写回循环。
    private var isReloadingFromDefaults = false

    /// applyFromConfig 期间临时为 true，防止 capture toggle didSet 写回 ConfigStore 死循环。
    private var isReloadingFromConfig = false

    private var reporterSink: AnyCancellable?
    private var autoResumeTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        let store = ConfigStore.shared

        // 三个 capture 开关从 TOML 读初值。
        self.screenCaptureEnabled = store.recording.screen.enabled
        self.audioCaptureEnabled = store.recording.audio.enabled
        self.systemAudioCaptureEnabled = store.recording.audio.captureSystemAudio

        // 其他字段仍走 UserDefaults。
        self.ignoredAppNames = Set(defaults.stringArray(forKey: SettingsKeys.ignoredApps) ?? [])
        self.ignoredUrlPatterns = defaults.stringArray(forKey: SettingsKeys.ignoredURLs) ?? []

        // 暂停到期：过期就清掉。
        let storedPause = defaults.object(forKey: PrivateKeys.pauseUntil) as? Date
        if let d = storedPause, d > Date() {
            self.pauseUntil = d
        } else {
            self.pauseUntil = nil
            if storedPause != nil {
                defaults.removeObject(forKey: PrivateKeys.pauseUntil)
            }
        }

        self.isLoading = false

        if let d = pauseUntil {
            scheduleAutoResume(at: d)
        }

        // 监听 ConfigStore.recording 变化（vim 编辑 TOML / UI toggle / 状态栏 都走它）。
        startObservingConfig()

        // 监听 UserDefaults 变化（ignoredApps / ignoredUrls 仍在 UserDefaults）。
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDefaults()
            }
        }
    }

    /// 用 Observation 框架追踪 ConfigStore.recording 字段。任一变化 → 重跑
    /// applyFromConfig 推送到 @Published → Combine sink 醒来。
    /// withObservationTracking 是一次性的：onChange 触发后注册自动失效，所以
    /// 在 onChange 里递归重启。
    private func startObservingConfig() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.recording.screen.enabled
            _ = store.recording.audio.enabled
            _ = store.recording.audio.captureSystemAudio
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyFromConfig()
                self.startObservingConfig()
            }
        }
    }

    /// ConfigStore → @Published 单向同步。带 reentrancy guard 防 didSet 写回 →
    /// 再触发 observe → 再 apply 的循环。
    private func applyFromConfig() {
        let store = ConfigStore.shared
        isReloadingFromConfig = true
        defer { isReloadingFromConfig = false }
        if screenCaptureEnabled != store.recording.screen.enabled {
            screenCaptureEnabled = store.recording.screen.enabled
        }
        if audioCaptureEnabled != store.recording.audio.enabled {
            audioCaptureEnabled = store.recording.audio.enabled
        }
        if systemAudioCaptureEnabled != store.recording.audio.captureSystemAudio {
            systemAudioCaptureEnabled = store.recording.audio.captureSystemAudio
        }
    }

    /// didSet → ConfigStore。带 guard 防被 applyFromConfig 触发后又写回。
    private func writeBackToConfig(_ kp: WritableKeyPath<MyPortraitConfig, Bool>, _ value: Bool) {
        guard !isLoading, !isReloadingFromConfig else { return }
        let store = ConfigStore.shared
        guard store.current[keyPath: kp] != value else { return }
        store.mutate { $0[keyPath: kp] = value }
    }

    // 注：不写 deinit 移除 observer —— Swift 6 严格并发禁止 nonisolated deinit
    // 访问 @MainActor 字段。Observer 闭包 [weak self] 在 self 释放后变 nil
    // (block 体内 self?.xxx 啥也不做)，残留通知记录无害（NotificationCenter
    // 用 weak 引用 observer token）。Services.stopManagedLifecycle 可显式断。

    /// Services 在初始化后调一次，把 reporter 的状态镜像过来。
    func bindUnimplementedFlag(from reporter: UnimplementedReporter) {
        reporterSink = reporter.$callCount.sink { [weak self] count in
            self?.hasUnimplementedStubs = count > 0
        }
    }

    // MARK: - 私有

    /// UserDefaults 变化 → @Published 字段。**只覆盖** ignoredApps / ignoredUrls
    /// 这两个仍在 UserDefaults 的字段；capture toggle 已转走 ConfigStore，不再监听。
    private func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }

        let newApps = Set(defaults.stringArray(forKey: SettingsKeys.ignoredApps) ?? [])
        if newApps != ignoredAppNames { ignoredAppNames = newApps }

        let newUrls = defaults.stringArray(forKey: SettingsKeys.ignoredURLs) ?? []
        if newUrls != ignoredUrlPatterns { ignoredUrlPatterns = newUrls }
    }

    private func scheduleAutoResume(at expiration: Date) {
        autoResumeTask?.cancel()
        let delay = expiration.timeIntervalSinceNow
        guard delay > 0 else {
            pauseUntil = nil
            return
        }
        let ns = UInt64(delay * 1_000_000_000)
        autoResumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.pauseUntil = nil }
        }
    }
}

// MARK: - SwiftUI 环境注入

private struct CaptureSettingsKey: EnvironmentKey {
    static let defaultValue: CaptureSettings? = nil
}

extension EnvironmentValues {
    var captureSettings: CaptureSettings? {
        get { self[CaptureSettingsKey.self] }
        set { self[CaptureSettingsKey.self] = newValue }
    }
}
