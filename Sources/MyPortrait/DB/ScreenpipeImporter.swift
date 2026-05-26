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
        let framesImported: Int        // 新建 frames
        let framesBackfilled: Int      // 老 frame 补上 video_chunk_id (这次 import 媒体场景)
        let videoChunksImported: Int   // 新建 video_chunks (拷贝 MP4)
        let videoBytesCopied: Int64    // 实际拷的 MP4 总字节
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

    /// 进度回调载体。UI 用来渲染当前阶段 + 进度条。
    /// 阶段顺序:scanning → copyingVideo → importingFrames → importingAudio → done
    struct Progress: Sendable {
        enum Stage: String, Sendable {
            case scanning              // 0
            case copyingVideo          // 1
            case importingFrames       // 2
            case importingAudio        // 3
            case done                  // 4
        }
        let stage: Stage
        let current: Int               // 当前 stage 已完成数
        let total: Int                 // 当前 stage 总数(0 = 未知)
        let bytesDone: Int64           // copyingVideo 用,其它阶段 0
        let bytesTotal: Int64          // copyingVideo 用
        /// 0..1 给 SwiftUI ProgressView。0 / negative → 不确定进度。
        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1.0, Double(current) / Double(total))
        }
    }

    /// 扫盘结果。UI 自动扫盘后展示给用户。**count 字段都是按 cutoff 过滤
    /// 后"还需要导入的"数量**,不是源端总数 —— 用户能直接判断"按下 Import
    /// 会写多少行 / 还有没有数据要导"。
    struct ScanResult: Sendable {
        let sourceDir: URL
        let dbPath: URL
        let exists: Bool          // db.sqlite 在不在
        let cutoffMs: Int64?      // 用户当前 cutoff(My-Portrait 最早 frame ts)
        let frameCount: Int       // 待导入 OCR frame 数(已减掉 < cutoff 过滤)
        let videoChunkCount: Int  // 待导入 MP4 chunks 数
        let videoBytesEst: Int64  // 待拷 MP4 总字节(扫盘 stat)
        let audioChunkCount: Int  // 待导入 audio chunk 数
        let audioTranscriptCount: Int  // 待导入 transcript 数
        let earliestMs: Int64?    // 源端最早 ts(显示用)
        let latestMs: Int64?      // 源端最晚 ts

        /// 0 = 全都已导(按钮该灰)。也包含 videoChunk —— B 方案 backfill 场景下
        /// frameCount 可能 0 但 chunks 还要补。
        var hasAnythingToImport: Bool {
            frameCount > 0 || audioTranscriptCount > 0 || videoChunkCount > 0
        }
    }

    /// 候选扫描位置(按优先级)。screenpipe 一般固定 ~/.screenpipe,但
    /// 用户万一改了 base_dir 也兜底搜常见位置。
    static func candidateDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".screenpipe"),
            home.appendingPathComponent("Library/Application Support/screenpipe"),
            home.appendingPathComponent("Documents/screenpipe"),
        ]
    }

    /// 扫盘:找第一个有 db.sqlite 的候选目录,按 cutoff 过滤统计**待导入**
    /// 元数据。找不到返回 exists=false。
    /// - Parameter cutoffMs: My-Portrait 当前最早 frame ts。**所有 count 都
    ///   按 source.ts < cutoff 过滤** —— 跟真正导入用的边界一致。nil = 全统计。
    static func scan(cutoffMs: Int64?) -> ScanResult {
        for dir in candidateDirs() {
            let db = dir.appendingPathComponent("db.sqlite")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            do {
                return try scanSingle(dir: dir, dbPath: db, cutoffMs: cutoffMs)
            } catch {
                importLog.warning("scan: failed to open \(db.path, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }
        return ScanResult(
            sourceDir: defaultSourceDir,
            dbPath: defaultSourceDir.appendingPathComponent("db.sqlite"),
            exists: false, cutoffMs: cutoffMs,
            frameCount: 0,
            videoChunkCount: 0, videoBytesEst: 0,
            audioChunkCount: 0, audioTranscriptCount: 0,
            earliestMs: nil, latestMs: nil
        )
    }

    /// 单目录扫盘(自动扫 / 用户 picker 选都用这个)。
    /// **internal** —— UI 兜底 picker 也直接调。
    static func scanSingle(dir: URL, dbPath: URL? = nil, cutoffMs: Int64?) throws -> ScanResult {
        let db = dbPath ?? dir.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else {
            return ScanResult(
                sourceDir: dir, dbPath: db, exists: false, cutoffMs: cutoffMs,
                frameCount: 0,
                videoChunkCount: 0, videoBytesEst: 0,
                audioChunkCount: 0, audioTranscriptCount: 0,
                earliestMs: nil, latestMs: nil
            )
        }
        var c = Configuration()
        c.readonly = true
        let q = try DatabaseQueue(path: db.path, configuration: c)
        // **不用 ISO 字符串比较** —— screenpipe 历史 timestamp 有两种格式
        // ('2024-05-04 14:23:12' 和 '2024-05-04T14:23:12.000Z'),字符串比
        // 较里空格 < T,老格式行永远算 "< cutoff" false positive,导致 scan
        // 显示固定卡 1 帧(真 import 里 Swift 层 ms 二次过滤把它 skip)。
        // 改用 strftime('%s', ...) 转 unix sec,SQLite 能解析两种格式,
        // 结果跟 isoToMs 一致。
        let cutoffSec: Int64? = cutoffMs.map { $0 / 1000 }
        let (fc, ac, tc, minMs, maxMs): (Int, Int, Int, Int64?, Int64?) = try q.read { d in
            // frames count(JOIN ocr_text + 按 cutoff 过滤)
            let frameSQL: String
            if cutoffSec != nil {
                frameSQL = """
                    SELECT COUNT(*) FROM frames f
                    INNER JOIN ocr_text o ON o.frame_id = f.id
                    WHERE o.text IS NOT NULL AND o.text != ''
                      AND CAST(strftime('%s', f.timestamp) AS INTEGER) < :cutoff
                    """
            } else {
                frameSQL = """
                    SELECT COUNT(*) FROM frames f
                    INNER JOIN ocr_text o ON o.frame_id = f.id
                    WHERE o.text IS NOT NULL AND o.text != ''
                    """
            }
            var frameArgs: StatementArguments = [:]
            if let cu = cutoffSec { frameArgs = ["cutoff": cu] }
            let fc = (try? Int.fetchOne(d, sql: frameSQL, arguments: frameArgs)) ?? 0

            // audio_transcripts count(按 cutoff 过滤)
            let trSQL: String
            if cutoffSec != nil {
                trSQL = """
                    SELECT COUNT(*) FROM audio_transcriptions
                    WHERE transcription IS NOT NULL AND transcription != ''
                      AND CAST(strftime('%s', timestamp) AS INTEGER) < :cutoff
                    """
            } else {
                trSQL = """
                    SELECT COUNT(*) FROM audio_transcriptions
                    WHERE transcription IS NOT NULL AND transcription != ''
                    """
            }
            var trArgs: StatementArguments = [:]
            if let cu = cutoffSec { trArgs = ["cutoff": cu] }
            let tc = (try? Int.fetchOne(d, sql: trSQL, arguments: trArgs)) ?? 0

            // audio chunks 数:有 transcripts 关联的(跟真正 import 用的口径一致)
            let acSQL: String
            if cutoffSec != nil {
                acSQL = """
                    SELECT COUNT(DISTINCT ac.id) FROM audio_chunks ac
                    INNER JOIN audio_transcriptions at ON at.audio_chunk_id = ac.id
                    WHERE at.transcription IS NOT NULL AND at.transcription != ''
                      AND CAST(strftime('%s', at.timestamp) AS INTEGER) < :cutoff
                    """
            } else {
                acSQL = """
                    SELECT COUNT(DISTINCT ac.id) FROM audio_chunks ac
                    INNER JOIN audio_transcriptions at ON at.audio_chunk_id = ac.id
                    WHERE at.transcription IS NOT NULL AND at.transcription != ''
                    """
            }
            var acArgs: StatementArguments = [:]
            if let cu = cutoffSec { acArgs = ["cutoff": cu] }
            let ac = (try? Int.fetchOne(d, sql: acSQL, arguments: acArgs)) ?? 0

            // earliest / latest 源端日期 —— 不带 cutoff,UI 显示源端时间范围。
            let minTs: String? = (try? String.fetchOne(d, sql: "SELECT MIN(timestamp) FROM frames")) ?? nil
            let maxTs: String? = (try? String.fetchOne(d, sql: "SELECT MAX(timestamp) FROM frames")) ?? nil
            return (fc, ac, tc, minTs.flatMap(isoToMs), maxTs.flatMap(isoToMs))
        }

        // 视频 chunks 数 + 总字节(让 UI 提示用户要拷多少 GB)
        // 单独 read,因为需要文件 stat,不能在前面 read closure 里做。
        let chunkRows: [(id: Int64, path: String)] = try q.read { d -> [(Int64, String)] in
            let chunkSQL: String
            if cutoffSec != nil {
                chunkSQL = """
                    SELECT DISTINCT vc.id, vc.file_path
                    FROM video_chunks vc
                    INNER JOIN frames f ON f.video_chunk_id = vc.id
                    WHERE CAST(strftime('%s', f.timestamp) AS INTEGER) < :cutoff
                    """
            } else {
                chunkSQL = """
                    SELECT DISTINCT vc.id, vc.file_path
                    FROM video_chunks vc
                    INNER JOIN frames f ON f.video_chunk_id = vc.id
                    """
            }
            var chunkArgs: StatementArguments = [:]
            if let cu = cutoffSec { chunkArgs = ["cutoff": cu] }
            return try Row.fetchAll(d, sql: chunkSQL, arguments: chunkArgs).map {
                ($0["id"], ($0["file_path"] as String?) ?? "")
            }
        }
        // stat 实际待拷字节(已存在的复用就不算)
        let fm = FileManager.default
        let videoRoot = Storage.videoDir
        var chunksToImport = 0
        var bytesEst: Int64 = 0
        for (_, path) in chunkRows {
            let srcAbs: URL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : dir.appendingPathComponent(path)
            guard fm.fileExists(atPath: srcAbs.path) else { continue }
            let base = "imported_\(srcAbs.lastPathComponent)"
            // 粗略 day 估算 —— 用文件名里 unix_ms 抽,失败用 mtime
            let dayDir = videoRoot.appendingPathComponent("*")
            _ = dayDir   // 实际路径要 startTsMs 算,scan 阶段不必精确,只用来探重
            // 已存在的不算(避免重复 stat 多算)
            // 简化:任何一个候选 day 目录里有同名文件就算已拷。
            var alreadyExists = false
            if let days = try? fm.contentsOfDirectory(atPath: videoRoot.path) {
                for day in days {
                    let candidate = videoRoot.appendingPathComponent(day).appendingPathComponent(base)
                    if fm.fileExists(atPath: candidate.path) { alreadyExists = true; break }
                }
            }
            if alreadyExists { continue }
            chunksToImport += 1
            if let size = (try? srcAbs.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                bytesEst += Int64(size)
            }
        }
        return ScanResult(
            sourceDir: dir, dbPath: db, exists: true, cutoffMs: cutoffMs,
            frameCount: fc,
            videoChunkCount: chunksToImport,
            videoBytesEst: bytesEst,
            audioChunkCount: ac, audioTranscriptCount: tc,
            earliestMs: minMs, latestMs: maxMs
        )
    }

    let sourceDir: URL

    init(sourceDir: URL = ScreenpipeImporter.defaultSourceDir) {
        self.sourceDir = sourceDir
    }

    /// 主入口。
    /// - Parameters:
    ///   - target: 目标 My-Portrait DatabasePool。
    ///   - onProgress: 进度回调,主线程友好(实际调用线程不保证 MainActor)。
    /// - Returns: Report —— 总导入 / 跳过 / 错误数。
    func run(
        into target: DatabasePool,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Report {
        onProgress?(Progress(stage: .scanning, current: 0, total: 0, bytesDone: 0, bytesTotal: 0))

        // 1. 找 source db
        let sourceDB = sourceDir.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: sourceDB.path) else {
            throw ImportError.sourceMissing(sourceDB.path)
        }

        // 2. 算 cutoff:My-Portrait 最早**带媒体**的 frame ts。无媒体的老
        // imported frames 不算,允许这次回头补 video_chunk(B 方案 backfill 场景)。
        let cutoffMs = try await Task.detached(priority: .userInitiated) {
            try target.read { db in
                try Int64.fetchOne(
                    db, sql: """
                        SELECT MIN(timestamp_ms) FROM frames
                        WHERE snapshot_path IS NOT NULL OR video_chunk_id IS NOT NULL
                        """
                )
            }
        }.value
        importLog.info("cutoff_ms=\(cutoffMs.map(String.init) ?? "nil", privacy: .public) (MyPortrait earliest with media)")

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

        // 4. 拷 MP4 video_chunks → 拿 chunkId map
        let (chunkIdMap, videoChunksIn, videoBytes) = try await Task.detached(priority: .userInitiated) { [sourceDir] in
            try Self.importVideoChunks(
                source: source, target: target,
                cutoffMs: cutoffMs, sourceDir: sourceDir,
                onProgress: onProgress
            )
        }.value

        // 5. 导 frames + ocr_text(UPSERT:ts+app 已存在 → UPDATE video_chunk_id)
        let (framesIn, framesBackfilled, skippedFrames) = try await Task.detached(priority: .userInitiated) {
            try Self.importFrames(
                source: source, target: target,
                cutoffMs: cutoffMs, chunkIdMap: chunkIdMap,
                onProgress: onProgress
            )
        }.value

        // 6. 导 audio_chunks + audio_transcriptions
        let (chunksIn, transcriptsIn) = try await Task.detached(priority: .userInitiated) {
            try Self.importAudio(
                source: source, target: target, cutoffMs: cutoffMs,
                onProgress: onProgress
            )
        }.value

        onProgress?(Progress(stage: .done, current: 1, total: 1, bytesDone: 0, bytesTotal: 0))

        return Report(
            cutoffMs: cutoffMs,
            framesImported: framesIn,
            framesBackfilled: framesBackfilled,
            videoChunksImported: videoChunksIn,
            videoBytesCopied: videoBytes,
            audioChunksImported: chunksIn,
            audioTranscriptsImported: transcriptsIn,
            skippedFramesNoOCR: skippedFrames,
            errorMessage: nil
        )
    }

    // MARK: - Video chunks (B 方案:真拷 MP4)

    /// 拷 screenpipe MP4 chunks 到 ~/.portrait/raw_data/video/<day>/imported/,
    /// 同时 INSERT My-Portrait video_chunks 行,返回 old_chunk_id → new_chunk_id 映射
    /// 给 importFrames 用。
    ///
    /// 已经拷过的 chunk(file_path basename 比对) → 复用 new_id 不重复拷。
    /// fps / start_ts_ms / end_ts_ms / frame_count 从 screenpipe.frames JOIN 算。
    private static func importVideoChunks(
        source: DatabaseQueue,
        target: DatabasePool,
        cutoffMs: Int64?,
        sourceDir: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> (chunkIdMap: [Int64: Int64], imported: Int, bytesCopied: Int64) {
        let cutoffSec: Int64? = cutoffMs.map { $0 / 1000 }

        // 拉所有 chunks(JOIN frames 算 start/end/count/fps),按 cutoff 过滤
        struct ChunkRow: Sendable {
            let oldId: Int64
            let filePath: String       // 原 screenpipe 路径(可能相对)
            let startTsMs: Int64
            let endTsMs: Int64
            let frameCount: Int
            let fps: Double
        }
        let rows: [ChunkRow] = try source.read { db in
            let sql: String
            if cutoffSec != nil {
                sql = """
                    SELECT vc.id, vc.file_path,
                           (CAST(strftime('%s', MIN(f.timestamp)) AS INTEGER) * 1000) AS start_ms,
                           (CAST(strftime('%s', MAX(f.timestamp)) AS INTEGER) * 1000) AS end_ms,
                           COUNT(f.id) AS n
                    FROM video_chunks vc
                    INNER JOIN frames f ON f.video_chunk_id = vc.id
                    WHERE CAST(strftime('%s', f.timestamp) AS INTEGER) < :cutoff
                    GROUP BY vc.id, vc.file_path
                    """
            } else {
                sql = """
                    SELECT vc.id, vc.file_path,
                           (CAST(strftime('%s', MIN(f.timestamp)) AS INTEGER) * 1000) AS start_ms,
                           (CAST(strftime('%s', MAX(f.timestamp)) AS INTEGER) * 1000) AS end_ms,
                           COUNT(f.id) AS n
                    FROM video_chunks vc
                    INNER JOIN frames f ON f.video_chunk_id = vc.id
                    GROUP BY vc.id, vc.file_path
                    """
            }
            var args: StatementArguments = [:]
            if let c = cutoffSec { args = ["cutoff": c] }
            return try Row.fetchAll(db, sql: sql, arguments: args).map {
                let start = ($0["start_ms"] as Int64?) ?? 0
                let end = ($0["end_ms"] as Int64?) ?? start
                let n = ($0["n"] as Int64?).map { Int($0) } ?? 0
                let durS = max(1.0, Double(end - start) / 1000.0)
                let fps = n > 1 ? max(0.1, Double(n) / durS) : 1.0
                return ChunkRow(
                    oldId: $0["id"],
                    filePath: ($0["file_path"] as String?) ?? "",
                    startTsMs: start, endTsMs: end, frameCount: n, fps: fps
                )
            }
        }
        importLog.info("video_chunks to consider: \(rows.count, privacy: .public)")

        // 拷文件到 ~/.portrait/raw_data/video/<day>/imported_<basename>
        var idMap: [Int64: Int64] = [:]
        var importedCount = 0
        var bytesCopied: Int64 = 0
        let fm = FileManager.default
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let videoRoot = Storage.videoDir
        try fm.createDirectory(at: videoRoot, withIntermediateDirectories: true)

        // 总字节估算给进度条 —— 跟 scan 同款 stat。也算 chunk 总数。
        var bytesTotal: Int64 = 0
        for r in rows {
            let src: URL = r.filePath.hasPrefix("/")
                ? URL(fileURLWithPath: r.filePath)
                : sourceDir.appendingPathComponent(r.filePath)
            if fm.fileExists(atPath: src.path),
               let s = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                bytesTotal += Int64(s)
            }
        }
        let total = rows.count
        onProgress?(Progress(
            stage: .copyingVideo, current: 0, total: total,
            bytesDone: 0, bytesTotal: bytesTotal
        ))

        for (idx, r) in rows.enumerated() {
            // 1. resolve source path:可能是绝对路径,可能 sourceDir 相对
            let srcAbs: URL = r.filePath.hasPrefix("/")
                ? URL(fileURLWithPath: r.filePath)
                : sourceDir.appendingPathComponent(r.filePath)
            guard fm.fileExists(atPath: srcAbs.path) else {
                importLog.warning("video chunk source missing: \(srcAbs.path, privacy: .public) — skip")
                continue
            }
            // 2. 按 chunk start_ts day 分目录
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"
            dayFmt.timeZone = TimeZone(identifier: "UTC")
            let day = dayFmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.startTsMs) / 1000))
            let dayDir = videoRoot.appendingPathComponent(day, isDirectory: true)
            try? fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let destName = "imported_\(srcAbs.lastPathComponent)"
            let destAbs = dayDir.appendingPathComponent(destName)

            // 3. 已存在同名 → 复用(再 import 同 chunk 不重复拷)
            if fm.fileExists(atPath: destAbs.path) {
                // 找已有 My-Portrait video_chunks 行
                let relPath = "raw_data/video/\(day)/\(destName)"
                let existingId: Int64? = try? target.read { d in
                    try Int64.fetchOne(
                        d,
                        sql: "SELECT id FROM video_chunks WHERE file_path = :p",
                        arguments: ["p": relPath]
                    )
                }
                if let eid = existingId {
                    idMap[r.oldId] = eid
                    continue
                }
                // 文件在但 DB 没行(被清过) → 当成新文件继续
            } else {
                do {
                    try fm.copyItem(at: srcAbs, to: destAbs)
                    let size = (try? destAbs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    bytesCopied += Int64(size)
                } catch {
                    importLog.warning("copy failed \(srcAbs.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    continue
                }
            }

            // 4. INSERT My-Portrait video_chunks(path 存 Storage.rootURL 相对,
            //    跟原 capture 流水线一致 —— compactor / retention 都按相对路径)。
            let relPath = "raw_data/video/\(day)/\(destName)"
            let newId: Int64 = try target.write { d in
                try d.execute(sql: """
                    INSERT INTO video_chunks
                        (file_path, device_name, fps, start_ts_ms, end_ts_ms,
                         frame_count, created_at_ms)
                    VALUES (:fp, 'imported', :fps, :st, :en, :n, :now)
                    """,
                    arguments: [
                        "fp": relPath, "fps": r.fps,
                        "st": r.startTsMs, "en": r.endTsMs,
                        "n": Int64(r.frameCount), "now": nowMs
                    ])
                return d.lastInsertedRowID
            }
            idMap[r.oldId] = newId
            importedCount += 1
            // tick 进度 —— 每个 chunk 完一份 callback。文件大 callback 间隔
            // 几秒,UI 看着够 smooth。
            onProgress?(Progress(
                stage: .copyingVideo, current: idx + 1, total: total,
                bytesDone: bytesCopied, bytesTotal: bytesTotal
            ))
        }
        importLog.info("video chunks imported=\(importedCount, privacy: .public) bytes=\(bytesCopied, privacy: .public)")
        return (idMap, importedCount, bytesCopied)
    }

    // MARK: - Frames

    /// JOIN screenpipe `frames` × `ocr_text`,转换 ISO TIMESTAMP → UTC ms,
    /// INSERT/UPSERT 到 My-Portrait `frames`。
    /// - UPSERT 模式:同 (ts, app) 已存在的 frame → UPDATE video_chunk_id (B 方案
    ///   backfill);不存在 → INSERT 新行。
    /// - 无 OCR 的 frame 跳过(My-Portrait full_text notNull,且没 OCR 就没价值)。
    private static func importFrames(
        source: DatabaseQueue,
        target: DatabasePool,
        cutoffMs: Int64?,
        chunkIdMap: [Int64: Int64],
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> (inserted: Int, backfilled: Int, skippedNoOCR: Int) {
        var inserted = 0
        var backfilled = 0
        var skipped = 0

        // 批量 fetch(全捞到内存,几万 rows 通常 ~50MB)。带 video_chunk_id +
        // start_ts 算 offset_ms。
        let rows: [SourceFrameRow] = try source.read { db in
            let cutoffSec: Int64? = cutoffMs.map { $0 / 1000 }
            let sql: String
            if cutoffSec != nil {
                sql = """
                    SELECT f.id, f.timestamp, f.app_name, f.window_name, f.browser_url, f.focused,
                           f.video_chunk_id, o.text
                    FROM frames f
                    LEFT JOIN ocr_text o ON o.frame_id = f.id
                    WHERE CAST(strftime('%s', f.timestamp) AS INTEGER) < :cutoff
                    ORDER BY f.timestamp ASC
                    """
            } else {
                sql = """
                    SELECT f.id, f.timestamp, f.app_name, f.window_name, f.browser_url, f.focused,
                           f.video_chunk_id, o.text
                    FROM frames f
                    LEFT JOIN ocr_text o ON o.frame_id = f.id
                    ORDER BY f.timestamp ASC
                    """
            }
            var args: StatementArguments = [:]
            if let c = cutoffSec { args = ["cutoff": c] }

            return try Row.fetchAll(db, sql: sql, arguments: args).map { r -> SourceFrameRow in
                SourceFrameRow(
                    timestampISO: r["timestamp"] as String? ?? "",
                    appName: r["app_name"] as String? ?? "unknown",
                    windowName: r["window_name"] as String?,
                    browserURL: r["browser_url"] as String?,
                    focused: (r["focused"] as Int64?).map { $0 != 0 } ?? true,
                    sourceVideoChunkId: r["video_chunk_id"] as Int64?,
                    ocrText: r["text"] as String?
                )
            }
        }
        importLog.info("screenpipe frames to consider: \(rows.count, privacy: .public)")

        // 拿 video_chunks 的 start_ts_ms 给 offset_ms 算
        let chunkStartTs: [Int64: Int64] = try target.read { db in
            var out: [Int64: Int64] = [:]
            for (_, newId) in chunkIdMap {
                if let st = try Int64.fetchOne(
                    db, sql: "SELECT start_ts_ms FROM video_chunks WHERE id = :id",
                    arguments: ["id": newId]
                ) {
                    out[newId] = st
                }
            }
            return out
        }

        let total = rows.count
        onProgress?(Progress(
            stage: .importingFrames, current: 0, total: total,
            bytesDone: 0, bytesTotal: 0
        ))
        var processed = 0
        try target.write { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // 每 ~200 行回调一次 UI,避免 callback overhead 拖慢 INSERT。
            let tickEvery = max(1, total / 50)
            for r in rows {
                processed += 1
                if processed % tickEvery == 0 || processed == total {
                    onProgress?(Progress(
                        stage: .importingFrames, current: processed, total: total,
                        bytesDone: 0, bytesTotal: 0
                    ))
                }
                guard let text = r.ocrText, !text.isEmpty else {
                    skipped += 1
                    continue
                }
                let ts = Self.isoToMs(r.timestampISO) ?? nowMs
                if let cutoff = cutoffMs, ts >= cutoff {
                    skipped += 1
                    continue
                }
                // 算这条 frame 该挂哪个 My-Portrait chunk + offset_ms
                let newChunkId: Int64? = r.sourceVideoChunkId.flatMap { chunkIdMap[$0] }
                let offsetMs: Int64? = newChunkId.flatMap { id in
                    chunkStartTs[id].map { max(0, ts - $0) }
                }

                // UPSERT:同 (ts, app) 已存在 → UPDATE video_chunk_id / offset_ms
                // (B 方案 backfill 场景)。否则 INSERT 新行。
                let existingId: Int64? = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM frames
                        WHERE timestamp_ms = :ts AND app_name = :app
                          AND device_name = 'imported'
                        LIMIT 1
                        """,
                    arguments: ["ts": ts, "app": r.appName]
                )
                if let eid = existingId {
                    // 已有行:只补 video_chunk_id + offset_ms,别的字段保留
                    if let newChunkId = newChunkId {
                        try db.execute(sql: """
                            UPDATE frames
                            SET video_chunk_id = :vc, offset_ms = :off
                            WHERE id = :id
                            """,
                            arguments: [
                                "vc": newChunkId, "off": offsetMs,
                                "id": eid
                            ])
                        backfilled += 1
                    } else {
                        // 同 ts 已存在 + 这次没新 chunk → 真重复,跳过
                        skipped += 1
                    }
                } else {
                    try db.execute(sql: """
                        INSERT INTO frames
                            (timestamp_ms, app_name, window_name, browser_url, focused,
                             device_name, snapshot_path, video_chunk_id, offset_ms,
                             capture_trigger, full_text, text_source, created_at_ms)
                        VALUES (:ts, :app, :win, :url, :focused,
                                'imported', NULL, :vc, :off,
                                'screenpipe_import', :text, 'ocr', :now)
                        """,
                        arguments: [
                            "ts": ts, "app": r.appName, "win": r.windowName,
                            "url": r.browserURL, "focused": r.focused,
                            "vc": newChunkId, "off": offsetMs,
                            "text": text, "now": nowMs
                        ])
                    inserted += 1
                }
            }
        }
        importLog.info("frames inserted=\(inserted, privacy: .public) backfilled=\(backfilled, privacy: .public) skipped=\(skipped, privacy: .public)")
        return (inserted, backfilled, skipped)
    }

    // MARK: - Audio

    /// JOIN screenpipe `audio_chunks` × `audio_transcriptions`,先插 chunk 拿
    /// 新 id,再按这个 id 插 transcripts(My-Portrait audio_chunks 有 FK)。
    private static func importAudio(
        source: DatabaseQueue,
        target: DatabasePool,
        cutoffMs: Int64?,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> (chunks: Int, transcripts: Int) {
        var importedChunks = 0
        var importedTranscripts = 0

        // 同 importFrames 用 strftime sec 比较 —— 避免字符串两种格式问题。
        let cutoffSec: Int64? = cutoffMs.map { $0 / 1000 }

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
            if cutoffSec != nil {
                chunkSQL = """
                    SELECT ac.id, ac.file_path,
                           (CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER) * 1000) AS first_ms,
                           (CAST(strftime('%s', MAX(at.timestamp)) AS INTEGER)
                          - CAST(strftime('%s', MIN(at.timestamp)) AS INTEGER)) AS dur_s
                    FROM audio_chunks ac
                    JOIN audio_transcriptions at ON at.audio_chunk_id = ac.id
                    WHERE CAST(strftime('%s', at.timestamp) AS INTEGER) < :cutoff
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
            if let c = cutoffSec { chunkArgs = ["cutoff": c] }
            let chunkRows = try Row.fetchAll(db, sql: chunkSQL, arguments: chunkArgs).map {
                ChunkRow(
                    oldId: $0["id"], filePath: $0["file_path"] as String? ?? "",
                    firstTsMs: $0["first_ms"] as Int64? ?? 0,
                    durationS: Double($0["dur_s"] as Int64? ?? 0)
                )
            }

            // transcripts
            let transcriptSQL: String
            if cutoffSec != nil {
                transcriptSQL = """
                    SELECT audio_chunk_id, timestamp, transcription
                    FROM audio_transcriptions
                    WHERE CAST(strftime('%s', timestamp) AS INTEGER) < :cutoff
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
            if let c = cutoffSec { transArgs = ["cutoff": c] }
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
        let totalChunks = chunks.count
        let totalTranscripts = transcripts.count
        let totalTicks = totalChunks + totalTranscripts
        var ticked = 0
        let tickEvery = max(1, totalTicks / 50)
        onProgress?(Progress(
            stage: .importingAudio, current: 0, total: totalTicks,
            bytesDone: 0, bytesTotal: 0
        ))
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
                ticked += 1
                if ticked % tickEvery == 0 || ticked == totalTicks {
                    onProgress?(Progress(
                        stage: .importingAudio, current: ticked, total: totalTicks,
                        bytesDone: 0, bytesTotal: 0
                    ))
                }
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
                ticked += 1
                if ticked % tickEvery == 0 || ticked == totalTicks {
                    onProgress?(Progress(
                        stage: .importingAudio, current: ticked, total: totalTicks,
                        bytesDone: 0, bytesTotal: 0
                    ))
                }
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
        /// 源端 video_chunks.id —— importVideoChunks 拷完后通过 idMap 映射到
        /// My-Portrait video_chunks.id 当 frames.video_chunk_id 用。
        let sourceVideoChunkId: Int64?
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
