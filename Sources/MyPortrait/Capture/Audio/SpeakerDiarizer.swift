import Foundation

/// 说话人识别接口（speaker diarization）。
///
/// **当前状态：stub**。返回 nil，DB 的 speaker_id 列永远 nil。
///
/// 设计文档点名要的功能（"Whisper 转录 + 主人识别 (speaker ID)"），
/// 但真实实现需要嵌 ONNX Runtime + pyannote 蒸馏模型，是个独立的大工程
/// (~300 行 + 模型权重)。schema 字段 + 接口在这里把位置占好，未来直接换实现。
///
/// 接入位置：TranscriptionScheduler.transcribeOne 在 whisper.transcribe 完成后
/// 调一次 diarizer.diarize，把结果写入 TranscriptionRecord.speakerId。
public protocol SpeakerDiarizer: Sendable {

    /// 给一个 wav 段做说话人识别，返回主说话人 id（小整数）或 nil。
    /// nil = 无法识别 / 未实现 / 多人无法定主。
    func diarize(wavPath: String) async -> Int?
}

/// 默认 stub —— 始终返回 nil。
///
/// 真实实现替换此 type 时：
///   1. 嵌入 ONNX Runtime（Swift package：onnxruntime-swift 或自己 bridge）
///   2. 下载 pyannote 蒸馏的 speaker_embeddings 模型（~80MB）
///   3. 提取 wav 的 embedding，跟用户"主人 embedding"（首次注册时录的样本）
///      算余弦相似度
///   4. 高于阈值 → 返回主人 id (0)；低于 → 返回 nil 或递增的 guest id
public struct NoopSpeakerDiarizer: SpeakerDiarizer {
    public init() {}
    public func diarize(wavPath: String) async -> Int? { nil }
}
