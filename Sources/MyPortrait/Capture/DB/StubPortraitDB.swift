import Foundation

/// P0 占位实现。所有方法 throw `notImplemented`，让状态栏冒红点。
///
/// 真实实现归 DB 层：`Sources/MyPortrait/DB/PortraitDBImpl.swift`（用户写）。
/// 那个文件 import 这里的 protocol。
///
/// 注意：这个 stub **只在 P0 期间被 Services 使用**。
/// 一旦真实 PortraitDBImpl 写好，Services 切过去这个 stub 应该被删除。
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
}
