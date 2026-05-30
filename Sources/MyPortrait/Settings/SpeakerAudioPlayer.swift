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
    func toggle(speakerId: Int64) {
        if playingId == speakerId {
            stop()
            return
        }
        // 切换 speaker → 老的先停
        stop()
        guard let path = TimelineDB().latestAudioPath(forSpeakerId: speakerId) else {
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
            self.playingId = speakerId
        } catch {
            // 文件存在但格式不识别(.mp4 但 codec 怪)等等 —— 静默失败,
            // 不弹错保持 UI 干净。
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
