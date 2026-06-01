import AppKit
import Combine
import CoreAudio
import Foundation
import os.log

/// 检测当前是否有「暂停名单里的」app 在输出音频。
///
/// 用 Core Audio 进程对象接口（macOS 14.4+，公开 API，不需要额外权限）枚举
/// 正在输出音频的进程，对每个进程取它的 bundle id + 自报的应用类别
/// (`LSApplicationCategoryType`)，命中用户配置的 `pauseAudioApps`(bundle id) 或
/// `pauseAudioCategories`(类别) 即判定要暂停。类别 `public.app-category.games`
/// 特殊：匹配任意 `*-games` 子类。
///
/// actor 隔离 —— 类别查询结果缓存避免每次轮询都读 Info.plist。
actor MusicAudioDetector {

    /// bundleID → LSApplicationCategoryType（读过一次就缓存;空串 = 没声明/查不到）。
    private var categoryCache: [String: String] = [:]
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "music-detector")

    /// 当前是否有「命中暂停名单」的 app 正在输出音频。
    func shouldPause(apps: Set<String>, categories: Set<String>) -> Bool {
        var verdict = false
        var report: [String] = []
        for process in Self.audioProcessObjects() {
            guard Self.isRunningOutput(process) else { continue }
            let bundleID = Self.bundleID(of: process)
            let cat = bundleID.map { category(of: $0) }
            let hit: Bool = {
                if let b = bundleID, apps.contains(b) { return true }
                if let c = cat, Self.categoryMatches(c, selected: categories) { return true }
                return false
            }()
            let catLabel = (cat?.isEmpty == false) ? "(\(cat!))" : ""
            report.append("\(bundleID ?? "<no-bundle>")\(catLabel)\(hit ? " [PAUSE]" : "")")
            if hit { verdict = true }
        }
        logger.notice("shouldPause: outputting=[\(report.joined(separator: ", "), privacy: .public)] → \(verdict, privacy: .public)")
        return verdict
    }

    /// 读 app 自报的 LSApplicationCategoryType（缓存）。空串 = 没声明/查不到。
    private func category(of bundleID: String) -> String {
        if let cached = categoryCache[bundleID] { return cached }
        var category = ""
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let cat = bundle.infoDictionary?["LSApplicationCategoryType"] as? String {
            category = cat
        }
        logger.notice("category lookup: \(bundleID, privacy: .public) = \(category.isEmpty ? "<none>" : category, privacy: .public)")
        categoryCache[bundleID] = category
        return category
    }

    /// 命中判定：精确匹配,或 `games` 选中时匹配任意 `*-games` 子类。
    private static func categoryMatches(_ declared: String, selected: Set<String>) -> Bool {
        guard !declared.isEmpty, !selected.isEmpty else { return false }
        if selected.contains(declared) { return true }
        if selected.contains("public.app-category.games"), declared.hasSuffix("-games") { return true }
        return false
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

    /// 当前是否有「命中暂停名单」的 app 在输出音频(→ 暂停采集)。两个名单都
    /// 空时恒为 false。沿用 `musicDetected` 名字 —— Services 的采集 sink 订阅它。
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
        let audio = ConfigStore.shared.current.capture.audio
        let apps = Set(audio.pauseAudioApps)
        let cats = Set(audio.pauseAudioCategories)
        guard !apps.isEmpty || !cats.isEmpty else {
            logger.notice("tick: pause list empty → musicDetected forced false")
            if musicDetected { musicDetected = false }
            return
        }
        let playing = await detector.shouldPause(apps: apps, categories: cats)
        logger.notice("tick: apps=\(apps.count, privacy: .public) cats=\(cats.count, privacy: .public) playing=\(playing, privacy: .public) before=\(self.musicDetected, privacy: .public)")
        if musicDetected != playing {
            musicDetected = playing
            logger.notice("pause-audio \(playing ? "started" : "stopped", privacy: .public) — capture \(playing ? "paused" : "resumed", privacy: .public)")
        }
    }
}
