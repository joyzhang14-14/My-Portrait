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

    func resetInProgressAudioChunks() async throws -> Int {
        throw reporter.notImplemented("StubPortraitDB.resetInProgressAudioChunks")
    }

    func mediaPathsBefore(ms: Int64) async throws -> RetentionFileList {
        throw reporter.notImplemented("StubPortraitDB.mediaPathsBefore")
    }

    func applyRetention(mode: RetentionMode, beforeMs: Int64) async throws -> RetentionStats {
        throw reporter.notImplemented("StubPortraitDB.applyRetention")
    }

    func framesForDay(_ day: Date, limit: Int) async throws -> [ScreenpipeFrame] {
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

    func framesNeedingEmbedding(limit: Int) async throws -> [Int64] {
        throw reporter.notImplemented("StubPortraitDB.framesNeedingEmbedding")
    }

    func setFrameEmbedding(frameId: Int64, vector: [Float]) async throws {
        throw reporter.notImplemented("StubPortraitDB.setFrameEmbedding")
    }

    func allFrameEmbeddings(limit: Int) async throws -> [(id: Int64, vector: [Float])] {
        throw reporter.notImplemented("StubPortraitDB.allFrameEmbeddings")
    }

    func framesByIds(_ ids: [Int64]) async throws -> [FrameMetadata] {
        throw reporter.notImplemented("StubPortraitDB.framesByIds")
    }
}
