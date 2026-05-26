import Foundation
import GRDB
import os.log

private let importLog = Logger(subsystem: "com.myportrait.db", category: "screenpipe-import")

/// 从 screenpipe(`~/.screenpipe/`)的 SQLite 把历史 frames + audio
/// transcripts 搬到 My-Portrait,**只导比 My-Portrait 最早数据还老的**
/// (按 timestamp_ms 边界),避免覆盖 My-Portrait 当前已有数据。
///
/// 媒体文件(MP4 / WAV / JPG)**不导**,只搬元数据 + OCR / 转译文本。
/// 体积 < 100 MB,秒级 ~ 分钟级完成。
///
/// 不修改 screenpipe DB(read-only 打开)。
///
/// 用法:
///   let r = try await ScreenpipeImporter(sourcePath: "/Users/x/.screenpipe").run(into: dbPool)
struct ScreenpipeImporter: Sendable {

    struct Report: Sendable {
        let cutoffMs: Int64?           // 时间边界:导 < 这个 ts 的;nil = 全导(MyPortrait 空)
        let framesImported: Int
        let audioChunksImported: Int
        let audioTranscriptsImported: Int
        let skippedFramesNoOCR: Int
        let errorMessage: String?
    }

    enum ImportError: LocalizedError {
        case sourceMissing(String)
        case sourceOpenFailed(String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "Screenpipe DB not found: \(p)"
            case .sourceOpenFailed(let m): return "Open screenpipe DB failed: \(m)"
            }
        }
    }

    /// 标准 screenpipe 数据目录(可被 --import-screenpipe <path> 覆盖)。
    static let defaultSourceDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".screenpipe")

    let sourceDir: URL

    init(sourceDir: URL = ScreenpipeImporter.defaultSourceDir) {
        self.sourceDir = sourceDir
    }

    /// 主入口。
    /// - Parameter target: 目标 My-Portrait DatabasePool。
    /// - Returns: Report —— 总导入 / 跳过 / 错误数。
    func run(into target: DatabasePool) async throws -> Report {
        // 1. 找 source db
        let sourceDB = sourceDir.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: sourceDB.path) else {
            throw ImportError.sourceMissing(sourceDB.path)
        }

        // 2. 算 cutoff:My-Portrait 最早 frame timestamp,只导比它老的。
        let cutoffMs = try await Task.detached(priority: .userInitiated) {
            try target.read { db in
                try Int64.fetchOne(
                    db, sql: "SELECT MIN(timestamp_ms) FROM frames"
                )
            }
        }.value
        importLog.info("cutoff_ms=\(cutoffMs.map(String.init) ?? "nil", privacy: .public) (MyPortrait earliest)")

        // 3. read-only 打开 screenpipe DB(URI mode 加 mode=ro 防误写)。
        let roConfig: Configuration = {
            var c = Configuration()
            c.readonly = true
            return c
        }()
        let source: DatabaseQueue
        do {
            source = try DatabaseQueue(path: sourceDB.path, configuration: roConfig)
        } catch {
            throw ImportError.sourceOpenFailed(error.localizedDescription)
        }

        // 4. 导 frames + ocr_text
        let (framesIn, skippedFrames) = try await Task.detached(priority: .userInitiated) {
            try Self.importFrames(source: source, target: target, cutoffMs: cutoffMs)
        }.value

        // 5. 导 audio_chunks + audio_transcriptions
        let (chunksIn, transcriptsIn) = try await Task.detached(priority: .userInitiated) {
            try Self.importAudio(source: source, target: target, cutoffMs: cutoffMs)
        }.value

        return Report(
            cutoffMs: cutoffMs,
            framesImported: framesIn,
            audioChunksImported: chunksIn,
            audioTranscriptsImported: transcriptsIn,
            skippedFramesNoOCR: skippedFrames,
            errorMessage: nil
        )
    }

    // MARK: - Frames

    /// JOIN screenpipe `frames` × `ocr_text`,转换 ISO TIMESTAMP → UTC ms,
    /// INSERT 到 My-Portrait `frames`。无 OCR 的 frame 跳过(My-Portrait full_text
    /// notNull,且没 OCR 就没价值给 distill)。
    private static func importFrames(
        source: DatabaseQueue,
        target: DatabasePool,
        cutoffMs: Int64?
    ) throws -> (imported: Int, skippedNoOCR: Int) {
        // 拿 screenpipe 那边 ts < cutoff 的 frames(没 cutoff 就全拿)。
        // screenpipe.timestamp 是 ISO 8601 TEXT,SQL 用 strftime 转 unix sec
        // 再乘 1000 拿 ms。
        var imported = 0
        var skipped = 0

        // 批量 fetch(全捞到内存,几万 rows 通常 ~50MB,可接受;否则 cursor)。
        let rows: [SourceFrameRow] = try source.read { db in
            // ts 边界用 SQL 端过滤,省序列化。
            let cutoffISO: String? = cutoffMs.map { ms in
                // ms → ISO 比 ts < x 安全。SQLite datetime() round-trip。
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return fmt.string(from: date)
            }

            let sql: String
            if cutoffISO != nil {
                sql = """
                    SELECT f.id, f.timestamp, f.app_name, f.window_name, f.browser_url, f.focused,
                           o.text
                    FROM frames f
                    LEFT JOIN ocr_text o ON o.frame_id = f.id
                    WHERE f.timestamp < :cutoff
                    ORDER BY f.timestamp ASC
                    """
            } else {
                sql = """
                    SELECT f.id, f.timestamp, f.app_name, f.window_name, f.browser_url, f.focused,
                           o.text
                    FROM frames f
                    LEFT JOIN ocr_text o ON o.frame_id = f.id
                    ORDER BY f.timestamp ASC
                    """
            }
            var args: StatementArguments = [:]
            if let c = cutoffISO { args = ["cutoff": c] }

            return try Row.fetchAll(db, sql: sql, arguments: args).map { r -> SourceFrameRow in
                SourceFrameRow(
                    timestampISO: r["timestamp"] as String? ?? "",
                    appName: r["app_name"] as String? ?? "unknown",
                    windowName: r["window_name"] as String?,
                    browserURL: r["browser_url"] as String?,
                    focused: (r["focused"] as Int64?).map { $0 != 0 } ?? true,
                    ocrText: r["text"] as String?
                )
            }
        }

        importLog.info("screenpipe frames to consider: \(rows.count, privacy: .public)")

        // 批量 INSERT 进 My-Portrait。事务包裹,触发 FTS5 同步一次性。
        try target.write { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            for r in rows {
                guard let text = r.ocrText, !text.isEmpty else {
                    skipped += 1
                    continue
                }
                let ts = Self.isoToMs(r.timestampISO) ?? nowMs
                // **再次** 在客户端确认 ts < cutoff(SQL 转换偶发漂)
                if let cutoff = cutoffMs, ts >= cutoff {
                    skipped += 1
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO frames
                        (timestamp_ms, app_name, window_name, browser_url, focused,
                         device_name, snapshot_path, video_chunk_id, offset_ms,
                         capture_trigger, full_text, text_source, created_at_ms)
                    VALUES (:ts, :app, :win, :url, :focused,
                            'imported', NULL, NULL, NULL,
                            'screenpipe_import', :text, 'ocr', :now)
                    """,
                    arguments: [
                        "ts": ts, "app": r.appName, "win": r.windowName,
                        "url": r.browserURL, "focused": r.focused,
                        "text": text, "now": nowMs
                    ])
                imported += 1
            }
        }
        importLog.info("frames imported=\(imported, privacy: .public) skipped=\(skipped, privacy: .public)")
        return (imported, skipped)
    }

    // MARK: - Audio

    /// JOIN screenpipe `audio_chunks` × `audio_transcriptions`,先插 chunk 拿
    /// 新 id,再按这个 id 插 transcripts(My-Portrait audio_chunks 有 FK)。
    private static func importAudio(
        source: DatabaseQueue,
        target: DatabasePool,
        cutoffMs: Int64?
    ) throws -> (chunks: Int, transcripts: Int) {
        var importedChunks = 0
        var importedTranscripts = 0

        let cutoffISO: String? = cutoffMs.map { ms in
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.string(from: date)
        }

        // 拉所有 audio_chunks(没有自身 ts —— audio_transcriptions.timestamp 是
        // 这条 chunk 第一段转译的时刻;按它 group by chunk id 取 min/max)。
        struct ChunkRow {
            let oldId: Int64
            let filePath: String
            let firstTsMs: Int64
            let durationS: Double
        }
        struct TranscriptRow {
            let oldChunkId: Int64
            let timestampMs: Int64
            let text: String
        }

        let (chunks, transcripts): ([ChunkRow], [TranscriptRow]) = try source.read { db in
            // chunk 元数据
            let chunkSQL: String
            if cutoffISO != nil {
                chunkSQL = """
                    SELECT ac.id, ac.file_path,
                           (CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER) * 1000) AS first_ms,
                           (CAST(strftime('%s', MAX(at.timestamp)) AS INTEGER)
                          - CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER)) AS dur_s
                    FROM audio_chunks ac
                    JOIN audio_transcriptions at ON at.audio_chunk_id = ac.id
                    WHERE at.timestamp < :cutoff
                    GROUP BY ac.id, ac.file_path
                    """
            } else {
                chunkSQL = """
                    SELECT ac.id, ac.file_path,
                           (CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER) * 1000) AS first_ms,
                           (CAST(strftime('%s', MAX(at.timestamp)) AS INTEGER)
                          - CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER)) AS dur_s
                    FROM audio_chunks ac
                    JOIN audio_transcriptions at ON at.audio_chunk_id = ac.id
                    GROUP BY ac.id, ac.file_path
                    """
            }
            var chunkArgs: StatementArguments = [:]
            if let c = cutoffISO { chunkArgs = ["cutoff": c] }
            let chunkRows = try Row.fetchAll(db, sql: chunkSQL, arguments: chunkArgs).map {
                ChunkRow(
                    oldId: $0["id"], filePath: $0["file_path"] as String? ?? "",
                    firstTsMs: $0["first_ms"] as Int64? ?? 0,
                    durationS: Double($0["dur_s"] as Int64? ?? 0)
                )
            }

            // transcripts
            let transcriptSQL: String
            if cutoffISO != nil {
                transcriptSQL = """
                    SELECT audio_chunk_id, timestamp, transcription
                    FROM audio_transcriptions
                    WHERE timestamp < :cutoff
                    ORDER BY audio_chunk_id ASC, timestamp ASC
                    """
            } else {
                transcriptSQL = """
                    SELECT audio_chunk_id, timestamp, transcription
                    FROM audio_transcriptions
                    ORDER BY audio_chunk_id ASC, timestamp ASC
                    """
            }
            var transArgs: StatementArguments = [:]
            if let c = cutoffISO { transArgs = ["cutoff": c] }
            let transRows = try Row.fetchAll(db, sql: transcriptSQL, arguments: transArgs).map {
                TranscriptRow(
                    oldChunkId: $0["audio_chunk_id"],
                    timestampMs: Self.isoToMs($0["timestamp"] as String? ?? "") ?? 0,
                    text: $0["transcription"] as String? ?? ""
                )
            }
            return (chunkRows, transRows)
        }
        importLog.info("screenpipe audio: chunks=\(chunks.count) transcripts=\(transcripts.count)")

        // INSERT。先插 chunks 攒 old→new id map,再插 transcripts。
        try target.write { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var idMap: [Int64: Int64] = [:]    // screenpipe.chunk_id → portrait.chunk_id
            for c in chunks {
                guard c.firstTsMs > 0 else { continue }
                try db.execute(sql: """
                    INSERT INTO audio_chunks
                        (file_path, recorded_at_ms, duration_s, device, is_input, status, created_at_ms)
                    VALUES (:fp, :ts, :dur, 'imported', 1, 'done', :now)
                    """,
                    arguments: [
                        "fp": c.filePath, "ts": c.firstTsMs,
                        "dur": c.durationS, "now": nowMs
                    ])
                idMap[c.oldId] = db.lastInsertedRowID
                importedChunks += 1
            }

            for t in transcripts {
                guard let newId = idMap[t.oldChunkId], t.timestampMs > 0, !t.text.isEmpty else { continue }
                try db.execute(sql: """
                    INSERT INTO audio_transcriptions
                        (audio_chunk_id, start_s, end_s, text, engine, transcribed_at_ms)
                    VALUES (:cid, 0, 0, :text, 'screenpipe_import', :ts)
                    """,
                    arguments: [
                        "cid": newId, "text": t.text, "ts": t.timestampMs
                    ])
                importedTranscripts += 1
            }
        }
        importLog.info("audio imported chunks=\(importedChunks, privacy: .public) transcripts=\(importedTranscripts, privacy: .public)")
        return (importedChunks, importedTranscripts)
    }

    // MARK: - Helpers

    private struct SourceFrameRow: Sendable {
        let timestampISO: String
        let appName: String
        let windowName: String?
        let browserURL: String?
        let focused: Bool
        let ocrText: String?
    }

    /// ISO 8601 timestamp string → unix ms。screenpipe 可能是
    /// "2024-09-13T10:30:01.123Z" / "2024-09-13 10:30:01" / "2024-09-13T10:30:01.123456+00:00"
    /// 三种主要形态,挨个试。
    private static func isoToMs(_ s: String) -> Int64? {
        guard !s.isEmpty else { return nil }
        // 1. ISO8601 带小数秒
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso1.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        // 2. ISO8601 整秒
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        // 3. screenpipe 老格式:"YYYY-MM-DD HH:MM:SS" (假设 UTC)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = df.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        // 4. 带微秒
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        if let d = df.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
    }
}
