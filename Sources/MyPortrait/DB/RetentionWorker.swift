import Foundation
import os.log

/// 数据保留期 / 自动删除后台 worker。
///
/// 每天跑一次（cold-start 后 5 分钟 + 24h 兜底 timer）。读 ConfigStore.snapshot：
///   - `retentionDays`: 7 / 14 / 30 / 60 / 90 / forever
///   - `autoDeleteMode`: off / mediaOnly / everything
///
/// 流程：
///   1. retentionDays = forever 或 mode = off → 立即 return
///   2. cutoff = now - retentionDays * 86400_000
///   3. db.mediaPathsBefore(cutoff) 拿盘上文件清单
///   4. 删盘上文件（jpg + mp4 + wav + 配套 .meta.json / .transcript.json）
///   5. db.applyRetention(mode:, beforeMs:) 清 DB
///   6. 写 log（删了多少 + 模式 + 耗时）
///
/// **永远不删 ~/.portrait/audio_queue/ 里没在 DB 里的 wav** —— 那些是孤儿文件，
/// 应该由 user 手动看（journal 里也会标）。我们只删 DB 知道的。
actor RetentionWorker {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "retention")
    private let db: PortraitDB

    private let coldStartDelaySeconds: TimeInterval = 300        // 5 分钟
    private let pollIntervalSeconds: TimeInterval = 24 * 3600    // 1 天

    private var task: Task<Void, Never>?

    init(db: PortraitDB) {
        self.db = db
    }

    func start() {
        guard task == nil else { return }
        let coldNs = UInt64(coldStartDelaySeconds * 1_000_000_000)
        let pollNs = UInt64(pollIntervalSeconds * 1_000_000_000)
        task = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: coldNs)
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(nanoseconds: pollNs)
            }
        }
        logger.info("RetentionWorker started (24h cadence)")
    }

    func stop() {
        task?.cancel()
        task = nil
        logger.info("RetentionWorker stopped")
    }

    /// 立即跑一轮（调试 / 手动按钮 / 测试用）。
    func runOnce() async {
        let (days, mode, waitForTranscription) = readSettings()
        guard let cutoffDays = days, mode != .off else {
            // forever 或 off → 不动数据
            return
        }
        let now = Date()
        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(cutoffDays * 86400 * 1000)
        let modeRetention: RetentionMode = (mode == .mediaOnly) ? .mediaOnly : .everything

        logger.info("retention pass starting: mode=\(mode.rawValue, privacy: .public), cutoff_days=\(cutoffDays), cutoff_ms=\(cutoffMs), wait_for_transcription=\(waitForTranscription, privacy: .public)")
        let started = Date()

        // 1. 拿文件清单(wait_for_transcription 开 → 未转录音频不进清单,
        //    等转录产出文本后下一轮再删)
        let files: RetentionFileList
        do {
            files = try await db.mediaPathsBefore(ms: cutoffMs, excludeUntranscribedAudio: waitForTranscription)
        } catch {
            logger.error("mediaPathsBefore failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 2. 删盘上文件
        let totalFiles = files.snapshotPaths.count + files.videoChunkPaths.count + files.audioPaths.count
        deleteFiles(files)

        // 3. 清 DB
        let stats: RetentionStats
        do {
            stats = try await db.applyRetention(mode: modeRetention, beforeMs: cutoffMs, excludeUntranscribedAudio: waitForTranscription)
        } catch {
            logger.error("applyRetention failed: \(String(describing: error), privacy: .public)")
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        logger.info("retention pass done in \(elapsed, format: .fixed(precision: 2))s: files=\(totalFiles), frames_affected=\(stats.framesAffected), video_chunks_deleted=\(stats.videoChunksDeleted), audio_chunks_deleted=\(stats.audioChunksDeleted)")
    }

    // MARK: - 私有

    private func readSettings() -> (days: Int?, mode: AutoDeleteMode, waitForTranscription: Bool) {
        let s = ConfigStore.snapshot

        let retention = RetentionDays(rawValue: s.retentionDays) ?? .d30
        let days: Int? = {
            switch retention {
            case .d7: return 7
            case .d14: return 14
            case .d30: return 30
            case .d60: return 60
            case .d90: return 90
            case .forever: return nil
            }
        }()

        let mode = AutoDeleteMode(rawValue: s.autoDeleteMode) ?? .off

        return (days, mode, s.waitForTranscription)
    }

    private func deleteFiles(_ files: RetentionFileList) {
        let fm = FileManager.default

        // 硬护栏:retention 只删 ~/.portrait 树内的文件。早期 screenpipe import 的
        // audio_chunks 行 file_path 可能指向只读的 ~/.screenpipe 原始录音 —— 绝不能
        // 删(那是用户原始数据,且 ~/.screenpipe 全程只读)。任何 ~/.portrait 之外的
        // 路径直接跳过 + 警告。新导入已改成拷贝进 ~/.portrait,这道护栏兜底历史行。
        let root = Storage.rootURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        func safeRemove(_ path: String) {
            guard path.hasPrefix(rootPrefix) else {
                logger.warning("retention skipped out-of-tree path (not under ~/.portrait): \(path, privacy: .public)")
                return
            }
            try? fm.removeItem(atPath: path)
        }

        // 屏幕快照 jpg
        for path in files.snapshotPaths { safeRemove(path) }

        // 视频块 mp4
        for path in files.videoChunkPaths { safeRemove(path) }

        // 音频 wav + 配套 sidecar
        for path in files.audioPaths {
            safeRemove(path)
            // 同时删 .meta.json 和 .transcript.json（同名兄弟）
            let url = URL(fileURLWithPath: path)
            let base = url.deletingPathExtension()
            safeRemove(base.appendingPathExtension("meta.json").path)
            safeRemove(base.appendingPathExtension("transcript.json").path)
        }
    }
}
