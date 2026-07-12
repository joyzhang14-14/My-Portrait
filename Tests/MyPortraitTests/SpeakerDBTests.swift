import XCTest
@testable import MyPortrait

/// 说话人识别 DB 层 + 转录失败重试的单元测试。用临时 DB，纯逻辑、不碰音频。
/// 隐含验证 schema v6（retry_count）/ v7（speakers 表）迁移能正常应用。
final class SpeakerDBTests: XCTestCase {

    private var tempPaths: [String] = []
    private let model = "test_campplus"

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
            .appendingPathComponent("MyPortraitSpeakerTest-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        return try PortraitDBImpl(path: path)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 与 e0 的余弦相似度恰为 `cosine` 的 512 维单位向量。
    private func vector(cosineToE0 cosine: Float, dim: Int = 512) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[0] = cosine
        v[1] = (1 - cosine * cosine).squareRoot()
        return v
    }

    // MARK: - 说话人匹配 / 注册

    func testEnrollAndMatchSpeaker() async throws {
        let db = try makeDB()
        let a = vector(cosineToE0: 1.0)
        let id = try await db.enrollSpeaker(embedding: a, model: model)
        XCTAssertGreaterThan(id, 0)

        // 同向量 → 匹配上自己。
        let matched = try await db.matchSpeaker(embedding: a, model: model)
        guard case .matched(let matchedID) = matched else {
            return XCTFail("同向量应命中已注册说话人")
        }
        XCTAssertEqual(matchedID, id)

        // 正交向量（余弦 0）→ 不匹配。
        let none = try await db.matchSpeaker(embedding: vector(cosineToE0: 0), model: model)
        guard case .none = none else {
            return XCTFail("正交向量不应匹配说话人")
        }
    }

    func testMatchSpeakerThreshold() async throws {
        let db = try makeDB()
        let id = try await db.enrollSpeaker(embedding: vector(cosineToE0: 1.0), model: model)

        // 余弦 0.5 > 阈值 0.45 → 匹配。
        let near = try await db.matchSpeaker(embedding: vector(cosineToE0: 0.5), model: model)
        guard case .matched(let matchedID) = near else {
            return XCTFail("高于阈值的向量应匹配")
        }
        XCTAssertEqual(matchedID, id)
        // 余弦 0.3 < 阈值 0.45 → 不匹配。
        let far = try await db.matchSpeaker(embedding: vector(cosineToE0: 0.3), model: model)
        guard case .none = far else {
            return XCTFail("低于阈值的向量不应匹配")
        }
    }

    func testAddEmbeddingKeepsSpeakerMatchable() async throws {
        let db = try makeDB()
        let a = vector(cosineToE0: 1.0)
        let id = try await db.enrollSpeaker(embedding: a, model: model)
        try await db.addEmbeddingToSpeaker(speakerId: id, embedding: a)
        try await db.addEmbeddingToSpeaker(speakerId: id, embedding: vector(cosineToE0: 0.9))
        // 追加样本后仍能匹配回同一说话人。
        let matched = try await db.matchSpeaker(embedding: a, model: model)
        guard case .matched(let matchedID) = matched else {
            return XCTFail("追加样本后应仍能匹配")
        }
        XCTAssertEqual(matchedID, id)
    }

    func testNameSpeakerIfUnnamedDoesNotThrow() async throws {
        let db = try makeDB()
        let id = try await db.enrollSpeaker(embedding: vector(cosineToE0: 1.0), model: model)
        // 只验证不抛错（读回名字的接口在 TimelineDB，单测够不到）。
        try await db.nameSpeakerIfUnnamed(speakerId: id, name: "Alice")
        try await db.nameSpeakerIfUnnamed(speakerId: id, name: "Bob")
    }

    // MARK: - 转录失败重试（retry_count）

    func testRetryableFailedReset() async throws {
        let db = try makeDB()
        let id = try await db.insertAudioChunk(AudioChunkRecord(
            id: nil, filePath: "/tmp/test.wav", recordedAtMs: nowMs(),
            durationS: 1, device: "default_microphone", isInput: true, status: .pending
        ))

        // 失败 1 次 → retry_count=1 → 启动恢复时应被重置。
        try await db.recordAudioChunkFailure(chunkId: id)
        let reset1 = try await db.resetRetryableFailedAudioChunks()
        XCTAssertEqual(reset1, 1)

        // 再失败到 retry_count=3 → 到上限,不再重试。
        try await db.recordAudioChunkFailure(chunkId: id)   // 2
        try await db.recordAudioChunkFailure(chunkId: id)   // 3
        let reset2 = try await db.resetRetryableFailedAudioChunks()
        XCTAssertEqual(reset2, 0)
    }

    func testResetInProgressAudioChunks() async throws {
        let db = try makeDB()
        let id = try await db.insertAudioChunk(AudioChunkRecord(
            id: nil, filePath: "/tmp/test2.wav", recordedAtMs: nowMs(),
            durationS: 1, device: "default_microphone", isInput: true, status: .pending
        ))
        try await db.updateAudioChunkStatus(chunkId: id, status: .inProgress)
        // 崩溃恢复：in_progress → pending。
        let reset = try await db.resetInProgressAudioChunks()
        XCTAssertEqual(reset, 1)
    }
}
