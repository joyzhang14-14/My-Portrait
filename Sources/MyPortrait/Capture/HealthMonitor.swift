import Foundation
import Combine
import os.log

/// 采集层健康状态汇总。各子系统(KeystrokeLedger / 等)发现异常时调
/// `report(component:reason:)`,StatusBarMenu 订阅 `$unhealthy` 把图标
/// 变红。同步写一行到 `~/.portrait/logs/health.log` 留痕。
///
/// 设计取舍:
/// - 全局单例 vs 注入:采集子系统散布在很多地方(KeystrokeLedger / Coordinator
///   / Observer),都要触达 health 太繁。单例足够。
/// - @Published 给 Combine 用,StatusBarMenu sink 一次性接上即可。
@MainActor
final class HealthMonitor: ObservableObject {

    static let shared = HealthMonitor()

    /// true = 至少一个采集组件异常,UI 应高亮(红色 icon)。
    @Published private(set) var unhealthy: Bool = false

    /// 当前出问题的组件名 → 最近一次告警时间。展示用。
    @Published private(set) var faults: [String: Date] = [:]

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "health")
    private let healthLogQueue = DispatchQueue(label: "com.myportrait.health.log")

    private init() {}

    /// 报告异常。`component` 例:"KeystrokeLedger.tap";`reason` 自由文本。
    /// 同名 component 重复 report 只刷新时间不重复写 log(降噪)。
    func report(component: String, reason: String) {
        let now = Date()
        let isNew = faults[component] == nil
        faults[component] = now
        unhealthy = true
        log.warning("HEALTH: \(component, privacy: .public) — \(reason, privacy: .public)")
        if isNew {
            appendLog(line: "[\(Self.iso(now))] FAULT \(component) — \(reason)")
        }
    }

    /// 组件自报恢复。
    func clear(component: String) {
        guard faults[component] != nil else { return }
        faults.removeValue(forKey: component)
        unhealthy = !faults.isEmpty
        log.info("HEALTH: \(component, privacy: .public) recovered")
        appendLog(line: "[\(Self.iso(Date()))] RECOVER \(component)")
    }

    // MARK: - log file

    /// 写一行到 ~/.portrait/logs/health.log。文件夹不存在就建。
    /// 失败不抛 —— 健康日志写失败本身不该再制造异常。
    private func appendLog(line: String) {
        let url = Self.logFileURL
        healthLogQueue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static var logFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".portrait", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("health.log")
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
