import Foundation
import SwiftUI
import Observation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, pipes, timeline, memories, connections
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Home"
        case .pipes: return "Pipes"
        case .timeline: return "Timeline"
        case .memories: return "Memories"
        case .connections: return "Connections"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "plus.message"
        case .pipes: return "puzzlepiece.extension"
        case .timeline: return "clock.arrow.circlepath"
        case .memories: return "sparkles"
        case .connections: return "powerplug"
        }
    }
}

// MARK: - Chat

enum ChatRole: String, Codable { case user, assistant }

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let role: ChatRole
    var text: String                // mutable so streaming tokens can append in place
    let time: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, time: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
    }
}

// MARK: - Integrations

struct Integration: Identifiable, Hashable {
    let id: String
    let name: String
    /// Bundle identifier — if app is installed, NSWorkspace pulls the real icon.
    let bundleId: String?
    /// Single-letter "wordmark" glyph used when no real icon is available.
    let letter: String
    /// Brand accent color, used for the letter glyph background and accents.
    let accent: Color
    let signInMethod: SignInMethod
    let category: Category

    enum SignInMethod: String { case oauth, apiKey, localApp, systemAccess }
    enum Category: String { case ai = "AI Providers", productivity = "Productivity", media = "Media & Calendar", local = "Local Models" }
}

enum IntegrationRegistry {
    /// Brand colors — picked to match each service's actual brand palette
    /// (not Apple system colors, not SF Symbol tinting).
    static let all: [Integration] = [
        // AI providers
        .init(id: "chatgpt",            name: "ChatGPT",         bundleId: "com.openai.chat",                       letter: "G",  accent: Color(red: 0.06, green: 0.65, blue: 0.51),  signInMethod: .oauth,        category: .ai),
        .init(id: "claude",             name: "Claude Desktop",  bundleId: "com.anthropic.claudefordesktop",        letter: "C",  accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .localApp,     category: .ai),
        .init(id: "claude-code",        name: "Claude Code",     bundleId: nil,                                     letter: ">",  accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .localApp,     category: .ai),
        .init(id: "anthropic-api",      name: "Anthropic API",   bundleId: nil,                                     letter: "A",  accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .apiKey,       category: .ai),
        .init(id: "gemini",             name: "Gemini",          bundleId: nil,                                     letter: "G",  accent: Color(red: 0.26, green: 0.52, blue: 0.96),  signInMethod: .apiKey,       category: .ai),
        .init(id: "perplexity",         name: "Perplexity",      bundleId: "ai.perplexity.mac",                     letter: "P",  accent: Color(red: 0.11, green: 0.66, blue: 0.69),  signInMethod: .apiKey,       category: .ai),
        .init(id: "cursor",             name: "Cursor",          bundleId: "com.todesktop.230313mzl4w4u92",         letter: "C",  accent: Color(white: 0.85),                         signInMethod: .localApp,     category: .ai),
        .init(id: "warp",               name: "Warp",            bundleId: "dev.warp.Warp-Stable",                  letter: "W",  accent: Color(red: 0.95, green: 0.30, blue: 0.50),  signInMethod: .localApp,     category: .ai),

        // Local model runners
        .init(id: "ollama",             name: "Ollama",          bundleId: "com.electron.ollama",                   letter: "🦙", accent: Color(white: 0.92),                         signInMethod: .localApp,     category: .local),
        .init(id: "lmstudio",           name: "LM Studio",       bundleId: "ai.lmstudio.LMStudio",                  letter: "L",  accent: Color(red: 0.32, green: 0.40, blue: 0.78),  signInMethod: .localApp,     category: .local),
        .init(id: "msty",               name: "Msty",            bundleId: "com.msty.studio",                       letter: "M",  accent: Color(red: 0.20, green: 0.71, blue: 0.65),  signInMethod: .localApp,     category: .local),

        // Productivity
        .init(id: "obsidian",           name: "Obsidian",        bundleId: "md.obsidian",                           letter: "○",  accent: Color(red: 0.49, green: 0.34, blue: 0.78),  signInMethod: .localApp,     category: .productivity),
        .init(id: "notion",             name: "Notion",          bundleId: "notion.id",                             letter: "N",  accent: Color(white: 0.95),                         signInMethod: .oauth,        category: .productivity),
        .init(id: "linear",             name: "Linear",          bundleId: "com.linear",                            letter: "L",  accent: Color(red: 0.36, green: 0.40, blue: 0.94),  signInMethod: .oauth,        category: .productivity),

        // Media / Calendar
        .init(id: "spotify",            name: "Spotify",         bundleId: "com.spotify.client",                    letter: "♪",  accent: Color(red: 0.11, green: 0.72, blue: 0.33),  signInMethod: .oauth,        category: .media),
        .init(id: "apple-calendar",     name: "Apple Calendar",  bundleId: "com.apple.iCal",                        letter: "📅", accent: Color(red: 0.93, green: 0.27, blue: 0.27),  signInMethod: .systemAccess, category: .media),
        .init(id: "google-calendar",    name: "Google Calendar", bundleId: nil,                                     letter: "📆", accent: Color(red: 0.26, green: 0.52, blue: 0.96),  signInMethod: .oauth,        category: .media),
        .init(id: "voice-memos",        name: "Voice Memos",     bundleId: "com.apple.VoiceMemos",                  letter: "🎙", accent: Color(red: 0.93, green: 0.27, blue: 0.27),  signInMethod: .systemAccess, category: .media),
        .init(id: "apple-intelligence", name: "Apple Intelligence", bundleId: nil,                                  letter: "✦",  accent: Color(red: 0.92, green: 0.42, blue: 0.66),  signInMethod: .systemAccess, category: .media)
    ]
}

