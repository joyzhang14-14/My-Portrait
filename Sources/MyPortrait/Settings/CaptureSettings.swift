import Combine
import Foundation
import SwiftUI

/// 采集层用户开关 — SwiftUI Settings UI 与后端 Services 之间的桥。
///
/// **单一真相在 UserDefaults**。Settings UI 用 `@AppStorage(SettingsKeys.xxx)`
/// 写，这里也用同样的 key 读写，外加监听 `UserDefaults.didChangeNotification`
/// 把变化映射到 `@Published` 字段。Services 通过 Combine sink 订阅 @Published。
///
/// 双向同步流程：
///   - UI 改 @AppStorage → UserDefaults 变 → 通知 → reloadFromDefaults → @Published → Services sink
///   - 状态栏菜单改 settings.xxx → didSet 写 UserDefaults → 通知 → reloadFromDefaults (flag 抑制) → 仍触发 sink
///
/// 默认值（首次启动 UserDefaults 无值时）：
///   - screen / audio / systemAudio 都 **OFF**（开发期测试方便；不弹权限）
///   - SwiftUI 视图里的 `@AppStorage(...) private var xxx = true` 默认无效 ——
///     init 里 force-write false 抢先注册（已经有值的不动）。
@MainActor
final class CaptureSettings: ObservableObject {

    // MARK: - 用户可改字段（与 SettingsKeys / Settings UI 共享 UserDefaults key）

    /// 屏幕采集总开关。对应 `SettingsKeys.screenRecordingEnabled`。
    @Published var screenCaptureEnabled: Bool {
        didSet { writeIfNeeded(screenCaptureEnabled, forKey: SettingsKeys.screenRecordingEnabled) }
    }

    /// 麦克风采集总开关。对应 `SettingsKeys.audioRecordingEnabled`。
    @Published var audioCaptureEnabled: Bool {
        didSet { writeIfNeeded(audioCaptureEnabled, forKey: SettingsKeys.audioRecordingEnabled) }
    }

    /// 系统音频采集开关。对应 `SettingsKeys.captureSystemAudio`。
    @Published var systemAudioCaptureEnabled: Bool {
        didSet { writeIfNeeded(systemAudioCaptureEnabled, forKey: SettingsKeys.captureSystemAudio) }
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

    private var reporterSink: AnyCancellable?
    private var autoResumeTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard

        // 首次启动：force-write false 覆盖 SwiftUI `@AppStorage(...) = true` 默认。
        // 仅在 UserDefaults 完全没有该 key 时写入（已经有值的不动）。
        for key in [
            SettingsKeys.screenRecordingEnabled,
            SettingsKeys.audioRecordingEnabled,
            SettingsKeys.captureSystemAudio,
        ] where defaults.object(forKey: key) == nil {
            defaults.set(false, forKey: key)
        }

        // 读初值。
        self.screenCaptureEnabled = defaults.bool(forKey: SettingsKeys.screenRecordingEnabled)
        self.audioCaptureEnabled = defaults.bool(forKey: SettingsKeys.audioRecordingEnabled)
        self.systemAudioCaptureEnabled = defaults.bool(forKey: SettingsKeys.captureSystemAudio)
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

        // 监听 UserDefaults 变化（SwiftUI @AppStorage 写入会触发）。
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

    /// UserDefaults 变化 → @Published 字段。带 reentrancy guard 防回写循环；
    /// 比较新旧值，只在变化时赋值。
    private func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }

        let newScreen = defaults.bool(forKey: SettingsKeys.screenRecordingEnabled)
        if newScreen != screenCaptureEnabled { screenCaptureEnabled = newScreen }

        let newAudio = defaults.bool(forKey: SettingsKeys.audioRecordingEnabled)
        if newAudio != audioCaptureEnabled { audioCaptureEnabled = newAudio }

        let newSys = defaults.bool(forKey: SettingsKeys.captureSystemAudio)
        if newSys != systemAudioCaptureEnabled { systemAudioCaptureEnabled = newSys }

        let newApps = Set(defaults.stringArray(forKey: SettingsKeys.ignoredApps) ?? [])
        if newApps != ignoredAppNames { ignoredAppNames = newApps }

        let newUrls = defaults.stringArray(forKey: SettingsKeys.ignoredURLs) ?? []
        if newUrls != ignoredUrlPatterns { ignoredUrlPatterns = newUrls }
    }

    private func writeIfNeeded(_ value: Bool, forKey key: String) {
        guard !isLoading, !isReloadingFromDefaults else { return }
        UserDefaults.standard.set(value, forKey: key)
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
