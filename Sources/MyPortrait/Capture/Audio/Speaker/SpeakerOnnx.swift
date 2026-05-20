import Foundation
import OnnxRuntimeBindings

/// 进程级共享的 ORT 环境。两个说话人模型共用。
/// `nonisolated(unsafe)`：ORTEnv 非 Sendable，但 ONNX Runtime 的 env 本就设计为
/// 跨线程共享、只初始化一次后只读，实际安全。
enum SpeakerOnnxEnv {
    nonisolated(unsafe) static let shared: ORTEnv? = try? ORTEnv(loggingLevel: ORTLoggingLevel.warning)
}

/// 单输入单输出 ONNX 模型的薄封装。pyannote 分离模型和 wespeaker CAM++
/// 都是这个形态。非 Sendable（持有 ORTSession）——由 OnnxSpeakerDiarizer
/// actor 独占持有，推理天然串行。
final class OnnxModel {
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    init(modelPath: String, preferredOutput: String) throws {
        guard let env = SpeakerOnnxEnv.shared else {
            throw NSError(domain: "MyPortrait.Onnx", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ORT env init failed"])
        }
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        try opts.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)

        let ins = (try? session.inputNames()) ?? []
        inputName = ins.first ?? "input"
        let outs = (try? session.outputNames()) ?? []
        outputName = outs.contains(preferredOutput) ? preferredOutput : (outs.first ?? preferredOutput)
    }

    /// 跑一次推理。`shape` 元素总数须等于 `input.count`。
    /// 返回输出张量的扁平 float 数组 + 形状。
    func run(input: [Float], shape: [Int]) throws -> (data: [Float], shape: [Int]) {
        let byteCount = input.count * MemoryLayout<Float>.stride
        guard let data = NSMutableData(length: byteCount) else {
            throw NSError(domain: "MyPortrait.Onnx", code: -4)
        }
        input.withUnsafeBytes { src in
            data.mutableBytes.copyMemory(from: src.baseAddress!, byteCount: byteCount)
        }
        let value = try ORTValue(
            tensorData: data,
            elementType: ORTTensorElementDataType.float,
            shape: shape.map { NSNumber(value: $0) }
        )
        let outputs = try session.run(
            withInputs: [inputName: value],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let out = outputs[outputName] else {
            throw NSError(domain: "MyPortrait.Onnx", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "missing output \(outputName)"])
        }
        let info = try out.tensorTypeAndShapeInfo()
        let outShape = info.shape.map { $0.intValue }
        let outData = try out.tensorData() as Data
        guard let floats = outData.asFloats else {
            throw NSError(domain: "MyPortrait.Onnx", code: -3)
        }
        return (floats, outShape)
    }
}

/// wespeaker CAM++ 音色向量提取器。Fbank 特征 → 512 维 L2 归一化向量。
final class SpeakerEmbeddingExtractor {
    private let model: OnnxModel
    private let fbank: FbankExtractor

    init(modelPath: String, fbank: FbankExtractor) throws {
        model = try OnnxModel(modelPath: modelPath, preferredOutput: "embs")
        self.fbank = fbank
    }

    /// 16kHz mono samples → 512 维音色向量。nil = 样本太短 / 推理失败。
    func embed(_ samples: [Float]) -> [Float]? {
        let feats = fbank.compute(samples)              // [num_frames][80]
        guard !feats.isEmpty else { return nil }
        var flat: [Float] = []
        flat.reserveCapacity(feats.count * FbankExtractor.numMelBins)
        for row in feats { flat.append(contentsOf: row) }
        do {
            let (out, _) = try model.run(
                input: flat, shape: [1, feats.count, FbankExtractor.numMelBins]
            )
            guard !out.isEmpty else { return nil }
            var v = out
            VectorMath.l2Normalize(&v)
            return v
        } catch {
            return nil
        }
    }
}

/// pyannote segmentation-3.0。一个 10s 窗口 → 每帧的类别打分。
/// screenpipe 只用它做语音/非语音判定（argmax != 0 = 有人说话）。
final class SpeakerSegmentationModel {
    private let model: OnnxModel

    init(modelPath: String) throws {
        model = try OnnxModel(modelPath: modelPath, preferredOutput: "output")
    }

    /// 一个窗口（通常 160000 samples = 10s）→ `[num_frames][num_classes]`。
    func process(window: [Float]) throws -> [[Float]] {
        let (out, shape) = try model.run(input: window, shape: [1, 1, window.count])
        guard shape.count == 3 else { return [] }
        let frames = shape[1]
        let classes = shape[2]
        guard frames > 0, classes > 0, out.count >= frames * classes else { return [] }
        var result: [[Float]] = []
        result.reserveCapacity(frames)
        for f in 0..<frames {
            result.append(Array(out[f * classes ..< (f + 1) * classes]))
        }
        return result
    }
}