@Observable
final class AppState {
    var connectedIds: Set<String> = []
    var activeAIId: String? = nil

    init() {
        // Restore persisted connections from disk-backed secret stores.
        if ChatGPTOAuth.isLoggedIn() {
            connectedIds.insert("chatgpt")
            if activeAIId == nil { activeAIId = "chatgpt" }
        }
    }

    func isConnected(_ id: String) -> Bool { connectedIds.contains(id) }

    func toggleConnect(_ integration: Integration) {
        if connectedIds.contains(integration.id) {
            connectedIds.remove(integration.id)
            if activeAIId == integration.id { activeAIId = nil }
        } else {
            connectedIds.insert(integration.id)
            if integration.category == .ai && activeAIId == nil { activeAIId = integration.id }
        }
    }

    var activeAI: Integration? {
        guard let id = activeAIId else { return nil }
        return IntegrationRegistry.all.first { $0.id == id }
    }
}

// MARK: - Home greeting

struct SuggestionCard: Identifiable, Hashable {
    let id = UUID()
    let emoji: String
    let title: String
    let subtitle: String
}

struct ActivityChip: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let hint: String?
}

enum Mock {
    static let suggestionCards: [SuggestionCard] = [
        .init(emoji: "⚡️", title: "Automate My Work",     subtitle: "Analyze your habits and…"),
        .init(emoji: "📋", title: "Day Recap",             subtitle: "Today's accomplishments, ke…"),
        .init(emoji: "🏢", title: "Standup Update",        subtitle: "What you did, what's next, an…"),
        .init(emoji: "💡", title: "What's Top of Mind",    subtitle: "Recurring topics and themes…"),
        .init(emoji: "✨", title: "Custom Summary",        subtitle: "Build your own"),
        .init(emoji: "🔍", title: "Discover",              subtitle: "6 more ›")
    ]

    static let activityChips: [ActivityChip] = [
        .init(text: "summarize my coding session", hint: nil),
        .init(text: "any errors or warnings in my…", hint: "check Terminal output"),
        .init(text: "what commands did I run in Terminal?", hint: nil),
        .init(text: "how much time did I spend coding today?", hint: nil),
        .init(text: "summarize my day so far", hint: nil),
        .init(text: "which apps did I use most today", hint: nil)
    ]

