import Foundation
import os.log

// TODO(Phase 4.1): audio_transcriptions embedding pipeline.
// Schema v4 已给 audio_transcriptions 预留 embedding + embedding_model 列 +
// idx_transcriptions_embedding_null 部分索引（Schema.swift:148-158），本 worker
// 只处理 frames，HybridSearchEngine.searchTranscriptions 走 FTS-only。接入时
// 复制 framesNeedingEmbedding / setFrameEmbedding 对照 transcription 版本即可。

/// 后台 worker：把 frames.full_text 没 embed 的行批量喂给 embedder → 存 BLOB。
///
/// 触发：
///   - 启动后 30s 跑一次（清积压；首次启动 bge-m3 模型还在下载，整轮放弃下次再来）
///   - 之后每 60s 一轮，回灌期间持续吃积压；积压清完后基本空转（DB 索引 0 成本）
///
/// embedder 抛错时（首次模型未下完 / 推理 OOM）整轮放弃 + 下一轮再试。
/// 不无限重试 —— 模型加载失败重试 100 次也救不回来，让 reporter 报红点提醒。
///
/// 批量策略：一轮拉 `batchSize` 个 id，再 chunk 成 `embedChunkSize` 一组喂给
/// `embedder.embedBatch`。bge-m3 一次 forward 32-64 句比逐句快 ~10×（GPU 利用率）。
///
/// 数据量预期：~7000 帧历史回灌 + 1000 帧/天增量。M 系芯片上 bge-m3 batch=32
/// 约 100ms / batch，7000 / 32 ≈ 220 batch × 100ms ≈ 22 秒纯推理。加 DB 写入 / IO
/// 实际 ~3-5 分钟回完整段历史。
actor EmbeddingWorker {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "embed")
    private let db: PortraitDB
    private let embedder: any VectorEmbedder

    private let coldStartDelaySeconds: TimeInterval = 30
    private let pollIntervalSeconds: TimeInterval = 60     // 1 分钟一轮，回灌期紧凑
    /// 单轮拉多少行：太大 DB 一次扫描慢；太小一轮干完空转过早。
    private let batchSize = 256
    /// 一次喂给 embedder.embedBatch 的子批：bge-m3 + M 系 GPU 的甜蜜区。
    private let embedChunkSize = 32

    private var task: Task<Void, Never>?

    init(db: PortraitDB, embedder: any VectorEmbedder) {
        self.db = db
        self.embedder = embedder
    }

    func start() {
        guard task == nil else { return }
        let coldNs = UInt64(coldStartDelaySeconds * 1_000_000_000)
        let pollNs = UInt64(pollIntervalSeconds * 1_000_000_000)
        // 注意：**不能用 `.background`**。MLX-Swift 的 scheduler thread 在 `.background`
        // QoS context 下创建会 throw → libc++abi terminate（实测 macOS 26）。
        // `.utility` 跟 `.background` 在 CPU 让度上区别极小，但 MLX 能正常起。
        task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: coldNs)
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(nanoseconds: pollNs)
            }
        }
        logger.info("EmbeddingWorker started (batch=\(self.batchSize), chunk=\(self.embedChunkSize))")
    }

    func stop() {
        task?.cancel()
        task = nil
        logger.info("EmbeddingWorker stopped")
    }

    /// 手动跑一轮（调试 / 测试用）。
    /// 一轮做两件事：先吃 frames 积压，再吃 transcriptions 积压。两个独立，
    /// frames 失败不阻塞 transcriptions（中间一次推理出错可能是模型 OOM，
    /// transcriptions 一组小得多，往往能继续）。
    func runOnce() async {
        // 设置里的语义索引开关（AI Models 页）。关掉 → 不 embed + 卸载 bge-m3。
        let indexEnabled = await MainActor.run {
            ConfigStore.shared.current.aiModels.semanticIndexEnabled
        }
        guard indexEnabled else {
            await embedder.unload()
            return
        }
        // 电池模式：不 embed（重活留给插电时），顺手卸载 bge-m3 释放 ~1.15GB 内存。
        // 与 TranscriptionScheduler 的 AC 门控一致。
        guard PowerMonitor.isOnAC else {
            await embedder.unload()
            return
        }
        let model = embedder.modelIdentifier
        await processFrames(model: model)
        if Task.isCancelled { return }
        await processTranscriptions(model: model)
    }

    private func processFrames(model: String) async {
        let ids: [Int64]
        do {
            ids = try await db.framesNeedingEmbedding(model: model, limit: batchSize)
        } catch {
            logger.warning("framesNeedingEmbedding failed: \(String(describing: error), privacy: .public)")
            return
        }
        if ids.isEmpty { return }

        let metas: [FrameMetadata]
        do {
            metas = try await db.framesByIds(ids)
        } catch {
            logger.warning("framesByIds failed: \(String(describing: error), privacy: .public)")
            return
        }
        let work: [(id: Int64, text: String)] = metas.compactMap { m in
            guard let t = m.fullText, !t.isEmpty else { return nil }
            return (m.id, t)
        }
        if work.isEmpty { return }

        let started = Date()
        logger.info("embedding \(work.count) frames in chunks of \(self.embedChunkSize)")

        var written = 0
        var index = 0
        while index < work.count {
            let end = min(index + embedChunkSize, work.count)
            let chunk = Array(work[index..<end])
            let vectors: [[Float]]
            do {
                vectors = try await embedder.embedBatch(chunk.map(\.text))
            } catch {
                logger.info("frames embedBatch failed at offset \(index)/\(work.count) — aborting round: \(String(describing: error), privacy: .public)")
                return
            }
            for (i, pair) in chunk.enumerated() {
                guard i < vectors.count else { break }
                var v = vectors[i]
                VectorMath.l2Normalize(&v)
                do {
                    try await db.setFrameEmbedding(frameId: pair.id, vector: v, model: model)
                    written += 1
                } catch {
                    logger.warning("setFrameEmbedding(\(pair.id)) failed: \(String(describing: error), privacy: .public)")
                }
            }
            index = end
            if Task.isCancelled { break }
        }

        let elapsed = Date().timeIntervalSince(started)
        logger.info("embedded \(written)/\(work.count) frames in \(elapsed, format: .fixed(precision: 1))s (\(Double(written) / max(elapsed, 0.001), format: .fixed(precision: 1)) frames/s)")
    }

    private func processTranscriptions(model: String) async {
        let ids: [Int64]
        do {
            ids = try await db.transcriptionsNeedingEmbedding(model: model, limit: batchSize)
        } catch {
            logger.warning("transcriptionsNeedingEmbedding failed: \(String(describing: error), privacy: .public)")
            return
        }
        if ids.isEmpty { return }

        let metas: [TranscriptionMetadata]
        do {
            metas = try await db.transcriptionsByIds(ids)
        } catch {
            logger.warning("transcriptionsByIds failed: \(String(describing: error), privacy: .public)")
            return
        }
        let work: [(id: Int64, text: String)] = metas.compactMap { t in
            guard !t.text.isEmpty else { return nil }
            return (t.id, t.text)
        }
        if work.isEmpty { return }

        let started = Date()
        logger.info("embedding \(work.count) transcriptions in chunks of \(self.embedChunkSize)")

        var written = 0
        var index = 0
        while index < work.count {
            let end = min(index + embedChunkSize, work.count)
            let chunk = Array(work[index..<end])
            let vectors: [[Float]]
            do {
                vectors = try await embedder.embedBatch(chunk.map(\.text))
            } catch {
                logger.info("transcriptions embedBatch failed at offset \(index)/\(work.count) — aborting: \(String(describing: error), privacy: .public)")
                return
            }
            for (i, pair) in chunk.enumerated() {
                guard i < vectors.count else { break }
                var v = vectors[i]
                VectorMath.l2Normalize(&v)
                do {
                    try await db.setTranscriptionEmbedding(transcriptionId: pair.id, vector: v, model: model)
                    written += 1
                } catch {
                    logger.warning("setTranscriptionEmbedding(\(pair.id)) failed: \(String(describing: error), privacy: .public)")
                }
            }
            index = end
            if Task.isCancelled { break }
        }

        let elapsed = Date().timeIntervalSince(started)
        logger.info("embedded \(written)/\(work.count) transcriptions in \(elapsed, format: .fixed(precision: 1))s")
    }
}
