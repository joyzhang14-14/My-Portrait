import Foundation
import GRDB
import os.log

/// `PortraitDB` 协议的真正实现。actor 隔离的 `DatabasePool`（WAL 模式 →
/// 多 reader + 单 writer 不阻塞），跑 `DBSchema.migrator()` 完成 schema。
///
/// 默认路径：`~/.portrait/portrait.sqlite`。测试可注入 `:memory:`。
///
/// 写入策略：所有方法都 `try await dbPool.write { ... }`，actor 保证只有一个
/// writer 同时跑，WAL 允许 reader 并发读不阻塞。
actor PortraitDBImpl: PortraitDB {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "impl")

    /// 内部可见的 pool 引用。SearchEngine 实现共用此 pool（WAL 下多 reader 安全）。
    /// `nonisolated let` —— DatabasePool 是 Sendable，跨 actor 边界传零成本。
    nonisolated let dbPool: DatabasePool

    init(path: String = Storage.portraitDBPath) throws {
        // 确保父目录存在（首启时 ~/.portrait/ 可能还没建好）。
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL：写不阻塞读，崩溃恢复用 .wal 文件
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // NORMAL：WAL 下足够安全（FULL 慢 10×），系统/电源故障最多丢最近一次提交
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // 默认 SQLite 不强制外键，必须显式开
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // 注册 Foundation 后端的 ICU 分词器，FTS5 表才能识别 tokenizer="foundation_icu"。
            // 见 FoundationTokenizer.swift —— Foundation enumerateSubstrings(.byWords)
            // 在 Darwin 上是 ICU-backed，等价于"直接用 ICU 分词器"。
            db.add(tokenizer: FoundationTokenizer.self)
        }

        self.dbPool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(self.dbPool)
        logger.info("PortraitDB opened: \(path, privacy: .public)")
    }

    // MARK: - P1: 屏幕帧

    func insertFrame(_ record: FrameRecord) async throws -> Int64 {
        try await dbPool.write { db in
            var row = FrameRow.fromRecord(record)
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func insertFrameWithOCR(_ record: FrameRecord, ocr: OCRResult?) async throws -> Int64 {
        let ocrFields = try Self.encodeOCRFields(ocr)
        return try await dbPool.write { db in
            var row = FrameRow.fromRecord(record, ocr: ocrFields)
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func updateFrameOCR(frameId: Int64, ocr: OCRResult) async throws {
        let ocrFields = try Self.encodeOCRFields(ocr)
        try await dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE frames
                SET full_text = ?, ocr_words_json = ?, ocr_confidence = ?, text_source = ?
                WHERE id = ?
                """,
                arguments: [
                    ocrFields?.fullText,
                    ocrFields?.wordsJson,
                    ocrFields?.confidence,
                    ocrFields?.textSource,
                    frameId,
                ]
            )
        }
    }

    // MARK: - P3: MP4 压缩

    func framesToCompact(olderThanMs: Int64, limit: Int) async throws -> [FrameForCompaction] {
        try await dbPool.read { db in
            let sql = """
            SELECT id, timestamp_ms, snapshot_path, device_name
            FROM frames
            WHERE snapshot_path IS NOT NULL
              AND timestamp_ms < ?
            ORDER BY device_name, timestamp_ms
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [olderThanMs, limit])
            return rows.compactMap { row -> FrameForCompaction? in
                guard let id: Int64 = row["id"],
                      let ts: Int64 = row["timestamp_ms"],
                      let rawPath: String = row["snapshot_path"],
                      let device: String = row["device_name"]
                else { return nil }
                // resolve to absolute. Skip the frame if the file is
                // missing on disk — compactor can't compact a JPG we can't
                // read, and CompactionWorker no longer has its own resolve.
                guard let path = AssetPath.resolve(rawPath) else { return nil }
                return FrameForCompaction(
                    id: id, timestampMs: ts, snapshotPath: path, deviceName: device
                )
            }
        }
    }

    func replaceFramesWithVideoChunk(
        chunk: VideoChunkRecord,
        frames: [(frameId: Int64, offsetMs: Int)]
    ) async throws -> Int64 {
        let chunkRow = VideoChunkRow(
            id: nil,
            filePath: AssetPath.normalize(chunk.filePath),
            deviceName: chunk.deviceName,
            fps: chunk.fps,
            startTsMs: chunk.startTsMs,
            endTsMs: chunk.endTsMs,
            frameCount: chunk.frameCount,
            createdAtMs: Self.nowMs()
        )
        return try await dbPool.write { db in
            var row = chunkRow
            try row.insert(db)
            let chunkId = row.id ?? 0
            // 批量 UPDATE frames，预编译语句循环。
            let stmt = try db.makeStatement(sql: """
                UPDATE frames
                SET video_chunk_id = ?, offset_ms = ?, snapshot_path = NULL
                WHERE id = ?
                """)
            for (frameId, offset) in frames {
                try stmt.execute(arguments: [chunkId, offset, frameId])
            }
            return chunkId
        }
    }

    // MARK: - P4: 音频

    func insertAudioChunk(_ record: AudioChunkRecord) async throws -> Int64 {
        try await dbPool.write { db in
            var row = AudioChunkRow(
                id: nil,
                filePath: AssetPath.normalize(record.filePath),
                recordedAtMs: record.recordedAtMs,
                durationS: record.durationS,
                device: record.device,
                isInput: record.isInput,
                status: record.status.rawValue,
                createdAtMs: Self.nowMs()
            )
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func updateAudioChunkStatus(chunkId: Int64, status: AudioChunkStatus) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = ? WHERE id = ?",
                arguments: [status.rawValue, chunkId]
            )
        }
    }

    func insertTranscription(_ record: TranscriptionRecord) async throws {
        try await dbPool.write { db in
            var row = TranscriptionRow(
                id: nil,
                audioChunkId: record.audioChunkId,
                startS: record.startS,
                endS: record.endS,
                text: record.text,
                speakerId: record.speakerId,
                engine: record.engine,
                transcribedAtMs: record.transcribedAtMs
            )
            try row.insert(db)
        }
    }

    func pendingAudioChunks(limit: Int) async throws -> [AudioChunkRecord] {
        try await dbPool.read { db in
            let rows = try AudioChunkRow
                .filter(Column("status") == AudioChunkStatus.pending.rawValue)
                .order(Column("recorded_at_ms"))
                .limit(limit)
                .fetchAll(db)
            return rows.compactMap { row -> AudioChunkRecord? in
                // resolve filePath; skip if file is missing (worker can't
                // transcribe / play what isn't on disk).
                guard let resolved = AssetPath.resolve(row.filePath) else { return nil }
                return AudioChunkRecord(
                    id: row.id,
                    filePath: resolved,
                    recordedAtMs: row.recordedAtMs,
                    durationS: row.durationS,
                    device: row.device,
                    isInput: row.isInput,
                    status: AudioChunkStatus(rawValue: row.status) ?? .pending
                )
            }
        }
    }

    func recordAudioChunkFailure(chunkId: Int64) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = ?, retry_count = retry_count + 1 WHERE id = ?",
                arguments: [AudioChunkStatus.failed.rawValue, chunkId]
            )
        }
    }

    func resetInProgressAudioChunks() async throws -> Int {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = ? WHERE status = ?",
                arguments: [AudioChunkStatus.pending.rawValue, AudioChunkStatus.inProgress.rawValue]
            )
            return db.changesCount
        }
    }

    func resetRetryableFailedAudioChunks() async throws -> Int {
        try await dbPool.write { db in
            // retry_count < 3：重试上限，超过的保持 failed 不再重跑。
            try db.execute(
                sql: "UPDATE audio_chunks SET status = ? WHERE status = ? AND retry_count < 3",
                arguments: [AudioChunkStatus.pending.rawValue, AudioChunkStatus.failed.rawValue]
            )
            return db.changesCount
        }
    }

    // MARK: - 说话人识别（speaker diarization）

    /// 余弦相似度阈值。> 此值判定同一说话人（对齐 screenpipe 的 0.45）。
    private static let speakerMatchThreshold: Float = 0.45
    /// 每个说话人最多保留的样本向量数。
    private static let maxEmbeddingsPerSpeaker = 10
    /// centroid 指数移动平均的有效计数上限——防止老说话人 centroid 僵化。
    private static let centroidEMACap = 50

    func matchSpeaker(embedding: [Float]) async throws -> Int64? {
        try await dbPool.read { db in
            var best: (id: Int64, sim: Float)?
            // 1. 先比对每个说话人的样本向量。
            let embRows = try Row.fetchAll(db, sql: """
                SELECT se.speaker_id AS sid, se.embedding AS emb
                FROM speaker_embeddings se
                JOIN speakers s ON s.id = se.speaker_id
                WHERE s.hidden = 0
                """)
            for row in embRows {
                guard let blob: Data = row["emb"], let vec = blob.asFloats,
                      vec.count == embedding.count else { continue }
                let sim = VectorMath.cosineSimilarity(embedding, vec)
                if sim > Self.speakerMatchThreshold, sim > (best?.sim ?? Self.speakerMatchThreshold) {
                    best = (row["sid"], sim)
                }
            }
            if let b = best { return b.id }
            // 2. 样本没命中再比对 centroid（运行平均向量）。
            let cRows = try Row.fetchAll(db, sql: """
                SELECT id, centroid FROM speakers WHERE hidden = 0 AND centroid IS NOT NULL
                """)
            for row in cRows {
                guard let blob: Data = row["centroid"], let vec = blob.asFloats,
                      vec.count == embedding.count else { continue }
                let sim = VectorMath.cosineSimilarity(embedding, vec)
                if sim > Self.speakerMatchThreshold, sim > (best?.sim ?? Self.speakerMatchThreshold) {
                    best = (row["id"], sim)
                }
            }
            return best?.id
        }
    }

    func enrollSpeaker(embedding: [Float]) async throws -> Int64 {
        let blob = Data(floats: embedding)
        let now = Self.nowMs()
        return try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO speakers (name, centroid, embedding_count, hidden, created_at_ms, updated_at_ms)
                VALUES (NULL, ?, 1, 0, ?, ?)
                """, arguments: [blob, now, now])
            let sid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms) VALUES (?, ?, ?)
                """, arguments: [sid, blob, now])
            return sid
        }
    }

    func addEmbeddingToSpeaker(speakerId: Int64, embedding: [Float]) async throws {
        let now = Self.nowMs()
        try await dbPool.write { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT centroid, embedding_count FROM speakers WHERE id = ?", arguments: [speakerId])
            else { return }
            let count: Int = row["embedding_count"] ?? 0
            let centroid: [Float]
            if let blob: Data = row["centroid"], let c = blob.asFloats, c.count == embedding.count {
                centroid = c
            } else {
                centroid = embedding
            }
            // centroid 指数移动平均，有效计数上限 centroidEMACap。
            let eff = Float(min(count, Self.centroidEMACap))
            var next = [Float](repeating: 0, count: embedding.count)
            for i in 0..<embedding.count {
                next[i] = (centroid[i] * eff + embedding[i]) / (eff + 1)
            }
            VectorMath.l2Normalize(&next)
            try db.execute(sql: """
                UPDATE speakers SET centroid = ?, embedding_count = embedding_count + 1, updated_at_ms = ?
                WHERE id = ?
                """, arguments: [Data(floats: next), now, speakerId])
            try db.execute(sql:
                "INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms) VALUES (?, ?, ?)",
                arguments: [speakerId, Data(floats: embedding), now])
            // 样本超上限 → 删掉最接近 centroid 的（最冗余）。
            let embRows = try Row.fetchAll(db, sql:
                "SELECT id, embedding FROM speaker_embeddings WHERE speaker_id = ?", arguments: [speakerId])
            if embRows.count > Self.maxEmbeddingsPerSpeaker {
                var closest: (id: Int64, sim: Float)?
                for r in embRows {
                    guard let blob: Data = r["embedding"], let v = blob.asFloats,
                          v.count == next.count else { continue }
                    let sim = VectorMath.cosineSimilarity(next, v)
                    if sim > (closest?.sim ?? -2) { closest = (r["id"], sim) }
                }
                if let c = closest {
                    try db.execute(sql: "DELETE FROM speaker_embeddings WHERE id = ?", arguments: [c.id])
                }
            }
        }
    }

    func nameSpeakerIfUnnamed(speakerId: Int64, name: String) async throws {
        let now = Self.nowMs()
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE speakers SET name = ?, updated_at_ms = ?
                WHERE id = ? AND (name IS NULL OR name = '')
                """, arguments: [name, now, speakerId])
        }
    }

    // MARK: - 向量（Phase 4）

    func framesNeedingEmbedding(model: String, limit: Int) async throws -> [Int64] {
        try await dbPool.read { db in
            // `embedding IS NULL` 走 partial index `idx_frames_embedding_null` —— 冷数据零成本。
            // `embedding_model != model` 走全表扫但只在换模型那阵子触发，
            // 跑完一遍历史数据后所有行 model 都对齐，后续轮次几乎只命中第一支条件。
            try Int64.fetchAll(db, sql: """
                SELECT id FROM frames
                WHERE (embedding IS NULL OR embedding_model IS NOT ?)
                  AND full_text IS NOT NULL AND length(full_text) > 4
                ORDER BY timestamp_ms DESC
                LIMIT ?
                """, arguments: [model, limit])
        }
    }

    func setFrameEmbedding(frameId: Int64, vector: [Float], model: String) async throws {
        let blob = Data(floats: vector)
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE frames SET embedding = ?, embedding_model = ? WHERE id = ?",
                arguments: [blob, model, frameId]
            )
        }
    }

    func allFrameEmbeddings(model: String, limit: Int) async throws -> [(id: Int64, vector: [Float])] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, embedding FROM frames
                WHERE embedding IS NOT NULL AND embedding_model = ?
                ORDER BY timestamp_ms DESC
                LIMIT ?
                """, arguments: [model, limit])
            return rows.compactMap { row -> (Int64, [Float])? in
                guard let id: Int64 = row["id"],
                      let blob: Data = row["embedding"],
                      let vec = blob.asFloats else { return nil }
                return (id, vec)
            }
        }
    }

    // MARK: - 向量：转录

    func transcriptionsNeedingEmbedding(model: String, limit: Int) async throws -> [Int64] {
        try await dbPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM audio_transcriptions
                WHERE (embedding IS NULL OR embedding_model IS NOT ?)
                  AND text IS NOT NULL AND length(text) > 4
                ORDER BY transcribed_at_ms DESC
                LIMIT ?
                """, arguments: [model, limit])
        }
    }

    func setTranscriptionEmbedding(transcriptionId: Int64, vector: [Float], model: String) async throws {
        let blob = Data(floats: vector)
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_transcriptions SET embedding = ?, embedding_model = ? WHERE id = ?",
                arguments: [blob, model, transcriptionId]
            )
        }
    }

    func allTranscriptionEmbeddings(model: String, limit: Int) async throws -> [(id: Int64, vector: [Float])] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, embedding FROM audio_transcriptions
                WHERE embedding IS NOT NULL AND embedding_model = ?
                ORDER BY transcribed_at_ms DESC
                LIMIT ?
                """, arguments: [model, limit])
            return rows.compactMap { row -> (Int64, [Float])? in
                guard let id: Int64 = row["id"],
                      let blob: Data = row["embedding"],
                      let vec = blob.asFloats else { return nil }
                return (id, vec)
            }
        }
    }

    func transcriptionsByIds(_ ids: [Int64]) async throws -> [TranscriptionMetadata] {
        guard !ids.isEmpty else { return [] }
        return try await dbPool.read { db in
            var out: [TranscriptionMetadata] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({
                Array(ids[$0..<min($0 + 500, ids.count)])
            }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT t.id, t.audio_chunk_id, c.recorded_at_ms, t.text
                FROM audio_transcriptions t
                JOIN audio_chunks c ON c.id = t.audio_chunk_id
                WHERE t.id IN (\(placeholders))
                """
                let args = StatementArguments(chunk.map { DatabaseValue(value: $0) ?? .null })
                let rows = try Row.fetchAll(db, sql: sql, arguments: args)
                for row in rows {
                    out.append(TranscriptionMetadata(
                        id: row["id"] ?? 0,
                        audioChunkId: row["audio_chunk_id"] ?? 0,
                        recordedAtMs: row["recorded_at_ms"] ?? 0,
                        text: row["text"] ?? ""
                    ))
                }
            }
            return out
        }
    }

    func framesByIds(_ ids: [Int64]) async throws -> [FrameMetadata] {
        guard !ids.isEmpty else { return [] }
        return try await dbPool.read { db in
            // SQLite bind 上限 999；ids 列表理论不会到那么大但分块保险。
            var out: [FrameMetadata] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({
                Array(ids[$0..<min($0 + 500, ids.count)])
            }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT id, timestamp_ms, app_name, window_name, browser_url, full_text
                FROM frames
                WHERE id IN (\(placeholders))
                """
                let args = StatementArguments(chunk.map { DatabaseValue(value: $0) ?? .null })
                let rows = try Row.fetchAll(db, sql: sql, arguments: args)
                for row in rows {
                    out.append(FrameMetadata(
                        id: row["id"] ?? 0,
                        timestampMs: row["timestamp_ms"] ?? 0,
                        appName: row["app_name"] ?? "",
                        windowName: row["window_name"],
                        browserUrl: row["browser_url"],
                        fullText: row["full_text"]
                    ))
                }
            }
            return out
        }
    }

    // MARK: - Retention

    func mediaPathsBefore(ms: Int64) async throws -> RetentionFileList {
        try await dbPool.read { db in
            // Pull raw paths from each table, then resolve. Files that
            // already vanished off disk are dropped — retention has
            // nothing to delete for them.
            let rawSnapshots = try String.fetchAll(db, sql: """
                SELECT snapshot_path FROM frames
                WHERE snapshot_path IS NOT NULL AND timestamp_ms < ?
                """, arguments: [ms])
            let rawVideoChunks = try String.fetchAll(db, sql: """
                SELECT file_path FROM video_chunks
                WHERE end_ts_ms < ?
                """, arguments: [ms])
            let rawAudio = try String.fetchAll(db, sql: """
                SELECT file_path FROM audio_chunks
                WHERE recorded_at_ms < ?
                """, arguments: [ms])

            return RetentionFileList(
                snapshotPaths: rawSnapshots.compactMap(AssetPath.resolve),
                videoChunkPaths: rawVideoChunks.compactMap(AssetPath.resolve),
                audioPaths: rawAudio.compactMap(AssetPath.resolve)
            )
        }
    }

    // MARK: - 读（UI 用）

    func framesForDay(_ day: Date, limit: Int) async throws -> [TimelineFrame] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(dayEnd.timeIntervalSince1970 * 1000)

        return try await dbPool.read { db in
            let sql = """
            SELECT f.id, f.timestamp_ms, f.app_name, f.window_name, f.browser_url,
                   f.snapshot_path, v.file_path AS video_path, f.offset_ms,
                   COALESCE(v.fps, 1.0) AS fps
            FROM frames f
            LEFT JOIN video_chunks v ON v.id = f.video_chunk_id
            WHERE (f.snapshot_path IS NOT NULL OR f.video_chunk_id IS NOT NULL)
              AND f.timestamp_ms >= ? AND f.timestamp_ms < ?
            ORDER BY f.timestamp_ms DESC
            LIMIT ?
            """
            // DESC + limit：超出上限时丢最旧的、保留最近的（不会让刚拍的帧落到
            // 截断区外）。结果再 reverse 回时间正序给时间线用。
            let rows = try Row.fetchAll(db, sql: sql, arguments: [startMs, endMs, limit])
            return rows.reversed().map { row -> TimelineFrame in
                let id: Int64 = row["id"] ?? 0
                let ts: Int64 = row["timestamp_ms"] ?? 0
                let app: String = row["app_name"] ?? ""
                let win: String = row["window_name"] ?? ""
                let url: String? = row["browser_url"]
                // Paths in DB are stored relative to Storage.rootURL.
                // AssetPath.resolve gives back absolute paths + nil-out
                // anything whose file is missing — so callers can treat the
                // value as "ready to load or nothing's there".
                let snap: String? = AssetPath.resolve(row["snapshot_path"])
                let vpath: String? = AssetPath.resolve(row["video_path"])
                let offsetMs: Int = row["offset_ms"] ?? 0
                let fps: Double = row["fps"] ?? 1.0

                return TimelineFrame(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                    appName: app,
                    windowName: win,
                    browserUrl: url,
                    snapshotPath: snap,
                    videoPath: vpath,
                    videoOffsetMs: Int(offsetMs),
                    videoFps: fps
                )
            }
        }
    }

    func activeAppsAround(timestamp: Date, windowSeconds: TimeInterval) async throws -> [ActiveAppEntry] {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        let startMs = ms - Int64(windowSeconds * 1000)
        let endMs = ms + Int64(windowSeconds * 1000)

        return try await dbPool.read { db in
            let sql = """
            SELECT app_name,
                   COALESCE(window_name, '') AS window_name,
                   COALESCE(browser_url, '') AS browser_url,
                   MAX(timestamp_ms) AS latest
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name, window_name
            ORDER BY latest DESC
            LIMIT 30
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [startMs, endMs])
            return rows.map { row -> ActiveAppEntry in
                let app: String = row["app_name"] ?? ""
                let win: String = row["window_name"] ?? ""
                let url: String = row["browser_url"] ?? ""
                let latest: Int64 = row["latest"] ?? 0
                return ActiveAppEntry(
                    appName: app,
                    windowName: win,
                    browserUrl: url.isEmpty ? nil : url,
                    lastSeen: Date(timeIntervalSince1970: TimeInterval(latest) / 1000)
                )
            }
        }
    }

    func audioTranscriptsAround(
        timestamp: Date,
        beforeSeconds: TimeInterval,
        afterSeconds: TimeInterval
    ) async throws -> [AudioTranscriptEntry] {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        let startMs = ms - Int64(beforeSeconds * 1000)
        let endMs = ms + Int64(afterSeconds * 1000)

        return try await dbPool.read { db in
            // PortraitDB schema 还没有 speakers 表（NoopSpeakerDiarizer 永远 nil）。
            // 直接 JOIN audio_chunks 拿 recorded_at_ms + device，speakerId/name 留 nil。
            let sql = """
            SELECT c.recorded_at_ms AS ts_ms,
                   t.text,
                   c.device,
                   c.is_input,
                   t.speaker_id
            FROM audio_transcriptions t
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            WHERE c.recorded_at_ms >= ? AND c.recorded_at_ms <= ?
              AND t.text IS NOT NULL AND t.text != ''
            ORDER BY c.recorded_at_ms ASC
            LIMIT 60
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [startMs, endMs])
            return rows.map { row -> AudioTranscriptEntry in
                let tsMs: Int64 = row["ts_ms"] ?? 0
                let text: String = row["text"] ?? ""
                let device: String = row["device"] ?? ""
                let isInput: Bool = row["is_input"] ?? true
                let speakerId: Int? = row["speaker_id"]
                return AudioTranscriptEntry(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                    text: text,
                    device: device,
                    isInput: isInput,
                    speakerId: speakerId,
                    speakerName: nil
                )
            }
        }
    }

    func applyRetention(mode: RetentionMode, beforeMs: Int64) async throws -> RetentionStats {
        try await dbPool.write { db in
            switch mode {
            case .mediaOnly:
                // 1. NULL 掉 frames 的媒体引用（保留 OCR 文本）
                try db.execute(sql: """
                    UPDATE frames
                    SET snapshot_path = NULL, video_chunk_id = NULL, offset_ms = NULL
                    WHERE timestamp_ms < ?
                    """, arguments: [beforeMs])
                let framesAffected = db.changesCount

                // 2. 删旧的 video_chunks 行（frames 已经 NULL 了 video_chunk_id 引用）
                try db.execute(sql: """
                    DELETE FROM video_chunks WHERE end_ts_ms < ?
                    """, arguments: [beforeMs])
                let videoChunksDeleted = db.changesCount

                // mediaOnly：audio_chunks 保留（含 transcriptions 关联），文件由 worker 删。
                return RetentionStats(
                    framesAffected: framesAffected,
                    videoChunksDeleted: videoChunksDeleted,
                    audioChunksDeleted: 0
                )

            case .everything:
                try db.execute(sql: """
                    DELETE FROM frames WHERE timestamp_ms < ?
                    """, arguments: [beforeMs])
                let framesAffected = db.changesCount

                try db.execute(sql: """
                    DELETE FROM video_chunks WHERE end_ts_ms < ?
                    """, arguments: [beforeMs])
                let videoChunksDeleted = db.changesCount

                // CASCADE 删 transcriptions
                try db.execute(sql: """
                    DELETE FROM audio_chunks WHERE recorded_at_ms < ?
                    """, arguments: [beforeMs])
                let audioChunksDeleted = db.changesCount

                return RetentionStats(
                    framesAffected: framesAffected,
                    videoChunksDeleted: videoChunksDeleted,
                    audioChunksDeleted: audioChunksDeleted
                )
            }
        }
    }

    // MARK: - 私有

    /// 把 OCRResult 拆成 4 个列要存的字符串/数字。失败抛错（JSON encode 不应该失败）。
    private static func encodeOCRFields(_ ocr: OCRResult?) throws -> OCRFields? {
        guard let ocr else { return nil }
        let wordsJson: String?
        if ocr.words.isEmpty {
            wordsJson = nil   // 空数组省一行 JSON ("[]")，让 NULL 表示"无 bbox"
        } else {
            let data = try JSONEncoder().encode(ocr.words)
            wordsJson = String(data: data, encoding: .utf8)
        }
        return OCRFields(
            fullText: ocr.fullText,
            wordsJson: wordsJson,
            confidence: ocr.avgConfidence,
            textSource: ocr.textSource.rawValue
        )
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// 编码后的 OCR 列值组合。文件作用域，PortraitDBImpl 和 FrameRow 扩展共用。
fileprivate struct OCRFields {
    let fullText: String
    let wordsJson: String?
    let confidence: Double
    let textSource: String
}

// MARK: - FrameRow / FrameRecord 转换

private extension FrameRow {
    /// 从 FrameRecord 构造行（OCR 字段空）。用于 `insertFrame` 占位路径。
    static func fromRecord(_ record: FrameRecord) -> FrameRow {
        FrameRow(
            id: nil,
            timestampMs: record.timestampMs,
            appName: record.appName,
            windowName: record.windowName,
            browserUrl: record.browserUrl,
            focused: record.focused,
            deviceName: record.deviceName,
            snapshotPath: AssetPath.normalize(record.snapshotPath),
            videoChunkId: nil,
            offsetMs: nil,
            captureTrigger: record.captureTrigger,
            fullText: nil,
            ocrWordsJson: nil,
            ocrConfidence: nil,
            textSource: nil,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// 从 FrameRecord + OCR 字段构造行（一次性写入 + OCR 路径）。
    static func fromRecord(_ record: FrameRecord, ocr: OCRFields?) -> FrameRow {
        FrameRow(
            id: nil,
            timestampMs: record.timestampMs,
            appName: record.appName,
            windowName: record.windowName,
            browserUrl: record.browserUrl,
            focused: record.focused,
            deviceName: record.deviceName,
            snapshotPath: AssetPath.normalize(record.snapshotPath),
            videoChunkId: nil,
            offsetMs: nil,
            captureTrigger: record.captureTrigger,
            fullText: ocr?.fullText,
            ocrWordsJson: ocr?.wordsJson,
            ocrConfidence: ocr?.confidence,
            textSource: ocr?.textSource,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
