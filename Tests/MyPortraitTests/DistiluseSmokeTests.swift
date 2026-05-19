import XCTest
@testable import MyPortrait

/// MultilingualMiniLM 真推理 smoke test。**首次运行会下 ~120 MB 模型到 HF cache**，
/// 后续从 cache 读，~3 秒内完成。
///
/// **注意**：`swift test` 命令行没法编 MLX Metal kernels，跑这套必须用
/// `xcodebuild test` 或 Xcode 内跑。直接 `swift test` 会在 MLX init 时 abort。
///
/// 默认 **跳过**：CI 不该被强制下模型。
/// 需要跑这套时（Xcode 内）设置环境变量：`MYPORTRAIT_RUN_EMBED_SMOKE=1`。
final class DistiluseSmokeTests: XCTestCase {

    private func skipUnlessOptedIn() throws {
        guard ProcessInfo.processInfo.environment["MYPORTRAIT_RUN_EMBED_SMOKE"] == "1" else {
            throw XCTSkip("Set MYPORTRAIT_RUN_EMBED_SMOKE=1 to enable (downloads ~120 MB; must run via xcodebuild for MLX metallib)")
        }
    }

    /// 检查向量维度 + L2 归一化 + 同句确定性。
    func testEmbedDimsAndNormalizationAndDeterminism() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = MultilingualDistiluseEmbedder(reporter: reporter)

        let v1 = try await embedder.embed("Hello, world.")
        XCTAssertEqual(v1.count, 512, "distiluse-multi-v2 dense vector must be 512-d")
        let norm = sqrt(v1.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "output must be L2-normalized")

        // 同句两次应当一模一样。
        let v2 = try await embedder.embed("Hello, world.")
        XCTAssertEqual(v1.count, v2.count)
        let dot = zip(v1, v2).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(dot, 1.0, accuracy: 1e-4, "deterministic forward pass")
    }

    /// 语义相关性 sanity：含义近的句子 cosine 应高于不相关的。
    func testSemanticRelatednessSanity() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = MultilingualDistiluseEmbedder(reporter: reporter)

        let anchor = try await embedder.embed("How to reset my password?")
        let near = try await embedder.embed("I forgot my login credentials and need a new one.")
        let far = try await embedder.embed("Tomatoes grow best in full sunlight.")

        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let sNear = cos(anchor, near)
        let sFar = cos(anchor, far)
        XCTAssertGreaterThan(sNear, sFar, "near=\(sNear) far=\(sFar)")
    }

    /// 跨语言 sanity：英文 anchor 跟中文同义句的 cosine 应高于英文跟无关中文。
    func testCrossLingualSanity() async throws {
        try skipUnlessOptedIn()
        let reporter = await UnimplementedReporter()
        let embedder = MultilingualDistiluseEmbedder(reporter: reporter)

        let anchorEN = try await embedder.embed("How to reset my password?")
        let nearZH = try await embedder.embed("我忘了登录密码，怎么重置？")
        let farZH = try await embedder.embed("番茄在阳光充足的地方生长得最好。")

        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let sNear = cos(anchorEN, nearZH)
        let sFar = cos(anchorEN, farZH)
        XCTAssertGreaterThan(sNear, sFar, "EN anchor vs ZH paraphrase should beat unrelated ZH (near=\(sNear), far=\(sFar))")
    }
}
