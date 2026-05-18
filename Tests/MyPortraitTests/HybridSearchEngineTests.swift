import XCTest
@testable import MyPortrait

/// HybridSearchEngine 在 embedder 不可用时（当前 stub）必须降级到 FTS-only。
/// 这是 Phase 4 模型还没接通时 UI 仍然可用的关键。
final class HybridSearchEngineTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() async throws {
        let fm = FileManager.default
        for path in tempPaths {
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + "-wal")
            try? fm.removeItem(atPath: path + "-shm")
        }
        tempPaths.removeAll()
    }

    private func makeDB() throws -> PortraitDBImpl {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPortraitTest-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        return try PortraitDBImpl(path: path)
    }

    /// embedder 永远 throw —— Hybrid 走 FTS-only 路径，应该返回 FTS 命中。
    func testFallsBackToFTSWhenEmbedderUnavailable() async throws {
        let db = try makeDB()
        let reporter = await UnimplementedReporter()

        let record = FrameRecord(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            appName: "Xcode",
            windowName: "ContentView.swift",
            browserUrl: nil,
            focused: true,
            deviceName: "main",
            snapshotPath: "/tmp/x.jpg",
            captureTrigger: "manual"
        )
        let ocr = OCRResult(
            fullText: "the quick brown fox jumps over the lazy dog",
            words: [],
            avgConfidence: 1.0
        )
        _ = try await db.insertFrameWithOCR(record, ocr: ocr)

        let fts = FTSSearchEngine(dbPool: db.dbPool)
        let stubEmbedder = AlwaysFailingEmbedder()
        let hybrid = HybridSearchEngine(db: db, fts: fts, embedder: stubEmbedder)

        let hits = try await hybrid.searchFrames(query: "fox", limit: 10)
        XCTAssertEqual(hits.count, 1, "FTS-only fallback should still surface the row")
        XCTAssertTrue(hits.first?.snippet.contains("fox") ?? false)
    }

    /// RRF: 验证多列表融合后排名稳定 + 较前位置得分更高。
    func testRRFFusionRanksOverlapHigher() {
        let listA: [Int64] = [1, 2, 3, 4, 5]
        let listB: [Int64] = [3, 1, 6, 7, 5]
        // id=1: rank 1 + rank 2 → 1/(60+1) + 1/(60+2) = 高
        // id=3: rank 3 + rank 1 → 1/(60+3) + 1/(60+1) = 高
        // id=5: rank 5 + rank 5 → 双低
        // id=2 / 4 / 6 / 7: 只在一个列表
        let fused = RRF.fuse([listA, listB])

        // 同时出现的（1, 3, 5）应该排在只出现一次的（2, 4, 6, 7）前面。
        let topThreeIds = Set(fused.prefix(3).map(\.id))
        XCTAssertTrue(topThreeIds.contains(1))
        XCTAssertTrue(topThreeIds.contains(3))
        XCTAssertTrue(topThreeIds.contains(5))
    }

    /// VectorMath：cosine + L2 norm 基本正确性。
    func testVectorMathBasics() {
        var v: [Float] = [3, 4, 0]
        VectorMath.l2Normalize(&v)
        // 5,5,0 单位向量 → [0.6, 0.8, 0]
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-5)

        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(VectorMath.cosineSimilarity(a, b), 0, accuracy: 1e-6,
                       "正交单位向量的 cosine 应为 0")

        let c: [Float] = [1, 0, 0]
        XCTAssertEqual(VectorMath.cosineSimilarity(a, c), 1, accuracy: 1e-6,
                       "相同单位向量的 cosine 应为 1")
    }

    /// BLOB 编解码 round-trip。
    func testFloatBlobRoundTrip() {
        let original: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5]
        let blob = Data(floats: original)
        XCTAssertEqual(blob.count, original.count * 4)
        let decoded = blob.asFloats
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, original.count)
        for (a, b) in zip(original, decoded ?? []) {
            XCTAssertEqual(a, b, accuracy: 1e-10)
        }
    }
}

/// 测试用 embedder：永远 throw，模拟 Phase 4 推理未接通。
private struct AlwaysFailingEmbedder: VectorEmbedder {
    func embed(_ text: String) async throws -> [Float] {
        throw NSError(domain: "Test", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "stub"
        ])
    }
}
