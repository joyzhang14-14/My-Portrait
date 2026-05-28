import Foundation

/// AI chat 主页 "Quick Actions" 6 张芯片的动态生成器。
///
/// 设计端口自 screenpipe-app-tauri 的 `suggestions.rs` (template_suggestions
/// 分支 —— 跳过 AI 生成,只跑 mode-aware 模板):
///   1. 查最近 ~60 分钟的 frames,统计 top 活跃 app + window
///   2. classifyApp 把 app 名映射到 mode(coding / browsing / meeting / ...)
///   3. detectMode 看哪个 mode 占比最大,选定本轮模式
///   4. modeSpecificSuggestions 按模式产 4-6 个带 preview 的 chip
///
/// 不调 AI = 纯本地、毫秒级返回、无 API 成本。HomeView 每次 appear /
/// 每 60s 重跑一次。
enum SuggestionEngine {

    /// 单条建议 chip。
    struct Suggestion: Identifiable, Hashable, Sendable {
        let id = UUID()
        let text: String
        /// 二行小字预览,比如 "32min in Cursor — AppDelegate.swift, README.md"。
        /// nil 时 ChipView 不显示第二行。
        let preview: String?
    }

    enum Mode: String, Sendable {
        case coding, browsing, meeting, communication, writing, videoEditing, idle
    }

    /// 入口:跑模式检测 + 模板生成,返回 ≤6 条 chip。
    /// 完全 nonisolated,可以 detached 跑。
    static func suggestions(from activity: TimelineDB.RecentActivity) -> [Suggestion] {
        let mode = detectMode(apps: activity.apps, windows: activity.windows)
        let chips = modeSuggestions(
            mode: mode,
            apps: activity.apps,
            windows: activity.windows
        )
        // 保证最多 6 条 + 永远有"summarize my day"兜底
        var out = chips
        if !out.contains(where: { $0.text.lowercased().contains("summarize my day") }) {
            out.append(.init(text: "summarize my day so far", preview: nil))
        }
        return Array(out.prefix(6))
    }

    // MARK: - App → Mode 分类

    /// 跟 screenpipe 同一张表(精简到 macOS 常见集),app 名字 lowercase 包含子串。
    private static let codingApps: [String] = [
        "cursor", "visual studio code", "code", "zed", "xcode", "intellij",
        "webstorm", "pycharm", "neovim", "vim", "sublime", "atom", "fleet",
        "android studio", "rider", "goland", "rustrover", "clion",
    ]
    private static let terminalApps: [String] = [
        "wezterm", "iterm2", "iterm", "terminal", "alacritty", "kitty", "warp",
        "tabby", "hyper", "rio",
    ]
    private static let browserApps: [String] = [
        "safari", "google chrome", "chrome", "firefox", "arc", "brave",
        "microsoft edge", "edge", "vivaldi", "opera", "zen browser",
    ]
    private static let meetingApps: [String] = [
        "zoom", "zoom.us", "google meet", "microsoft teams", "teams", "webex",
        "discord stage", "facetime",
    ]
    private static let communicationApps: [String] = [
        "slack", "discord", "messages", "telegram", "whatsapp", "wechat",
        "signal", "mail", "spark", "outlook", "feishu", "lark",
    ]
    private static let writingApps: [String] = [
        "notion", "obsidian", "bear", "craft", "notes", "logseq", "drafts",
        "ulysses", "scrivener", "microsoft word", "pages",
    ]
    private static let videoEditingApps: [String] = [
        "final cut pro", "premiere pro", "davinci resolve", "imovie",
        "screenflow", "capcut", "after effects",
    ]
    /// 浏览器里跑会议 URL → 升级到 meeting 模式。
    private static let meetingSites: [String] = [
        "meet.google.com", "zoom.us/j/", "teams.microsoft.com",
        "whereby.com", "around.co",
    ]

    private static func classifyApp(_ rawName: String) -> Mode? {
        let n = rawName.lowercased()
        if codingApps.contains(where: { n.contains($0) }) { return .coding }
        if terminalApps.contains(where: { n.contains($0) }) { return .coding }
        if browserApps.contains(where: { n == $0 || n.hasPrefix($0) }) { return .browsing }
        if meetingApps.contains(where: { n.contains($0) }) { return .meeting }
        if communicationApps.contains(where: { n.contains($0) }) { return .communication }
        if writingApps.contains(where: { n.contains($0) }) { return .writing }
        if videoEditingApps.contains(where: { n.contains($0) }) { return .videoEditing }
        return nil
    }

    // MARK: - Mode detection

