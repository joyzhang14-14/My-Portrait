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
    /// WhisperKit 模型 wrapper —— 启动时 prefetch + transcriber 持引用复用。
    let whisper: WhisperKitWrapper
    let powerWatcher: PowerWatcher
    /// 订阅 powerWatcher.states 重算屏幕采集功耗档位的常驻 task。
    private var powerProfileTask: Task<Void, Never>?
    /// 上一次应用的 profile —— 没变就不重复推给 coordinator,省无谓的 actor 调用。
    private var lastPowerProfile: PowerProfile?
    let retentionWorker: RetentionWorker
    let permissions: PermissionMonitor
    /// Stall 检测后台 driver(30s 一次 evaluate)。startManagedLifecycle 启,
    /// 不主动 stop —— 跟随进程退出。
    let stallDriver: StallDetectorDriver
    /// 音乐播放监测 —— 开启 pauseOnMusicApp 后,音乐类 app 出声时暂停音频采集。
    let musicMonitor: MusicPlaybackMonitor
    /// 锁屏监听 —— Record audio while locked 关时,锁屏暂停音频采集。
    let screenLockMonitor: ScreenLockMonitor
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

        // 纯 FTS5 关键词搜索。语义搜索（bge-m3 向量 + RRF 融合）已整体移除。
        self.searchEngine = ftsEngine

        self.coordinator = CaptureCoordinator(db: dbImpl, reporter: reporter)
        self.compactor = CompactionWorker(db: dbImpl, reporter: reporter)
        let audioSvc = AudioCaptureService(reporter: reporter)
        self.audio = audioSvc
        self.systemAudio = SystemAudioCaptureService(reporter: reporter)
        let pw = PowerWatcher()
        self.powerWatcher = pw
        // 说话人分离：ONNX 实现。运行时由 recording.audio.speakerIdEnabled 开关
        // 控制（关掉时 diarize 直接返回空，退化为整段一行无说话人）。
        // 单独持引用让启动时能 prefetch 模型(防止用户第一次真录音才下 150MB)。
        let whisperWrapper = WhisperKitWrapper(
            modelName: ConfigStore.shared.current.capture.audio.whisperModel
        )
        self.whisper = whisperWrapper
        // Qwen3-ASR 走手动下载（不在启动 prefetch）；模型 id 由设置 qwenModel 决定。
        let qwenWrapper = Qwen3ASRWrapper(
            modelId: ConfigStore.shared.current.capture.audio.qwenModel
        )
        self.transcriber = TranscriptionScheduler(
            db: dbImpl,
            audio: audioSvc,
            systemAudio: self.systemAudio,
            reporter: reporter,
            power: pw,
            whisper: whisperWrapper,
            qwen: qwenWrapper,
            speaker: OnnxSpeakerDiarizer(db: dbImpl)
        )
        self.retentionWorker = RetentionWorker(db: dbImpl)
        let permissions = PermissionMonitor()
        self.permissions = permissions
        self.stallDriver = StallDetectorDriver(db: dbImpl, permissions: permissions)
        self.musicMonitor = MusicPlaybackMonitor()
        self.screenLockMonitor = ScreenLockMonitor()

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
        // 启动时清残留 zombie processing 行 —— 上次进程崩 / 用户硬退之后
        // 没改回 final status 的 run。否则下次 runBacklog 报 "already in progress"。
        if let zombies = try? writingStore.markStuckProcessingAsFailed(
            message: "process exited before run completed"
        ), zombies > 0 {
            print("[writing-capture] startup recovery: marked \(zombies) zombie run(s) as failed")
        }

        // speech_style 提炼链路(独立于写作采集 + memory pipeline)。也共用
        // 同一 DatabasePool。注册到 SpeechStyleDistiller.shared 给 UI / scheduler 用。
        let ssStore = SpeechStyleStore(dbPool: dbImpl.dbPool)
        SpeechStyleDistiller.shared = SpeechStyleDistiller(store: ssStore)
        // 启动时清残留 zombie processing 行 —— 上次进程崩 / 用户硬退之后
        // 没改回 final status 的 run。
        if let zombies = try? ssStore.markStuckProcessingAsFailed(
            message: "process exited before run completed"
        ), zombies > 0 {
            print("[speech-style] startup recovery: marked \(zombies) zombie run(s) as failed")
        }
    }

    /// AppDelegate 在 `applicationDidFinishLaunching` 末尾调一次。
    /// - 崩溃恢复：把所有卡在 in_progress 的 audio_chunks 回退到 pending
    /// - 启动 compactor / transcriber（始终运行，无开关）
    /// - 订阅 settings 变化 → 启停 coordinator / audio
    /// - 用初始 settings 值同步对齐一次状态（默认都 OFF，所以两者都不启）
    func startManagedLifecycle() {
        // 启动一次把 ~/.portrait/bin/mp-query symlink 到当前 app 主二进制,
        // 给 pi-coding-agent 用 bash 调本地数据查询接口(SKILL.md 风格)。
        // app 升级路径变后这里会重链。
        _ = AIPaths.installMpQueryLink()

        // PowerWatcher 必须在 main thread 注册 IOPS run loop source。
        powerWatcher.start()

        // 权限轮询启动。3 秒一次查 TCC / AX / AVCapture，状态变化会触发
        // 下面的 Combine sink 重新评估 capture toggle 是否能 effective。
        permissions.start()

        // 音乐播放监测（每 5s 轮询；pauseOnMusicApp 关闭时空转）。
        musicMonitor.start()

        // 锁屏监听（事件驱动）。Record audio while locked 关时锁屏暂停音频。
        screenLockMonitor.start()

        // 崩溃恢复 + 启动后台 worker。
        let db = self.db
        let logger = self.logger
        let whisper = self.whisper
        // 启动时统一后台 prefetch 所有可能 lazy 下载的本地资源。新用户首启
        // 时直接拉满,避免用户在 onboarding / 真用某功能时才下载导致卡顿
        // 或失败:
        //   1. Speaker / VAD ONNX (~40MB):VoiceTrainer 依赖
        //   2. WhisperKit 模型 (默认 base ~150MB):Audio Capture 第一段录音依赖
        //   3. Bun + Pi @mariozechner/pi-coding-agent (~30MB):Chat / cron job 依赖
        Task.detached(priority: .utility) { [whisper] in
            await SpeakerModelStore.shared.prefetchAll()
            // 只预下「当前选中」的 Whisper 模型(whisper.modelName);其余在 AI models
            // 页按需手动下载,避免启动一次拉满好几 GB。
            await whisper.prefetch()
        }
        Task { @MainActor in
            // ensureInstalled 内部已 idempotent(已 ready 直接 return)。
            AISetup.shared.ensureInstalled()
        }

        Task.detached(priority: .utility) { [compactor, transcriber, retentionWorker, logger] in
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
        }

        // 记忆流水线调度器：启动时回收死锁、立刻 tick 一次、再起周期 timer。
        // 调试开关：env `MYPORTRAIT_NO_SCHEDULER=1` 跳过。
        if ProcessInfo.processInfo.environment["MYPORTRAIT_NO_SCHEDULER"] != "1" {
            MemoryScheduler.shared.start()
        } else {
            logger.info("MemoryScheduler SKIPPED (MYPORTRAIT_NO_SCHEDULER=1)")
        }

        // Stall 检测后台 driver。30s 一次 evaluate;有 verdict → log +
        // (notifications.captureStalls 亮时) post 浮窗。无 env 开关:
        // 跟 PermissionMonitor / DRMWatcher 同级,常驻轻量。
        stallDriver.start()

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
        // **启动初始 emission 永远不 request 权限**。系统权限对话框只在两个
        // 地方触发:
        //   ① OnboardingView Permissions step 用户主动点 Allow(独立路径,
        //      直接调 monitor.requestXxx,不走这里的 sink)
        //   ② 用户在 Settings 主动 toggle capture OFF → ON,sink 触发,
        //      userInitiated=true 走 request
        // 启动时 sink 初始 emission(userInitiated=false)一律静默,避免新用户
        // 还没看到 onboarding 第一页就被 N 个权限对话框糊脸。
        var screenSinkSeenInitial = false
        settings.$screenCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                let userInitiated = screenSinkSeenInitial
                screenSinkSeenInitial = true
                guard let self, enabled, userInitiated else { return }
                if self.permissions.screenRecording == .granted { return }
                self.logger.info("screen toggled on by user, requesting permission")
                self.permissions.requestScreenRecording()
            }
            .store(in: &settingsCancellables)

        var audioSinkSeenInitial = false
        settings.$audioCaptureEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                let userInitiated = audioSinkSeenInitial
                audioSinkSeenInitial = true
                guard let self, enabled, userInitiated else { return }
                let perm = self.permissions.microphone
                if perm == .granted { return }
                self.logger.info("audio toggled on by user, mic permission=\(String(describing: perm), privacy: .public)")
                if perm == .notDetermined {
                    self.permissions.requestMicrophone()
                } else {
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

        // 音频采集订阅。effective = enabled && mic granted && !music && !锁屏暂停。
        // music 在播 → 整体暂停采集（pauseOnMusicApp；关闭时 musicDetected 恒 false）。
        // 锁屏 且 recordAudioWhileLocked 关 → 暂停（解锁后 sink 重评估自动恢复）。
        Publishers.CombineLatest4(
            settings.$audioCaptureEnabled,
            permissions.$microphone,
            musicMonitor.$musicDetected,
            screenLockMonitor.$screenLocked
        )
            .map { [logger] enabled, perm, music, locked in
                let lockPause = locked && !ConfigStore.shared.privacy.recordAudioWhileLocked
                let effective = !music && !lockPause && perm.isGranted && enabled
                logger.notice("audio sink: enabled=\(enabled, privacy: .public) micPerm=\(perm.isGranted, privacy: .public) music=\(music, privacy: .public) lockPause=\(lockPause, privacy: .public) → effective=\(effective, privacy: .public)")
                return effective
            }
            .removeDuplicates()
            .sink { [weak self] effective in
                self?.applyAudioCapture(enabled: effective)
            }
            .store(in: &settingsCancellables)

        // 系统音频订阅。系统音频也需要 microphone 权限（CATapDescription 路径）。
        Publishers.CombineLatest4(
            settings.$systemAudioCaptureEnabled,
            permissions.$microphone,
            musicMonitor.$musicDetected,
            screenLockMonitor.$screenLocked
        )
            .map { enabled, perm, music, locked in
                if music { return false }
                if locked && !ConfigStore.shared.privacy.recordAudioWhileLocked { return false }
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
        observePreferredInputDevice()

        // 屏幕采集功耗档位(Settings → Screen Capture → Power mode)。三个触发源:
        //   ① powerWatcher.states:插拔电源 / 电量变化(IOKit 事件)
        //   ② NSProcessInfoPowerStateDidChange:系统低电量模式开关
        //   ③ ConfigStore.capture.system.powerMode:用户在 UI 改档位
        // 任一变化都重算 profile,变了才推给 coordinator。
        startPowerProfileSync()

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

    /// applyTypingCapture 是不是被启动时第一次调过 —— 首次调=启动 emission
    /// 不 request 权限,之后=用户主动 toggle 才 request。
    private var typingSinkSeenInitial = false

    private func applyTypingCapture(enabled: Bool) {
        let userInitiated = typingSinkSeenInitial
        typingSinkSeenInitial = true
        if enabled {
            // 打字采集需要 Accessibility 权限。**仅在用户主动 toggle 时**才
            // request + 引导,跟 screen / audio sink 同款逻辑。启动初始调
            // 静默(observer 自己 AX 门禁挡着,没授权也不会瞎跑)。
            if permissions.accessibility != .granted, userInitiated {
                logger.info("typing toggled on by user, accessibility not granted — requesting + guiding")
                permissions.requestAccessibility()
                confirmThenOpenSettings(
                    title: "Accessibility Permission Needed",
                    body: "My Portrait needs Accessibility access to capture your typing. "
                        + "Open System Settings to grant it?",
                    perm: .accessibility
                )
            }
            // observer.start() 照常 —— AX 没授就 idle,有授就跑。
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
        coordinator.setPauseCaptureList(apps: p.pauseCaptureApps, urls: p.pauseCaptureUrls)
        Task { await coordinator.setIgnoreIncognito(p.ignoreIncognito) }
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
            _ = store.privacy.ignoreIncognito
            _ = store.privacy.pauseCaptureApps
            _ = store.privacy.pauseCaptureUrls
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pushIgnoreRules()
                self.observeIgnoreRules()
            }
        }
    }

    /// 用户在 Settings 改了锁定的输入设备 UID → 跑步中重启 AudioCaptureService
    /// 重新绑定。withObservationTracking 一次性,onChange 后递归重订阅。
    private func observePreferredInputDevice() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.capture.audio.preferredInputDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.audio.restartIfRunning()
                self.observePreferredInputDevice()
            }
        }
    }

    // MARK: - 功耗档位

    /// 起 powerWatcher.states 订阅 + 低电量通知 + powerMode 设置监听,
    /// 任一信号触发就重算并应用 profile。
    private func startPowerProfileSync() {
        // ① 电源/电量变化(PowerWatcher 启动时也会立刻 yield 一次 baseline)。
        powerProfileTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.powerWatcher.states {
                await MainActor.run { self.recomputePowerProfile() }
            }
        }
        // ② 系统低电量模式开关。
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputePowerProfile() }
        }
        // ③ 用户在 UI 改 powerMode。
        observePowerMode()
    }

    /// 监听 ConfigStore.capture.system.powerMode,变化时重算(仿 observeIgnoreRules)。
    private func observePowerMode() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.current.capture.system.powerMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recomputePowerProfile()
                self.observePowerMode()
            }
        }
    }

    /// 读 用户档位 + 系统快照 → PowerProfile.resolve → 变了才推给 coordinator。
    private func recomputePowerProfile() {
        let raw = ConfigStore.shared.current.capture.system.powerMode
        let mode = PowerMode(rawValue: raw) ?? .auto
        let profile = PowerProfile.resolve(userMode: mode, snapshot: PowerMonitor.snapshot())
        guard profile != lastPowerProfile else { return }
        lastPowerProfile = profile
        Task { await coordinator.applyPowerProfile(profile) }
    }

    /// AppDelegate 在 `applicationWillTerminate` 调，停所有子系统。
    func stopManagedLifecycle() async {
        powerProfileTask?.cancel()
        screenLockMonitor.stop()
        await coordinator.stop()
        await audio.stop()
        await systemAudio.stop()
        await compactor.stop()
        await transcriber.stop()
        await retentionWorker.stop()
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
        // 通知 StallDetector:用户关 toggle 后无帧是预期。
        IntentionalPauseState.shared.captureDisabled = !enabled
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
