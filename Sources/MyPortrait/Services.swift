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
    let searchEngine: SearchEngine
    let coordinator: CaptureCoordinator
    let compactor: CompactionWorker
    let audio: AudioCaptureService
    let systemAudio: SystemAudioCaptureService
    let transcriber: TranscriptionScheduler
    let powerWatcher: PowerWatcher
    let retentionWorker: RetentionWorker
    let modelManager: BGEM3ModelManager
    let embedder: any VectorEmbedder
    let embeddingWorker: EmbeddingWorker

    private let logger = Logger(subsystem: "com.myportrait", category: "services")
    private var settingsCancellables: Set<AnyCancellable> = []

    init() {
        let reporter = UnimplementedReporter()
        self.reporter = reporter

        let settings = CaptureSettings()
        settings.bindUnimplementedFlag(from: reporter)
        self.settings = settings

        // 真 DB —— 失败抛错冒到 AppDelegate，那边弹 alert 退出。
        // 失败常见原因：磁盘满 / 权限不对 / migration 失败。开发期罕见。
        let dbImpl: PortraitDBImpl
        do {
            dbImpl = try PortraitDBImpl()
        } catch {
            // 启动期 DB 打不开是致命的。直接 fatalError 比挂个 stub 上线更诚实。
            fatalError("PortraitDB failed to open: \(error)")
        }
        self.db = dbImpl
        // 共用同一个 DatabasePool（WAL 多 reader 安全）。
        let ftsEngine = FTSSearchEngine(dbPool: dbImpl.dbPool)
        let manager = BGEM3ModelManager()
        let bgeEmbedder = BGEM3VectorEmbedder(modelManager: manager, reporter: reporter)
        self.modelManager = manager
        self.embedder = bgeEmbedder
        // Hybrid：FTS + 向量 + RRF。embedder 抛错时自动降级 FTS-only，
        // 所以即使 bge-m3 推理还没接通（Phase 4 stub），UI 行为也跟纯 FTS 一致。
        self.searchEngine = HybridSearchEngine(
            db: dbImpl, fts: ftsEngine, embedder: bgeEmbedder
        )

        self.coordinator = CaptureCoordinator(db: dbImpl, reporter: reporter)
        self.compactor = CompactionWorker(db: dbImpl, reporter: reporter)
        let audioSvc = AudioCaptureService(reporter: reporter)
        self.audio = audioSvc
        self.systemAudio = SystemAudioCaptureService(reporter: reporter)
        let pw = PowerWatcher()
        self.powerWatcher = pw
        self.transcriber = TranscriptionScheduler(
            db: dbImpl,
            audio: audioSvc,
            systemAudio: self.systemAudio,
            reporter: reporter,
            power: pw
        )
        self.retentionWorker = RetentionWorker(db: dbImpl)
        self.embeddingWorker = EmbeddingWorker(db: dbImpl, embedder: bgeEmbedder)
    }

    /// AppDelegate 在 `applicationDidFinishLaunching` 末尾调一次。
    /// - 崩溃恢复：把所有卡在 in_progress 的 audio_chunks 回退到 pending
    /// - 启动 compactor / transcriber（始终运行，无开关）
    /// - 订阅 settings 变化 → 启停 coordinator / audio
    /// - 用初始 settings 值同步对齐一次状态（默认都 OFF，所以两者都不启）
    func startManagedLifecycle() {
        // PowerWatcher 必须在 main thread 注册 IOPS run loop source。
        powerWatcher.start()

        // 崩溃恢复 + 启动后台 worker。
        let db = self.db
        let logger = self.logger
        Task.detached(priority: .utility) { [compactor, transcriber, retentionWorker, modelManager, embeddingWorker, logger] in
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
            await retentionWorker.start()
            await embeddingWorker.start()    // embedder 现在 stub，worker 空转直到模型接通

            // 后台下 bge-m3 模型（~2.5 GB），不阻塞任何东西。
            // Phase 4 上线推理后这个 await 才有意义；当前只是把文件下到本地。
            do {
                try await modelManager.ensureDownloaded()
            } catch {
                logger.warning("bge-m3 model download failed (will retry next launch): \(String(describing: error), privacy: .public)")
            }
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

        // 系统音频订阅。同样的暂停语义。
        Publishers.CombineLatest(settings.$systemAudioCaptureEnabled, settings.$pauseUntil)
            .map { enabled, until in
                if let until, until > Date() { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applySystemAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 忽略 app 列表订阅。
        let coordinator = self.coordinator
        settings.$ignoredAppNames
            .sink { apps in
                coordinator.setIgnoredApps(apps)
            }
            .store(in: &settingsCancellables)

        // 忽略 URL pattern 列表订阅。
        settings.$ignoredUrlPatterns
            .sink { patterns in
                coordinator.setIgnoredUrlPatterns(patterns)
            }
            .store(in: &settingsCancellables)
    }

    /// AppDelegate 在 `applicationWillTerminate` 调，停所有子系统。
    func stopManagedLifecycle() async {
        await coordinator.stop()
        await audio.stop()
        await systemAudio.stop()
        await compactor.stop()
        await transcriber.stop()
        await retentionWorker.stop()
        await embeddingWorker.stop()
        powerWatcher.stop()
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

    // MARK: - Audio kill switch（临时）
    //
    // 调查"一 build 就音乐音量被压"现象期间，强制保持 AudioCaptureService +
    // SystemAudioCaptureService **永远是 stop 状态**，无论 settings 切到什么。
    //
    // 怀疑路径（待确认）：
    //   - SystemAudioCaptureService 启动时 CATapDescription + AVAudioEngine 一起跑，
    //     macOS 对系统音频 tap 会自动套用 "voice processing" 音频策略，结果就是
    //     其他 app 的 playback volume 被 duck（典型现象）
    //   - 也可能是用户在 dev 期间手动 toggle 过 systemAudio=true 进 UserDefaults，
    //     没改回来，每次启动都"持续录"
    //
    // 把 kill switch 翻成 false 即恢复 settings 控制。
    private static let audioCaptureKillSwitchOn = true

    private func applyAudioCapture(enabled: Bool) {
        let audio = self.audio
        let killed = Self.audioCaptureKillSwitchOn
        let logger = self.logger
        Task.detached(priority: .userInitiated) {
            if killed {
                // 永远 stop，不管 enabled 是什么。
                await audio.stop()
                if enabled {
                    logger.warning("audio kill-switch ON: ignored start request (settings.audioCaptureEnabled=true). Flip Services.audioCaptureKillSwitchOn = false to re-enable.")
                }
                return
            }
            if enabled {
                await audio.start()
            } else {
                await audio.stop()
            }
        }
    }

    private func applySystemAudioCapture(enabled: Bool) {
        let sysAudio = self.systemAudio
        let killed = Self.audioCaptureKillSwitchOn
        let logger = self.logger
        Task.detached(priority: .userInitiated) {
            if killed {
                await sysAudio.stop()
                if enabled {
                    logger.warning("audio kill-switch ON: ignored start request (settings.systemAudioCaptureEnabled=true). Flip Services.audioCaptureKillSwitchOn = false to re-enable.")
                }
                return
            }
            if enabled {
                await sysAudio.start()
            } else {
                await sysAudio.stop()
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
