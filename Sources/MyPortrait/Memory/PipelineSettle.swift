import Foundation

/// 结算时刻:流水线上次真跑完的时间(10-26 update)。
///
/// weight 的时间衰减、归档、事件图谱时间轴的终点都以它为「现在」—— 流水线不跑,
/// 界面上的 weight 和可拖的天数保持原样;跑完一轮才按日历结算到当时。
///   - events:本机 event job 至少处理完一个区间,或 Premium 导入成功;
///   - portrait:本机 distill 各分类都跑成,或 Premium 导入成功。
/// 没记录过(刚升级)时,从文件内容里的日期推一次(事件取最后一次发生日,画像取
/// last_modified),不看文件 mtime —— 手动编辑也会改 mtime。
enum PipelineSettle {

    private static let eventsKey = "memory.settled.events"
    private static let portraitKey = "memory.settled.portrait"

    static var events: Date {
        read(eventsKey) ?? seed(eventsKey, from: Storage.eventsDir) { $0.lastOccurrence ?? $0.created }
    }
    static var portrait: Date {
        read(portraitKey) ?? seed(portraitKey, from: Storage.portraitDir) { $0.lastModified ?? $0.created }
    }

    static func markEvents(_ at: Date = Date()) { UserDefaults.standard.set(at.timeIntervalSince1970, forKey: eventsKey) }
    static func markPortrait(_ at: Date = Date()) { UserDefaults.standard.set(at.timeIntervalSince1970, forKey: portraitKey) }

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