    private static func detectMode(
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> Mode {
        guard !apps.isEmpty else { return .idle }
        let totalFrames = apps.reduce(0) { $0 + $1.count }
        var scores: [Mode: Int] = [:]

        for app in apps {
            if let mode = classifyApp(app.appName) {
                scores[mode, default: 0] += app.count
            }
        }

        // 浏览器开会议 URL → 加 meeting 分(只算 meeting,communication 站点不算
        // 防止"搜 slack alternatives"被误判)。
        for w in windows {
            let appLower = w.appName.lowercased()
            guard browserApps.contains(where: { appLower == $0 || appLower.hasPrefix($0) }) else { continue }
            let titleLower = w.windowName.lowercased()
            if meetingSites.contains(where: { titleLower.contains($0) }) {
                scores[.meeting, default: 0] += w.count
            }
        }

        // meeting 只要 > 5% 就赢(开会比刷网页优先级高)
        if let meetingScore = scores[.meeting],
           Double(meetingScore) / Double(totalFrames) > 0.05 {
            return .meeting
        }

        var best: (mode: Mode, score: Int) = (.idle, 0)
        for (mode, score) in scores where score > best.score {
            best = (mode, score)
        }
        // 没有任何模式 ≥ 15% → idle(混合 / 太短)
        if totalFrames > 0, Double(best.score) / Double(totalFrames) < 0.15 {
            return .idle
        }
        return best.mode
    }

    // MARK: - Mode → 模板

    private static func modeSuggestions(
        mode: Mode,
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> [Suggestion] {
        switch mode {
        case .coding:      return codingTemplate(apps: apps, windows: windows)
        case .browsing:    return browsingTemplate(apps: apps, windows: windows)
        case .meeting:     return meetingTemplate(apps: apps, windows: windows)
        case .communication: return communicationTemplate(apps: apps)
        case .writing:     return writingTemplate(apps: apps, windows: windows)
        case .videoEditing: return videoEditingTemplate(apps: apps)
        case .idle:        return idleTemplate()
        }
    }

    // MARK: Coding

    private static func codingTemplate(
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> [Suggestion] {
        let editor = apps.first { app in
            codingApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        let terminal = apps.first { app in
            terminalApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        // 1 帧 ≈ 1 秒 → /60 = 分钟。
        let editorMins = (editor?.count ?? 0) / 60
        let editorFiles: [String] = editor.map { ed in
            windows
                .filter { $0.appName.caseInsensitiveCompare(ed.appName) == .orderedSame
                          && $0.windowName.count > 3 }
                .prefix(3)
                .map { extractFilename(from: $0.windowName) }
        } ?? []

        var out: [Suggestion] = []
        let editorName = editor?.appName ?? "your editor"
        let editorPreview: String? = {
            if editorMins > 0, !editorFiles.isEmpty {
                return "\(editorMins)min in \(editorName) — \(editorFiles.joined(separator: ", "))"
            }
            if editorMins > 0 { return "\(editorMins)min in \(editorName)" }
            return nil
        }()
        out.append(.init(text: "summarize my coding session", preview: editorPreview))

        if let term = terminal {
            out.append(.init(
                text: "what commands did I run in \(term.appName)?",
                preview: nil
            ))
            out.append(.init(
                text: "any errors or warnings in my terminal?",
                preview: "check \(term.appName) output"
            ))
        }
        if let ed = editor {
            out.append(.init(
                text: "what files did I edit in \(ed.appName)?",
                preview: editorFiles.isEmpty ? nil : editorFiles.joined(separator: ", ")
            ))
        }
        out.append(.init(text: "how much time did I spend coding today?", preview: nil))
        return out
    }

    // MARK: Browsing

    private static func browsingTemplate(
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> [Suggestion] {
        let totalMins = apps
            .filter { app in browserApps.contains { app.appName.lowercased().hasPrefix($0) } }
            .reduce(0) { $0 + $1.count } / 60
        let pages = windows
            .filter { w in
                let app = w.appName.lowercased()
                let title = w.windowName.lowercased()
                let isBrowser = browserApps.contains { app == $0 || app.hasPrefix($0) }
                let isMeetingURL = meetingSites.contains { title.contains($0) }
                return isBrowser && !isMeetingURL && w.windowName.count > 5
                    && w.windowName != "Untitled" && w.windowName != "New Tab"
            }
            .prefix(3)
            .map { truncate($0.windowName, max: 35) }

        var out: [Suggestion] = []
        let preview: String? = {
            if totalMins > 0, !pages.isEmpty {
                return "\(totalMins)min browsing — \(pages.joined(separator: ", "))"
            }
            if totalMins > 0 { return "\(totalMins)min browsing" }
            return nil
        }()
        out.append(.init(text: "summarize the pages I browsed", preview: preview))
        for p in pages {
            out.append(.init(text: "what was I reading on \"\(p)\"?", preview: nil))
        }
        out.append(.init(text: "how much time did I spend browsing?",
                         preview: totalMins > 0 ? "~\(totalMins)min total" : nil))
        return out
    }

    // MARK: Meeting

    private static func meetingTemplate(
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> [Suggestion] {
        let meetingApp = apps.first { app in
            meetingApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        let meetingMins = (meetingApp?.count ?? 0) / 60
        let appLabel = meetingApp?.appName ?? "your call"
        let meetingTitle = windows
            .first { w in
                meetingApps.contains(where: { w.appName.lowercased().contains($0) })
                    && w.windowName.count > 3
            }?
            .windowName

        var out: [Suggestion] = [
            .init(
                text: "summarize my meeting",
                preview: meetingMins > 0
                    ? "\(meetingMins)min in \(appLabel)\(meetingTitle.map { " — \($0)" } ?? "")"
                    : meetingTitle.map { "in \(appLabel) — \($0)" }
            ),
            .init(text: "what were the action items from my call?", preview: nil),
            .init(text: "key decisions from the meeting", preview: nil),
            .init(text: "who said what in this call?", preview: nil),
        ]
        if let t = meetingTitle { out.insert(.init(text: "recap \"\(t)\"", preview: nil), at: 1) }
        return out
    }

    // MARK: Communication

    private static func communicationTemplate(
        apps: [TimelineDB.RecentActivity.AppCount]
    ) -> [Suggestion] {
        let topComm = apps.first { app in
            communicationApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        let mins = (topComm?.count ?? 0) / 60
        let label = topComm?.appName ?? "chat"
        return [
            .init(text: "summarize my conversations",
                  preview: mins > 0 ? "\(mins)min in \(label)" : nil),
            .init(text: "what messages do I need to reply to?", preview: nil),
            .init(text: "who reached out today?", preview: nil),
            .init(text: "key threads from this morning", preview: nil),
        ]
    }

    // MARK: Writing

    private static func writingTemplate(
        apps: [TimelineDB.RecentActivity.AppCount],
        windows: [TimelineDB.RecentActivity.WindowCount]
    ) -> [Suggestion] {
        let writer = apps.first { app in
            writingApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        let mins = (writer?.count ?? 0) / 60
        let label = writer?.appName ?? "your notes"
        let docs = writer.map { w in
            windows
                .filter { $0.appName.caseInsensitiveCompare(w.appName) == .orderedSame }
                .prefix(3)
                .map { truncate($0.windowName, max: 35) }
        } ?? []
        return [
            .init(text: "summarize what I wrote",
                  preview: mins > 0 && !docs.isEmpty
                    ? "\(mins)min in \(label) — \(docs.joined(separator: ", "))"
                    : (mins > 0 ? "\(mins)min in \(label)" : nil)),
            .init(text: "main ideas from my notes", preview: nil),
            .init(text: "what was I drafting?", preview: docs.isEmpty ? nil : docs.joined(separator: ", ")),
            .init(text: "how much time did I spend writing?", preview: nil),
        ]
    }

    // MARK: Video editing

    private static func videoEditingTemplate(
        apps: [TimelineDB.RecentActivity.AppCount]
    ) -> [Suggestion] {
        let editor = apps.first { app in
            videoEditingApps.contains(where: { app.appName.lowercased().contains($0) })
        }
        let mins = (editor?.count ?? 0) / 60
        return [
            .init(text: "summarize my editing session",
                  preview: mins > 0 ? "\(mins)min in \(editor?.appName ?? "editor")" : nil),
            .init(text: "what timeline edits did I make?", preview: nil),
            .init(text: "show my recent screen activity", preview: nil),
            .init(text: "summarize my day so far", preview: nil),
        ]
    }

    // MARK: Idle

    private static func idleTemplate() -> [Suggestion] {
        [
            .init(text: "what did I work on in the last hour?", preview: nil),
            .init(text: "summarize my day so far", preview: nil),
            .init(text: "which apps did I use most today", preview: nil),
            .init(text: "show my recent screen activity", preview: nil),
            .init(text: "what was I working on", preview: nil),
            .init(text: "how much time did I spend on each app", preview: nil),
        ]
    }

    // MARK: Helpers

    /// 窗口标题里抠文件名(典型形如 "AppDelegate.swift — Xcode")。
    private static func extractFilename(from windowTitle: String) -> String {
        let title = windowTitle.split(separator: " — ").first.map(String.init)
            ?? windowTitle.split(separator: " - ").first.map(String.init)
            ?? windowTitle
        return truncate(title, max: 30)
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 3)) + "..."
    }
}
