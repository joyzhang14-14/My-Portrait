import CoreGraphics
import Foundation
import ImageIO
import os.log

/// JPG → HEVC MP4 后台压缩。
///
/// 流程（每 5 分钟一轮）：
///   1. 电池模式 → 跳过
///   2. db.framesToCompact(olderThanMs: now - 10min, limit: 5000)
///   3. 按 deviceName 分组
///   4. 每组按时间排序，切成 ≤ 100 帧的 chunk
///   5. 每个 chunk：
///       - 探第一帧拿尺寸
///       - HEVCEncoder 编码 → 写 raw_data/video/YYYY-MM-DD/m{id}_{startTs}.mp4
///       - db.replaceFramesWithVideoChunk（事务）
///       - 删除原 JPG 文件
///
/// 抄 My-Orphies snapshot_compaction.rs 的参数：
///   - MIN_AGE_SECS = 600     (10 分钟前的 JPG 才压)
///   - POLL_INTERVAL = 300    (5 分钟一轮)
///   - MAX_FRAMES_PER_CHUNK = 100
///
/// 注：thermal-aware 节流（thermal 严重时 50 帧/块、延迟拉长）P3.1 再加。
actor CompactionWorker {

    private let db: PortraitDB
    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "compaction")

    private let minAgeSeconds: TimeInterval = 600        // 10 分钟
    private let pollIntervalSeconds: TimeInterval = 300  // 5 分钟
    /// MP4 块时长上限（毫秒）。设计文档要求 "60s/块"。
    private let maxChunkDurationMs: Int64 = 60_000
    /// 安全帽：万一时间戳异常（比如长 idle 后两帧间隔 > 60s），仍限制单块帧数。
    private let maxFramesPerChunk: Int = 100
    private let queryLimit: Int = 5000

    private var task: Task<Void, Never>?

    init(db: PortraitDB, reporter: UnimplementedReporter, config: CaptureConfig = .default) {
        self.db = db
        self.reporter = reporter
        self.config = config
    }

    var isRunning: Bool { task != nil }

    /// 启动后台循环。初次延迟 60s（让 app 启动期 CPU 让出来），之后每 5 分钟一轮。
    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60s 冷启动延迟
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(nanoseconds: UInt64(300) * 1_000_000_000)
            }
        }
        logger.info("CompactionWorker started")
    }

    func stop() {
        task?.cancel()
        task = nil
        logger.info("CompactionWorker stopped")
    }

    /// 立即跑一轮（手动触发 / 调试用）。
    func runOnce() async {
        // 1. 电池跳过。
        let powerState = PowerMonitor.currentState()
        if powerState == .battery {
            logger.info("on battery, skipping compaction pass")
            return
        }

        // 2. 查待压缩帧。
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs - Int64(minAgeSeconds * 1000)
        let frames: [FrameForCompaction]
        do {
            frames = try await db.framesToCompact(olderThanMs: cutoffMs, limit: queryLimit)
        } catch {
            logger.error("framesToCompact query failed: \(String(describing: error), privacy: .public)")
            return
        }

        if frames.isEmpty { return }
        logger.info("compacting \(frames.count) frames")

        // 3. 按 deviceName 分组，每组按时间排序。
        let grouped = Dictionary(grouping: frames, by: \.deviceName)
        for (device, group) in grouped {
            let sorted = group.sorted { $0.timestampMs < $1.timestampMs }
            await compactDevice(device: device, frames: sorted)
        }
    }

    // MARK: - 私有

    private func compactDevice(device: String, frames: [FrameForCompaction]) async {
        // 按"时间窗 ≤ 60s 或帧数 ≤ 100"切块。
        var index = 0
        while index < frames.count {
            let chunkStart = frames[index].timestampMs
            var end = index + 1
            while end < frames.count {
                let durationOK = frames[end].timestampMs - chunkStart <= maxChunkDurationMs
                let frameCountOK = (end - index) < maxFramesPerChunk
                if !durationOK || !frameCountOK { break }
                end += 1
            }
            let chunk = Array(frames[index..<end])
            index = end

            do {
                try await compactChunk(device: device, frames: chunk)
            } catch {
                logger.error("compactChunk(\(device, privacy: .public), n=\(chunk.count)) failed: \(String(describing: error), privacy: .public)")
                // 继续处理下一块，单块失败不阻塞。
            }
        }
    }

    private func compactChunk(device: String, frames: [FrameForCompaction]) async throws {
        guard let firstFrame = frames.first, let lastFrame = frames.last else { return }

        // 探第一帧拿尺寸。JPG 损坏跳过整块。
        guard let firstImage = loadJPG(at: firstFrame.snapshotPath) else {
            logger.warning("first frame JPG unreadable: \(firstFrame.snapshotPath, privacy: .public); skipping chunk")
            return
        }
        let size = CGSize(width: firstImage.width, height: firstImage.height)

        // 构 MP4 输出路径。
        let day = dayString(forMs: firstFrame.timestampMs)
        let mp4Path = config.videoDir
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("m\(device)_\(firstFrame.timestampMs).mp4")

        // 编码。
        let encoder = try HEVCEncoder(url: mp4Path, size: size)
        try encoder.start()

        // 第一帧已加载，直接喂。
        try await encoder.append(image: firstImage, timestampMs: firstFrame.timestampMs)

        // 其余帧逐个加载 + append（一次只持一帧）。
        for frame in frames.dropFirst() {
            guard let img = loadJPG(at: frame.snapshotPath) else {
                logger.warning("frame JPG unreadable: \(frame.snapshotPath, privacy: .public); skipping frame")
                continue
            }
            try await encoder.append(image: img, timestampMs: frame.timestampMs)
        }

        try await encoder.finalize()

        // 实际 fps = frame_count / duration_seconds
        let durationMs = max(1, lastFrame.timestampMs - firstFrame.timestampMs)
        let fps = Double(encoder.frameCount) * 1000.0 / Double(durationMs)

        // DB 事务：插 video_chunks + 更新 frames。
        let chunkRecord = VideoChunkRecord(
            filePath: mp4Path.path,
            deviceName: device,
            fps: fps,
            startTsMs: firstFrame.timestampMs,
            endTsMs: lastFrame.timestampMs,
            frameCount: encoder.frameCount
        )
        let frameOffsets: [(frameId: Int64, offsetMs: Int)] = frames.map { frame in
            (frame.id, Int(frame.timestampMs - firstFrame.timestampMs))
        }

        let chunkId: Int64
        do {
            chunkId = try await db.replaceFramesWithVideoChunk(
                chunk: chunkRecord, frames: frameOffsets
            )
        } catch {
            // DB 写失败 → 删掉刚生成的 mp4，避免孤儿文件。
            try? FileManager.default.removeItem(at: mp4Path)
            throw error
        }

        logger.info("video_chunk \(chunkId) written: \(encoder.frameCount) frames, \(durationMs)ms, \(mp4Path.lastPathComponent, privacy: .public)")

        // DB 事务完成后，删 JPG 文件。删失败不抛错（DB 已正确，JPG 残留无害）。
        for frame in frames {
            try? FileManager.default.removeItem(atPath: frame.snapshotPath)
        }

        // Tell any timeline view holding a stale `TimelineState.frames`
        // array (with snapshotPath still pointing at JPGs we just deleted)
        // to refetch from DB.
        let affectedDay = Date(timeIntervalSince1970: TimeInterval(firstFrame.timestampMs) / 1000)
        NotificationCenter.default.post(name: .timelineFramesChanged, object: affectedDay)
    }

    /// 读 JPG → CGImage。失败返回 nil。
    private func loadJPG(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayString(forMs ms: Int64) -> String {
        Self.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}
