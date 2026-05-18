import Combine
import Foundation
import SwiftUI
import os.log

/// 进程级服务集合。AppDelegate 在 `applicationDidFinishLaunching` 创建一次，
/// 进程退出时释放。通过 EnvironmentKey 注入 SwiftUI 树。
///
/// 持有：
///   - `reporter`:     notImplemented 上报中枢
///   - `settings`:     用户开关（默认 OFF；SwiftUI Settings 面板 bind 到这里）
///   - `db`:           PortraitDB 实现（P0 是 stub）
///   - `coordinator`:  CaptureCoordinator（屏幕采集主流水线）
///   - `compactor`:    CompactionWorker（JPG → MP4 后台压缩；无条件启）
///   - `audio`:        AudioCaptureService（麦克风 30s 段）
///   - `transcriber`:  TranscriptionScheduler（VAD + WhisperKit 调度；无条件启）
///
/// 设计：
///   - `coordinator` / `audio` 的启停**完全由 settings 驱动**，不在 init 里启
///   - `compactor` / `transcriber` 总是在跑（idle 时零成本：查 DB 空表返回）
///   - settings 变化 → Combine sink → 异步调对应子系统 start/stop
///
/// 不持有窗口 —— AppDelegate 自己管。
@MainActor
final class Services {
    let reporter: UnimplementedReporter
    let settings: CaptureSettings
    let db: PortraitDB
    let coordinator: CaptureCoordinator
    let compactor: CompactionWorker
    let audio: AudioCaptureService
    let transcriber: TranscriptionScheduler

    private let logger = Logger(subsystem: "com.myportrait", category: "services")
    private var settingsCancellables: Set<AnyCancellable> = []

    init() {
        let reporter = UnimplementedReporter()
        self.reporter = reporter

        let settings = CaptureSettings()
        settings.bindUnimplementedFlag(from: reporter)
        self.settings = settings

        let stubDB = StubPortraitDB(reporter: reporter)
        self.db = stubDB

        self.coordinator = CaptureCoordinator(db: stubDB, reporter: reporter)
        self.compactor = CompactionWorker(db: stubDB, reporter: reporter)
        let audioSvc = AudioCaptureService(reporter: reporter)
        self.audio = audioSvc
        self.transcriber = TranscriptionScheduler(
            db: stubDB, audio: audioSvc, reporter: reporter
        )
    }

    /// AppDelegate 在 `applicationDidFinishLaunching` 末尾调一次。
    /// - 崩溃恢复：把所有卡在 in_progress 的 audio_chunks 回退到 pending
    /// - 启动 compactor / transcriber（始终运行，无开关）
    /// - 订阅 settings 变化 → 启停 coordinator / audio
    /// - 用初始 settings 值同步对齐一次状态（默认都 OFF，所以两者都不启）
    func startManagedLifecycle() {
        // 崩溃恢复 + 启动后台 worker。
        let db = self.db
        let logger = self.logger
        Task.detached(priority: .utility) { [compactor, transcriber] in
            // 崩溃 / 强杀后某些 chunk 可能停在 in_progress，重启时回退为 pending
            // 让 TranscriptionScheduler 重新拾起。失败（如 stub）只 log，不阻塞启动。
            do {
                let reset = try await db.resetInProgressAudioChunks()
                if reset > 0 {
                    logger.info("crash recovery: reset \(reset, privacy: .public) audio chunks from in_progress to pending")
                }
            } catch {
                logger.warning("resetInProgressAudioChunks failed (expected with stub DB): \(String(describing: error), privacy: .public)")
            }

            await compactor.start()
            await transcriber.start()
        }

        // 屏幕采集订阅。effective = enabled && !paused。
        // CombineLatest 在任一上游变化时重算；pauseUntil 自动到期由 CaptureSettings
        // 内的 Task 把 pauseUntil 置回 nil → 再次触发本 sink。
        Publishers.CombineLatest(settings.$screenCaptureEnabled, settings.$pauseUntil)
            .map { enabled, until in
                if let until, until > Date() { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyScreenCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 音频采集订阅。effective = enabled && !paused。
        Publishers.CombineLatest(settings.$audioCaptureEnabled, settings.$pauseUntil)
            .map { enabled, until in
                if let until, until > Date() { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 忽略 app 列表订阅。
        let coordinator = self.coordinator
        settings.$ignoredAppNames
            .sink { apps in
                coordinator.setIgnoredApps(apps)
            }
            .store(in: &settingsCancellables)
    }

    /// AppDelegate 在 `applicationWillTerminate` 调，停所有子系统。
    func stopManagedLifecycle() async {
        await coordinator.stop()
        await audio.stop()
        await compactor.stop()
        await transcriber.stop()
        settingsCancellables.removeAll()
    }

    // MARK: - 私有：响应 settings 变化

    private func applyScreenCapture(enabled: Bool) {
        let coordinator = self.coordinator
        let logger = self.logger
        Task.detached(priority: .userInitiated) {
            if enabled {
                do {
                    try await coordinator.start()
                } catch {
                    logger.error("coordinator.start failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                await coordinator.stop()
            }
        }
    }

    private func applyAudioCapture(enabled: Bool) {
        let audio = self.audio
        Task.detached(priority: .userInitiated) {
            if enabled {
                await audio.start()
            } else {
                await audio.stop()
            }
        }
    }
}

// MARK: - SwiftUI 环境注入

private struct ServicesKey: EnvironmentKey {
    static let defaultValue: Services? = nil
}

extension EnvironmentValues {
    var services: Services? {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}
