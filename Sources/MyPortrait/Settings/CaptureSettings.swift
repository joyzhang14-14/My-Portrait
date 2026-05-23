import Combine
import Foundation
import SwiftUI

/// 采集层用户开关 — SwiftUI Settings UI 与后端 Services 之间的桥。
///
/// **三个 capture 开关 (screen / audio / systemAudio) 的单一真相在 ConfigStore
/// (~/.portrait/config.toml)**，本类是它的镜像 + Combine 适配层。原因：
///   - Settings UI (RecordingView) 直接绑定 `ConfigStore.capture.xxx.enabled`
///   - Services 用 Combine sink 订阅 @Published，要桥到 Observation 框架
///   - vim 改 TOML 也要 live reload（ConfigStore 已经实现 DispatchSource 监听）
///
/// 双向同步：
///   - UI / TOML / 状态栏 → ConfigStore.mutate → withObservationTracking 触发
///     → applyFromConfig → @Published → Services sink
///   - 程序化 settings.xxx = true → didSet → ConfigStore.mutate → 走上面这一路
///
/// ignore 列表（apps / urls）的单一真相在 ConfigStore.privacy；本类不再镜像。
@MainActor
final class CaptureSettings: ObservableObject {

    // MARK: - 用户可改字段

    /// 屏幕采集总开关。镜像 `ConfigStore.shared.capture.screen.enabled`。
    @Published var screenCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.capture.screen.enabled, screenCaptureEnabled) }
    }

    /// 麦克风采集总开关。镜像 `ConfigStore.shared.capture.audio.enabled`。
    @Published var audioCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.capture.audio.enabled, audioCaptureEnabled) }
    }

    /// 系统音频采集开关。镜像 `ConfigStore.shared.capture.audio.captureSystemAudio`。
    @Published var systemAudioCaptureEnabled: Bool {
        didSet { writeBackToConfig(\.capture.audio.captureSystemAudio, systemAudioCaptureEnabled) }
    }

    /// 是否有 stub 路径被命中。镜像 UnimplementedReporter.hasUnimplementedStubs。
    @Published private(set) var hasUnimplementedStubs: Bool = false

    // MARK: - 私有状态

    /// init 期间临时为 true，防止 didSet 把 default 写回 UserDefaults。
    private var isLoading = true

    /// applyFromConfig 期间临时为 true，防止 capture toggle didSet 写回 ConfigStore 死循环。
    private var isReloadingFromConfig = false

    private var reporterSink: AnyCancellable?

    init() {
        let store = ConfigStore.shared

        // 三个 capture 开关从 TOML 读初值。
        self.screenCaptureEnabled = store.capture.screen.enabled
        self.audioCaptureEnabled = store.capture.audio.enabled
        self.systemAudioCaptureEnabled = store.capture.audio.captureSystemAudio

        self.isLoading = false

        // 监听 ConfigStore.capture 变化（vim 编辑 TOML / UI toggle / 状态栏 都走它）。
        startObservingConfig()
    }

    /// 用 Observation 框架追踪 ConfigStore.capture 字段。任一变化 → 重跑
    /// applyFromConfig 推送到 @Published → Combine sink 醒来。
    /// withObservationTracking 是一次性的：onChange 触发后注册自动失效，所以
    /// 在 onChange 里递归重启。
    private func startObservingConfig() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.capture.screen.enabled
            _ = store.capture.audio.enabled
            _ = store.capture.audio.captureSystemAudio
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
        if screenCaptureEnabled != store.capture.screen.enabled {
            screenCaptureEnabled = store.capture.screen.enabled
        }
        if audioCaptureEnabled != store.capture.audio.enabled {
            audioCaptureEnabled = store.capture.audio.enabled
        }
        if systemAudioCaptureEnabled != store.capture.audio.captureSystemAudio {
            systemAudioCaptureEnabled = store.capture.audio.captureSystemAudio
        }
    }

    /// didSet → ConfigStore。带 guard 防被 applyFromConfig 触发后又写回。
    private func writeBackToConfig(_ kp: WritableKeyPath<MyPortraitConfig, Bool>, _ value: Bool) {
        guard !isLoading, !isReloadingFromConfig else { return }
        let store = ConfigStore.shared
        guard store.current[keyPath: kp] != value else { return }
        store.mutate { $0[keyPath: kp] = value }
    }

    /// Services 在初始化后调一次，把 reporter 的状态镜像过来。
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
