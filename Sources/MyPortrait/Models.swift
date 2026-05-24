import Foundation
import SwiftUI
import Observation

/// Shared selection state for the Memories tab. Lives in ContentView so the
/// outer TimelineSidebar (left rail) and MemoriesView (detail) can both
/// read/write the same selection.
enum MemoryScope: Hashable, Identifiable {
    case events
    case input
    case portrait(category: String)

    var id: String {
        switch self {
        case .events:              return "__events__"
        case .input:               return "__input__"
        case .portrait(let c):     return "portrait:\(c)"
        }
    }
    var displayName: String {
        switch self {
        case .events:              return "Events"
        case .input:               return "Input"
        case .portrait(let c):     return c.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var systemImage: String {
        switch self {
        case .events:                   return "clock.arrow.circlepath"
        case .input:                    return "keyboard"
        case .portrait("personality"):  return "person.fill"
        case .portrait("social"):       return "person.3.fill"
        case .portrait("background"):   return "books.vertical.fill"
        case .portrait("experiences"):  return "map.fill"
        case .portrait("interests"):    return "sparkles"
        case .portrait("speech_style"): return "text.bubble.fill"
        case .portrait("skills"):       return "wrench.adjustable.fill"
        case .portrait("emotions"):     return "heart.fill"
        case .portrait:                 return "doc.text"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, cronJobs, timeline, memories, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Home"
        case .cronJobs: return "Cron Jobs"
        case .timeline: return "Timeline"
        case .memories: return "Memories"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "plus.message"
        case .cronJobs: return "puzzlepiece.extension"
        case .timeline: return "clock.arrow.circlepath"
        case .memories: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Chat

enum ChatRole: String, Codable { case user, assistant }

/// One renderable piece of an assistant message. Messages are a sequence of
/// these so text and tool-call cards can be interleaved in the order Pi
/// emitted them.
enum ContentPart: Identifiable, Hashable, Codable {
    case text(id: UUID, value: String)
    case tool(ToolBlock)
    case thinking(ThinkingBlock)
    case error(ErrorBlock)
    case editDraft(EditDraftBlock)

    var id: UUID {
        switch self {
        case .text(let id, _):   return id
        case .tool(let b):       return b.id
        case .thinking(let b):   return b.id
        case .error(let b):      return b.id
        case .editDraft(let b):  return b.id
        }
    }

    // Custom Codable so the JSON layout is stable.
    private enum CodingKeys: String, CodingKey { case kind, id, value, block }
    private enum Kind: String, Codable { case text, tool, thinking, error, editDraft = "edit_draft" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(id: try c.decode(UUID.self, forKey: .id),
                         value: try c.decode(String.self, forKey: .value))
        case .tool:
            self = .tool(try c.decode(ToolBlock.self, forKey: .block))
        case .thinking:
            self = .thinking(try c.decode(ThinkingBlock.self, forKey: .block))
        case .error:
            self = .error(try c.decode(ErrorBlock.self, forKey: .block))
        case .editDraft:
            self = .editDraft(try c.decode(EditDraftBlock.self, forKey: .block))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let id, let v):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(v,  forKey: .value)
        case .tool(let b):
            try c.encode(Kind.tool, forKey: .kind)
            try c.encode(b, forKey: .block)
        case .thinking(let b):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(b, forKey: .block)
        case .error(let b):
            try c.encode(Kind.error, forKey: .kind)
            try c.encode(b, forKey: .block)
        case .editDraft(let b):
            try c.encode(Kind.editDraft, forKey: .kind)
            try c.encode(b, forKey: .block)
        }
    }
}

/// AI 编辑 draft 卡片。AI 调 `--ai-draft-write-body` 落 draft 后,
/// ChatController 拦 toolEnd 自动注入这块到 assistant 消息流。UI 渲染
/// 前后对比 + Approve/Reject 按钮。状态在用户拍板后翻成 approved/
/// rejected,UI 收起按钮换显示「已批准」/「已拒绝」。
struct EditDraftBlock: Identifiable, Hashable, Codable {
    let id: UUID
    let originalRelPath: String       // events/2026-05-16/foo.md 之类
    let request: String
    var summary: String?
    var beforeBody: String
    var afterBody: String
    var state: State

    enum State: String, Codable, Hashable {
        case pending, approved, rejected, failed
    }
    var errorMessage: String?         // state=.failed 时填
}

/// Streamed chain-of-thought block (gpt-5, o1, claude reasoning models).
/// Renders as a collapsible "Thinking" card under the assistant bubble.
struct ThinkingBlock: Identifiable, Hashable, Codable {
    let id: UUID
    var text: String
    var isRunning: Bool
    /// How long the thinking phase took, set on `thinking_end`.
    var durationMs: Int?
}

/// LLM-level error surfaced through the chat — quota, rate limit, etc. Rendered
/// as a card instead of plain text so the user can see the category at a glance.
struct ErrorBlock: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: Kind
    var message: String       // raw error message from Pi (kept for "show details")
    /// Optional ISO timestamp the limit resets at (parsed from message).
    var resetsAt: String?

    enum Kind: String, Codable, Hashable {
        case rateLimit          // too many requests right now
        case dailyLimit         // hit daily ChatGPT quota
        case creditsExhausted   // BYOK / paid plan out of credits
        case modelNotAllowed    // selected model not available on this plan
        case authExpired        // token revoked / expired
        case network            // connectivity / 5xx
        case other
    }

    static func classify(_ message: String) -> ErrorBlock {
        let m = message.lowercased()
        var kind: Kind = .other
        if m.contains("credits_exhausted") || m.contains("insufficient_quota") {
            kind = .creditsExhausted
        } else if m.contains("daily") && (m.contains("limit") || m.contains("quota")) {
            kind = .dailyLimit
        } else if m.contains("rate") && m.contains("limit") || m.contains("too many requests") {
            kind = .rateLimit
        } else if m.contains("model_not_found") || m.contains("model_not_allowed") || m.contains("not have access") {
            kind = .modelNotAllowed
        } else if m.contains("invalid_grant") || m.contains("unauthorized") || m.contains("accountid") {
            kind = .authExpired
        } else if m.contains("network") || m.contains("timeout") || m.contains("econnrefused") || m.contains("503") || m.contains("502") {
            kind = .network
        }
        // Try to lift "resets_at": "..." or similar field out of the message.
        var resetsAt: String?
        if let r = message.range(of: #""resets_at"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let snippet = message[r]
            if let q = snippet.range(of: #""([^"]+)"$"#, options: .regularExpression) {
                let inner = snippet[q].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                resetsAt = inner
            }
        }
        return ErrorBlock(id: UUID(), kind: kind, message: message, resetsAt: resetsAt)
    }
}

/// One tool invocation. Streamed in two phases: created on
/// `tool_execution_start`, output / status filled on `tool_execution_end`.
struct ToolBlock: Identifiable, Hashable, Codable {
    let id: UUID
    let toolCallId: String
    var name: String
    var command: String        // human-readable summary of args (e.g. the bash command)
    var output: String
    var isRunning: Bool
    var isError: Bool
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let role: ChatRole
    /// User messages keep this as their single text body. Assistant messages
    /// accumulate `parts` instead; `text` here remains a convenience for the
    /// user-bubble path and tests.
    var text: String
    var parts: [ContentPart]
    let time: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, parts: [ContentPart] = [], time: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.parts = parts
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
    /// 可选 SF Symbol —— 优先级:assetName > iconSymbol > letter。
    let iconSymbol: String?
    /// 可选 Assets.xcassets 里的 imageset 名(用真品牌 SVG)。
    /// 优先级最高 —— 有就用,没有再 iconSymbol,再 letter。
    let assetName: String?
    /// Brand accent color, used for the letter glyph background and accents.
    let accent: Color
    let signInMethod: SignInMethod
    let category: Category

    init(id: String, name: String, bundleId: String?, letter: String,
         iconSymbol: String? = nil, assetName: String? = nil,
         accent: Color, signInMethod: SignInMethod, category: Category) {
        self.id = id; self.name = name; self.bundleId = bundleId
        self.letter = letter; self.iconSymbol = iconSymbol; self.assetName = assetName
        self.accent = accent; self.signInMethod = signInMethod; self.category = category
    }

    enum SignInMethod: String { case oauth, apiKey, localApp, systemAccess, smtp }
    enum Category: String { case ai = "AI Providers", productivity = "Productivity", media = "Media & Calendar", local = "Local Models" }
}

enum IntegrationRegistry {
    /// Brand colors — picked to match each service's actual brand palette
    /// (not Apple system colors, not SF Symbol tinting).
    static let all: [Integration] = [
        // AI providers
        .init(id: "chatgpt",            name: "ChatGPT",         bundleId: "com.openai.chat",                       letter: "G",  accent: Color(red: 0.06, green: 0.65, blue: 0.51),  signInMethod: .oauth,        category: .ai),
        .init(id: "claude-code",        name: "Claude Code",     bundleId: nil,                                     letter: ">",  accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .localApp,     category: .ai),
        // Anthropic API 复用 Claude Desktop 的 bundleId,NSWorkspace 装了 Claude
        // app 就显示真图标(原"Claude Desktop"tile 拔了)。
        .init(id: "anthropic-api",      name: "Anthropic API",   bundleId: "com.anthropic.claudefordesktop",        letter: "A",  accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .apiKey,       category: .ai),
        .init(id: "gemini",             name: "Gemini",          bundleId: nil,                                     letter: "G",  accent: Color(red: 0.26, green: 0.52, blue: 0.96),  signInMethod: .apiKey,       category: .ai),
        // Perplexity:用 bundle 的 perplexity.svg 资源(从 screenpipe 引来的
        // 原版品牌 logo),iconSymbol asterisk 是再下一层兜底。
        .init(id: "perplexity",         name: "Perplexity",      bundleId: "ai.perplexity.mac",                     letter: "P",  iconSymbol: "asterisk", assetName: "Perplexity", accent: Color(red: 0.12, green: 0.72, blue: 0.80),  signInMethod: .apiKey,       category: .ai),

        // Local model runners
        .init(id: "ollama",             name: "Ollama",          bundleId: "com.electron.ollama",                   letter: "🦙", accent: Color(white: 0.92),                         signInMethod: .localApp,     category: .local),

        // Productivity
        .init(id: "obsidian",           name: "Obsidian",        bundleId: "md.obsidian",                           letter: "○",  accent: Color(red: 0.49, green: 0.34, blue: 0.78),  signInMethod: .localApp,     category: .productivity),
        .init(id: "notion",             name: "Notion",          bundleId: "notion.id",                             letter: "N",  accent: Color(white: 0.95),                         signInMethod: .oauth,        category: .productivity),
        .init(id: "email-smtp",         name: "Email (SMTP)",    bundleId: nil,                                     letter: "@",  iconSymbol: "envelope.fill", accent: Color(red: 0.20, green: 0.55, blue: 0.86),  signInMethod: .smtp,         category: .productivity),

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
    var connectedIds: Set<String> = [] {
        didSet { if !suppressSave { saveConnections() } }
    }
    var activeAIId: String? = nil {
        didSet { if !suppressSave { saveConnections() } }
    }
    /// Last model picked per provider. Persists across launches via
    /// `loadModelChoices()` / `saveModelChoices()`. Keyed by integration id
    /// (e.g. "anthropic-api"), value is the model id (e.g. "claude-haiku-4-5").
    var modelByIntegration: [String: String] = [:]

    private let modelDefaultsKey      = "MyPortrait.modelByIntegration.v1"
    private let connectedDefaultsKey  = "MyPortrait.connectedIds.v1"
    private let activeAIDefaultsKey   = "MyPortrait.activeAIId.v1"

    /// Guards the didSet writers while we're populating fields from disk so
    /// `loadConnections()` doesn't re-save what it just read.
    private var suppressSave = false

    init() {
        suppressSave = true
        loadConnections()
        loadModelChoices()
        reconcileWithSecretStore()
        suppressSave = false
    }

    /// Cross-check the persisted connection set against the actual on-disk
    /// credentials. If the user revoked a token / deleted an API key
    /// elsewhere, drop the now-stale connection so the picker doesn't show
    /// a connected tile that can't actually authenticate.
    private func reconcileWithSecretStore() {
        var changed = false

        // ChatGPT OAuth: tile only stays connected while a token still exists.
        if connectedIds.contains("chatgpt"), !ChatGPTOAuth.isLoggedIn() {
            connectedIds.remove("chatgpt")
            changed = true
        }
        // BYOK providers: must still have a key in SecretStore.
        for id in Array(connectedIds) {
            guard let p = Provider.from(integrationId: id),
                  let key = p.secretKey else { continue }      // .chatgpt + .ollama have no secretKey
            if SecretStore.shared.get(key) == nil {
                connectedIds.remove(id)
                changed = true
            }
        }

        // Inverse: if a credential exists but the cached connection is gone
        // (e.g. user added a key in a prior session before this code shipped),
        // light the tile back up.
        if !connectedIds.contains("chatgpt"), ChatGPTOAuth.isLoggedIn() {
            connectedIds.insert("chatgpt")
            changed = true
        }
        for p in Provider.allCases {
            guard let key = p.secretKey else { continue }
            let intId = Self.integrationId(for: p)
            if let intId, SecretStore.shared.get(key) != nil,
               !connectedIds.contains(intId) {
                connectedIds.insert(intId)
                changed = true
            }
        }

        // If activeAIId points at a connection we just dropped, fall back to
        // whatever is still connected.
        if let active = activeAIId, !connectedIds.contains(active) {
            activeAIId = connectedIds.first(where: { Provider.from(integrationId: $0) != nil })
            changed = true
        }
        if activeAIId == nil, let firstAI = connectedIds.first(where: { Provider.from(integrationId: $0) != nil }) {
            activeAIId = firstAI
            changed = true
        }

        if changed { saveConnections() }
    }

    /// Inverse of `Provider.from(integrationId:)`. Used by the reverse-sync
    /// step above to find the tile id for a provider with a credential.
    private static func integrationId(for p: Provider) -> String? {
        switch p {
        case .chatgpt:       return "chatgpt"
        case .anthropic:     return "anthropic-api"
        case .gemini:        return "gemini"
        case .ollama:        return "ollama"
        case .perplexity:    return "perplexity"
        case .openaiBYOK:    return nil    // no dedicated tile yet
        }
    }

    /// The currently selected model for `integrationId`, falling back to the
    /// provider's first available model.
    func currentModel(forIntegrationId id: String) -> String {
        if let m = modelByIntegration[id] { return m }
        return Provider.from(integrationId: id)?.defaultModel ?? ""
    }

    func setModel(_ model: String, forIntegrationId id: String) {
        modelByIntegration[id] = model
        saveModelChoices()
    }

    private func loadModelChoices() {
        if let stored = UserDefaults.standard.dictionary(forKey: modelDefaultsKey) as? [String: String] {
            modelByIntegration = stored
        }
    }
    private func saveModelChoices() {
        UserDefaults.standard.set(modelByIntegration, forKey: modelDefaultsKey)
    }

    // MARK: - Connection persistence

    private func loadConnections() {
        if let arr = UserDefaults.standard.stringArray(forKey: connectedDefaultsKey) {
            connectedIds = Set(arr)
        }
        if let active = UserDefaults.standard.string(forKey: activeAIDefaultsKey) {
            activeAIId = active
        }
    }
    private func saveConnections() {
        UserDefaults.standard.set(Array(connectedIds), forKey: connectedDefaultsKey)
        UserDefaults.standard.set(activeAIId, forKey: activeAIDefaultsKey)
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
        "帮我看看我最近一个小时和终…", "todo-list-assistant #218", "search timeline for what …",
        "go to x.com", "todo-list-assistant #195", "search timeline for what …",
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

    /// Resolve an app icon given just the localized app name from a timeline frame.
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
