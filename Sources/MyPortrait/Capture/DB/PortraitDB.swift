import Foundation

/// 采集层 ↔ DB 层边界。
///
/// 实现归 DB 层（`Sources/MyPortrait/DB/PortraitDBImpl.swift`）。
/// 采集层只 import 这个 protocol，schema 变化时双方各自迭代不打架。
///
/// 这是"依赖倒置"：高层（采集）定义需求，低层（DB）满足。
///
/// 见 memory: project-module-layout。

/// `matchSpeaker` 的三态结果。区分「明确命中」「模糊」「全不像」—— 后两者含义不同:
/// `.ambiguous`(跟两个**不同人**都接近,判别不开)不能 enroll 新人,否则边界段会
/// 变成新碎簇、反而加剧碎片化;只有 `.none`(跟谁都不像)才是真·新人。
enum SpeakerMatch: Sendable {
    case matched(Int64)
    case ambiguous
    case none
}

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

    /// 启动期孤儿媒体清扫用:给定一批 DB 存储格式(相对 root)的路径,
    /// 返回其中仍被 frames.snapshot_path 引用的子集。
    func referencedSnapshotPaths(in paths: [String]) async throws -> Set<String>

    /// 同上,对 video_chunks.file_path。
    func referencedVideoPaths(in paths: [String]) async throws -> Set<String>

    // MARK: - P4: 音频

    func insertAudioChunk(_ record: AudioChunkRecord) async throws -> Int64
    func updateAudioChunkStatus(chunkId: Int64, status: AudioChunkStatus) async throws
    func insertTranscription(_ record: TranscriptionRecord) async throws
    func pendingAudioChunks(limit: Int) async throws -> [AudioChunkRecord]

    /// audio_chunks pending 队列实时 stats。StallDetector 用来判 audioBacklog
    /// stall(数量 > 阈值且最老 chunk 已超 freshness)。
    ///
    /// 返回 `(pendingCount, oldestRecordedAtMs)`。`oldestRecordedAtMs == nil`
    /// 当 pendingCount = 0(没活时直接早退,不报 stall)。
    func audioBacklogStats() async throws -> (pendingCount: Int, oldestRecordedAtMs: Int64?)

    /// 转录失败：`status = failed` 且 `retry_count += 1`。
    /// 启动时 `resetRetryableFailedAudioChunks()` 会把 retry_count 没到上限的
    /// failed 行回退 pending 重跑。
    func recordAudioChunkFailure(chunkId: Int64) async throws

    /// 启动时崩溃恢复：把所有 `status = in_progress` 的 audio_chunks 回退到 `pending`，
    /// 让 TranscriptionScheduler 下一轮拾起重跑。
    ///
    /// 触发场景：app 崩溃 / 强杀 / 系统休眠未唤醒等情况下，某个 chunk 被标
    /// in_progress 但 WhisperKit 那一步从未完成。没这一步会永远卡住。
    ///
    /// 返回受影响的行数（log 出来方便观察）。
    func resetInProgressAudioChunks() async throws -> Int

    /// 启动时失败重试：把 `status = failed AND retry_count < 3` 的 audio_chunks
    /// 回退到 `pending` 重跑。retry_count >= 3 的保持 failed，不再重试。
    ///
    /// 返回受影响的行数。
    func resetRetryableFailedAudioChunks() async throws -> Int

    // MARK: - 跨通道转录去重(外放回录,见 TranscriptDeduper)

    /// 取某一通道在 [fromMs, toMs](按 chunk recorded_at_ms)内的全部转录段,
    /// 换算成绝对时间的去重视图。`isInput` true=麦克风,false=系统音频。
    func transcriptionsForDedup(isInput: Bool, fromMs: Int64, toMs: Int64) async throws -> [TranscriptDeduper.Segment]

    /// 删指定转录行(去重判定出的 mic 重复份)。
    /// 实现必须走注册了 FTS 分词器的连接(transcriptions_fts 同步触发器)。
    func deleteTranscriptions(ids: [Int64]) async throws

    /// audio_chunks 全表时间范围(MIN/MAX recorded_at_ms)。空表 → nil。
    /// 历史去重扫描用来分窗。
    func audioChunkTimeRangeMs() async throws -> (minMs: Int64, maxMs: Int64)?

    // MARK: - 说话人识别（speaker diarization）

    /// 找匹配的说话人。`embedding` 须已 L2 归一化。质心余弦 > 阈值才算候选;
    /// 命中需明显比「最强异名候选」更近(裕度),否则判 `.ambiguous`(防 Joy/Stan
    /// 声纹接近时把边界段标反)。详见 `SpeakerMatch`。
    /// `model` = 当前 embedding 模型 id（`en_campplus`/`zh_campplus`/...）—— 只跟
    /// 同一模型产的声纹比对(不同模型向量空间不兼容)。
    func matchSpeaker(embedding: [Float], model: String) async throws -> SpeakerMatch

    /// 新建说话人：centroid = `embedding`，写入首个样本，绑定 `model`，返回新 speaker id。
    func enrollSpeaker(embedding: [Float], model: String) async throws -> Int64

    /// 给已有说话人追加一个样本：更新 centroid（指数移动平均，有效计数上限 50），
    /// 样本数超 10 时轮换掉最接近 centroid 的（保多样性）。
    func addEmbeddingToSpeaker(speakerId: Int64, embedding: [Float]) async throws

    /// 给说话人命名，但仅当它当前还没名字（name 为 NULL 或空）。
    /// 用于把麦克风里的单一说话人自动标成用户本人。
    func nameSpeakerIfUnnamed(speakerId: Int64, name: String) async throws

    // MARK: - 保留期 / 自动删除（RetentionWorker 用）

    /// 早于 `ms` 的所有媒体文件路径快照。
    /// RetentionWorker 先用这个清单删盘上文件，再调 `applyRetention(...)` 清 DB。
    /// `excludeUntranscribedAudio` 开(wait_for_transcription 设置,默认开)→
    /// 还没转录完的音频(pending / in_progress / 还会重试的 failed)不进清单,
    /// 等转录产出文本后下一轮再删 —— 否则转录积压超过保留期时,mediaOnly
    /// 承诺保留的文本随文件一起永久丢失。
    func mediaPathsBefore(ms: Int64, excludeUntranscribedAudio: Bool) async throws -> RetentionFileList

    /// 按 `mode` 清 DB：
    /// - `.mediaOnly`：NULL 掉 frames.snapshot_path / video_chunk_id；DELETE 旧 video_chunks。
    ///   保留 frames 行（含 OCR 文本）和 audio_chunks 行（含转录）。
    /// - `.everything`：DELETE frames / video_chunks 所有早于 ms 的行;
    ///   audio_chunks 只删 `audioChunkIds` 这批 id(来自同一轮 `mediaPathsBefore`
    ///   的快照,CASCADE 到 audio_transcriptions)。**不重新按 status 求值** ——
    ///   文件清单与行删除之间转录管线在并发推进 status,两次独立求值会产生
    ///   「行删了文件没删」的永久孤儿 wav。
    func applyRetention(mode: RetentionMode, beforeMs: Int64, audioChunkIds: [Int64]) async throws -> RetentionStats

    // MARK: - 读 (UI 用)

    /// 某天的全部帧（按 timestamp 升序），TimelineView 主体读这个。
    /// 包含 video_chunks JOIN 出来的 MP4 文件路径 + fps，方便 AVAssetImageGenerator 抠帧。
    /// 不设 limit —— 一天的帧天然有界（秒数 × 采集频率封顶）。
    func framesForDay(_ day: Date) async throws -> [TimelineFrame]

    /// 在某时刻附近活跃的 app 列表（按"最后出现时间"倒序），用于 Timeline 侧边栏。
    func activeAppsAround(timestamp: Date, windowSeconds: TimeInterval) async throws -> [ActiveAppEntry]

    /// 在某时刻附近的语音转录，用于 Timeline 侧边栏。
    func audioTranscriptsAround(
        timestamp: Date,
        beforeSeconds: TimeInterval,
        afterSeconds: TimeInterval
    ) async throws -> [AudioTranscriptEntry]
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
    let windowsJson: String?     // CGWindowList 在屏窗口清单(前→后 z 序),v42 起

    init(
        timestampMs: Int64, appName: String, windowName: String?,
        browserUrl: String?, focused: Bool, deviceName: String,
        snapshotPath: String, captureTrigger: String,
        windowsJson: String? = nil
    ) {
        self.timestampMs = timestampMs
        self.appName = appName
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.focused = focused
        self.deviceName = deviceName
        self.snapshotPath = snapshotPath
        self.captureTrigger = captureTrigger
        self.windowsJson = windowsJson
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
    /// 进清单那一刻命中删除条件的 audio_chunks 行 id 快照。applyRetention
    /// (.everything) 按这批 id 删行,而不是再按 status 重新求值 —— 文件清单
    /// 与行删除之间隔着耗时的 deleteFiles,期间转录管线会推进 status,
    /// 两次独立求值会出现「行删了文件没删」的永久孤儿 wav。
    let audioChunkIds: [Int64]

    init(snapshotPaths: [String], videoChunkPaths: [String], audioPaths: [String], audioChunkIds: [Int64]) {
        self.snapshotPaths = snapshotPaths
        self.videoChunkPaths = videoChunkPaths
        self.audioPaths = audioPaths
        self.audioChunkIds = audioChunkIds
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
