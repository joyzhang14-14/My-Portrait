import Combine
import Foundation
import SwiftUI

/// 采集层用户开关。
///
/// 持久化通过 UserDefaults。SwiftUI Settings 面板直接 bind 到 `@Published` 字段：
/// ```swift
/// Toggle("屏幕采集", isOn: $settings.screenCaptureEnabled)
/// ```
///
/// Services 订阅本对象的 publishers，flag 变化时自动 start/stop 对应子系统。
/// 调用方**不需要**直接调 coordinator.start/stop —— 改 setting，Services 接管。
///
/// 默认值（**两个采集开关都 OFF**）：
///   - 方便开发期反复重启调试
///   - 第一次启动不弹屏幕录制 / 麦克风权限请求（用户主动开才弹）
///   - 用户必须在 Settings 里显式启用
@MainActor
final class CaptureSettings: ObservableObject {

    // MARK: - 持久化 keys（UserDefaults）

    private enum Keys {
        static let screenCaptureEnabled = "MyPortrait.capture.screenEnabled.v1"
        static let audioCaptureEnabled = "MyPortrait.capture.audioEnabled.v1"
        static let systemAudioCaptureEnabled = "MyPortrait.capture.systemAudioEnabled.v1"
        static let ignoredAppNames = "MyPortrait.capture.ignoredAppNames.v1"
        static let ignoredUrlPatterns = "MyPortrait.capture.ignoredUrlPatterns.v1"
        static let pauseUntil = "MyPortrait.capture.pauseUntil.v1"
    }

    // MARK: - 用户可改字段

