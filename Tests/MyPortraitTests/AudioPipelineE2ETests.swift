import AVFoundation
import XCTest
@testable import MyPortrait

/// 用真实会议录音端到端跑音频管线：Silero VAD → pyannote 分离 → CAM++ 嵌入
/// → 说话人聚类 → Whisper 转录。
///
/// **默认跳过**（首次会下载 ~35MB ONNX 模型 + Whisper 模型，需联网）。
/// 跑法：环境变量 `MYPORTRAIT_RUN_AUDIO_E2E=1` + `MYPORTRAIT_E2E_AUDIO=<路径>`。
final class AudioPipelineE2ETests: XCTestCase {

    private func optedIn() throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard env["MYPORTRAIT_RUN_AUDIO_E2E"] == "1" else {
            throw XCTSkip("set MYPORTRAIT_RUN_AUDIO_E2E=1 to run audio E2E")
        }
        guard let path = env["MYPORTRAIT_E2E_AUDIO"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("set MYPORTRAIT_E2E_AUDIO=<wav/mp4 path>")
        }
        return path
    }

    /// 解码音频文件前 `maxSeconds` 秒为 16kHz mono float。
    private func loadAudio16k(path: String, maxSeconds: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let srcFormat = file.processingFormat
        let framesToRead = AVAudioFrameCount(
            min(Double(file.length), srcFormat.sampleRate * maxSeconds)
        )
        guard framesToRead > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesToRead)
        else { return nil }
        do { try file.read(into: inBuf, frameCount: framesToRead) } catch { return nil }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: srcFormat, to: outFormat) else { return nil }

        let ratio = 16_000.0 / srcFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return nil }

        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    func testAudioPipelineEndToEnd() async throws {
        let audioPath = try optedIn()

        print("=== AUDIO E2E: \(audioPath) ===")
        guard let samples = loadAudio16k(path: audioPath, maxSeconds: 60) else {
            XCTFail("could not decode audio")
            return
        }
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let peak = samples.map { abs($0) }.max() ?? 0
        print("decoded \(samples.count) samples @16kHz (\(String(format: "%.1f", Double(samples.count) / 16000))s) rms=\(rms) peak=\(peak)")
        XCTAssertGreaterThan(samples.count, 16_000, "expected at least 1s of audio")

        // --- 1. Silero VAD ---
        do {
            let modelPath = try await SpeakerModelStore.shared.path(for: .vadSilero)
            let vad = try SileroVAD(modelPath: modelPath.path)
            var speech = 0, total = 0
            var probs: [Float] = []
            var i = 0
            while i + SileroVAD.frameSize <= samples.count {
                let frame = Array(samples[i ..< i + SileroVAD.frameSize])
                if let p = vad.probability(frame) {
                    total += 1
                    probs.append(p)
                    if p > 0.5 { speech += 1 }
                }
                i += SileroVAD.frameSize
            }
            let pct = total > 0 ? Double(speech) / Double(total) * 100 : 0
            let mn = probs.min() ?? 0, mx = probs.max() ?? 0
            let mean = probs.isEmpty ? 0 : probs.reduce(0, +) / Float(probs.count)
            print("SILERO VAD: \(total) frames, \(speech) speech (\(String(format: "%.0f", pct))%)")
            print("  prob min=\(mn) max=\(mx) mean=\(mean) first5=\(probs.prefix(5).map { String(format: "%.3f", $0) })")
            XCTAssertGreaterThan(total, 0, "Silero produced no frames — ONNX I/O likely wrong")
        }

        // --- 2. 说话人分离（pyannote + CAM++ + Fbank + 聚类）---
        let tmpWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).wav")
        try AudioWAV.encode(samples: samples).write(to: tmpWav)
        defer { try? FileManager.default.removeItem(at: tmpWav) }

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).sqlite").path
        let db = try PortraitDBImpl(path: dbPath)
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: dbPath + "-wal")
            try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        }

        let diarizer = OnnxSpeakerDiarizer(db: db)
        let segments = await diarizer.diarize(wavPath: tmpWav.path, isInput: true)
        let speakers = Set(segments.compactMap { $0.speakerId })
        print("DIARIZER: \(segments.count) segments, \(speakers.count) distinct speakers")
        for (i, seg) in segments.prefix(8).enumerated() {
            print(String(format: "  seg %d: %.1f–%.1fs  speaker=%@",
                         i, seg.startS, seg.endS, seg.speakerId.map(String.init) ?? "nil"))
        }

        // --- 3. Whisper 转录 ---
        let whisper = WhisperKitWrapper(modelName: "openai_whisper-base")
        if let first = segments.first {
            let text = try await whisper.transcribe(
                samples: first.samples, language: nil, vocabulary: [], filterMusic: false)
            print("WHISPER (first segment): \"\(text.prefix(200))\"")
        } else {
            // 分离没出段（可能模型问题）→ 直接整段转录,至少验证 Whisper 通。
            let text = try await whisper.transcribe(
                samples: samples, language: nil, vocabulary: [], filterMusic: false)
            print("WHISPER (no segments, whole 60s): \"\(text.prefix(200))\"")
        }
        print("=== AUDIO E2E DONE ===")
    }
}
