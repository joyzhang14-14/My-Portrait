import Foundation

/// 采集层 ↔ DB 层边界。
///
/// 实现归 DB 层（`Sources/MyPortrait/DB/PortraitDBImpl.swift`）。
/// 采集层只 import 这个 protocol，schema 变化时双方各自迭代不打架。
///
/// 这是"依赖倒置"：高层（采集）定义需求，低层（DB）满足。
///
/// 见 memory: project-module-layout。
protocol PortraitDB: Sendable {

    // MARK: - P1: 屏幕帧

    /// 插入一帧元数据（OCR 字段空），返回 frame id。
    /// 用于"先入库占位、OCR 异步回填"路径。
    func insertFrame(_ record: FrameRecord) async throws -> Int64

    /// 一次写入帧 + OCR。**性能路径首选**：避免两次 round-trip。
    /// OCR 失败时传 nil 即可。
    func insertFrameWithOCR(_ record: FrameRecord, ocr: OCRResult?) async throws -> Int64

    /// OCR 完成后回填（搭配 `insertFrame` 走异步路径时用）。
    /// 调用方应允许失败 —— OCR 不是关键路径，失败只 log。
    func updateFrameOCR(frameId: Int64, ocr: OCRResult) async throws

    // MARK: - P3: MP4 压缩

    /// 找出需要压缩的 JPG 帧（>10 分钟前、还有 snapshot_path）。
    func framesToCompact(olderThanMs: Int64, limit: Int) async throws -> [FrameForCompaction]

    /// 压完一个 MP4 后原子写入：
    ///   1. INSERT video_chunks 行
    ///   2. UPDATE 这些 frames 的 video_chunk_id + offset_ms，置 snapshot_path = NULL
    /// 返回新 video_chunks.id。
    /// 调用方在事务 commit 后删 JPG 文件。
    func replaceFramesWithVideoChunk(
        chunk: VideoChunkRecord,
        frames: [(frameId: Int64, offsetMs: Int)]
    ) async throws -> Int64

    // MARK: - P4: 音频

    func insertAudioChunk(_ record: AudioChunkRecord) async throws -> Int64
    func updateAudioChunkStatus(chunkId: Int64, status: AudioChunkStatus) async throws
    func insertTranscription(_ record: TranscriptionRecord) async throws
    func pendingAudioChunks(limit: Int) async throws -> [AudioChunkRecord]

    /// 启动时崩溃恢复：把所有 `status = in_progress` 的 audio_chunks 回退到 `pending`，
    /// 让 TranscriptionScheduler 下一轮拾起重跑。
    ///
    /// 触发场景：app 崩溃 / 强杀 / 系统休眠未唤醒等情况下，某个 chunk 被标
    /// in_progress 但 WhisperKit 那一步从未完成。没这一步会永远卡住。
    ///
    /// 返回受影响的行数（log 出来方便观察）。
    func resetInProgressAudioChunks() async throws -> Int

    // MARK: - 保留期 / 自动删除（RetentionWorker 用）

    /// 早于 `ms` 的所有媒体文件路径快照。
    /// RetentionWorker 先用这个清单删盘上文件，再调 `applyRetention(...)` 清 DB。
    func mediaPathsBefore(ms: Int64) async throws -> RetentionFileList

    /// 按 `mode` 清 DB：
    /// - `.mediaOnly`：NULL 掉 frames.snapshot_path / video_chunk_id；DELETE 旧 video_chunks。
    ///   保留 frames 行（含 OCR 文本）和 audio_chunks 行（含转录）。
    /// - `.everything`：DELETE frames / video_chunks / audio_chunks 三表所有早于 ms 的行。
    ///   audio_chunks DELETE CASCADE 到 audio_transcriptions。
    func applyRetention(mode: RetentionMode, beforeMs: Int64) async throws -> RetentionStats

    // MARK: - 读 (UI 用)

    /// 某天的全部帧（按 timestamp 升序），TimelineView 主体读这个。
    /// 包含 video_chunks JOIN 出来的 MP4 文件路径 + fps，方便 AVAssetImageGenerator 抠帧。
    func framesForDay(_ day: Date, limit: Int) async throws -> [TimelineFrame]

    /// 在某时刻附近活跃的 app 列表（按"最后出现时间"倒序），用于 Timeline 侧边栏。
    func activeAppsAround(timestamp: Date, windowSeconds: TimeInterval) async throws -> [ActiveAppEntry]

    /// 在某时刻附近的语音转录，用于 Timeline 侧边栏。
    func audioTranscriptsAround(
        timestamp: Date,
        beforeSeconds: TimeInterval,
        afterSeconds: TimeInterval
    ) async throws -> [AudioTranscriptEntry]

    // MARK: - 向量（Phase 4 Hybrid 搜索）

    /// 拉一批还没 embed 的 frame id（按时间倒序，新数据优先 embed）。
    /// EmbeddingWorker 后台调，一次几百个一批避开内存峰值。
    func framesNeedingEmbedding(limit: Int) async throws -> [Int64]

    /// 写 frame 的向量。`vector` 应该已 L2 归一化（cosine == dot 的前提）。
    func setFrameEmbedding(frameId: Int64, vector: [Float]) async throws

    /// 拉所有已 embed 的 (id, vector)。HybridSearchEngine 做 brute-force cosine 用。
    /// 数据量大时考虑分页或 sample；7000 行 × 1024 维 ≈ 28 MB，内存可承受。
    func allFrameEmbeddings(limit: Int) async throws -> [(id: Int64, vector: [Float])]

