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
                      let path: String = row["snapshot_path"],
                      let device: String = row["device_name"]
                else { return nil }
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
            filePath: chunk.filePath,
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
                filePath: record.filePath,
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
            return rows.map { row in
                AudioChunkRecord(
                    id: row.id,
                    filePath: row.filePath,
                    recordedAtMs: row.recordedAtMs,
                    durationS: row.durationS,
                    device: row.device,
                    isInput: row.isInput,
                    status: AudioChunkStatus(rawValue: row.status) ?? .pending
                )
            }
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

    // MARK: - Retention

    func mediaPathsBefore(ms: Int64) async throws -> RetentionFileList {
        try await dbPool.read { db in
            // 屏幕快照（.jpg）
            let snapshotPaths = try String.fetchAll(db, sql: """
                SELECT snapshot_path FROM frames
                WHERE snapshot_path IS NOT NULL AND timestamp_ms < ?
                """, arguments: [ms])

            // MP4 视频块
            let videoChunkPaths = try String.fetchAll(db, sql: """
                SELECT file_path FROM video_chunks
                WHERE end_ts_ms < ?
                """, arguments: [ms])

            // 音频 wav
            let audioPaths = try String.fetchAll(db, sql: """
                SELECT file_path FROM audio_chunks
                WHERE recorded_at_ms < ?
                """, arguments: [ms])

            return RetentionFileList(
                snapshotPaths: snapshotPaths,
                videoChunkPaths: videoChunkPaths,
                audioPaths: audioPaths
            )
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
            snapshotPath: record.snapshotPath,
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
            snapshotPath: record.snapshotPath,
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
