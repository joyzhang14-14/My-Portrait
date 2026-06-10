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
///   4. 每组按时间排序，切成 ≤ 60s 时长的 chunk（≤ 100 帧为安全帽）
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
            if Task.isCancelled { return }
            await self?.sweepOrphanMedia()   // 每次启动清一次历史孤儿
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

    // MARK: - 孤儿媒体清扫

    /// 启动期清一次历史孤儿(基于 DB 引用,与文件名无关):
    ///  - JPG:compactChunk 的 DB 事务提交(snapshot_path 置 NULL)后、删文件前
    ///    崩溃/被 kill —— framesToCompact 只查 snapshot_path IS NOT NULL,
    ///    这些文件从此无人访问,永久残留
    ///  - MP4:编码中途崩溃留下的半成品 / 行被删后残留的文件
    /// 只动 mtime 超过 7 天的文件:(1) 新 JPG 先落盘、insertFrame 随后,
    /// 在编 MP4 尚未入库 —— 都不能误删;(2) CaptureCoordinator 承诺
    /// insertFrame 失败时已落盘的 JPG 可事后回补 —— 留一周回补窗口,
    /// 孤儿本来就只在启动期清一次,不急。
    private func sweepOrphanMedia() async {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let jpg = await sweepDir(config.framesDir, ext: "jpg", olderThan: cutoff) { [db] paths in
            try await db.referencedSnapshotPaths(in: paths)
        }
        let mp4 = await sweepDir(config.videoDir, ext: "mp4", olderThan: cutoff) { [db] paths in
            try await db.referencedVideoPaths(in: paths)
        }
        if jpg + mp4 > 0 {
            logger.info("orphan media sweep: removed \(jpg, privacy: .public) JPG + \(mp4, privacy: .public) MP4")
        }
    }

    /// 单次启动每个目录最多删这么多文件。真实孤儿来源(崩溃窗口)单次最多
    /// 100 个 JPG + 个位数 MP4,远超说明判定大概率不对(见 sweepDir 护栏注释)。
    private static let sweepMaxRemovals = 500

    /// 枚举 `dir` 下指定扩展名、mtime 早于 `cutoff` 的文件,删掉 DB 不引用的。
    /// 返回删除数。查询失败 → 一个都不删(宁可留垃圾,不误删)。
    ///
    /// 两道大规模误删护栏 —— 数据树是 relocatable 的,portrait.sqlite 和
    /// raw_data 是独立文件,用户删库重建 / 只迁移媒体目录时「DB 不引用」
    /// 不等于「是孤儿」:
    ///  1. 候选不少而 DB 引用为空 → 多半是新建/重置过的库,整目录跳过
    ///  2. 单次删除量超过 sweepMaxRemovals → 只告警不删(误判宁可留垃圾)
    private func sweepDir(
        _ dir: URL, ext: String, olderThan cutoff: Date,
        referenced: ([String]) async throws -> Set<String>
    ) async -> Int {
        let fm = FileManager.default
        let absPaths = Self.listFiles(in: dir, ext: ext, olderThan: cutoff)
        guard !absPaths.isEmpty else { return 0 }

        // DB 存的是相对 root 的路径(AssetPath),membership 按相对路径比。
        let refs: Set<String>
        do {
            refs = try await referenced(absPaths.map(AssetPath.normalize))
        } catch {
            logger.warning("orphan sweep query failed for \(dir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
        // 护栏 1:有一批候选文件但 DB 一条都不引用 → 库八成被重建/换过,
        // 这些不是孤儿,是还没有(或不再有)行的真实数据。
        if refs.isEmpty, absPaths.count > 20 {
            logger.warning("orphan sweep skipped \(dir.lastPathComponent, privacy: .public): \(absPaths.count, privacy: .public) candidates but zero DB references (rebuilt/replaced DB?)")
            return 0
        }
        let doomed = absPaths.filter { !refs.contains(AssetPath.normalize($0)) }
        // 护栏 2:量级离谱 → 不删,留给人看。
        if doomed.count > Self.sweepMaxRemovals {
            logger.warning("orphan sweep skipped \(dir.lastPathComponent, privacy: .public): \(doomed.count, privacy: .public) unreferenced files exceeds cap \(Self.sweepMaxRemovals, privacy: .public), refusing bulk delete")
            return 0
        }
        var removed = 0
        for abs in doomed {
            if (try? fm.removeItem(atPath: abs)) != nil { removed += 1 }
        }
        return removed
    }

    /// 同步枚举(DirectoryEnumerator 的迭代器不能在 async 上下文用)。
    nonisolated private static func listFiles(in dir: URL, ext: String, olderThan cutoff: Date) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let it = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil)
        else { return [] }
        var absPaths: [String] = []
        for case let url as URL in it {
            guard url.pathExtension.lowercased() == ext else { continue }
            // screenpipe 导入文件一律跳过:importer 先 copyItem 后 INSERT 行,
            // 且 copyItem 保留源 mtime(历史录像落地即"很旧"),mtime 护栏对它
            // 无效 —— 导入进行中撞上 sweep 会误删刚拷完、行还没插的文件。
            guard !url.lastPathComponent.hasPrefix("imported_") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let mtime, mtime < cutoff else { continue }
            absPaths.append(url.path)
        }
        return absPaths
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

        // 编码。中途抛错(磁盘满/热限流/appendFailed)时删掉写了一半的 .mp4 ——
        // 否则错误传回 compactDevice 被吞,半成品残留;chunk 边界因坏帧移位后
        // 文件名不再复现,HEVCEncoder 的同名兜底也删不到它。
        let encoder = try HEVCEncoder(url: mp4Path, size: size)
        // 只追踪**真正编进 MP4** 的帧。跳过的帧若仍写元数据,offset_ms 会指向 MP4
        // 里不含它的位置,加上 JPG 被删 → 画面永久错位/丢失。
        var encoded = [firstFrame]
        do {
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
                encoded.append(frame)
            }

            try await encoder.finalize()
        } catch {
            try? FileManager.default.removeItem(at: mp4Path)
            throw error
        }

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
        let frameOffsets: [(frameId: Int64, offsetMs: Int)] = encoded.map { frame in
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

        // DB 事务完成后，删 JPG 文件。只删真正编进 MP4 的帧 —— 跳过的帧 JPG 留着
        // (下轮还能重试)。删失败不抛错（DB 已正确，JPG 残留无害）。
        for frame in encoded {
            try? FileManager.default.removeItem(atPath: frame.snapshotPath)
        }

        // Tell any timeline view holding a stale `TimelineState.frames`
        // array (with snapshotPath still pointing at JPGs we just deleted)
        // to refetch from DB.
        let affectedDay = Date(timeIntervalSince1970: TimeInterval(firstFrame.timestampMs) / 1000)
        // NotificationCenter 观察者在 post 所在线程同步执行;这里是后台 actor
        // 线程,而 TimelineView 的 onReceive 没有 receive(on: main),会在非主
        // 线程改 SwiftUI state。切回主线程再 post。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .timelineFramesChanged, object: affectedDay)
        }
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