    /// 按 id 拉一批 frame 的元数据（HybridSearchEngine 拿到 RRF 结果后获取
    /// 显示字段）。返回顺序与 ids 顺序无关；调用方按 id 自己 reorder。
    func framesByIds(_ ids: [Int64]) async throws -> [FrameMetadata]
}

// MARK: - Records

/// 单帧元数据（写入时载体）。
struct FrameRecord: Sendable {
    let timestampMs: Int64       // UTC ms
    let appName: String
    let windowName: String?
    let browserUrl: String?
    let focused: Bool
    let deviceName: String       // monitor id，P1 = "main"
    let snapshotPath: String     // JPG 绝对路径
    let captureTrigger: String   // P1 = "timer"

    init(
        timestampMs: Int64, appName: String, windowName: String?,
        browserUrl: String?, focused: Bool, deviceName: String,
        snapshotPath: String, captureTrigger: String
    ) {
        self.timestampMs = timestampMs
        self.appName = appName
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.focused = focused
        self.deviceName = deviceName
        self.snapshotPath = snapshotPath
        self.captureTrigger = captureTrigger
    }
}

/// CompactionWorker 查询返回。
struct FrameForCompaction: Sendable {
    let id: Int64
    let timestampMs: Int64
    let snapshotPath: String
    let deviceName: String

    init(id: Int64, timestampMs: Int64, snapshotPath: String, deviceName: String) {
        self.id = id
        self.timestampMs = timestampMs
        self.snapshotPath = snapshotPath
        self.deviceName = deviceName
    }
}

struct VideoChunkRecord: Sendable {
    let filePath: String
    let deviceName: String
    let fps: Double
    let startTsMs: Int64
    let endTsMs: Int64
    let frameCount: Int

    init(
        filePath: String, deviceName: String, fps: Double,
        startTsMs: Int64, endTsMs: Int64, frameCount: Int
    ) {
        self.filePath = filePath
        self.deviceName = deviceName
        self.fps = fps
        self.startTsMs = startTsMs
        self.endTsMs = endTsMs
        self.frameCount = frameCount
    }
}

struct AudioChunkRecord: Sendable {
    let id: Int64?
    let filePath: String
    let recordedAtMs: Int64
    let durationS: Double
    let device: String
    let isInput: Bool
    let status: AudioChunkStatus

    init(
        id: Int64?, filePath: String, recordedAtMs: Int64, durationS: Double,
        device: String, isInput: Bool, status: AudioChunkStatus
    ) {
        self.id = id
        self.filePath = filePath
        self.recordedAtMs = recordedAtMs
        self.durationS = durationS
        self.device = device
        self.isInput = isInput
        self.status = status
    }
}

enum AudioChunkStatus: String, Sendable {
    case pending
    case inProgress = "in_progress"
    case done
    case failed
}

// MARK: - Retention 数据载体

enum RetentionMode: String, Sendable {
    /// 只删媒体文件 + 媒体 DB 引用，保留 frames 行（OCR 文本）和转录文本
    case mediaOnly
    /// 删媒体文件 + DB 行（一切）。CASCADE 到 transcriptions
    case everything
}

struct RetentionFileList: Sendable {
    let snapshotPaths: [String]    // .jpg
    let videoChunkPaths: [String]  // .mp4
    let audioPaths: [String]       // .wav (+ 配套 .meta.json / .transcript.json 由 worker 推断)

    init(snapshotPaths: [String], videoChunkPaths: [String], audioPaths: [String]) {
        self.snapshotPaths = snapshotPaths
        self.videoChunkPaths = videoChunkPaths
        self.audioPaths = audioPaths
    }
}

struct RetentionStats: Sendable {
    let framesAffected: Int
    let videoChunksDeleted: Int
    let audioChunksDeleted: Int

    init(framesAffected: Int, videoChunksDeleted: Int, audioChunksDeleted: Int) {
        self.framesAffected = framesAffected
        self.videoChunksDeleted = videoChunksDeleted
        self.audioChunksDeleted = audioChunksDeleted
    }
}

/// HybridSearchEngine 拿 RRF 排序结果后查元数据用的最小字段集。
/// 比 TimelineFrame 轻量：不带 videoPath/offsetIndex/fps 那一套（搜索结果不需要抠帧）。
struct FrameMetadata: Sendable {
    let id: Int64
    let timestampMs: Int64
    let appName: String
    let windowName: String?
    let browserUrl: String?
    let fullText: String?

    init(id: Int64, timestampMs: Int64, appName: String,
         windowName: String?, browserUrl: String?, fullText: String?) {
        self.id = id
        self.timestampMs = timestampMs
        self.appName = appName
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.fullText = fullText
    }
}

struct TranscriptionRecord: Sendable {
    let audioChunkId: Int64
    let startS: Double
    let endS: Double
    let text: String
    let speakerId: Int?
    let engine: String
    let transcribedAtMs: Int64

    init(
        audioChunkId: Int64, startS: Double, endS: Double, text: String,
        speakerId: Int?, engine: String, transcribedAtMs: Int64
    ) {
        self.audioChunkId = audioChunkId
        self.startS = startS
        self.endS = endS
        self.text = text
        self.speakerId = speakerId
        self.engine = engine
        self.transcribedAtMs = transcribedAtMs
    }
}
