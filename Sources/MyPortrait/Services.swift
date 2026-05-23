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
    /// 音乐播放监测 —— 开启 pauseOnMusicApp 后,音乐类 app 出声时暂停音频采集。
    let musicMonitor: MusicPlaybackMonitor
    /// 打字采集：把用户在输入框里最终打出的文字写库（学习写作风格）。
    let typingStore: TypingEventStore
    let typingObserver: TypingObserver

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
        // 说话人分离：ONNX 实现。运行时由 recording.audio.speakerIdEnabled 开关
        // 控制（关掉时 diarize 直接返回空，退化为整段一行无说话人）。
        self.transcriber = TranscriptionScheduler(
            db: dbImpl,
            audio: audioSvc,
            systemAudio: self.systemAudio,
            reporter: reporter,
            power: pw,
            whisper: WhisperKitWrapper(
                modelName: ConfigStore.shared.current.capture.audio.whisperModel
            ),
            speaker: OnnxSpeakerDiarizer(db: dbImpl)
        )
        self.retentionWorker = RetentionWorker(db: dbImpl)
        self.embeddingWorker = EmbeddingWorker(db: dbImpl, embedder: activeEmbedder)
        self.permissions = PermissionMonitor()
        self.musicMonitor = MusicPlaybackMonitor()

        // 打字采集。共用同一个 DatabasePool（WAL 多 reader 安全）。
        // 启停由 startManagedLifecycle 按 recording.typingCaptureEnabled 驱动。
        let typingStore = TypingEventStore(dbPool: dbImpl.dbPool)
        let keystrokeStore = KeystrokeStore(dbPool: dbImpl.dbPool)
        self.typingStore = typingStore
        self.typingObserver = TypingObserver(
            store: typingStore,
            keystrokeStore: keystrokeStore
        )

        // 写作采集 worker(共用同一 DatabasePool)。注册到 WritingCaptureWorker.shared
        // 给 UI(MemorySettingsView)用。
        let writingStore = WritingCaptureStore(dbPool: dbImpl.dbPool)
        let writingWorker = WritingCaptureWorker(store: writingStore)
        WritingCaptureWorker.shared = writingWorker
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

        // 音乐播放监测（每 5s 轮询；pauseOnMusicApp 关闭时空转）。
        musicMonitor.start()

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

            // 失败重试：把 retry_count 没到上限的 failed chunk 回退 pending 重跑。
            do {
                let retried = try await db.resetRetryableFailedAudioChunks()
                if retried > 0 {
                    logger.info("retry recovery: reset \(retried, privacy: .public) failed audio chunks to pending")
                }
            } catch {
                logger.warning("resetRetryableFailedAudioChunks failed: \(String(describing: error), privacy: .public)")
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

        // 记忆流水线调度器：启动时回收死锁、立刻 tick 一次、再起周期 timer。
        // 调试开关：env `MYPORTRAIT_NO_SCHEDULER=1` 跳过。
        if ProcessInfo.processInfo.environment["MYPORTRAIT_NO_SCHEDULER"] != "1" {
            MemoryScheduler.shared.start()
        } else {
            logger.info("MemoryScheduler SKIPPED (MYPORTRAIT_NO_SCHEDULER=1)")
        }

        // **权限请求触发**。两类信号要分清楚：
        //   1. CGRequestScreenCaptureAccess / AVCaptureDevice.requestAccess
        //      —— 弹**系统标准权限对话框**。这个**启动时也该调**：app 要截屏
        //      就得请求，首次调用会把 app 注册进 TCC 列表（不调的话系统设置里
        //      根本不出现 My Portrait）。
        //   2. openSettings —— 打开**系统设置窗口**。这个只该在**用户主动
        //      toggle** 时弹，启动时弹很烦。
        //
        // 所以不能整体 dropFirst。改成：每个 sink 自己记"是不是首次 emission"
        // （= 启动时的初始值），请求权限两种情况都做，但 openSettings 引导只在
        // 非首次（用户主动切）时做。
        var screenSinkSeenInitial = false
        settings.$screenCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                let userInitiated = screenSinkSeenInitial
                screenSinkSeenInitial = true
                guard let self, enabled else { return }
                _ = userInitiated
                if self.permissions.screenRecording == .granted { return }
                self.logger.info("screen enabled, permission not granted — requesting")
                // requestScreenRecording 内部会真正 probe 一次 SCK —— 首次会弹
                // 系统对话框 + 把 app 注册进 TCC「屏幕录制」列表。授权结果由
                // PermissionMonitor 的 3 秒轮询捕获，上面的 CombineLatest3 sink
                // 自动重新评估。所以这里不需要再弹我们自己的确认框。
                self.permissions.requestScreenRecording()
            }
            .store(in: &settingsCancellables)

        var audioSinkSeenInitial = false
        settings.$audioCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                let userInitiated = audioSinkSeenInitial
                audioSinkSeenInitial = true
                guard let self, enabled else { return }
                let perm = self.permissions.microphone
                if perm == .granted { return }
                self.logger.info("audio enabled, permission=\(String(describing: perm), privacy: .public) (userInitiated=\(userInitiated))")
                if perm == .notDetermined {
                    // 从没问过 → 弹系统标准对话框（启动时弹也 OK）。
                    self.permissions.requestMicrophone()
                } else if userInitiated {
                    // denied + 用户主动切 → 引导去系统设置。
                    self.confirmThenOpenSettings(
                        title: "Microphone Permission Needed",
                        body: "My Portrait needs microphone access to record audio. Open System Settings to grant it?",
                        perm: .microphone
                    )
                }
            }
            .store(in: &settingsCancellables)

        // 屏幕采集订阅。effective = enabled && screenRecording granted。
        // **权限**：PermissionMonitor 3 秒轮询；用户在 System Settings 里授权后
        // 这个 publisher 会变 granted，sink 自动重新评估，coordinator 自动启动，
        // 不需要用户再 toggle 一次。
        Publishers.CombineLatest(
            settings.$screenCaptureEnabled,
            permissions.$screenRecording
        )
            .map { enabled, perm in
                guard perm.isGranted else { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyScreenCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 音频采集订阅。effective = enabled && microphone granted && !music。
        // music 在播 → 整体暂停采集（pauseOnMusicApp；关闭时 musicDetected 恒 false）。
        Publishers.CombineLatest3(
            settings.$audioCaptureEnabled,
            permissions.$microphone,
            musicMonitor.$musicDetected
        )
            .map { [logger] enabled, perm, music in
                let effective = !music && perm.isGranted && enabled
                logger.notice("audio sink: enabled=\(enabled, privacy: .public) micPerm=\(perm.isGranted, privacy: .public) music=\(music, privacy: .public) → effective=\(effective, privacy: .public)")
                return effective
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 系统音频订阅。系统音频也需要 microphone 权限（CATapDescription 路径）。
        Publishers.CombineLatest3(
            settings.$systemAudioCaptureEnabled,
            permissions.$microphone,
            musicMonitor.$musicDetected
        )
            .map { enabled, perm, music in
                if music { return false }
                guard perm.isGranted else { return false }
                return enabled
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applySystemAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 忽略规则（app + URL）。单一真相是 ConfigStore.privacy（TOML）。
        // ConfigStore 是 @Observable 不是 Combine，用 withObservationTracking
        // 递归重注册——跟 CaptureSettings.startObservingConfig 一个套路。
        pushIgnoreRules()
        observeIgnoreRules()

        // 打字采集。escape hatch：MYPORTRAIT_NO_TYPING=1 完全不启。
        // 否则按 ConfigStore.capture.typingCaptureEnabled 动态启停 ——
        // TypingObserver 自身还有 AX / Input Monitoring 权限门禁，没授权会自己 idle。
        if ProcessInfo.processInfo.environment["MYPORTRAIT_NO_TYPING"] == "1" {
            logger.info("TypingObserver SKIPPED (MYPORTRAIT_NO_TYPING=1)")
        } else {
            applyTypingCapture(enabled: ConfigStore.shared.capture.typingCaptureEnabled)
            observeTypingCapture()
            // AX 权限是 typing observer 的硬门禁。用户在系统设置里授权后，
            // PermissionMonitor 3 秒轮询会捕获到 → 把 idle 的 observer 拾起。
            permissions.$accessibility
                .removeDuplicates()
                .sink { [weak self] status in
                    guard let self, status == .granted,
                          ConfigStore.shared.capture.typingCaptureEnabled else { return }
                    self.logger.info("accessibility granted — starting typing observer")
                    self.typingObserver.start()
                }
                .store(in: &settingsCancellables)
        }
    }

    /// 监听 ConfigStore.capture.typingCaptureEnabled（vim 改 TOML / UI 编辑都走它），
    /// 翻 true → typingObserver.start()，翻 false → stop()。
    /// withObservationTracking 一次性，onChange 里递归重注册。
    private func observeTypingCapture() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.capture.typingCaptureEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyTypingCapture(enabled: ConfigStore.shared.capture.typingCaptureEnabled)
                self.observeTypingCapture()
            }
        }
    }

    private func applyTypingCapture(enabled: Bool) {
        if enabled {
            // 打字采集需要 Accessibility 权限。没授 → 请求 + 引导。
            if permissions.accessibility != .granted {
                logger.info("typing enabled, accessibility not granted — requesting + guiding")
                // ① 把 app 注册进系统设置的「辅助功能」列表（macOS 肯弹时也会
                //    弹系统标准对话框）。
                permissions.requestAccessibility()
                // ② AX 的系统对话框是「一次性」的 —— app 进列表后不再弹，照抄
                //    screen 的系统弹窗对老用户静默无效。补一个我们自己的 NSAlert
                //    （同 microphone denied 路径），必定可见、点确认直达系统设置。
                //    授权后 PermissionMonitor 轮询 → $accessibility sink 拾起 observer。
                confirmThenOpenSettings(
                    title: "Accessibility Permission Needed",
                    body: "My Portrait needs Accessibility access to capture your typing. "
                        + "Open System Settings to grant it?",
                    perm: .accessibility
                )
            }
            // start() 内部会 print 启动 banner；AX 没授时它自己 idle。
            typingObserver.start()
        } else {
            // 总开关关 —— observer 不启动。显式 print，避免「为什么没采集」
            // 又是一次无提示的 silent failure。
            print("[TypingObserver] not started — typing_capture_enabled = false  ⚠️")
            typingObserver.stop()
        }
    }

    /// 把 ConfigStore.privacy 的 ignore 规则推给 capture coordinator。
    private func pushIgnoreRules() {
        let p = ConfigStore.shared.privacy
        coordinator.setIgnoredApps(Set(p.ignoredApps))
        coordinator.setIgnoredUrlPatterns(p.ignoredUrls)
        coordinator.setIgnoredWindowTitles(p.ignoredWindowTitles)
        coordinator.setMaskingEnabled(p.maskIgnoredApps)
    }

    /// 监听 ConfigStore.privacy 的 ignore 字段（vim 改 TOML / UI 编辑都走它），
    /// 变化时重推给 coordinator。withObservationTracking 一次性，onChange 里递归重注册。
    private func observeIgnoreRules() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.privacy.ignoredApps
            _ = store.privacy.ignoredUrls
            _ = store.privacy.ignoredWindowTitles
            _ = store.privacy.maskIgnoredApps
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pushIgnoreRules()
                self.observeIgnoreRules()
            }
        }
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
        typingObserver.stop()
        powerWatcher.stop()
        permissions.stop()
        settingsCancellables.removeAll()
    }

    // MARK: - 私有：权限

    /// 权限被 denied 时弹 NSAlert 问用户，确认后才打开系统设置。
    /// 不再像之前那样无脑 openSettings —— 那样每次启动都弹设置窗口。
    private func confirmThenOpenSettings(title: String, body: String, perm: PermissionMonitor.Kind) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissions.openSettings(for: perm)
        }
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
        logger.notice("applyAudioCapture(enabled: \(enabled, privacy: .public))")
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
