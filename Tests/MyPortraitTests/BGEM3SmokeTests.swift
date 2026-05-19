import XCTest
@testable import MyPortrait

/// bge-m3 真推理 smoke test。**首次运行会下 ~1.13 GB 模型到 HF cache**
/// （`~/Library/Caches/huggingface/`），后续从 cache 读，~3 秒内完成。
///
/// 默认 **跳过**：CI / 普通 `swift test` 不应该被强制下 GB 级模型。
/// 需要跑这套时：
///   ```bash
///   MYPORTRAIT_RUN_BGE_M3_SMOKE=1 swift test --filter BGEM3SmokeTests
///   ```
final class BGEM3SmokeTests: XCTestCase {

    private func skipUnlessOptedIn() throws {
        guard ProcessInfo.processInfo.environment["MYPORTRAIT_RUN_BGE_M3_SMOKE"] == "1" else {
            throw XCTSkip("Set MYPORTRAIT_RUN_BGE_M3_SMOKE=1 to enable (downloads ~1.13 GB)")
        }
    }

    /// 检查向量维度 + L2 归一化 + 同句确定性。
    func testEmbedDimsAndNormalizationAndDeterminism() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        print("[smoke] embedder constructed; calling embed…")
        fflush(stdout)
        let v1: [Float]
        do {
            v1 = try await embedder.embed("Hello, world.")
        } catch {
            print("[smoke] embed THREW: \(error)")
            fflush(stdout)
            throw error
        }
        print("[smoke] embed returned, dim=\(v1.count)")
        fflush(stdout)
        XCTAssertEqual(v1.count, 1024, "bge-m3 dense vector must be 1024-d")
        let norm = sqrt(v1.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "output must be L2-normalized")

        // 同句两次应当一模一样（fp16 round-off 极小但确定）。
        let v2 = try await embedder.embed("Hello, world.")
        XCTAssertEqual(v1.count, v2.count)
        let dot = zip(v1, v2).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(dot, 1.0, accuracy: 1e-4, "deterministic forward pass: same input → same vector")
    }

    /// 语义相关性 sanity：含义近的句子 cosine 应高于不相关的。
    func testSemanticRelatednessSanity() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        let anchor = try await embedder.embed("How to reset my password?")
        let near = try await embedder.embed("I forgot my login credentials and need a new one.")
        let far = try await embedder.embed("Tomatoes grow best in full sunlight.")

        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let sNear = cos(anchor, near)
        let sFar = cos(anchor, far)
        XCTAssertGreaterThan(sNear, sFar, "semantically related pair should beat unrelated pair (near=\(sNear), far=\(sFar))")
        // 不假设绝对阈值（bge-m3 给同领域常 > 0.5；这里只验序）。
    }

    /// batch 路径与单条路径数值一致。
    func testBatchMatchesSingle() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        let texts = [
            "Coffee is brewed from roasted beans.",
            "Swift macros run at compile time."
        ]
        let batched = try await embedder.embedBatch(texts)
        XCTAssertEqual(batched.count, 2)

        for (i, t) in texts.enumerated() {
            let single = try await embedder.embed(t)
            let dot = zip(single, batched[i]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            // batch path 的 padding 会让数值跟单条略差（attention mask 上正确，
            // 但 LayerNorm / softmax 数值精度受 batch 内其他句长影响），允许 1e-2 容差。
            XCTAssertEqual(dot, 1.0, accuracy: 1e-2, "single vs batch should agree within fp16 padding noise (i=\(i))")
        }
    }
}
