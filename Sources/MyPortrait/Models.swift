import Foundation
import SwiftUI
import Observation

/// Shared selection state for the Memories tab. Lives in ContentView so the
/// outer TimelineSidebar (left rail) and DataView (detail) can both
/// read/write the same selection.
enum DataScope: Hashable, Identifiable {
    case personalInfo
    case events
    case input
    case portrait(category: String)
    /// Text 侧栏底部的设置入口（排序方式等），不是记忆内容 scope。
    case textSettings
    /// Neural Graph 侧栏 GRAPH 下的设置入口(07-11 update):主内容区显示图谱设置
    /// (主球照片等),不是图谱形态。
    case neuralGraphSettings

    var id: String {
        switch self {
        case .personalInfo:        return "__personal_info__"
        case .events:              return "__events__"
        case .input:               return "__input__"
        case .portrait(let c):     return "portrait:\(c)"
        case .textSettings:        return "__text_settings__"
        case .neuralGraphSettings: return "__neural_graph_settings__"
        }
    }
    /// `id` 的反函数 —— 存进 config 再读回来(Memories 记住上次停在哪)。
    /// 认不出就 nil(比如 portrait 分类被删了),调用方回落默认 scope。
    init?(id: String) {
        switch id {
        case "__personal_info__":         self = .personalInfo
        case "__events__":                self = .events
        case "__input__":                 self = .input
        case "__text_settings__":         self = .textSettings
        case "__neural_graph_settings__": self = .neuralGraphSettings
        default:
            let prefix = "portrait:"
            guard id.hasPrefix(prefix) else { return nil }
            let category = String(id.dropFirst(prefix.count))
            guard !category.isEmpty else { return nil }
            self = .portrait(category: category)
        }
    }

    var displayName: String {
        switch self {
        case .personalInfo:        return "Personal Info"
        case .events:              return "Events"
        case .input:               return "Input"
        case .portrait(let c):     return c.replacingOccurrences(of: "_", with: " ").capitalized
        case .textSettings:        return "Settings"
        case .neuralGraphSettings: return "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .personalInfo:             return "person.text.rectangle.fill"
        case .events:                   return "clock.arrow.circlepath"
        case .input:                    return "keyboard"
        case .textSettings:             return "slider.horizontal.3"
        case .neuralGraphSettings:      return "slider.horizontal.3"
        case .portrait("personality"):  return "person.fill"
        case .portrait("social"):       return "person.3.fill"
        case .portrait("background"):   return "books.vertical.fill"
        case .portrait("experiences"):  return "map.fill"
        case .portrait("interests"):    return "sparkles"
        case .portrait("writing_style"): return "text.bubble.fill"
        case .portrait("skills"):       return "wrench.adjustable.fill"
        case .portrait("emotions"):     return "heart.fill"
        case .portrait:                 return "doc.text"
        }
    }
}

/// Memories 区的查看模式:text = 列表视图,neuralGraph = Neural Graph 图谱视图。
/// 状态与 dataScope 一样住在 ContentView,侧栏(切换钮)与主面板共享。
enum DataViewMode: String, Hashable {
    case text, neuralGraph

