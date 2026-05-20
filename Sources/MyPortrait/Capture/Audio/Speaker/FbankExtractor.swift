import Accelerate
import Foundation

/// Kaldi 风格 log-mel filterbank 特征提取。
///
/// 复刻 knf-rs `ComputeFbank` 的配置（screenpipe 用它给 wespeaker CAM++ 喂特征）：
///   - 16kHz / 帧长 25ms(400) / 帧移 10ms(160) / FFT 512
///   - 80 个 mel 滤波器，20–8000Hz
///   - dither=0、remove_dc_offset、preemph 0.97、Povey 窗、snip_edges
///   - use_log_fbank + use_power，其余 kaldi-native-fbank 默认值
///
/// **风险声明**：这是手写复刻 Kaldi 的 DSP（Swift 生态无 knf-rs 等价物）。
/// 算法已尽力对齐 Kaldi，但数值精度只能靠真实音频回归验证。
///
/// 非 Sendable（持有 FFTSetup 指针）——由 OnnxSpeakerDiarizer actor 独占持有。
final class FbankExtractor {

    private static let sampleRate: Float = 16000
    private static let frameLength = 400          // 25ms @ 16kHz
    private static let frameShift = 160           // 10ms
    private static let fftSize = 512              // round_to_power_of_two(400)
    private static let log2n: vDSP_Length = 9     // 2^9 = 512
    private static let numFftBins = 256           // fftSize/2，mel 只用前 256 个
    static let numMelBins = 80
    private static let preemph: Float = 0.97
    private static let lowFreq: Float = 20
    private static let highFreq: Float = 8000     // nyquist

    private let window: [Float]                   // Povey 窗，长 400
    private let melFilters: [[Float]]             // [80][256] 三角滤波器权重
    private let fftSetup: FFTSetup

    init() {
        let n = FbankExtractor.frameLength
        let a = 2.0 * Float.pi / Float(n - 1)
        window = (0..<n).map { powf(0.5 - 0.5 * cosf(a * Float($0)), 0.85) }
        melFilters = FbankExtractor.buildMelFilters()
        fftSetup = vDSP_create_fftsetup(FbankExtractor.log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Kaldi mel 刻度：mel(f) = 1127 · ln(1 + f/700)。
    private static func mel(_ f: Float) -> Float { 1127.0 * logf(1.0 + f / 700.0) }

    /// 构造 80 个三角 mel 滤波器（Kaldi mel-computations.cc 的算法）。
    private static func buildMelFilters() -> [[Float]] {
        let melLow = mel(lowFreq)
        let melHigh = mel(highFreq)
        let delta = (melHigh - melLow) / Float(numMelBins + 1)
        let fftBinWidth = sampleRate / Float(fftSize)

        var filters: [[Float]] = []
        filters.reserveCapacity(numMelBins)
        for bin in 0..<numMelBins {
            let left = melLow + Float(bin) * delta
            let center = melLow + Float(bin + 1) * delta
            let right = melLow + Float(bin + 2) * delta
            var row = [Float](repeating: 0, count: numFftBins)
            for i in 0..<numFftBins {
                let m = mel(fftBinWidth * Float(i))
                if m > left && m < right {
                    row[i] = m <= center
                        ? (m - left) / (center - left)
                        : (right - m) / (right - center)
                }
            }
            filters.append(row)
        }
        return filters
    }

    /// 16kHz mono float → `[num_frames][80]` log-mel 特征。
    /// 样本不足一帧返回空。
    func compute(_ samples: [Float]) -> [[Float]] {
        let total = samples.count
        guard total >= FbankExtractor.frameLength else { return [] }
        let numFrames = 1 + (total - FbankExtractor.frameLength) / FbankExtractor.frameShift

        var result: [[Float]] = []
        result.reserveCapacity(numFrames)

        var realp = [Float](repeating: 0, count: FbankExtractor.fftSize / 2)
        var imagp = [Float](repeating: 0, count: FbankExtractor.fftSize / 2)
        var padded = [Float](repeating: 0, count: FbankExtractor.fftSize)

        for f in 0..<numFrames {
            let start = f * FbankExtractor.frameShift
            var frame = Array(samples[start ..< start + FbankExtractor.frameLength])

            // 1. 去直流偏置
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frame.count))
            var negMean = -mean
            vDSP_vsadd(frame, 1, &negMean, &frame, 1, vDSP_Length(frame.count))

            // 2. 预加重（从尾到头，最后处理首样本）
            for i in stride(from: FbankExtractor.frameLength - 1, through: 1, by: -1) {
                frame[i] -= FbankExtractor.preemph * frame[i - 1]
            }
            frame[0] -= FbankExtractor.preemph * frame[0]

            // 3. Povey 窗
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(FbankExtractor.frameLength))

            // 4. 补零到 512
            for i in 0..<FbankExtractor.fftSize {
                padded[i] = i < FbankExtractor.frameLength ? frame[i] : 0
            }

            // 5. 实数 FFT → 功率谱
            let power: [Float] = realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pb in
                        pb.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: FbankExtractor.fftSize / 2
                        ) { cb in
                            vDSP_ctoz(cb, 2, &split, 1, vDSP_Length(FbankExtractor.fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, FbankExtractor.log2n, FFTDirection(FFT_FORWARD))
                    // vDSP zrip 输出是标准 DFT 的 2 倍 → ×0.5 还原。
                    var pw = [Float](repeating: 0, count: FbankExtractor.numFftBins)
                    pw[0] = (rp[0] * 0.5) * (rp[0] * 0.5)          // DC（纯实）
                    for k in 1..<FbankExtractor.numFftBins {
                        let re = rp[k] * 0.5
                        let im = ip[k] * 0.5
                        pw[k] = re * re + im * im
                    }
                    return pw
                }
            }

            // 6. mel 滤波 + log（floor 在 FLT_EPSILON 防 log(0)）
            var melFrame = [Float](repeating: 0, count: FbankExtractor.numMelBins)
            for bin in 0..<FbankExtractor.numMelBins {
                var energy: Float = 0
                vDSP_dotpr(melFilters[bin], 1, power, 1, &energy,
                           vDSP_Length(FbankExtractor.numFftBins))
                melFrame[bin] = logf(max(energy, Float.ulpOfOne))
            }
            result.append(melFrame)
        }
        return result
    }
}
