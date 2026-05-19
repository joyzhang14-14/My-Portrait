import XCTest
@testable import MyPortrait

/// bge-m3 真推理 smoke test。**首次运行会下 ~1.13 GB 权重 + ~17 MB tokenizer**，
/// 后续从 cache 读，~3 秒内完成。
///
/// **注意**：`swift test` 命令行没法编 MLX Metal kernels，跑这套必须用
/// `xcodebuild test` 或 Xcode 内跑。直接 `swift test` 会在 MLX init 时 abort。
///
/// 默认 **跳过**：CI 不该被强制下 GB 级模型。
/// 需要跑这套时（Xcode 内）设置环境变量：`MYPORTRAIT_RUN_EMBED_SMOKE=1`。
final class BGEM3SmokeTests: XCTestCase {

    private func skipUnlessOptedIn() throws {
        guard ProcessInfo.processInfo.environment["MYPORTRAIT_RUN_EMBED_SMOKE"] == "1" else {
            throw XCTSkip("Set MYPORTRAIT_RUN_EMBED_SMOKE=1 (downloads ~1.13 GB; must run via xcodebuild)")
        }
    }

    /// 维度 + L2 归一化 + 同句确定性。
    func testEmbedDimsAndNormalizationAndDeterminism() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        let v1 = try await embedder.embed("Hello, world.")
        XCTAssertEqual(v1.count, 1024, "bge-m3 dense vector must be 1024-d")
        let norm = sqrt(v1.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "output must be L2-normalized")

        let v2 = try await embedder.embed("Hello, world.")
        let dot = zip(v1, v2).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(dot, 1.0, accuracy: 1e-4, "deterministic forward pass")
    }

    /// 同语言 sanity：含义近的句子 cosine 应高于不相关的。
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
        XCTAssertGreaterThan(cos(anchor, near), cos(anchor, far))
    }

    /// 跨语言 sanity：英文 anchor 跟中文同义句的 cosine 应高于英文跟无关中文。
    func testCrossLingualEnglishChinese() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        let anchorEN = try await embedder.embed("flu")
        let nearZH = try await embedder.embed("感冒")
        let farZH = try await embedder.embed("番茄")

        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let sNear = cos(anchorEN, nearZH)
        let sFar = cos(anchorEN, farZH)
        XCTAssertGreaterThan(sNear, sFar, "EN flu ↔ ZH 感冒 (near=\(sNear)) should beat ZH 番茄 (far=\(sFar))")
    }

    /// 跨语言 sanity 2：中文 anchor 跟英文同义。
    func testCrossLingualChineseEnglish() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = BGEM3VectorEmbedder(reporter: reporter)

        let anchorZH = try await embedder.embed("分手")
        let nearEN = try await embedder.embed("breakup")
        let farEN = try await embedder.embed("airplane")

        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let sNear = cos(anchorZH, nearEN)
        let sFar = cos(anchorZH, farEN)
        XCTAssertGreaterThan(sNear, sFar, "ZH 分手 ↔ EN breakup (\(sNear)) should beat EN airplane (\(sFar))")
    }
}
