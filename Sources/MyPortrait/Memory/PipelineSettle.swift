import Foundation

/// 结算时刻:流水线处理到的料截至哪个时间(10-27 update)。
///
/// weight 的时间衰减、周预算、归档、事件图谱时间轴的终点都以它为「现在」—— 按料的时间
/// 算,不按流水线是哪天跑的:料处理到 10-02,整套 weight 就按 10-02 重算。流水线不跑,
/// 界面上的 weight 和可拖的天数保持原样。只往前走,补跑旧区间不会把它拨回去。
///   - events:本机 event job 或 Premium 导入处理完的区间(event + impact 都 complete)
///     里最晚的结束时间;
///   - portrait:distill 跑成时读的是截至 events 结算时刻的事件,所以跟到 events。
/// 没记录过(刚升级)时,events 从事件内容里的最后一次发生日推一次(不看文件 mtime ——
/// 手动编辑也会改 mtime),portrait 取 events。
enum PipelineSettle {

    private static let eventsKey = "memory.settled.events"
    private static let portraitKey = "memory.settled.portrait"

    static var events: Date {
        read(eventsKey) ?? seed(eventsKey, from: Storage.eventsDir) { $0.lastOccurrence ?? $0.created }
    }
    static var portrait: Date {
        if let t = read(portraitKey) { return t }
        let at = events
        markPortrait(at)
        return at
    }

    /// 这轮处理完的料截至 `material` → 本轮 events 结算用的「现在」。
    static func eventsClock(through material: Date) -> Date { max(events, material) }
    /// distill 跑成后 portrait 结算用的「现在」。
    static var portraitClock: Date { max(portrait, events) }

    static func markEvents(_ at: Date) { UserDefaults.standard.set(at.timeIntervalSince1970, forKey: eventsKey) }
    static func markPortrait(_ at: Date) { UserDefaults.standard.set(at.timeIntervalSince1970, forKey: portraitKey) }

    private static func read(_ key: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private static func seed(_ key: String, from dir: URL, date: (PortraitFile) -> Date) -> Date {
        var latest = Date(timeIntervalSince1970: 0)
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md",
                  let f = try? PortraitFileIO.read(from: url) else { continue }
            latest = max(latest, date(f))
        }
        let at = latest.timeIntervalSince1970 > 0 ? latest : Date()
        UserDefaults.standard.set(at.timeIntervalSince1970, forKey: key)
        return at
    }
}

extension PortraitFile {
    /// 显示用的「现在」:事件按事件流水线上次结算,画像按画像流水线上次结算。
    var settledAsOf: Date { impact != nil ? PipelineSettle.events : PipelineSettle.portrait }
}
