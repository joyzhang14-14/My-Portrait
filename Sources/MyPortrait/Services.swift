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
    let permissions: PermissionMonitor

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

        // bge-m3 模型管理器保留：模型会下到 ~/.portrait/models/bge-m3/ 备用，
        // 下个 session MLX 推理上线后从 NLEmbedding 切到 BGEM3VectorEmbedder。
        let manager = BGEM3ModelManager()
        self.modelManager = manager

        // **当前激活的 embedder**：bge-m3 真推理（MLX，完全本地，1024 维）。
        // 首次启动会下 ~1.13 GB 权重 + ~17 MB tokenizer 到 HF cache，
        // 之后直接读 cache。embedder 加载/推理失败时 HybridSearchEngine 自动降级
        // FTS-only —— UI 搜索仍工作。
        //
        // 关键 trick：swift-transformers 0.1.24 没有 XLMRobertaTokenizer 路由，
        // 但 bge-m3 的 tokenizer.json 是 Unigram model，跟 T5Tokenizer 走同一条
        // UnigramTokenizer 代码路径。所以 BGEM3VectorEmbedder 加载时在内存里把
        // tokenizer_class 从 "XLMRobertaTokenizer" 改成 "T5Tokenizer"，零新依赖。
        let activeEmbedder: any VectorEmbedder = BGEM3VectorEmbedder(reporter: reporter)
        self.embedder = activeEmbedder

        // Hybrid：FTS + 向量 + RRF。embedder 抛错（NLEmbedding 对完全非英语
        // 输入会 throw `.unsupportedInput`）时自动降级 FTS-only。
        self.searchEngine = HybridSearchEngine(
            db: dbImpl, fts: ftsEngine, embedder: activeEmbedder
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
        self.embeddingWorker = EmbeddingWorker(db: dbImpl, embedder: activeEmbedder)
        self.permissions = PermissionMonitor()
    }

    /// AppDelegate 在 `applicationDidFinishLaunching` 末尾调一次。
    /// - 崩溃恢复：把所有卡在 in_progress 的 audio_chunks 回退到 pending
    /// - 启动 compactor / transcriber（始终运行，无开关）
    /// - 订阅 settings 变化 → 启停 coordinator / audio
    /// - 用初始 settings 值同步对齐一次状态（默认都 OFF，所以两者都不启）
    func startManagedLifecycle() {
        // PowerWatcher 必须在 main thread 注册 IOPS run loop source。
        powerWatcher.start()

        // 权限轮询启动。3 秒一次查 TCC / AX / AVCapture，状态变化会触发
        // 下面的 Combine sink 重新评估 capture toggle 是否能 effective。
        permissions.start()

        // 崩溃恢复 + 启动后台 worker。
        let db = self.db
        let logger = self.logger
        Task.detached(priority: .utility) { [compactor, transcriber, retentionWorker, embeddingWorker, logger] in
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

            let env = ProcessInfo.processInfo.environment
            if env["MYPORTRAIT_NO_COMPACTOR"] != "1" {
                await compactor.start()
            } else {
                logger.info("CompactionWorker SKIPPED (MYPORTRAIT_NO_COMPACTOR=1)")
            }
            if env["MYPORTRAIT_NO_TRANSCRIBER"] != "1" {
                await transcriber.start()
            } else {
                logger.info("TranscriptionScheduler SKIPPED (MYPORTRAIT_NO_TRANSCRIBER=1)")
            }
            await retentionWorker.start()

            // EmbeddingWorker 启。bge-m3 推理走 MLX 本地，不再撞 Apple Intelligence
            // XPC 的 entitlement 坑。首次启动 BGEM3VectorEmbedder.loadedContainer
            // 会下 ~1.13 GB 模型到 HF cache，之后秒级加载。
            //
            // 调试开关：env `MYPORTRAIT_NO_EMBED_WORKER=1` 时跳过 worker 启动。
            // 用于二分定位 capture toggle 崩溃是否跟 MLX/embedding 路径有关。
            if ProcessInfo.processInfo.environment["MYPORTRAIT_NO_EMBED_WORKER"] != "1" {
                await embeddingWorker.start()
            } else {
                logger.info("EmbeddingWorker SKIPPED (MYPORTRAIT_NO_EMBED_WORKER=1)")
            }
        }

        // **权限请求触发**：用户把 toggle 切 ON 时，如果权限不在 granted，
        // 主动调系统标准对话框（NotDetermined 状态）或开 Settings（Denied）。
        // PermissionMonitor 轮询会捕到授权结果，上面的 CombineLatest3 sink
        // 自动重新评估。
        settings.$screenCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                let perm = self.permissions.screenRecording
                if perm == .granted { return }
                self.logger.info("screen toggle ON but permission=\(String(describing: perm), privacy: .public) — requesting")
                self.permissions.requestScreenRecording()
                if perm == .denied {
                    // Denied 状态系统对话框不会弹，跳 Settings 让用户手动开
                    self.permissions.openSettings(for: .screen)
                }
            }
            .store(in: &settingsCancellables)

        settings.$audioCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                let perm = self.permissions.microphone
                if perm == .granted { return }
                self.logger.info("audio toggle ON but permission=\(String(describing: perm), privacy: .public) — requesting")
                self.permissions.requestMicrophone()
                if perm == .denied {
                    self.permissions.openSettings(for: .microphone)
                }
            }
            .store(in: &settingsCancellables)

        // 屏幕采集订阅。effective = enabled && !paused && screenRecording granted。
        // CombineLatest 在任一上游变化时重算；pauseUntil 自动到期由 CaptureSettings
        // 内的 Task 把 pauseUntil 置回 nil → 再次触发本 sink。
        // **权限**：PermissionMonitor 3 秒轮询；用户在 System Settings 里授权后
        // 这个 publisher 会变 granted，sink 自动重新评估，coordinator 自动启动，
        // 不需要用户再 toggle 一次。
        Publishers.CombineLatest3(
            settings.$screenCaptureEnabled,
            settings.$pauseUntil,
            permissions.$screenRecording
        )
            .map { enabled, until, perm in
                if let until, until > Date() { return false }
                guard perm.isGranted else { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyScreenCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 音频采集订阅。effective = enabled && !paused && microphone granted。
        Publishers.CombineLatest3(
            settings.$audioCaptureEnabled,
            settings.$pauseUntil,
            permissions.$microphone
        )
            .map { enabled, until, perm in
                if let until, until > Date() { return false }
                guard perm.isGranted else { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 系统音频订阅。系统音频也需要 microphone 权限（CATapDescription 路径）。
        Publishers.CombineLatest3(
            settings.$systemAudioCaptureEnabled,
            settings.$pauseUntil,
            permissions.$microphone
        )
            .map { enabled, until, perm in
                if let until, until > Date() { return false }
                guard perm.isGranted else { return false }
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
        permissions.stop()
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

    private func applySystemAudioCapture(enabled: Bool) {
        let sysAudio = self.systemAudio
        Task.detached(priority: .userInitiated) {
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
