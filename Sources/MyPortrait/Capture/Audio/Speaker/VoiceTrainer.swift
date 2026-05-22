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
    /// 传播合并阈值：训练窗口里和主簇 centroid 余弦相似度 ≥ 此值的其它簇，
    /// 判定为被分离器切碎的同一个人，合并进主簇。
    private static let mergeThreshold: Float = 0.5

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "voice-training")
    private var task: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { task != nil }

    /// 倒计时结束后调用。后台轮询 [now-120s, now] 窗口里的麦克风音频声纹簇，
    /// 把主簇命名为 `name`。
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
            var named = false
            for attempt in 1...Self.maxAttempts {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)

                let votes = await Self.fetchVotes(fromMs: startMs, toMs: endMs)
                guard !votes.isEmpty else {
                    if attempt % 4 == 0 {
                        self?.logger.info("voice training: no diarized input audio yet (attempt \(attempt)/\(Self.maxAttempts))")
                    }
                    continue
                }
                // 票数最多的声纹簇 = 用户本人。
                var tally: [Int64: Int] = [:]
                for v in votes { tally[v, default: 0] += 1 }
                guard let dominant = tally.max(by: { $0.value < $1.value })?.key else { continue }
                await Self.rename(speakerId: dominant, to: trimmed)
                named = true
                self?.logger.info("voice training: named speaker \(dominant) as '\(trimmed, privacy: .public)'")

                // 传播合并：训练时你一个人在说话，窗口里被分离器切出的其它声纹
                // 簇同样是你。和主簇 centroid 足够像的合并进主簇，消除碎片化。
                let others = Set(tally.keys).subtracting([dominant])
                if !others.isEmpty {
                    let simMap = Dictionary(
                        await Self.similarSpeakers(to: dominant).map { ($0.id, $0.similarity) },
                        uniquingKeysWith: { a, _ in a })
                    for sid in others where (simMap[sid] ?? 0) >= Self.mergeThreshold {
                        await Self.merge(keep: dominant, merge: sid)
                        self?.logger.info("voice training: merged speaker \(sid) into \(dominant)")
                    }
                }
                break
            }

            guard let self else { return }
            self.phase = named
                ? .success(name: trimmed)
                : .failure("没找到你的语音 —— 确认录音已开启、说话人识别已开启，并接上电源让转录跑完")
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
    private static func fetchVotes(fromMs: Int64, toMs: Int64) async -> [Int64] {
        await Task.detached { TimelineDB().inputSpeakerVotes(fromMs: fromMs, toMs: toMs) }.value
    }

    private static func rename(speakerId: Int64, to name: String) async {
        _ = await Task.detached { TimelineDB().renameSpeaker(id: speakerId, to: name) }.value
    }

    private static func similarSpeakers(to id: Int64) async -> [SimilarSpeaker] {
        await Task.detached { TimelineDB().similarSpeakers(to: id, limit: 20) }.value
    }

    private static func merge(keep: Int64, merge mergeId: Int64) async {
        _ = await Task.detached { TimelineDB().mergeSpeakers(keep: keep, merge: mergeId) }.value
    }
}
