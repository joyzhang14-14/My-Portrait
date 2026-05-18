import AVFoundation
import Foundation
import os.log

/// 离线 VAD：读 wav 段 → 算 RMS → 判断 speech_ratio。
///
/// 不做精细分句（那是 Silero/WebRTC VAD 的工作）。本类只决定"这段值不值得转录"。
///
/// 算法：
///   - 10ms 一帧（16kHz 下 160 samples）
///   - 每帧算 RMS，> rmsThreshold 视为 speech frame
///   - speech_ratio = speech_frames / total_frames
///   - 命中 minSpeechRatio 才返回 .keep
///
/// 阈值从 My-Orphies 抄：
///   - rmsThreshold = 0.01（normalized Float32 RMS）
///   - minSpeechRatio = 0.02（2% 帧有声音）
struct VADSegmenter: Sendable {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "vad")
    private let rmsThreshold: Float
    private let minSpeechRatio: Double
    private let frameSamples: Int

    init(
        rmsThreshold: Float = 0.01,
        minSpeechRatio: Double = 0.02,
        sampleRate: Int = 16_000,
        frameMs: Int = 10
    ) {
        self.rmsThreshold = rmsThreshold
        self.minSpeechRatio = minSpeechRatio
        self.frameSamples = sampleRate * frameMs / 1000
    }

    /// 分析 wav。返回 (是否保留, speech_ratio)。
    /// 读不到 wav / 没数据 → (.discard, 0)。
    func analyze(wavPath: String) -> Decision {
        let url = URL(fileURLWithPath: wavPath)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            logger.warning("VAD: cannot open \(wavPath, privacy: .public): \(String(describing: error), privacy: .public)")
            return Decision(action: .discard, speechRatio: 0)
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return Decision(action: .discard, speechRatio: 0)
        }

        do {
            try file.read(into: buffer)
        } catch {
            logger.warning("VAD: read failed \(String(describing: error), privacy: .public)")
            return Decision(action: .discard, speechRatio: 0)
        }

        guard let channelData = buffer.floatChannelData else {
            return Decision(action: .discard, speechRatio: 0)
        }
        let samples = channelData[0]
        let count = Int(buffer.frameLength)

        // 按 frameSamples 切窗 → 算 RMS。
        var speechFrames = 0
        var totalFrames = 0
        let threshold = rmsThreshold

        var i = 0
        while i + frameSamples <= count {
            var sumSq: Float = 0
            for j in 0..<frameSamples {
                let s = samples[i + j]
                sumSq += s * s
            }
            let rms = (sumSq / Float(frameSamples)).squareRoot()
            if rms > threshold {
                speechFrames += 1
            }
            totalFrames += 1
            i += frameSamples
        }

        let ratio = totalFrames > 0 ? Double(speechFrames) / Double(totalFrames) : 0
        let action: Decision.Action = ratio >= minSpeechRatio ? .keep : .discard
        return Decision(action: action, speechRatio: ratio)
    }

    struct Decision: Sendable {
        let action: Action
        let speechRatio: Double

        enum Action: Sendable {
            case keep
            case discard
        }
    }
}
