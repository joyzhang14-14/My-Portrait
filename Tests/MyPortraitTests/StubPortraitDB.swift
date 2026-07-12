import Foundation
@testable import MyPortrait

/// `PortraitDB` 协议的占位实现，**只在 Tests target 用**。
///
/// 所有方法 throw `notImplemented`，状态栏会冒红点（通过 reporter）。
/// 单元测试用此 stub 验证 capture 流水线在 DB 全失败时的降级行为。
///
/// 注：曾在 Sources/MyPortrait/Capture/DB/StubPortraitDB.swift 存在过；
/// 真 DB 接通后从 Sources 删除，按用户要求"只在 Tests target 中保留"。
final class StubPortraitDB: PortraitDB, Sendable {

    private let reporter: UnimplementedReporter

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
    }

    func insertFrame(_ record: FrameRecord) async throws -> Int64 {
        throw reporter.notImplemented("StubPortraitDB.insertFrame")
    }

    func insertFrameWithOCR(_ record: FrameRecord, ocr: OCRResult?) async throws -> Int64 {
        throw reporter.notImplemented("StubPortraitDB.insertFrameWithOCR")
    }

    func updateFrameOCR(frameId: Int64, ocr: OCRResult) async throws {
        throw reporter.notImplemented("StubPortraitDB.updateFrameOCR")
    }

    func framesToCompact(olderThanMs: Int64, limit: Int) async throws -> [FrameForCompaction] {
        throw reporter.notImplemented("StubPortraitDB.framesToCompact")
    }

    func replaceFramesWithVideoChunk(
        chunk: VideoChunkRecord,
        frames: [(frameId: Int64, offsetMs: Int)]
    ) async throws -> Int64 {
        throw reporter.notImplemented("StubPortraitDB.replaceFramesWithVideoChunk")
    }

    func referencedSnapshotPaths(in paths: [String]) async throws -> Set<String> {
        throw reporter.notImplemented("StubPortraitDB.referencedSnapshotPaths")
    }

    func referencedVideoPaths(in paths: [String]) async throws -> Set<String> {
        throw reporter.notImplemented("StubPortraitDB.referencedVideoPaths")
    }

    func insertAudioChunk(_ record: AudioChunkRecord) async throws -> Int64 {
        throw reporter.notImplemented("StubPortraitDB.insertAudioChunk")
    }

    func updateAudioChunkStatus(chunkId: Int64, status: AudioChunkStatus) async throws {
        throw reporter.notImplemented("StubPortraitDB.updateAudioChunkStatus")
    }

    func insertTranscription(_ record: TranscriptionRecord) async throws {
        throw reporter.notImplemented("StubPortraitDB.insertTranscription")
    }

    func pendingAudioChunks(limit: Int) async throws -> [AudioChunkRecord] {
        throw reporter.notImplemented("StubPortraitDB.pendingAudioChunks")
    }

    func audioBacklogStats() async throws -> (pendingCount: Int, oldestRecordedAtMs: Int64?) {
        throw reporter.notImplemented("StubPortraitDB.audioBacklogStats")
    }

    func resetInProgressAudioChunks() async throws -> Int {
        throw reporter.notImplemented("StubPortraitDB.resetInProgressAudioChunks")
    }

    func recordAudioChunkFailure(chunkId: Int64) async throws {
        throw reporter.notImplemented("StubPortraitDB.recordAudioChunkFailure")
    }

    func resetRetryableFailedAudioChunks() async throws -> Int {
        throw reporter.notImplemented("StubPortraitDB.resetRetryableFailedAudioChunks")
    }

    func transcriptionsForDedup(isInput: Bool, fromMs: Int64, toMs: Int64) async throws -> [TranscriptDeduper.Segment] {
        throw reporter.notImplemented("StubPortraitDB.transcriptionsForDedup")
    }

    func deleteTranscriptions(ids: [Int64]) async throws {
        throw reporter.notImplemented("StubPortraitDB.deleteTranscriptions")
    }

    func audioChunkTimeRangeMs() async throws -> (minMs: Int64, maxMs: Int64)? {
        throw reporter.notImplemented("StubPortraitDB.audioChunkTimeRangeMs")
    }

    func matchSpeaker(embedding: [Float], model: String) async throws -> SpeakerMatch {
        throw reporter.notImplemented("StubPortraitDB.matchSpeaker")
    }

    func enrollSpeaker(embedding: [Float], model: String) async throws -> Int64 {
        throw reporter.notImplemented("StubPortraitDB.enrollSpeaker")
    }

    func addEmbeddingToSpeaker(speakerId: Int64, embedding: [Float]) async throws {
        throw reporter.notImplemented("StubPortraitDB.addEmbeddingToSpeaker")
    }

    func nameSpeakerIfUnnamed(speakerId: Int64, name: String) async throws {
        throw reporter.notImplemented("StubPortraitDB.nameSpeakerIfUnnamed")
    }

    func mediaPathsBefore(ms: Int64, excludeUntranscribedAudio: Bool) async throws -> RetentionFileList {
        throw reporter.notImplemented("StubPortraitDB.mediaPathsBefore")
    }

    func applyRetention(mode: RetentionMode, beforeMs: Int64, audioChunkIds: [Int64]) async throws -> RetentionStats {
        throw reporter.notImplemented("StubPortraitDB.applyRetention")
    }

    func framesForDay(_ day: Date) async throws -> [TimelineFrame] {
        throw reporter.notImplemented("StubPortraitDB.framesForDay")
    }

    func activeAppsAround(timestamp: Date, windowSeconds: TimeInterval) async throws -> [ActiveAppEntry] {
        throw reporter.notImplemented("StubPortraitDB.activeAppsAround")
    }

    func audioTranscriptsAround(
        timestamp: Date,
        beforeSeconds: TimeInterval,
        afterSeconds: TimeInterval
    ) async throws -> [AudioTranscriptEntry] {
        throw reporter.notImplemented("StubPortraitDB.audioTranscriptsAround")
    }
}
