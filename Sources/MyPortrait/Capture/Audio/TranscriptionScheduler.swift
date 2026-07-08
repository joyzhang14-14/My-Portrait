import Foundation
import os.log

/// 串起 AudioCaptureService → VAD → DB → WhisperKit 三件事。
///
/// 两条独立循环：
///
///   A. Ingest loop：订阅 audio.segmentEvents
///      每个段：
///        1. VADSegmenter.analyze
///        2. .discard → 删 wav + meta，返回
///        3. .keep   → DB.insertAudioChunk(status=pending)
///
///   B. Transcribe loop：60 秒一轮（兜底防漏，轻量），插电时干活
///        - 电池 → sleep
///        - 查 DB.pendingAudioChunks(limit=N)
///        - 每个 chunk：WhisperKit.transcribe → DB.insertTranscription → 更新 status=done
///        - 异常 → status=failed
///
/// 设计抄设计文档第二节"延迟转录策略"：移动场景只录音（VAD 入库），AC 接通才烧
/// CPU/Neural-Engine 转录。中断恢复以"段"为单位（最坏丢一段未完成转录）。
actor TranscriptionScheduler {

    private let db: PortraitDB
    private let audio: AudioCaptureService
    private let systemAudio: SystemAudioCaptureService
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "transcribe")

    private let vad: VADSegmenter
    private let whisper: WhisperKitWrapper
    private let qwen: Qwen3ASRWrapper
    private let power: PowerWatcher
    private let speaker: any SpeakerDiarizer

    /// 后台兜底 poll 间隔。已有 PowerWatcher 事件驱动唤醒 +
    /// 新段事件直接驱动（ingest 成功入库后评估一轮），poll 仅作为"防漏"
    /// 兜底，故拉长到 60s（vs 之前 5s）。
    private let fallbackPollSeconds: TimeInterval = 60

    /// 攒批闸门:模型装载开销(GB 级读盘 + CoreML 编译)远超单段推理,
    /// 稳态录音下「每 60s 装载 → 转 1-2 段 → 卸载」是纯浪费。改成:
    /// 攒够 batchMinChunks 段,**或**最老的 pending 已等了 batchMaxWaitMs,
    /// 才真正开一轮 drain;poll / 新段事件 / 电源事件都按这个闸门评估。
    /// 代价:转录延迟最坏 ~5min + poll 间隔,换装载次数 ÷N(模型用完即卸,
    /// 不常驻内存)。阈值远低于 StallDetector 的 backlog 告警线(20 段/20min),
    /// 不会误报。
    private let batchMinChunks = 5
    private let batchMaxWaitMs: Int64 = 5 * 60_000
    /// 每轮 poll 从 DB 拉多少 chunk。设计文档要求"限并发数 1-2"。
    ///
    /// 注意：调用方 for 循环串行 await transcribeOne，**实际并发恒为 1**。
    /// 这个 limit 控制的是"一次 poll 取多少个进行串行处理"。设为 2 让 scheduler
    /// 有一个小 lookahead 窗口，但在 battery 切换时也只浪费 1 个尚未开始的段。
    ///
    /// 若未来要真正并发 2，必须先把 WhisperKitWrapper 从"@unchecked Sendable +
    /// serial-call contract"改为 actor + 内部排队，否则会 data race。
    private let queueBatchLimit: Int = 2

    private var ingestMicTask: Task<Void, Never>?
    private var ingestSysTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var dedupHistoryTask: Task<Void, Never>?
    /// drain 重入守卫 —— 同一时刻只允许一轮连续转录。WhisperKitWrapper 是
    /// serial-call 契约,并发转录会 data race(见 queueBatchLimit 注释)。
    private var isDraining = false

    init(
        db: PortraitDB,
        audio: AudioCaptureService,
        systemAudio: SystemAudioCaptureService,
        reporter: UnimplementedReporter,
        power: PowerWatcher,
        vad: VADSegmenter = VADSegmenter(),
        whisper: WhisperKitWrapper = WhisperKitWrapper(),
        qwen: Qwen3ASRWrapper = Qwen3ASRWrapper(),
        speaker: any SpeakerDiarizer = NoopSpeakerDiarizer()
    ) {
        self.db = db
        self.audio = audio
        self.systemAudio = systemAudio
        self.reporter = reporter
        self.power = power
        self.vad = vad
        self.whisper = whisper
        self.qwen = qwen
        self.speaker = speaker
    }

    func start() async {
        guard ingestMicTask == nil else { return }

        // 订阅麦克风段流。注意 segmentEvents() 是 async 方法（每个 service
        // 在 start 后才有 VADRecorder；这里调一次拿当前实例的流）。
        let micStream = await audio.segmentEvents()
        ingestMicTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in micStream {
                await self?.ingest(segment: segment)
            }
        }

        // 订阅系统音频段流。两路独立，但走同一个 ingest（device 字段区分来源）。
        let sysStream = await systemAudio.segmentEvents()
        ingestSysTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in sysStream {
                await self?.ingest(segment: segment)
            }
        }

        // 兜底循环：每 fallbackPollSeconds 检查一次队列，防漏。
        let fallbackNs = UInt64(fallbackPollSeconds * 1_000_000_000)
        transcribeTask = Task.detached(priority: .utility) { [weak self] in
            // 60s 冷启动延迟（与 CompactionWorker 错峰）。
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            while !Task.isCancelled {
                await self?.processQueueOnce()
                try? await Task.sleep(nanoseconds: fallbackNs)
            }
        }

        // 事件驱动主路：power 状态变化（如 battery → AC）立刻唤起一轮处理。
        let powerStream = power.subscribe()
        powerTask = Task.detached(priority: .utility) { [weak self] in
            for await _ in powerStream {
                guard let self else { break }
                await self.processQueueOnce()
            }
        }

        // 健康度起点。StallDetector 用 uptime > 120s 跳 warmup 误报。
        await AudioMetrics.shared.markStarted()
        logger.info("TranscriptionScheduler started (event-driven via PowerWatcher + 60s fallback)")

        // 一次性清理跨通道去重上线前积累的历史双份(外放回录)。120s 冷启动
        // 延迟避开启动高峰;纯 DB 读删,不碰模型,与 drain 循环并发安全
        //(双方都只删 mic 重复份)。
        dedupHistoryTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await self?.dedupHistoryOnce()
        }
    }

    func stop() {
        ingestMicTask?.cancel()
        ingestSysTask?.cancel()
        transcribeTask?.cancel()
        powerTask?.cancel()
        dedupHistoryTask?.cancel()
        ingestMicTask = nil
        ingestSysTask = nil
        transcribeTask = nil
        powerTask = nil
        dedupHistoryTask = nil
        // ⚠️ drain 在飞时不能 unload:WhisperKit/Qwen wrapper 是「调用方保证串行」
        // 契约,而 transcribeOne 挂起在 transcribeSamples 时 actor 空闲,stop()
        // 可以插进来 —— unload 从另一线程把 pipe/model 置 nil,落在 transcribe
        // 的同步窗口(预处理 FFT + 读 tokenizer 到 pipe!.transcribe 之间)就是
        // 强解包崩溃(插电积压转录时退出 app 即触发)。在飞 drain 结束时
        // processQueueOnce 的收尾路径自己会串行 unload,这里只管没 drain 的情况。
        if !isDraining {
            whisper.unload()
            qwen.unload()
        }
        // 任务取消后不会再有 processQueueOnce 来 refresh —— 这里显式放行睡眠(两 owner)。
        Task { @MainActor in
            KeepAwakeAssertion.shared.set(false, owner: "transcription")
            SleepHelperClient.shared.setKeepAwake(false, owner: "transcription")
        }
        logger.info("TranscriptionScheduler stopped")
    }

    // MARK: - A. Ingest

    private func ingest(segment: AudioSegmentEvent) async {
        let decision = vad.analyze(wavPath: segment.wavPath)

        if decision.action == .discard {
            // 静音段：删 wav + meta，DB 不入。
            try? FileManager.default.removeItem(atPath: segment.wavPath)
            try? FileManager.default.removeItem(atPath: segment.metaPath)
            logger.debug("VAD discard ratio=\(decision.speechRatio, format: .fixed(precision: 3)) path=\(segment.wavPath, privacy: .public)")
            return
        }

        let record = AudioChunkRecord(
            id: nil,
            filePath: segment.wavPath,
            recordedAtMs: segment.recordedAtMs,
            durationS: segment.durationS,
            device: segment.device,                              // 段自带的设备标签
            isInput: segment.device == "default_microphone",
            status: .pending
        )
        do {
            _ = try await db.insertAudioChunk(record)
            // 健康度埋点:成功入库一段(VAD 已过)。chunksProduced > 0 即说明
            // 音频管线在真正出活,audioNeverCaptured stall 不会误报。
            await AudioMetrics.shared.recordChunkProduced()
            // 事件驱动:新段入库立刻评估一轮(攒批闸门决定真开跑还是再等)。
            // fire-and-forget —— drain 可能跑几分钟,绝不能阻塞 ingest 流。
            Task { await self.processQueueOnce() }
        } catch {
            logger.error("DB insertAudioChunk failed (segment will be re-tried next launch via filesystem scan): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - B. Transcribe

    /// 立刻重评一轮(读最新设置 + 决定转/停/更新 "Paused on battery")。给 Services 在
    /// transcriptionPowerMode 等设置变化时调 —— 否则用户改档后要等最多 60s 的兜底 poll 才生效。
    func reevaluate() async {
        await processQueueOnce()
    }

    /// 攒批闸门(见 batchMinChunks 注释)。查询失败 → 放行,宁可多装载一次
    /// 模型,不能让队列积压。
    private func drainGateOpen() async -> Bool {
        guard let stats = try? await db.audioBacklogStats() else { return true }
        guard stats.pendingCount > 0 else { return false }
        if stats.pendingCount >= batchMinChunks { return true }
        if let oldest = stats.oldestRecordedAtMs {
            let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - oldest
            if ageMs >= batchMaxWaitMs { return true }
        }
        return false
    }

    private func processQueueOnce() async {
        // 重入守卫:tight drain 期间(可能跑几十分钟)power 事件 / 60s poll 会再次
        // 触发本函数 —— 同一时刻只允许一轮,否则并发转录 data race。
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        // 转录电源档位:决定「转 / 停」+ 隐含防睡方式(开盖 IOPMAssertion / 合盖 helper)。
        let mode = await MainActor.run {
            ConfigStore.shared.current.capture.audio.transcriptionPowerMode
        }
        // 当前电源状态下该不该跑(实时读 PowerMonitor —— 合盖 / 掉电会实时变):
        // always=除「电池+合盖」(机器本就睡)都跑;pluggedIn=需插电;
        // pluggedInLidClosed=需插电+合盖。
        func powerShouldRun() -> Bool {
            switch mode {
            case .always:             return PowerMonitor.isOnAC || !PowerMonitor.isLidClosed
            case .pluggedIn:          return PowerMonitor.isOnAC
            case .pluggedInLidClosed: return PowerMonitor.isOnAC && PowerMonitor.isLidClosed
            }
        }

        // 无进展保护:某个 chunk 因 DB 写失败(如磁盘满)一直标不掉 pending 时,tight
        // 循环会卡在队首空转(每轮还白跑一次模型 + 不放睡眠)。记住上轮队首 id,没变
        // 就停,交给下次 tick / 修盘后重试。
        var lastFrontId: Int64? = nil

        // 攒批闸门只在 drain 开始前评估一次;开跑后把本轮捞干净(中途不再
        // 因为"批又变小了"停手,模型已经装载,多转几段才划算)。
        var gateEvaluated = false

        // 连续转录直到队列清空 —— 不再「转 2 个睡 60s」。60s poll 退化成纯兜底:
        // 只在本轮 drain 结束后捡那期间 ingest 进来的新段。积压一口气在本调用清完。
        while !Task.isCancelled {
            // 引擎 disabled → 不消费队列:chunk 留在 pending,等用户重新启用引擎
            // 后由 60s poll 接着转。旧行为会把每个 chunk 跑一遍空转录
            //(transcribeSamples 返回 "")然后标 done —— 转录机会永久丢失。
            // **必须每轮活读**(不能像 acOnly 那样进循环前读一次):tight drain
            // 可跑几十分钟,重积压烧 CPU 时正是用户去关转录的时刻;期间新一轮
            // processQueueOnce 被 isDraining 守卫挡在门外,入口 gate 执行不到,
            // 只有这里能看到中途切换。
            let engine = await MainActor.run { ConfigStore.shared.current.capture.audio.engine }
            if engine == "disabled" {
                whisper.unload()
                qwen.unload()
                await MainActor.run {
                    IntentionalPauseState.shared.audioTranscriptionPaused = true
                    KeepAwakeAssertion.shared.set(false, owner: "transcription")
                    SleepHelperClient.shared.setKeepAwake(false, owner: "transcription")
                }
                return
            }
            // 电源档位不满足(电池 / 开盖但要求合盖等)→ 不转录:释放模型 + 放行睡眠 +
            // 标记 intentional pause(让 StallDetector 知道 pending 堆积是故意的,不报 backlog)。
            if !powerShouldRun() {
                whisper.unload()
                qwen.unload()
                await MainActor.run {
                    IntentionalPauseState.shared.audioTranscriptionPaused = true
                    KeepAwakeAssertion.shared.set(false, owner: "transcription")
                    SleepHelperClient.shared.setKeepAwake(false, owner: "transcription")
                }
                return
            }
            await MainActor.run { IntentionalPauseState.shared.audioTranscriptionPaused = false }

            // 攒批闸门(放在 engine/电源检查之后:那两个分支的暂停状态标记
            // 语义保持原样;闸门关闭只是推迟,不是暂停)。
            if !gateEvaluated {
                gateEvaluated = true
                guard await drainGateOpen() else { return }
            }

            let chunks: [AudioChunkRecord]
            do {
                chunks = try await db.pendingAudioChunks(limit: queueBatchLimit)
            } catch {
                logger.warning("pendingAudioChunks failed: \(String(describing: error), privacy: .public)")
                break
            }
            guard !chunks.isEmpty else { break }   // 清空 → 退出循环

            let frontId = chunks.first?.id
            if frontId == lastFrontId {
                logger.warning("drain stalled on chunk id \(frontId ?? -1, privacy: .public) (DB write failing? disk full?), stopping pass")
                break
            }
            lastFrontId = frontId

            // 有积压 → 按电源状态防睡:插电开盖用 IOPMAssertion 挡空闲睡眠,
            // 插电合盖用 SleepHelper(pmset)保持运行(两 owner 各自独立)。
            await MainActor.run {
                let ac = PowerMonitor.isOnAC, lid = PowerMonitor.isLidClosed
                KeepAwakeAssertion.shared.set(ac && !lid, owner: "transcription")
                SleepHelperClient.shared.setKeepAwake(ac && lid, owner: "transcription")
            }

            for chunk in chunks {
                if Task.isCancelled { break }
                // 中途电源状态变得不满足档位(掉电 / 开盖)→ 停批;回 while 顶
                // 命中 !powerShouldRun 分支收尾(释放防睡 + 标 pause)。
                if !powerShouldRun() { break }
                await transcribeOne(chunk: chunk)
            }
        }

        // 退出 drain(清空 / 取消 / 出错 / 无进展)→ 释放模型 + 放行系统睡眠(两 owner)。
        whisper.unload()
        qwen.unload()
        await MainActor.run {
            KeepAwakeAssertion.shared.set(false, owner: "transcription")
            SleepHelperClient.shared.setKeepAwake(false, owner: "transcription")
        }
    }

    /// 转录设置快照（引擎 + 语言 + 词汇 + 云引擎凭据）。
    private struct TranscribeSettings: Sendable {
        let engine: String
        let language: String?
        let vocabulary: [String]
        let filterMusic: Bool
        let deepgramKey: String
        let customEndpoint: String
        let customModel: String
        let customKey: String
    }

    /// 读设置里的转录配置（含云引擎凭据，从 SecretStore 解出）。
    private static func transcriptionConfig() async -> TranscribeSettings {
        await MainActor.run {
            let a = ConfigStore.shared.current.capture.audio
            // 多选语言(来自 CaptureView):恰好选 1 种 → 用作模型语言提示;0 种或多种
            // (如中英双语)→ nil = 自动检测。**每个 engine 用独立字段** ——
            // 切 engine 不应该把另一个 engine 的语言选择带过去。
            let langSource: [String] = {
                switch a.engine {
                case "qwen":     return a.qwenLanguages
                case "deepgram": return a.deepgramLanguages
                case "custom":   return a.customLanguages
                default:         return a.languages   // whisper(老字段名)
                }
            }()
            let langs = langSource.filter { !$0.isEmpty }
            let lang: String? = langs.count == 1 ? langs[0] : nil
            func secret(_ ref: String) -> String {
                guard !ref.isEmpty, let d = SecretStore.shared.get(ref) else { return "" }
                return String(data: d, encoding: .utf8) ?? ""
            }
            return TranscribeSettings(
                engine: a.engine,
                language: lang,
                vocabulary: a.customVocabulary,
                filterMusic: a.filterMusic,
                deepgramKey: secret(a.deepgramApiKeyRef),
                customEndpoint: a.customEndpoint,
                customModel: a.customModel,
                customKey: secret(a.customApiKeyRef)
            )
        }
    }

    /// 按设置里选的引擎转录一段样本。disabled → 空串。
    private func transcribeSamples(_ samples: [Float], _ s: TranscribeSettings) async throws -> String {
        switch s.engine {
        case "deepgram":
            // 云端引擎自己不做预处理，在这里补上（本地 whisper 在 wrapper 内部做）。
            let processed = AudioPreprocessor.process(samples, filterMusic: s.filterMusic)
            return try await CloudTranscriber.deepgram(
                samples: processed, apiKey: s.deepgramKey, language: s.language)
        case "custom":
            let processed = AudioPreprocessor.process(samples, filterMusic: s.filterMusic)
            return try await CloudTranscriber.openAICompatible(
                samples: processed, endpoint: s.customEndpoint, model: s.customModel,
                apiKey: s.customKey, language: s.language, vocabulary: s.vocabulary)
        case "qwen":
            // Qwen3-ASR（本地，MLX）。预处理在 wrapper 内部做，跟 whisper 一致。
            return try await qwen.transcribe(
                samples: samples, language: s.language,
                vocabulary: s.vocabulary, filterMusic: s.filterMusic)
        case "disabled":
            return ""
        default:   // whisper（本地）
            return try await whisper.transcribe(
                samples: samples, language: s.language,
                vocabulary: s.vocabulary, filterMusic: s.filterMusic)
        }
    }

    private func transcribeOne(chunk: AudioChunkRecord) async {
        guard let chunkId = chunk.id else { return }

        // 1. 标 in_progress
        try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .inProgress)

        let settings = await Self.transcriptionConfig()

        // 2. 说话人分离：把 chunk 切成若干说话人语音段（未启用 / 模型未就绪 → 空）。
        let segments = await speaker.diarize(wavPath: chunk.filePath, isInput: chunk.isInput)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [TranscriptionRecord] = []

        if segments.isEmpty {
            // 退化路径：整段一次转录，无说话人归属。
            guard let samples = AudioWAV.readSamples(path: chunk.filePath) else {
                // 文件不存在 / 读不出(损坏)—— 都没法转,标 done 退出队列(**不重试**,
                // 文件不会自己回来 / 修复)。否则缺文件的 chunk 会永远卡在 pending。
                logger.warning("audio chunk unreadable (missing/corrupt), marking done: \(chunk.filePath, privacy: .public)")
                try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
                return
            }
            let text: String
            do {
                text = try await transcribeSamples(samples, settings)
            } catch {
                logger.error("transcribe failed for \(chunk.filePath, privacy: .public): \(String(describing: error), privacy: .public)")
                DiagLog.error("transcribe.failed", ctx: [
                    "chunkId":   chunkId,
                    "path":      (chunk.filePath as NSString).lastPathComponent,
                    "durationS": chunk.durationS,
                    "device":    chunk.device,
                    "engine":    settings.engine,
                    "err":       String(describing: error),
                ])
                try? await db.recordAudioChunkFailure(chunkId: chunkId)
                return
            }
            if !text.isEmpty {
                records.append(TranscriptionRecord(
                    audioChunkId: chunkId, startS: 0, endS: chunk.durationS,
                    text: text, speakerId: nil, engine: settings.engine, transcribedAtMs: nowMs
                ))
            }
        } else {
            // 完整路径：逐说话人段单独转录，每段一行。
            for seg in segments {
                let text: String
                do {
                    text = try await transcribeSamples(seg.samples, settings)
                } catch {
                    logger.error("transcribe (segment) failed for \(chunk.filePath, privacy: .public): \(String(describing: error), privacy: .public)")
                    try? await db.recordAudioChunkFailure(chunkId: chunkId)
                    return
                }
                guard !text.isEmpty else { continue }
                records.append(TranscriptionRecord(
                    audioChunkId: chunkId, startS: seg.startS, endS: seg.endS,
                    text: text, speakerId: seg.speakerId.map { Int($0) },
                    engine: settings.engine, transcribedAtMs: nowMs
                ))
            }
        }

        // 全静音 / 无文本 → 仍标 done，避免反复重试。
        guard !records.isEmpty else {
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
            return
        }

        // 2.5 跨通道去重:外放通话时对方声音从扬声器出来,loopback 数字直录一份、
        //     mic 隔空拾取又一份 → 同句双行。mic 段撞已落库的 loopback 段 → 丢
        //     mic 段;loopback 段撞已落库的 mic 段 → 删那些 mic 行、本段照常入库
        //     (loopback 直录质量好,保留它)。详见 TranscriptDeduper。
        records = await dedupCrossChannel(chunk: chunk, records: records)
        guard !records.isEmpty else {
            // mic 份全部是 loopback 已录内容 → 本 chunk 不留文本,标 done。
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
            return
        }

        // 3. 写转录行到 DB（每段一行），**成功后才写 sidecar JSON**。
        //    顺序很重要:隐私删除(deleteAfter)会删掉窗口内 audio_chunks 行,
        //    外键让迟到的 insertTranscription 失败 —— sidecar 若先写,刚被
        //    用户删除的敏感全文会以 .transcript.json 复活在盘上。DB 是真相
        //    镜像,sidecar 跟着 DB 走:insert 被拒就什么都不留。
        do {
            for record in records {
                try await db.insertTranscription(record)
            }
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
            let fullText = records.map(\.text).joined(separator: " ")
            writeTranscriptSidecar(wavPath: chunk.filePath, text: fullText, chunk: chunk, engine: settings.engine, transcribedAtMs: nowMs)
            // 健康度埋点:成功转录并落 DB。Driver 比 chunksProduced 跟 chunksTranscribed
            // 拉差,持续走宽 → audio 路径正常。
            await AudioMetrics.shared.recordChunkTranscribed()
        } catch {
            logger.error("DB insertTranscription failed: \(String(describing: error), privacy: .public)")
            try? await db.recordAudioChunkFailure(chunkId: chunkId)
        }
    }

    /// 跨通道去重(transcribeOne 的 2.5 步)。查询/删除失败 → 原样放行,
    /// 宁可留重复也不丢转录。
    ///
    /// 注:被删 mic 行所属 chunk 的 .transcript.json sidecar 不回写 ——
    /// sidecar 只是调试镜像,DB 才是真相。
    private func dedupCrossChannel(
        chunk: AudioChunkRecord,
        records: [TranscriptionRecord]
    ) async -> [TranscriptionRecord] {
        let chunkEndMs = chunk.recordedAtMs + Int64(chunk.durationS * 1000)
        let newSegs = records.map { rec in
            TranscriptDeduper.Segment(
                id: nil,
                absStartMs: chunk.recordedAtMs + Int64(rec.startS * 1000),
                absEndMs: chunk.recordedAtMs + Int64(rec.endS * 1000),
                speakerId: rec.speakerId,
                text: rec.text
            )
        }
        let candidates: [TranscriptDeduper.Segment]
        do {
            candidates = try await db.transcriptionsForDedup(
                isInput: !chunk.isInput,
                fromMs: chunk.recordedAtMs - TranscriptDeduper.lookbackMs,
                toMs: chunkEndMs + TranscriptDeduper.slackMs
            )
        } catch {
            logger.warning("cross-channel dedup query failed, keeping all segments: \(String(describing: error), privacy: .public)")
            return records
        }
        guard !candidates.isEmpty else { return records }

        if chunk.isInput {
            // mic 新段:对上 loopback 已有段 → 丢弃。
            var kept: [TranscriptionRecord] = []
            for (i, rec) in records.enumerated() {
                if candidates.contains(where: { TranscriptDeduper.isDuplicate(mic: newSegs[i], loopback: $0) }) {
                    continue
                }
                kept.append(rec)
            }
            let dropped = records.count - kept.count
            if dropped > 0 {
                logger.info("cross-channel dedup: dropped \(dropped, privacy: .public) mic segment(s) already captured via system_loopback")
            }
            return kept
        } else {
            // loopback 新段:对上 mic 已有段 → 删 mic 行,本段照常入库。
            var doomedIds = Set<Int64>()
            for seg in newSegs {
                for cand in candidates where TranscriptDeduper.isDuplicate(mic: cand, loopback: seg) {
                    if let id = cand.id { doomedIds.insert(id) }
                }
            }
            if !doomedIds.isEmpty {
                do {
                    try await db.deleteTranscriptions(ids: Array(doomedIds))
                    logger.info("cross-channel dedup: deleted \(doomedIds.count, privacy: .public) mic segment(s) superseded by system_loopback")
                } catch {
                    logger.warning("cross-channel dedup delete failed (duplicates remain): \(String(describing: error), privacy: .public)")
                }
            }
            return records
        }
    }

    // MARK: - 历史跨通道去重(一次性)

    /// 成功跑完整趟后置 true;中途取消/出错不置,下次启动重扫
    ///(已删的行不会重删,重扫是幂等的)。
    private static let historyDedupDoneKey = "transcriptCrossChannelDedupV1Done"
    /// 每窗 24h(按 chunk recorded_at_ms 分窗),窗间歇 100ms 让出 DB。
    private static let historyDedupWindowMs: Int64 = 24 * 3600 * 1000

    /// 扫全库,删「与 loopback 段重复的 mic 段」—— 跨通道去重上线前积累的
    /// 外放回录双份。逐窗处理,内存里同时只有一天的段。
    private func dedupHistoryOnce() async {
        // 启动任务的 `try? await Task.sleep` 会吞掉 stop() 的取消(CancellationError
        // 被 try? 吃掉后任务继续往下走)—— 这里显式拦住,别在退出路径上白跑
        // actor hop + DB 查询(查询被取消还会打误导性 warning)。
        if Task.isCancelled { return }
        guard !UserDefaults.standard.bool(forKey: Self.historyDedupDoneKey) else { return }

        let range: (minMs: Int64, maxMs: Int64)?
        do {
            range = try await db.audioChunkTimeRangeMs()
        } catch {
            logger.warning("history dedup: time range query failed, will retry next launch: \(String(describing: error), privacy: .public)")
            return
        }
        guard let range else {
            // 空库:没历史可清,直接记完成。
            UserDefaults.standard.set(true, forKey: Self.historyDedupDoneKey)
            return
        }

        var lo = range.minMs
        var totalDeleted = 0
        while lo <= range.maxMs {
            if Task.isCancelled { return }   // 不标完成,下次启动续扫
            let hi = lo + Self.historyDedupWindowMs
            do {
                let mic = try await db.transcriptionsForDedup(isInput: true, fromMs: lo, toMs: hi - 1)
                if !mic.isEmpty {
                    // loopback 候选两侧各放宽 lookback:窗边界的 mic chunk
                    // 的对侧 chunk 可能落在窗外。
                    let loopback = try await db.transcriptionsForDedup(
                        isInput: false,
                        fromMs: lo - TranscriptDeduper.lookbackMs,
                        toMs: hi + TranscriptDeduper.lookbackMs
                    )
                    let doomed = TranscriptDeduper.duplicateMicIds(mic: mic, loopback: loopback)
                    if !doomed.isEmpty {
                        try await db.deleteTranscriptions(ids: doomed)
                        totalDeleted += doomed.count
                    }
                }
            } catch {
                logger.warning("history dedup: window failed, aborting (retry next launch): \(String(describing: error), privacy: .public)")
                return
            }
            lo = hi
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        UserDefaults.standard.set(true, forKey: Self.historyDedupDoneKey)
        logger.info("history cross-channel dedup complete: deleted \(totalDeleted, privacy: .public) duplicate mic segment(s)")
    }

    /// 写 `seg_<ts>.transcript.json` 到 wav 同目录。
    /// 失败只 log（DB 已经记了真相镜像，sidecar 丢了无大碍但要警告）。
    private func writeTranscriptSidecar(
        wavPath: String,
        text: String,
        chunk: AudioChunkRecord,
        engine: String,
        transcribedAtMs: Int64
    ) {
        let wavURL = URL(fileURLWithPath: wavPath)
        // 去掉 ".wav" 加 ".transcript.json"。
        let base = wavURL.deletingPathExtension()
        let sidecar = base.appendingPathExtension("transcript.json")

        let payload: [String: Any] = [
            "wav_path": wavPath,
            "recorded_at_ms": chunk.recordedAtMs,
            "duration_s": chunk.durationS,
            "device": chunk.device,
            "engine": engine,
            "transcribed_at_ms": transcribedAtMs,
            "text": text,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: sidecar, options: .atomic)
        } catch {
            logger.warning("transcript sidecar write failed for \(sidecar.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

}
