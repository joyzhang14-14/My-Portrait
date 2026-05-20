import Accelerate
import Foundation

/// 转录前的音频预处理。复刻 screenpipe 的 `normalize_v2` + `filter_music_frames`。
///
///   - normalize_v2：归一化到目标 RMS / 峰值，保留动态范围 —— 让 Whisper 拿到
///     电平一致的输入。
///   - filter_music_frames：检测音乐主导的 0.5s 窗口并清零 —— 防 Spotify /
///     YouTube 的歌词污染转录。受设置 `recording.audio.filterMusic` 控制。
///
/// 用在转录路径（offline、非实时），处理完整的 segment 缓冲。
enum AudioPreprocessor {

    /// 完整预处理：归一化 →（可选）音乐过滤。
    static func process(_ samples: [Float], filterMusic: Bool) -> [Float] {
        var out = normalizeV2(samples)
        if filterMusic { filterMusicFrames(&out) }
        return out
    }

    // MARK: - normalize_v2

    /// 归一化到 RMS 0.2 / 峰值 0.95，取两者缩放比的较小值（保留动态）。
    static func normalizeV2(_ audio: [Float]) -> [Float] {
        guard !audio.isEmpty else { return audio }
        let targetRMS: Float = 0.2
        let targetPeak: Float = 0.95

        var rms: Float = 0
        vDSP_rmsqv(audio, 1, &rms, vDSP_Length(audio.count))
        var peak: Float = 0
        vDSP_maxmgv(audio, 1, &peak, vDSP_Length(audio.count))

        guard rms > .ulpOfOne, peak > .ulpOfOne else { return audio }
        var scale = min(targetRMS / rms, targetPeak / peak)

        var out = [Float](repeating: 0, count: audio.count)
        vDSP_vsmul(audio, 1, &scale, &out, 1, vDSP_Length(audio.count))
        return out
    }

    // MARK: - 音乐过滤

    private static let windowSize = 8000          // 0.5s @ 16kHz
    private static let numSubFrames = 10
    private static let silenceThreshold: Float = 0.01
    private static let evrThreshold: Float = 0.30   // 能量方差比，低 → 音乐
    private static let zcrVarThreshold: Float = 0.04 // 过零率方差，低 → 音乐
    private static let sfVetoThreshold: Float = 0.70 // 谱平坦度过高 → 是噪声不是音乐
    private static let voteMajority = 3
    private static let voteWindow = 5

    /// 检测音乐主导的窗口并就地清零（3/5 滑动多数投票防误判）。
    static func filterMusicFrames(_ audio: inout [Float]) {
        guard audio.count >= windowSize else { return }
        let numWindows = audio.count / windowSize

        var candidates = [Bool](repeating: false, count: numWindows)
        for i in 0..<numWindows {
            let window = Array(audio[i * windowSize ..< (i + 1) * windowSize])
            candidates[i] = isMusicCandidate(window)
        }

        var confirmed = [Bool](repeating: false, count: numWindows)
        for i in 0..<numWindows {
            let lo = i >= voteWindow / 2 ? i - voteWindow / 2 : 0
            let hi = min(i + voteWindow / 2 + 1, numWindows)
            let count = candidates[lo..<hi].filter { $0 }.count
            confirmed[i] = count >= voteMajority
        }

        for i in 0..<numWindows where confirmed[i] {
            for j in i * windowSize ..< (i + 1) * windowSize { audio[j] = 0 }
        }
    }

    private static func isMusicCandidate(_ window: [Float]) -> Bool {
        if rms(window) < silenceThreshold { return false }   // 静音不算音乐
        return spectralFlatness(window) < sfVetoThreshold
            && energyVarianceRatio(window) < evrThreshold
            && zcrVariance(window) < zcrVarThreshold
    }

    private static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(s, 1, &r, vDSP_Length(s.count))
        return r
    }

    /// 子帧 RMS 的变异系数（std/mean）。音乐能量平稳 → 低；语音忽强忽弱 → 高。
    private static func energyVarianceRatio(_ samples: [Float]) -> Float {
        let sub = samples.count / numSubFrames
        guard sub > 0 else { return 1.0 }
        let rmsValues = (0..<numSubFrames).map { i -> Float in
            let start = i * sub
            let end = min(start + sub, samples.count)
            return rms(Array(samples[start..<end]))
        }
        let mean = rmsValues.reduce(0, +) / Float(rmsValues.count)
        guard mean > 0 else { return 1.0 }
        let variance = rmsValues.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(rmsValues.count)
        return variance.squareRoot() / mean
    }

    /// 子帧过零率的标准差。音乐过零率一致 → 低；语音变化大 → 高。
    private static func zcrVariance(_ samples: [Float]) -> Float {
        let sub = samples.count / numSubFrames
        guard sub >= 2 else { return 1.0 }
        let zcrValues = (0..<numSubFrames).map { i -> Float in
            let start = i * sub
            let end = min(start + sub, samples.count)
            var crossings = 0
            for k in (start + 1)..<end where (samples[k - 1] >= 0) != (samples[k] >= 0) {
                crossings += 1
            }
            return Float(crossings) / Float(end - start - 1)
        }
        let mean = zcrValues.reduce(0, +) / Float(zcrValues.count)
        let variance = zcrValues.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(zcrValues.count)
        return variance.squareRoot()
    }

    /// 谱平坦度 = 幅度谱的几何均值 / 算术均值。在前 4096 样本（2 的幂）上算。
    /// 接近 1 = 噪声样;低 = 有明显谐波结构（音乐 / 语音）。
    private static func spectralFlatness(_ window: [Float]) -> Float {
        let n = 4096
        guard window.count >= n else { return 1.0 }
        let log2n: vDSP_Length = 12
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 1.0 }
        defer { vDSP_destroy_fftsetup(setup) }

        let slice = Array(window[0..<n])
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                slice.withUnsafeBufferPointer { sb in
                    sb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cb in
                        vDSP_ctoz(cb, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                for k in 1..<(n / 2) {           // 跳过 DC
                    let re = rp[k] * 0.5
                    let im = ip[k] * 0.5
                    mags[k] = (re * re + im * im).squareRoot()
                }
            }
        }

        let valid = Array(mags[1...])
        let arith = valid.reduce(0, +) / Float(valid.count)
        guard arith > 0 else { return 1.0 }
        let logSum = valid.reduce(Float(0)) { $0 + Foundation.log(max($1, 1e-10)) }
        let geo = Foundation.exp(logSum / Float(valid.count))
        return min(max(geo / arith, 0), 1)
    }
}
