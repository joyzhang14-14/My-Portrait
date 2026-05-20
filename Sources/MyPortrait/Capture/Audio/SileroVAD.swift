import Foundation
import OnnxRuntimeBindings

/// Silero VAD v5。每 512 个 16kHz 样本输出一个语音概率 [0,1]，内部维护 LSTM 状态。
///
/// 复刻 screenpipe（它用 vad-rs 封装同一个 onnx）。这里直接用 ORT 跑：
/// 模型有 3 个输入(input / state / sr)、2 个输出(output / stateN)。
///
/// 非 Sendable（持 ORTSession + 可变 state）—— 由 VADRecorder actor 独占。
final class SileroVAD {

    /// Silero v5 固定帧长：512 样本 @16kHz（约 32ms）。
    static let frameSize = 512
    /// 帧间 context 样本数：模型实际窗口 = contextSize + frameSize = 576。
    static let contextSize = 64
    /// LSTM 状态张量元素数：[2, 1, 128]。
    private static let stateCount = 2 * 1 * 128

    private let session: ORTSession
    private let inputName: String
    private let stateName: String
    private let srName: String?
    private let probOutputName: String
    private let stateOutputName: String
    private var state: [Float]
    /// 上一帧尾部样本,拼到下一帧前面 —— silero v5 的窗口连续性靠它。
    private var context: [Float]

    init(modelPath: String) throws {
        guard let env = SpeakerOnnxEnv.shared else {
            throw NSError(domain: "MyPortrait.SileroVAD", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ORT env init failed"])
        }
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        try opts.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)

        let ins = (try? session.inputNames()) ?? []
        let outs = (try? session.outputNames()) ?? []
        inputName = ins.first { $0 == "input" } ?? (ins.first ?? "input")
        stateName = ins.first { $0 == "state" } ?? "state"
        srName = ins.first { $0 == "sr" }
        probOutputName = outs.first { $0 == "output" } ?? (outs.first ?? "output")
        stateOutputName = outs.first { $0 == "stateN" } ?? (outs.last ?? "stateN")
        state = [Float](repeating: 0, count: SileroVAD.stateCount)
        context = [Float](repeating: 0, count: SileroVAD.contextSize)
    }

    /// 清空 LSTM 状态 + context（段与段之间互不影响时调）。
    func reset() {
        state = [Float](repeating: 0, count: SileroVAD.stateCount)
        context = [Float](repeating: 0, count: SileroVAD.contextSize)
    }

    /// 512 个 16kHz 样本 → 语音概率。任何一步失败返回 nil（调用方退化为 RMS）。
    func probability(_ frame: [Float]) -> Float? {
        guard frame.count == SileroVAD.frameSize else { return nil }
        do {
            // silero v5 实际窗口 = 上一帧尾部 64 样本 context + 本帧 512 样本。
            let windowed = context + frame
            var inputs: [String: ORTValue] = [
                inputName: try floatTensor(windowed, shape: [1, windowed.count]),
                stateName: try floatTensor(state, shape: [2, 1, 128]),
            ]
            if let srName {
                inputs[srName] = try int64Scalar(16000)
            }
            let result = try session.run(
                withInputs: inputs,
                outputNames: [probOutputName, stateOutputName],
                runOptions: nil
            )
            guard let probV = result[probOutputName],
                  let prob = ((try probV.tensorData()) as Data).asFloats?.first
            else { return nil }
            if let stateV = result[stateOutputName],
               let newState = ((try stateV.tensorData()) as Data).asFloats,
               newState.count == SileroVAD.stateCount {
                state = newState
            }
            context = Array(windowed.suffix(SileroVAD.contextSize))
            return prob
        } catch {
            return nil
        }
    }

    // MARK: - 私有

    private func floatTensor(_ data: [Float], shape: [Int]) throws -> ORTValue {
        let bytes = data.count * MemoryLayout<Float>.stride
        guard let nsdata = NSMutableData(length: bytes) else {
            throw NSError(domain: "MyPortrait.SileroVAD", code: -2)
        }
        data.withUnsafeBytes { src in
            nsdata.mutableBytes.copyMemory(from: src.baseAddress!, byteCount: bytes)
        }
        return try ORTValue(
            tensorData: nsdata,
            elementType: ORTTensorElementDataType.float,
            shape: shape.map { NSNumber(value: $0) }
        )
    }

    private func int64Scalar(_ value: Int64) throws -> ORTValue {
        var v = value
        let nsdata = NSMutableData(bytes: &v, length: MemoryLayout<Int64>.size)
        return try ORTValue(
            tensorData: nsdata,
            elementType: ORTTensorElementDataType.int64,
            shape: []
        )
    }
}