    /// personalInfo 没有 Neural Graph 形态。
    /// input 的 Neural Graph 形态 = 打字活动面积图(InputActivityChartView)。
    static func supportsNeuralGraph(_ scope: DataScope) -> Bool {
        switch scope {
        case .events, .portrait, .input:  return true
        // 两种 settings scope 由 ContentView 显式路由到各自设置视图。
        case .personalInfo, .textSettings, .neuralGraphSettings: return false
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case timeline, data, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timeline: return "Timeline"
        case .data: return "Data"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .data: return "sparkles"
        case .settings: return "gearshape"
        }
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
    /// asset 本身已是完整 app-icon(自带圆角 + 背景)时设 true,
    /// 渲染走 realIcon 同款全填模式(不加白底、不再 padding)。
    let assetFullBleed: Bool
    /// Brand accent color, used for the letter glyph background and accents.
    let accent: Color
    let signInMethod: SignInMethod
    let category: Category

    init(id: String, name: String, bundleId: String?, letter: String,
         iconSymbol: String? = nil, assetName: String? = nil,
         assetFullBleed: Bool = false,
         accent: Color, signInMethod: SignInMethod, category: Category) {
        self.id = id; self.name = name; self.bundleId = bundleId
        self.letter = letter; self.iconSymbol = iconSymbol; self.assetName = assetName
        self.assetFullBleed = assetFullBleed
        self.accent = accent; self.signInMethod = signInMethod; self.category = category
    }

    enum SignInMethod: String { case oauth, apiKey, localApp }
    enum Category: String { case ai = "AI Providers", local = "Local Models", earlyAccess = "Early Access" }
}

enum IntegrationRegistry {
    /// Brand colors — picked to match each service's actual brand palette
    /// (not Apple system colors, not SF Symbol tinting).
    static let all: [Integration] = [
        // AI providers
        .init(id: "chatgpt",            name: "Codex",           bundleId: "com.openai.codex",                      letter: "G",  assetName: "Codex", assetFullBleed: true, accent: Color(red: 0.06, green: 0.65, blue: 0.51),  signInMethod: .oauth,        category: .ai),
        // 走 OpenAI 公共 API,不复用 Codex OAuth(那一档是 ChatGPT Plus 订阅
        // 走 Codex client_id 拿额度)。这一档纯 BYOK,贴 sk-... API key。
        .init(id: "openai-byok",        name: "OpenAI API",      bundleId: "com.openai.chat",                       letter: "O",  assetName: "OpenAI", assetFullBleed: true, accent: Color(white: 0.10),                         signInMethod: .apiKey,       category: .ai),
        .init(id: "claude-code",        name: "Claude Code CLI", bundleId: nil,                                     letter: ">",  assetName: "ClaudeCode", assetFullBleed: true, accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .localApp,     category: .ai),
        // Anthropic API 用 bundled asset "Anthropic"(自带橙底圆角 A| logo),不用
        // bundleId 抓系统图标 —— 系统图标随 app 版本变,且语义上不该跟 Claude Desktop 绑定。
        .init(id: "anthropic-api",      name: "Anthropic API",   bundleId: nil,                                     letter: "A",  assetName: "Anthropic", assetFullBleed: true, accent: Color(red: 0.85, green: 0.46, blue: 0.21),  signInMethod: .apiKey,       category: .ai),
        .init(id: "gemini",             name: "Gemini",          bundleId: nil,                                     letter: "G",  assetName: "Gemini", accent: Color(red: 0.26, green: 0.52, blue: 0.96),  signInMethod: .apiKey,       category: .ai),
        // Perplexity:用 bundle 的 perplexity.svg 资源(从 screenpipe 引来的
        // 原版品牌 logo),iconSymbol asterisk 是再下一层兜底。
        .init(id: "perplexity",         name: "Perplexity",      bundleId: "ai.perplexity.mac",                     letter: "P",  iconSymbol: "asterisk", assetName: "Perplexity", accent: Color(red: 0.12, green: 0.72, blue: 0.80),  signInMethod: .apiKey,       category: .ai),
        .init(id: "deepseek",           name: "DeepSeek",        bundleId: nil,                                     letter: "D",  assetName: "DeepSeek", accent: Color(red: 0.27, green: 0.49, blue: 0.94),  signInMethod: .apiKey,       category: .ai),

        // Local model runners
        // fullBleed=false(07-22 update):asset 是透明底白身羊驼,fullBleed 直接贴卡片
        // → light 主题白羊驼贴白卡隐身。false 走"固定白底圆角块 + logo"分支,
        // 深色描边羊驼在两种主题下都一样(固定图标,不随 scheme 变)。
        .init(id: "ollama",             name: "Ollama",          bundleId: "com.electron.ollama",                   letter: "🦙", assetName: "Ollama", assetFullBleed: false, accent: Color(white: 0.92),                         signInMethod: .localApp,     category: .local),
        // 自己跑的 OpenAI 兼容服务:填地址 + 模型名(见 `Provider.localModel`)。
        .init(id: "local-model",        name: "Local Model",     bundleId: nil,                                     letter: "L",  iconSymbol: "cpu", accent: Color(red: 0.36, green: 0.42, blue: 0.86),  signInMethod: .localApp,     category: .local),
        // 夜间分析搬到 Premium(上传到收件服务排队处理),不是 chat provider。
        .init(id: "premium",          name: "My Portrait Premium", bundleId: nil,                                     letter: "P",  assetName: "PremiumAvatar", assetFullBleed: true, accent: Color(red: 0.46, green: 0.73, blue: 0.0),  signInMethod: .localApp,     category: .earlyAccess),

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
    static let connectedDefaultsKey   = "MyPortrait.connectedIds.v1"
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

        // Inverse: if a ChatGPT token exists but the cached connection is gone,
        // light the tile back up. API keys stay in SecretStore after Disconnect
        // (the box shows them masked for the next Connect), so a stored key alone
        // doesn't mean connected.
        if !connectedIds.contains("chatgpt"), ChatGPTOAuth.isLoggedIn() {
            connectedIds.insert("chatgpt")
            changed = true
        }

        // 已下线的卡片(不在 IntegrationRegistry 里了)留下的连接记录一并清掉。
        let known = Set(IntegrationRegistry.all.map(\.id))
        if !connectedIds.isSubset(of: known) {
            connectedIds.formIntersection(known)
            changed = true
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

    /// The currently selected model for `integrationId`, falling back to the
    /// provider's first available model.
    func currentModel(forIntegrationId id: String) -> String {
        if let m = modelByIntegration[id] { return m }
        return Provider.from(integrationId: id)?.defaultModel ?? ""
    }

    /// 不绑某条 conv 时用的 provider + model:AI preset 标了 default 优先,
    /// 否则全局 picker 选的;都没有 → ChatGPT。chat 和 cron 共用。
    @MainActor
    func defaultProvider() -> (Provider, String, String?) {
        if let preset = ConfigStore.shared.aiModels.presets.first(where: { $0.isDefault }),
           let p = Provider(rawValue: preset.provider) {
            return (p, preset.model, preset.apiKeyRef.isEmpty ? nil : preset.apiKeyRef)
        }
        guard let id = activeAIId,
              let p = Provider.from(integrationId: id)
        else { return (.chatgpt, Provider.chatgpt.defaultModel, nil) }
        return (p, currentModel(forIntegrationId: id), nil)
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
        if let arr = UserDefaults.standard.stringArray(forKey: Self.connectedDefaultsKey) {
            connectedIds = Set(arr)
        }
        if let active = UserDefaults.standard.string(forKey: activeAIDefaultsKey) {
            activeAIId = active
        }
    }
    private func saveConnections() {
        UserDefaults.standard.set(Array(connectedIds), forKey: Self.connectedDefaultsKey)
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
    /// 关窗时清(重开按需再探)。
    func removeAll() { hits.removeAll(); misses.removeAll() }
}
