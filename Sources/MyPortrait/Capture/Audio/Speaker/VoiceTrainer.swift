import Foundation
import Observation
import os.log

/// 声纹训练。复刻 screenpipe `voice_training.rs` 的格式：
///
/// 用户在「30 秒倒计时」期间正常说话（常驻麦克风采集在录），倒计时结束后调
/// `assign(name:)` —— 后台轮询最近时间窗里麦克风采到的音频被分到哪个声纹簇，
/// 把票数最多的那个簇命名为用户本人。
///
/// 为什么要轮询：转录 + 说话人分离是接电源后才异步跑的，刚说完话不会立刻有
/// speaker_id，得等管线处理完。screenpipe 同样轮询（最多 10 分钟）。
///
/// 单例：后台轮询要在「关掉 Speakers 设置页」后仍存活，所以不挂在 View 上。
@MainActor
@Observable
final class VoiceTrainer {

    static let shared = VoiceTrainer()

    enum Phase: Equatable {
        case idle
        case matching                  // 后台轮询中
        case success(name: String)
        case failure(String)
    }

    private(set) var phase: Phase = .idle

    /// 训练时往回看的时间窗（screenpipe 用 120s，覆盖对话框弹出前就开始录的块）。
    private static let lookbackMs: Int64 = 120_000
    /// 轮询间隔与上限（15s × 40 = 10 分钟）。
    private static let pollIntervalNs: UInt64 = 15_000_000_000
    private static let maxAttempts = 40

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "voice-training")
    private var task: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { task != nil }

    /// 倒计时结束后调用。后台轮询 [now-120s, now] 窗口里的**麦克风录到的
    /// 转录行**(audio_transcriptions JOIN audio_chunks WHERE is_input=1),
    /// 一旦有行就**直接把它们的 speaker_id 改成用户的 speaker**
    /// —— 不依赖 diarization 是否产出 cluster。
    ///
    /// 这条路径参考 screenpipe `voice_training.rs` —— 原项目走 search API
    /// 拿 input chunk_id 然后调 `/speakers/reassign`,本质等价于直接 UPDATE。
    /// 我们的老实现等 diarization 投票产出 speaker_id 再 rename,只要
    /// diarization 任何一环卡(模型没下完 / 阈值 / VAD)训练就 timeout。
    /// 新实现 transcription 跑完(audio_transcriptions 有行)就 OK。
    func assign(name: String) {
        guard task == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failure("先填写你的名字")
            return
        }
        phase = .matching

        let endMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = endMs - Self.lookbackMs

        task = Task { [weak self] in
            var assignedRows = 0
            for attempt in 1...Self.maxAttempts {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)

                let count = await Self.transcribedInputCount(fromMs: startMs, toMs: endMs)
                guard count > 0 else {
                    if attempt % 4 == 0 {
                        self?.logger.info("voice training: no transcribed input audio yet (attempt \(attempt)/\(Self.maxAttempts))")
                    }
                    continue
                }
                // 等剩余 chunk 也跑完转录;最后一次轮询用现有兜底。
                let pending = await Self.pendingInputChunks(fromMs: startMs, toMs: endMs)
                if pending > 0, attempt < Self.maxAttempts {
                    self?.logger.info("voice training: \(pending) input chunk(s) still processing (attempt \(attempt)/\(Self.maxAttempts))")
                    continue
                }

                // 拿到/建用户自己的 speaker row,把窗口里所有 input transcription
                // 直接 reassign 过去。一行 SQL UPDATE,不依赖 diarization。
                guard let userSpeakerId = await Self.findOrCreateSpeaker(name: trimmed) else {
                    self?.logger.error("voice training: failed to find/create speaker '\(trimmed, privacy: .public)'")
                    continue
                }
                assignedRows = await Self.reassignInputs(speakerId: userSpeakerId, fromMs: startMs, toMs: endMs)
                self?.logger.info("voice training: reassigned \(assignedRows) input transcription rows to speaker \(userSpeakerId) ('\(trimmed, privacy: .public)')")
                break
            }

            guard let self else { return }
            self.phase = assignedRows > 0
                ? .success(name: trimmed)
                : .failure("没找到你的语音 —— 确认麦克风录音已开启,接上电源让转录跑完")
            self.task = nil
        }
    }

    /// 取消进行中的训练，回到初始态。
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // sqlite 查询放后台线程，别阻塞 main actor。
    private static func transcribedInputCount(fromMs: Int64, toMs: Int64) async -> Int {
        await Task.detached { TimelineDB().transcribedInputCount(fromMs: fromMs, toMs: toMs) }.value
    }

    private static func findOrCreateSpeaker(name: String) async -> Int64? {
        await Task.detached { TimelineDB().findOrCreateSpeaker(name: name) }.value
    }

    private static func reassignInputs(speakerId: Int64, fromMs: Int64, toMs: Int64) async -> Int {
        await Task.detached {
            TimelineDB().reassignInputTranscriptionsToSpeaker(speakerId, fromMs: fromMs, toMs: toMs)
        }.value
    }

    private static func pendingInputChunks(fromMs: Int64, toMs: Int64) async -> Int {
        await Task.detached { TimelineDB().pendingInputChunkCount(fromMs: fromMs, toMs: toMs) }.value
    }
}
