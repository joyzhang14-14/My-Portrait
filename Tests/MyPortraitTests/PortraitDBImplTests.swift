import XCTest
@testable import MyPortrait

/// `PortraitDBImpl` 基础 CRUD + 搜索 happy-path 测试。用 `:memory:` 数据库，
/// 不碰磁盘，单测可重复跑。
final class PortraitDBImplTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() async throws {
        let fm = FileManager.default
        for path in tempPaths {
            // 删主 DB + WAL / SHM 兄弟文件
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + "-wal")
            try? fm.removeItem(atPath: path + "-shm")
        }
        tempPaths.removeAll()
    }

    /// 每个测试自己开一个 temp DB，互不污染。
    /// 不用 `:memory:` —— WAL 模式不支持内存 DB。
    private func makeDB() throws -> PortraitDBImpl {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPortraitTest-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        return try PortraitDBImpl(path: path)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Frames

    func testInsertAndQueryFrame() async throws {
        let db = try makeDB()
        let record = FrameRecord(
            timestampMs: nowMs(),
            appName: "Xcode",
            windowName: "MyPortrait.xcodeproj",
            browserUrl: nil,
            focused: true,
            deviceName: "main",
            snapshotPath: "/tmp/test_frame.jpg",
            captureTrigger: "manual"
        )
        let id = try await db.insertFrame(record)
        XCTAssertGreaterThan(id, 0)
    }

    func testInsertFrameWithOCRPersistsTextSource() async throws {
        let db = try makeDB()
        let record = FrameRecord(
            timestampMs: nowMs(),
            appName: "Safari",
            windowName: "GitHub - PR #42",
            browserUrl: "https://github.com/me/repo/pull/42",
            focused: true,
            deviceName: "main",
            snapshotPath: "/tmp/test.jpg",
            captureTrigger: "app_switch"
        )
        let ocr = OCRResult(
            fullText: "force-merging is unwise — better wait for review",
            words: [],            // empty + 1.0 confidence => AX text source heuristic
            avgConfidence: 1.0
        )
        XCTAssertEqual(ocr.textSource, .ax)

        let id = try await db.insertFrameWithOCR(record, ocr: ocr)
        XCTAssertGreaterThan(id, 0)

        // 文本进了 frames_fts，搜得到。
        let engine = FTSSearchEngine(dbPool: db.dbPool)
        let hits = try await engine.searchFrames(query: "force-merging", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.frameId, id)
    }

    // MARK: - 崩溃恢复

    func testResetInProgressAudioChunks() async throws {
        let db = try makeDB()

        // 插 2 个 in_progress + 1 个 done
        for i in 0..<3 {
            let status: AudioChunkStatus = (i == 2) ? .done : .inProgress
            let chunk = AudioChunkRecord(
                id: nil,
                filePath: "/tmp/\(i).wav",
                recordedAtMs: nowMs() + Int64(i),
                durationS: 10,
                device: "default_microphone",
                isInput: true,
                status: status
            )
            _ = try await db.insertAudioChunk(chunk)
        }

        let reset = try await db.resetInProgressAudioChunks()
        XCTAssertEqual(reset, 2)

        let pending = try await db.pendingAudioChunks(limit: 10)
        XCTAssertEqual(pending.count, 2)
    }

    // MARK: - Retention

    func testApplyRetentionMediaOnlyClearsPathsButKeepsRows() async throws {
        let db = try makeDB()
        let oldMs: Int64 = 1000
        let newMs: Int64 = nowMs()

        let oldRecord = FrameRecord(
            timestampMs: oldMs, appName: "Old", windowName: nil,
            browserUrl: nil, focused: true, deviceName: "main",
            snapshotPath: "/old.jpg", captureTrigger: "timer"
        )
        let newRecord = FrameRecord(
            timestampMs: newMs, appName: "New", windowName: nil,
            browserUrl: nil, focused: true, deviceName: "main",
            snapshotPath: "/new.jpg", captureTrigger: "timer"
        )
        _ = try await db.insertFrame(oldRecord)
        _ = try await db.insertFrame(newRecord)

        let cutoff = (oldMs + newMs) / 2
        let stats = try await db.applyRetention(mode: .mediaOnly, beforeMs: cutoff, audioChunkIds: [])
        XCTAssertEqual(stats.framesAffected, 1)            // 旧帧的 snapshot_path 被 NULL
        XCTAssertEqual(stats.videoChunksDeleted, 0)        // 没 video chunks
        XCTAssertEqual(stats.audioChunksDeleted, 0)        // mediaOnly 不动 audio rows
    }
}
