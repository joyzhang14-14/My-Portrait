import Foundation

/// 把 PersonalityDailySnapshot 落到 `~/.portrait/personality_daily/<date>.md`。
///
/// 文件格式（极简，无冗余元数据 / summary）：
///
///   ---
///   date: 2026-05-11
///   generated_at: 2026-05-12T04:30:15Z
///   ---
///
///   # Tags
///
///   - verification
///     - set_up_my_orphies_app
///     - inspected_my_orphies_update_settings
///   - multitasking
///     - reviewed_exam_schedule_and_project_messages
///
/// frontmatter 只有 `date`（核心）+ `generated_at`（retention 基准 —— 文件
/// mtime 不可靠）。body 是 markdown tag list，evidence 作子 list。
enum PersonalityDailyStore {

    // 只配置一次再调线程安全方法，nonisolated(unsafe) opt-out 合适。
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 把 snapshot 写到 personality_daily/<snapshot.date>.md。返回写入的 URL。
    @discardableResult
    static func write(_ snapshot: PersonalityDailySnapshot,
                      generatedAt: Date = Date()) throws -> URL {
        let dir = Storage.personalityDailyDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(snapshot.date).md")

        var lines: [String] = ["---"]
        lines.append("date: \(snapshot.date)")
        lines.append("generated_at: \(isoFormatter.string(from: generatedAt))")
        lines.append("---")
        lines.append("")
        lines.append("# Tags")
        lines.append("")
        if snapshot.tags.isEmpty {
            lines.append("(none)")
        } else {
            for tag in snapshot.tags {
                lines.append("- \(tag.name)")
                for ev in tag.evidence {
                    lines.append("  - \(ev)")
                }
            }
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
