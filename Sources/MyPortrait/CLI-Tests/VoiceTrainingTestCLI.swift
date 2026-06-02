import AVFoundation
import Foundation

/// `--voice-test <audio-file>` —— 在真实音频上跑 voice training 的 embedding
/// 提取路径,不依赖 mic / 转录 / diarization。verifies 新版 VoiceTrainer
/// 的核心 stage:
///
///   audio file → 16kHz mono Float 样本 → SpeakerEmbeddingExtractor →
///   512 维 embedding → upsertVoiceTrainedSpeaker → 校验入库
///
/// 拿 `~/Movies/meetily-recordings/Meeting .../audio.mp4` 之类的人声测。
enum VoiceTrainingTestCLI {

    static func run(audioPath: String) {
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("ERROR: audio file not found: \(url.path)")
            exit(1)
        }
        print("=== voice training test ===")
        print("audio: \(url.path)")

        let samples: [Float]
        do {
            samples = try decodeToMono16k(url: url)
        } catch {
            print("ERROR: decode failed: \(error)")
            exit(2)
        }
        print("decoded: \(samples.count) samples @ 16kHz = \(Double(samples.count) / 16_000.0) s")

        // 截前 30s 当训练窗口(够 wespeaker 算稳定 embedding)。
        let trainSamples = Array(samples.prefix(30 * 16_000))
        print("training window: \(trainSamples.count) samples = \(Double(trainSamples.count) / 16_000.0) s")

        // 拿 wespeaker CAM++ 模型 path。同步等下载完。
        // Swift 6 strict concurrency 不让 Task 闭包捕获 var,box 一下。
        final class Box: @unchecked Sendable { var path: String?; var err: Error? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                box.path = try await SpeakerModelStore.shared.path(for: .embedding).path
            } catch {
                box.err = error
            }
            sem.signal()
        }
        sem.wait()
        guard let modelPath = box.path else {
            print("ERROR: speaker model not available: \(String(describing: box.err))")
            exit(3)
        }
        print("model:  \(modelPath)")

        // 跑 embedding。
        let extractor: SpeakerEmbeddingExtractor
        do {
            extractor = try SpeakerEmbeddingExtractor(modelPath: modelPath, fbank: FbankExtractor())
        } catch {
            print("ERROR: extractor init failed: \(error)")
            exit(4)
        }
        guard let embedding = extractor.embed(trainSamples), !embedding.isEmpty else {
            print("ERROR: embedding extraction returned nil/empty")
            exit(5)
        }
        let mean = embedding.reduce(0, +) / Float(embedding.count)
        let maxAbs = embedding.map { abs($0) }.max() ?? 0
        let l2 = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        print("embedding: \(embedding.count)-dim, mean=\(String(format: "%.5f", mean)), max|x|=\(String(format: "%.5f", maxAbs)), L2=\(String(format: "%.5f", l2))")
        print("  first 8: \(embedding.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", "))")

        // 写 DB(测试用 speaker 名 "Test-CLI")。
        guard let speakerId = TimelineDB().upsertVoiceTrainedSpeaker(name: "Test-CLI", embedding: embedding) else {
            print("ERROR: DB upsert failed (DB exists? path: \(TimelineDB().dbPath))")
            exit(6)
        }
        print("upserted speaker id=\(speakerId), name='Test-CLI'")

        // 再算一次后 30s 的 embedding,跟训练 embedding 做余弦相似度
        // —— 同一人的不同片段,wespeaker CAM++ 该 ≥ 0.7 算高度匹配。
        if samples.count >= 60 * 16_000 {
            let verifySamples = Array(samples.suffix(30 * 16_000))
            if let verify = extractor.embed(verifySamples) {
                let sim = VectorMath.cosineSimilarity(embedding, verify)
                print("self-similarity (first 30s vs last 30s): \(String(format: "%.4f", sim))")
                if sim >= 0.6 {
                    print("  ✓ above 0.6 — embedding consistent across same-speaker windows")
                } else {
                    print("  ⚠ below 0.6 — speaker might've changed or audio quality issue")
                }
            }
        }

        print("=== voice training test PASS ===")
        exit(0)
    }

    /// 任意 audio 文件 → 16kHz mono Float32 平面 [Float]。
    /// 走 AVAudioFile + AVAudioConverter,跟 VoiceTrainer 运行时一条路径。
    private static func decodeToMono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VoiceTrainingTestCLI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not construct target format"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "VoiceTrainingTestCLI", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"])
        }

        // 读全文件,转成 16k mono Float
        let totalFrames = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "VoiceTrainingTestCLI", code: -3)
        }
        try file.read(into: inBuf)

        let ratio = target.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(totalFrames) * ratio) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw NSError(domain: "VoiceTrainingTestCLI", code: -4)
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        if status == .error, let error {
            throw error
        }
        guard let ch = outBuf.floatChannelData, outBuf.frameLength > 0 else {
            throw NSError(domain: "VoiceTrainingTestCLI", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "converter produced no output"])
        }
        let count = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: count))
    }
}
