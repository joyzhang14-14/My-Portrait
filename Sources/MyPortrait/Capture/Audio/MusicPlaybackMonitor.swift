import AppKit
import Combine
import CoreAudio
import Foundation
import os.log

/// 检测当前是否有「音乐类」app 在输出音频。
///
/// 用 Core Audio 进程对象接口（macOS 14.4+，公开 API，不需要额外权限）枚举
/// 正在输出音频的进程，再读各 app 自己在 Info.plist 声明的应用类别
/// (`LSApplicationCategoryType`)，只有声明为 `public.app-category.music` 的
/// 才算「音乐软件」—— 这样能区分音乐 app 和通话 app（Zoom 等是 business 类，
/// 不会误触发，电话/会议照常录）。
///
/// actor 隔离 —— 分类结果缓存避免每次轮询都读 Info.plist。
actor MusicAudioDetector {

    private static let musicCategory = "public.app-category.music"

    /// bundleID → 是否音乐类 app。读过一次就缓存。
    private var categoryCache: [String: Bool] = [:]
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "music-detector")

    /// 当前是否有音乐类 app 正在输出音频。
    func isMusicPlaying() -> Bool {
        var verdict = false
        var report: [String] = []
        for process in Self.audioProcessObjects() {
            guard Self.isRunningOutput(process) else { continue }
            let bundleID = Self.bundleID(of: process)
            let music = bundleID.map { isMusicApp($0) } ?? false
            report.append("\(bundleID ?? "<no-bundle>")\(music ? " [MUSIC]" : "")")
            if music { verdict = true }
        }
        logger.notice("isMusicPlaying: outputting=[\(report.joined(separator: ", "), privacy: .public)] → \(verdict, privacy: .public)")
        return verdict
    }

    private func isMusicApp(_ bundleID: String) -> Bool {
        if let cached = categoryCache[bundleID] { return cached }
        var category = "<none>"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let cat = bundle.infoDictionary?["LSApplicationCategoryType"] as? String {
            category = cat
        }
        let isMusic = (category == Self.musicCategory)
        logger.notice("category lookup: \(bundleID, privacy: .public) = \(category, privacy: .public) → music=\(isMusic)")
        categoryCache[bundleID] = isMusic
        return isMusic
    }

    // MARK: - Core Audio 进程对象

    private static func audioProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var bundleID: CFString?
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &bundleID) == noErr,
              let cf = bundleID
        else { return nil }
        let bid = cf as String
        return bid.isEmpty ? nil : bid
    }
}

/// 周期轮询 `MusicAudioDetector`，把「是否有音乐在放」暴露成 Combine 状态。
/// Services 把它接进音频采集的 effective-state sink：音乐在放 → 暂停采集。
@MainActor
final class MusicPlaybackMonitor {

    /// 当前是否有音乐类 app 在输出音频。`pauseOnMusicApp` 关闭时恒为 false。
    @Published private(set) var musicDetected = false

    private let logger = Logger(subsystem: "com.myportrait", category: "music-monitor")
    private let detector = MusicAudioDetector()
    private var task: Task<Void, Never>?
    private static let pollIntervalNs: UInt64 = 5_000_000_000   // 5s

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        let enabled = ConfigStore.shared.current.capture.audio.pauseOnMusicApp
        guard enabled else {
            logger.notice("tick: pauseOnMusicApp=false → musicDetected forced false")
            if musicDetected { musicDetected = false }
            return
        }
        let playing = await detector.isMusicPlaying()
        logger.notice("tick: pauseOnMusicApp=true playing=\(playing, privacy: .public) musicDetected(before)=\(self.musicDetected, privacy: .public)")
        if musicDetected != playing {
            musicDetected = playing
            logger.notice("music \(playing ? "started" : "stopped", privacy: .public) — audio capture \(playing ? "paused" : "resumed", privacy: .public)")
        }
    }
}