    /// 屏幕采集总开关。改为 true → Services 启动 CaptureCoordinator
    /// （此时才触发屏幕录制权限弹窗）。改为 false → 停止 coordinator + 释放 SCStream。
    @Published var screenCaptureEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            UserDefaults.standard.set(screenCaptureEnabled, forKey: Keys.screenCaptureEnabled)
        }
    }

    /// 麦克风采集总开关。改为 true → Services 启动 AudioCaptureService
    /// （此时才触发麦克风权限弹窗）。改为 false → 停止录音。
    /// 转录调度器(TranscriptionScheduler)持续运行 —— 关掉录音后它只会查 DB
    /// 看到没有 pending 段、空转。
    @Published var audioCaptureEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            UserDefaults.standard.set(audioCaptureEnabled, forKey: Keys.audioCaptureEnabled)
        }
    }

    /// 系统音频（loopback / process tap）采集开关。**目前仅架构在位**，
    /// 启动后 Core Audio 资源会分配但 AVAudioEngine wiring 未完成，**不会产
    /// 出段**，状态栏会冒红点提示。
    /// macOS 14.4+ 才有这个能力（CATapDescription / AudioHardwareCreateProcessTap）。
    @Published var systemAudioCaptureEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            UserDefaults.standard.set(systemAudioCaptureEnabled, forKey: Keys.systemAudioCaptureEnabled)
        }
    }

    /// 用户配置的"屏蔽 app 名"。命中（不区分大小写）则该帧跳过截图 + OCR。
    ///
    /// 设计：保留焦点元数据（DB 里仍记一行"用户在用 Mail"），但不存内容。
    /// 跟 DRMGate 的区别：DRM 是系统级硬规则停整条流水线；这里只跳单帧。
    @Published var ignoredAppNames: Set<String> {
        didSet {
            guard !isLoading else { return }
            UserDefaults.standard.set(Array(ignoredAppNames), forKey: Keys.ignoredAppNames)
        }
    }

    /// 用户配置的"屏蔽 URL 模式"。glob 通配，例：
    ///   - `*.bank.com/*`  → secure.bank.com/login 等
    ///   - `*mail*`        → 任何含 mail 的 URL
    /// 走 NSPredicate LIKE[c]（不区分大小写）。
    @Published var ignoredUrlPatterns: [String] {
        didSet {
            guard !isLoading else { return }
            UserDefaults.standard.set(ignoredUrlPatterns, forKey: Keys.ignoredUrlPatterns)
        }
    }

    /// "暂停到何时"。非 nil 且未过期 → 屏幕/音频采集都暂停。到期后自动清回 nil。
    ///
    /// 设置方式：状态栏菜单 "Pause for 10/30/60 min" 写入；用户手动取消写 nil。
    @Published var pauseUntil: Date? {
        didSet {
            guard !isLoading else { return }
            if let d = pauseUntil {
                UserDefaults.standard.set(d, forKey: Keys.pauseUntil)
                scheduleAutoResume(at: d)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.pauseUntil)
                autoResumeTask?.cancel()
                autoResumeTask = nil
            }
        }
    }

    /// 派生：当前是否处于"暂停"状态（即采集应该停止）。
    /// View 可以直接读它，也可在 publisher 中 map(\.isPaused)。
    var isPaused: Bool {
        guard let d = pauseUntil else { return false }
        return d > Date()
    }

    // MARK: - 只读字段（运行时状态镜像，SwiftUI 一处订阅）

    /// 是否有 stub 路径被命中。镜像 UnimplementedReporter.hasUnimplementedStubs。
    /// 由 Services 在初始化时同步过来。
    @Published private(set) var hasUnimplementedStubs: Bool = false

    // MARK: - 内部

    /// init 期间临时为 true，防止 didSet 把 default 写回 UserDefaults。
    private var isLoading = true

    /// reporter → hasUnimplementedStubs 镜像订阅。
    private var reporterSink: AnyCancellable?

    /// pauseUntil 到期自动清空的任务。
    private var autoResumeTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        // 第一次启动两个 key 都不存在，bool(forKey:) 返回 false —— 正好就是我们要的默认值。
        self.screenCaptureEnabled = defaults.bool(forKey: Keys.screenCaptureEnabled)
        self.audioCaptureEnabled = defaults.bool(forKey: Keys.audioCaptureEnabled)
        self.systemAudioCaptureEnabled = defaults.bool(forKey: Keys.systemAudioCaptureEnabled)

        // 忽略列表：UserDefaults 存的是 Array，转 Set 以方便查找。
        let stored = defaults.stringArray(forKey: Keys.ignoredAppNames) ?? []
        self.ignoredAppNames = Set(stored)

        // URL pattern 列表：保持 Array 顺序（用户在 UI 上能拖排序）。
        self.ignoredUrlPatterns = defaults.stringArray(forKey: Keys.ignoredUrlPatterns) ?? []

        // 暂停到期：app 关后可能已经过期，下面 didSet 等价的检查代替。
        let storedPause = defaults.object(forKey: Keys.pauseUntil) as? Date
        if let d = storedPause, d > Date() {
            self.pauseUntil = d
        } else {
            self.pauseUntil = nil
            if storedPause != nil {
                // 过期 → 顺手清掉 UserDefaults 里那条。
                defaults.removeObject(forKey: Keys.pauseUntil)
            }
        }

        self.isLoading = false

        // isLoading=false 之后再调一次 scheduleAutoResume —— init 内 didSet 不触发。
        if let d = pauseUntil {
            scheduleAutoResume(at: d)
        }
    }

    private func scheduleAutoResume(at expiration: Date) {
        autoResumeTask?.cancel()
        let delay = expiration.timeIntervalSinceNow
        guard delay > 0 else {
            // 已经过期，立刻清掉。
            pauseUntil = nil
            return
        }
        let ns = UInt64(delay * 1_000_000_000)
        autoResumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.pauseUntil = nil
            }
        }
    }

    /// Services 在初始化后调一次，把 reporter 的状态镜像过来。
    /// reporter.$callCount → settings.hasUnimplementedStubs。
    func bindUnimplementedFlag(from reporter: UnimplementedReporter) {
        reporterSink = reporter.$callCount.sink { [weak self] count in
            self?.hasUnimplementedStubs = count > 0
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