    static let recents: [String] = [
        "帮我看看我最近一个小时和终…", "todo-list-assistant #218", "search screenpipe for what …",
        "go to x.com", "todo-list-assistant #195", "search screenpipe for what …",
        "todo-list-assistant #194", "todo-list-assistant #193", "what did I work on in the last…",
        "todo-list-assistant #111", "我这一个小时都在干什么?", "我这几天都在做什么?",
        "todo-list-assistant #109", "todo-list-assistant #106", "todo-list-assistant #105",
        "todo-list-assistant #104", "todo-list-assistant #103"
    ]

    static func canned(for userText: String) -> String {
        let lower = userText.lowercased()
        if lower.contains("terminal") {
            return "在过去 30 分钟里你在 Terminal 中主要在跑 `claude --dangerously-skip-permissions`，以及一些 `cargo check / swift build` 的编译命令。没有看到任何 panic 或编译错误。"
        }
        if lower.contains("summar") || lower.contains("总结") || lower.contains("做什么") {
            return "今天你主要在 My-Orphies 项目上工作，集中在 transcription/whisper 的修复和一个 Swift demo 项目的搭建。共编辑 17 个文件，提交 2 次。"
        }
        if lower.contains("time") || lower.contains("spend") || lower.contains("时间") {
            return "今天到现在为止你的活跃时间约 6h 12m：编辑器 (3h 40m) · Terminal (1h 50m) · 浏览器 (38m)。"
        }
        if lower.contains("app") || lower.contains("which") {
            return "今天使用最多的 App 是 Cursor (2h 14m)、Terminal (1h 50m)、Chrome (38m) 和 Obsidian (22m)。"
        }
        return "（demo 模式：未连接真实模型）我会根据你的屏幕活动来回答。当你在 Connections 里接入 ChatGPT / Claude 后，这里会变成真实回答。"
    }
}

// MARK: - Stable per-app color

enum AppColor {
    static func color(for appName: String) -> Color {
        if appName.isEmpty { return Color(white: 0.35) }
        var hash: UInt64 = 5381
        for ch in appName.unicodeScalars { hash = (hash &* 33) &+ UInt64(ch.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.62, brightness: 0.82)
    }
}

// MARK: - App icon loader (NSWorkspace bundle lookup)

import AppKit

enum AppIconLoader {
    /// Tries to load the real macOS app icon for a given bundle id.
    /// Returns nil if the app isn't installed — caller falls back to letter glyph.
    nonisolated static func icon(forBundleId id: String?) -> NSImage? {
        guard let id else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Resolve an app icon given just the localized app name from a screenpipe frame.
    /// Strategy:
    ///   1. Check currently-running apps (NSRunningApplication.localizedName)
    ///   2. Probe /Applications and ~/Applications for "<name>.app"
    /// Returns nil if no match — caller falls back to a colored letter glyph.
    nonisolated static func icon(forAppName name: String) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1. running apps (fastest, no disk I/O)
        for app in NSWorkspace.shared.runningApplications {
            if let local = app.localizedName, local.caseInsensitiveCompare(trimmed) == .orderedSame {
                return app.icon
            }
        }
        // 2. /Applications, ~/Applications, /System/Applications
        let dirs = [
            "/Applications", "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("\(trimmed).app")
            if FileManager.default.fileExists(atPath: candidate) {
                return NSWorkspace.shared.icon(forFile: candidate)
            }
        }
        return nil
    }
}

/// Simple actor-safe LRU cache for resolved app-name → icon lookups.
/// Avoids re-probing /Applications for every timeline bar render.
@MainActor
final class AppNameIconCache {
    static let shared = AppNameIconCache()
    private var hits: [String: NSImage] = [:]
    private var misses: Set<String> = []

    func get(_ name: String) -> NSImage? { hits[name] }
    func isKnownMiss(_ name: String) -> Bool { misses.contains(name) }
    func store(_ image: NSImage?, for name: String) {
        if let image { hits[name] = image } else { misses.insert(name) }
    }
}
