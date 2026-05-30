import Foundation
import AVFoundation
import Observation

/// 全局单例 —— SpeakersView 行里的"试听"按钮共用。
///
/// 行为:
///   - toggle(speakerId): 当前没在播 / 在播别的 speaker → 起播这个 speaker
///     最近一段;在播这个 speaker → 暂停 / 停止。
///   - playingId: 当前正在播放的 speaker id;nil = 没在播。
///
/// 单例理由:同一时刻只能播一条,跨多行 View 共享状态最干净。
@MainActor
@Observable
final class SpeakerAudioPlayer: NSObject {
    static let shared = SpeakerAudioPlayer()

    /// 当前正在播放的 speaker id。nil = 未播放。SwiftUI View 用这个驱动
    /// 图标 waveform → pause.fill 切换。
    private(set) var playingId: Int64? = nil

    private var player: AVAudioPlayer?

    private override init() { super.init() }

    /// 切换:在播这个 id → 停;否则起播。找不到音频静默返。
    /// 播放优先级:
    ///   1. ~/.portrait/voice_training/<id>.wav(用户训练录的那 30s)
    ///   2. audio_chunks 里最近一条带转录的会议音频(fallback)
    func toggle(speakerId: Int64) {
        if playingId == speakerId {
            stop()
            return
        }
        stop()
        let trainingPath = Storage.voiceTrainingDir
            .appendingPathComponent("\(speakerId).wav").path
        let path: String
        if FileManager.default.fileExists(atPath: trainingPath) {
            path = trainingPath
        } else if let p = TimelineDB().latestAudioPath(forSpeakerId: speakerId) {
            path = p
        } else {
            NSLog("[SpeakerAudioPlayer] no source for speaker \(speakerId)")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[SpeakerAudioPlayer] file missing: \(path)")
            return
        }
        NSLog("[SpeakerAudioPlayer] play \(path)")
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            let ok = p.play()
            NSLog("[SpeakerAudioPlayer] play()=\(ok) duration=\(p.duration)s volume=\(p.volume)")
            self.player = p
            self.playingId = speakerId
        } catch {
            NSLog("[SpeakerAudioPlayer] AVAudioPlayer init FAILED: \(error.localizedDescription)")
            self.player = nil
            self.playingId = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingId = nil
    }
}

extension SpeakerAudioPlayer: @preconcurrency AVAudioPlayerDelegate {
    /// 自然播完(到尾)→ 把按钮图标切回 waveform。
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playingId = nil
        }
    }
}
