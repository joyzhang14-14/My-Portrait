import Foundation

/// 说话人分离的结果片段：一段连续语音 + 它所属的持久说话人 id + 该段音频样本。
struct DiarizedSegment: Sendable {
    /// 段在 chunk 内的起止时间（秒）。
    let startS: Double
    let endS: Double
    /// DB `speakers.id`。nil = 解析失败（极少见）。
    let speakerId: Int64?
    /// 该段的 16kHz mono 样本，调用方拿去逐段转录。
    let samples: [Float]
}

/// 说话人分离接口（speaker diarization）。
///
/// 复刻 screenpipe：pyannote 分离模型找语音段 + wespeaker CAM++ 抽音色向量 +
/// 余弦聚类匹配持久说话人。实现见 [[OnnxSpeakerDiarizer]]。
///
/// 接入位置：TranscriptionScheduler.transcribeOne 先 diarize，再对每个返回段
/// 单独跑 WhisperKit 转录，每段写一行 audio_transcriptions（带 speaker_id）。
protocol SpeakerDiarizer: Sendable {

    /// 给一个 wav 段做说话人分离，返回按时间序的语音段。
    /// 空数组 = 未启用 / 模型未就绪 / 无语音 → 调用方退化为「整段一行、无说话人」。
    ///
    /// `isInput`：该段是否来自麦克风输入设备（用于把单一说话人自动命名为用户）。
    func diarize(wavPath: String, isInput: Bool) async -> [DiarizedSegment]
}

/// 默认 stub —— 始终返回空数组（说话人分离未启用时用）。
struct NoopSpeakerDiarizer: SpeakerDiarizer {
    func diarize(wavPath: String, isInput: Bool) async -> [DiarizedSegment] { [] }
}
