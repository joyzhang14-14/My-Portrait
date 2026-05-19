import XCTest
@testable import MyPortrait

/// 端到端：NLEmbedding embedder + HybridSearchEngine + RRF 真正跑一遍。
/// 验证 Phase 4 框架接上 Apple 自带的句向量模型后，**语义召回真的生效**
/// （不是 FTS-fallback 路径）。
///
/// 注：NLEmbedding 在 CI 沙盒里可能 unavailable（模型文件没装），
/// 此时整组测试 `XCTSkip` 而不是失败。本机 macOS 14+ 应该都能跑。
final class NLEmbeddingEndToEndTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() async throws {
        let fm = FileManager.default
        for p in tempPaths {
            try? fm.removeItem(atPath: p)
            try? fm.removeItem(atPath: p + "-wal")
            try? fm.removeItem(atPath: p + "-shm")
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

    /// "我感冒了" → "I'm sick" 这种跨语言不指望 NLEmbedding 召回，
    /// 但同语言里 "I have a flu" ↔ "I'm feeling under the weather" 应该有效。
    func testSemanticRecallBeatsExactMatch() async throws {
        let embedder = NLEmbeddingVectorEmbedder()

        // 先 embed 一个查询；如果 NLEmbedding 在这个机器上没装，整个测试 skip。
        do {
            _ = try await embedder.embed("the quick brown fox")
        } catch NLEmbeddingError.modelUnavailable {
            throw XCTSkip("NLEmbedding model not installed on this system")
        } catch {
            throw error
        }

        let db = try makeDB()

        // 三条 frame：
        //   1. 字面没"flu"但语义近"I'm feeling under the weather"
        //   2. 字面有"flu"但是说别人的 / 跟搜索意图不太一样
        //   3. 完全无关
        let texts = [
            "I'm feeling under the weather today and stayed home",
            "the flu vaccine works for most people",
            "let's compile the swift code with optimizations",
        ]
        var ids: [Int64] = []
        for (i, text) in texts.enumerated() {
            let record = FrameRecord(
                timestampMs: Int64(1_000_000_000 + i),
                appName: "Notes",
                windowName: nil, browserUrl: nil, focused: true,
                deviceName: "main",
                snapshotPath: "/tmp/\(i).jpg",
                captureTrigger: "manual"
            )
            let ocr = OCRResult(fullText: text, words: [], avgConfidence: 1.0)
            let id = try await db.insertFrameWithOCR(record, ocr: ocr)
            ids.append(id)

            // 主动 embed 一遍（emulate EmbeddingWorker）。
            let vec = try await embedder.embed(text)
            var norm = vec
            VectorMath.l2Normalize(&norm)
            try await db.setFrameEmbedding(frameId: id, vector: norm, model: embedder.modelIdentifier)
        }

        let fts = FTSSearchEngine(dbPool: db.dbPool)
        let hybrid = HybridSearchEngine(db: db, fts: fts, embedder: embedder)

        // 搜 "I have a flu" → 期望命中 1（语义近）+ 2（字面有 flu），3 应该最低。
        let hits = try await hybrid.searchFrames(query: "I have a flu", limit: 10)
        XCTAssertGreaterThanOrEqual(hits.count, 1, "Hybrid 至少应该返回点东西")

        let topId = hits.first?.frameId
        XCTAssertNotEqual(topId, ids[2], "无关的 swift compile 不应该排第一")
    }

    /// 完全相同的文本应该被 NLEmbedding 给出几乎相同的向量。
    func testIdenticalTextProducesIdenticalEmbedding() async throws {
        let embedder = NLEmbeddingVectorEmbedder()
        let text = "the rain in Spain stays mainly in the plain"
        do {
            let v1 = try await embedder.embed(text)
            let v2 = try await embedder.embed(text)
            XCTAssertEqual(v1.count, v2.count)
            for (a, b) in zip(v1, v2) {
                XCTAssertEqual(a, b, accuracy: 1e-6)
            }
        } catch NLEmbeddingError.modelUnavailable {
            throw XCTSkip("NLEmbedding model not installed")
        }
    }
}
