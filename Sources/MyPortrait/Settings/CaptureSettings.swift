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

    // MARK: - 只读字段（运行时状态镜像，SwiftUI 一处订阅）

    /// 是否有 stub 路径被命中。镜像 UnimplementedReporter.hasUnimplementedStubs。
    /// 由 Services 在初始化时同步过来。
    @Published private(set) var hasUnimplementedStubs: Bool = false

    // MARK: - 内部

    /// init 期间临时为 true，防止 didSet 把 default 写回 UserDefaults。
    private var isLoading = true

    /// reporter → hasUnimplementedStubs 镜像订阅。
    private var reporterSink: AnyCancellable?

    init() {
        let defaults = UserDefaults.standard
        // 第一次启动两个 key 都不存在，bool(forKey:) 返回 false —— 正好就是我们要的默认值。
        self.screenCaptureEnabled = defaults.bool(forKey: Keys.screenCaptureEnabled)
        self.audioCaptureEnabled = defaults.bool(forKey: Keys.audioCaptureEnabled)
        self.isLoading = false
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
