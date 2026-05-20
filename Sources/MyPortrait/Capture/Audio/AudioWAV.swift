import AVFoundation
import Foundation

/// WAV 编解码工具。云转录引擎上传音频用 16-bit PCM WAV
/// （用户明确不做 MP3 云压缩 —— 直接传无损 WAV）。
enum AudioWAV {

    /// `[Float]` 16kHz mono → 16-bit PCM WAV 字节。
    static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let blockAlign = channels * bits / 8
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataLen = UInt32(samples.count) * UInt32(blockAlign)

        var d = Data()
        d.reserveCapacity(44 + Int(dataLen))
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataLen); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(UInt32(sampleRate)); u32(byteRate); u16(blockAlign); u16(bits)
        str("data"); u32(dataLen)

        for s in samples {
            let clamped = max(-1, min(1, s))
            var le = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// 读 wav → 16kHz mono float 样本。AVAudioFile 的 processingFormat 总是 Float32。
    static func readSamples(path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let ch = buf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
