import Foundation

/// Persistent settings file mapped 1:1 to `~/.myportrait/config.toml`.
///
/// Design rules (all four enforced):
///   1. **schemaVersion** at the top so future shapes can be migrated in place.
///   2. **Secrets stay out**. OAuth tokens / API keys live in SecretStore;
///      this file only stores `*_ref = "name"` pointers.
///   3. **All fields have defaults**. The file only needs to carry overrides;
///      missing keys decode to defaults so old configs survive new builds.
///   4. **Fail-soft**. A malformed TOML never crashes — ConfigStore loads
///      defaults and surfaces an error message on the way through.
///
/// Each struct declares snake_case `CodingKeys` explicitly (TOMLKit doesn't
/// support `keyEncodingStrategy`). Missing keys are tolerated via custom
/// `init(from:)` that falls back to default-init values.
struct MyPortraitConfig: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int   = currentSchemaVersion
    var display:       DisplayConfig       = .init()
    var general:       GeneralConfig       = .init()
    var aiModels:      AIModelsConfig      = .init()
    var recording:     RecordingConfig     = .init()
    var notifications: NotificationsConfig = .init()
    var memory:        MemoryConfig        = .init()
    var usage:         UsageConfig         = .init()
    var privacy:       PrivacyConfig       = .init()
    var storage:       StorageConfig       = .init()
    var chat:          ChatConfig          = .init()

    init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case display, general, aiModels = "ai_models", recording, notifications
        case memory, usage, privacy, storage, chat
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.dflt(Int.self, .schemaVersion, schemaVersion)
        display       = c.dflt(DisplayConfig.self, .display, display)
        general       = c.dflt(GeneralConfig.self, .general, general)
        aiModels      = c.dflt(AIModelsConfig.self, .aiModels, aiModels)
        recording     = c.dflt(RecordingConfig.self, .recording, recording)
        notifications = c.dflt(NotificationsConfig.self, .notifications, notifications)
        memory        = c.dflt(MemoryConfig.self, .memory, memory)
        usage         = c.dflt(UsageConfig.self, .usage, usage)
        privacy       = c.dflt(PrivacyConfig.self, .privacy, privacy)
        storage       = c.dflt(StorageConfig.self, .storage, storage)
        chat          = c.dflt(ChatConfig.self, .chat, chat)
    }
}

// MARK: - Memory

struct MemoryConfig: Codable, Equatable {
    // Capture-layer indexer (existing).
    var indexerEnabled:        Bool   = true
    var indexIntervalMinutes:  Int    = 15

    // MemoryBudget — sleep-consolidation weekly pass.
    var weeklyBudget:          Double = 50
    var peakProtection:        Double = 4.5
    var maxRebalances:         Int    = 5
    var windowDays:            Int    = 7

    // WeightCalculator — power-law decay + log access boost.
    var alpha:                 Double = 0.3
    var minWeight:             Double = 0

    // Archiver — programmatic, no LLM.
    var archiveMaxImpact:      Double = 2
    var archiveMaxWeight:      Double = 0.05
    var archiveMinDaysIdle:    Int    = 90

    init() {}
    enum CodingKeys: String, CodingKey {
        case indexerEnabled       = "indexer_enabled"
        case indexIntervalMinutes = "index_interval_minutes"
        case weeklyBudget         = "weekly_budget"
        case peakProtection       = "peak_protection"
        case maxRebalances        = "max_rebalances"
        case windowDays           = "window_days"
        case alpha
        case minWeight            = "min_weight"
        case archiveMaxImpact     = "archive_max_impact"
        case archiveMaxWeight     = "archive_max_weight"
        case archiveMinDaysIdle   = "archive_min_days_idle"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indexerEnabled       = c.dflt(Bool.self,   .indexerEnabled,       indexerEnabled)
        indexIntervalMinutes = c.dflt(Int.self,    .indexIntervalMinutes, indexIntervalMinutes)
        weeklyBudget         = c.dflt(Double.self, .weeklyBudget,         weeklyBudget)
        peakProtection       = c.dflt(Double.self, .peakProtection,       peakProtection)
        maxRebalances        = c.dflt(Int.self,    .maxRebalances,        maxRebalances)
        windowDays           = c.dflt(Int.self,    .windowDays,           windowDays)
        alpha                = c.dflt(Double.self, .alpha,                alpha)
        minWeight            = c.dflt(Double.self, .minWeight,            minWeight)
        archiveMaxImpact     = c.dflt(Double.self, .archiveMaxImpact,     archiveMaxImpact)
        archiveMaxWeight     = c.dflt(Double.self, .archiveMaxWeight,     archiveMaxWeight)
        archiveMinDaysIdle   = c.dflt(Int.self,    .archiveMinDaysIdle,   archiveMinDaysIdle)
    }
}

// MARK: - Display

struct DisplayConfig: Codable, Equatable {
    var theme:                   String = "system"
    var chatAlwaysOnTop:         Bool   = false
    var translucentSidebar:      Bool   = true
    var hideModelReasoning:      Bool   = false
    var showOverlayInRecording:  Bool   = true
    var appName:                 String = "My Portrait"
    var customDockIcon:          String = ""
    var customTrayIcon:          String = ""
    var showInMenuBar:           Bool   = true

    init() {}
    enum CodingKeys: String, CodingKey {
        case theme
        case chatAlwaysOnTop          = "chat_always_on_top"
        case translucentSidebar       = "translucent_sidebar"
        case hideModelReasoning       = "hide_model_reasoning"
        case showOverlayInRecording   = "show_overlay_in_recording"
        case appName                  = "app_name"
        case customDockIcon           = "custom_dock_icon"
        case customTrayIcon           = "custom_tray_icon"
        case showInMenuBar            = "show_in_menu_bar"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme                   = c.dflt(String.self, .theme, theme)
        chatAlwaysOnTop         = c.dflt(Bool.self,   .chatAlwaysOnTop, chatAlwaysOnTop)
        translucentSidebar      = c.dflt(Bool.self,   .translucentSidebar, translucentSidebar)
        hideModelReasoning      = c.dflt(Bool.self,   .hideModelReasoning, hideModelReasoning)
        showOverlayInRecording  = c.dflt(Bool.self,   .showOverlayInRecording, showOverlayInRecording)
        appName                 = c.dflt(String.self, .appName, appName)
        customDockIcon          = c.dflt(String.self, .customDockIcon, customDockIcon)
        customTrayIcon          = c.dflt(String.self, .customTrayIcon, customTrayIcon)
        showInMenuBar           = c.dflt(Bool.self,   .showInMenuBar, showInMenuBar)
    }
}

// MARK: - General

struct GeneralConfig: Codable, Equatable {
    var launchAtLogin:       Bool = false
    var autoDownloadUpdates: Bool = true
    var updateCheckMinutes:  Int  = 60
    init() {}
    enum CodingKeys: String, CodingKey {
        case launchAtLogin       = "launch_at_login"
        case autoDownloadUpdates = "auto_download_updates"
        case updateCheckMinutes  = "update_check_minutes"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin       = c.dflt(Bool.self, .launchAtLogin, launchAtLogin)
        autoDownloadUpdates = c.dflt(Bool.self, .autoDownloadUpdates, autoDownloadUpdates)
        updateCheckMinutes  = c.dflt(Int.self,  .updateCheckMinutes, updateCheckMinutes)
    }
}

// MARK: - AI models

struct AIModelsConfig: Codable, Equatable {
    var presets: [AIPresetSpec] = []
    init() {}
    enum CodingKeys: String, CodingKey { case presets }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = c.dflt([AIPresetSpec].self, .presets, presets)
    }
}

struct AIPresetSpec: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "New preset"
    var provider: String = "chatgpt"
    var model: String = "gpt-5.4"
    var apiKeyRef: String = ""   // SecretStore key, never the raw value
    var baseUrl: String = ""
    var maxTokens: Int = 4096
    var maxContext: Int = 16384
    var systemPrompt: String = ""
    var isDefault: Bool = false
    init() {}
    init(id: UUID, name: String, provider: String, model: String,
         apiKeyRef: String, baseUrl: String,
         maxTokens: Int, maxContext: Int,
         systemPrompt: String, isDefault: Bool) {
        self.id = id; self.name = name; self.provider = provider; self.model = model
        self.apiKeyRef = apiKeyRef; self.baseUrl = baseUrl
        self.maxTokens = maxTokens; self.maxContext = maxContext
        self.systemPrompt = systemPrompt; self.isDefault = isDefault
    }
    enum CodingKeys: String, CodingKey {
        case id, name, provider, model
        case apiKeyRef     = "api_key_ref"
        case baseUrl       = "base_url"
        case maxTokens     = "max_tokens"
        case maxContext    = "max_context"
        case systemPrompt  = "system_prompt"
        case isDefault     = "is_default"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = c.dflt(UUID.self,   .id, id)
        name          = c.dflt(String.self, .name, name)
        provider      = c.dflt(String.self, .provider, provider)
        model         = c.dflt(String.self, .model, model)
        apiKeyRef     = c.dflt(String.self, .apiKeyRef, apiKeyRef)
        baseUrl       = c.dflt(String.self, .baseUrl, baseUrl)
        maxTokens     = c.dflt(Int.self,    .maxTokens, maxTokens)
        maxContext    = c.dflt(Int.self,    .maxContext, maxContext)
        systemPrompt  = c.dflt(String.self, .systemPrompt, systemPrompt)
        isDefault     = c.dflt(Bool.self,   .isDefault, isDefault)
    }
}

// MARK: - Recording

struct RecordingConfig: Codable, Equatable {
    var audio:  AudioConfig  = .init()
    var screen: ScreenConfig = .init()
    var system: SystemConfig = .init()
    init() {}
    enum CodingKeys: String, CodingKey { case audio, screen, system }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio  = c.dflt(AudioConfig.self,  .audio, audio)
        screen = c.dflt(ScreenConfig.self, .screen, screen)
        system = c.dflt(SystemConfig.self, .system, system)
    }
}

struct AudioConfig: Codable, Equatable {
    var enabled:                 Bool     = true
    var userName:                String   = ""
    var engine:                  String   = "whisper"
    var deepgramApiKeyRef:       String   = ""
    var languages:               [String] = []
    var microphonesSelected:     [String] = []
    var captureSystemAudio:      Bool     = true
    var useCoreAudioCapture:     Bool     = true
    var speakerIdEnabled:        Bool     = true
    var filterMusic:             Bool     = false
    var batchTranscription:      Bool     = true
    var autoSelectAudioDevices:  Bool     = true
    var customVocabulary:        [String] = []
    init() {}
    enum CodingKeys: String, CodingKey {
        case enabled
        case userName                = "user_name"
        case engine
        case deepgramApiKeyRef       = "deepgram_api_key_ref"
        case languages
        case microphonesSelected     = "microphones_selected"
        case captureSystemAudio      = "capture_system_audio"
        case useCoreAudioCapture     = "use_core_audio_capture"
        case speakerIdEnabled        = "speaker_id_enabled"
        case filterMusic             = "filter_music"
        case batchTranscription      = "batch_transcription"
        case autoSelectAudioDevices  = "auto_select_audio_devices"
        case customVocabulary        = "custom_vocabulary"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled                = c.dflt(Bool.self,     .enabled, enabled)
        userName               = c.dflt(String.self,   .userName, userName)
        engine                 = c.dflt(String.self,   .engine, engine)
        deepgramApiKeyRef      = c.dflt(String.self,   .deepgramApiKeyRef, deepgramApiKeyRef)
        languages              = c.dflt([String].self, .languages, languages)
        microphonesSelected    = c.dflt([String].self, .microphonesSelected, microphonesSelected)
        captureSystemAudio     = c.dflt(Bool.self,     .captureSystemAudio, captureSystemAudio)
        useCoreAudioCapture    = c.dflt(Bool.self,     .useCoreAudioCapture, useCoreAudioCapture)
        speakerIdEnabled       = c.dflt(Bool.self,     .speakerIdEnabled, speakerIdEnabled)
        filterMusic            = c.dflt(Bool.self,     .filterMusic, filterMusic)
        batchTranscription     = c.dflt(Bool.self,     .batchTranscription, batchTranscription)
        autoSelectAudioDevices = c.dflt(Bool.self,     .autoSelectAudioDevices, autoSelectAudioDevices)
        customVocabulary       = c.dflt([String].self, .customVocabulary, customVocabulary)
    }
}

struct ScreenConfig: Codable, Equatable {
    var enabled:         Bool   = true
    var ocrEngine:       String = "tesseract"
    var videoFps:        Int    = 1
    var quality:         String = "medium"
    var videoFormat:     String = "h264"
    var frameIntervalMs: Int    = 1000
    init() {}
    enum CodingKeys: String, CodingKey {
        case enabled
        case ocrEngine       = "ocr_engine"
        case videoFps        = "video_fps"
        case quality
        case videoFormat     = "video_format"
        case frameIntervalMs = "frame_interval_ms"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled         = c.dflt(Bool.self,   .enabled, enabled)
        ocrEngine       = c.dflt(String.self, .ocrEngine, ocrEngine)
        videoFps        = c.dflt(Int.self,    .videoFps, videoFps)
        quality         = c.dflt(String.self, .quality, quality)
        videoFormat     = c.dflt(String.self, .videoFormat, videoFormat)
        frameIntervalMs = c.dflt(Int.self,    .frameIntervalMs, frameIntervalMs)
    }
}

struct SystemConfig: Codable, Equatable {
    var chineseMirror: Bool   = false
    var powerMode:     String = "auto"
    init() {}
    enum CodingKeys: String, CodingKey {
        case chineseMirror = "chinese_mirror"
        case powerMode     = "power_mode"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chineseMirror = c.dflt(Bool.self,   .chineseMirror, chineseMirror)
        powerMode     = c.dflt(String.self, .powerMode, powerMode)
    }
}

// MARK: - Notifications

struct NotificationsConfig: Codable, Equatable {
    var appUpdates:             Bool     = true
    var pipeAlerts:             Bool     = true
    var captureStalls:          Bool     = false
    var mutedPipes:             [String] = []
    init() {}
    enum CodingKeys: String, CodingKey {
        case appUpdates             = "app_updates"
        case pipeAlerts             = "pipe_alerts"
        case captureStalls          = "capture_stalls"
        case mutedPipes             = "muted_pipes"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appUpdates             = c.dflt(Bool.self,     .appUpdates, appUpdates)
        pipeAlerts             = c.dflt(Bool.self,     .pipeAlerts, pipeAlerts)
        captureStalls          = c.dflt(Bool.self,     .captureStalls, captureStalls)
        mutedPipes             = c.dflt([String].self, .mutedPipes, mutedPipes)
    }
}

// MARK: - Usage

struct UsageConfig: Codable, Equatable {
    var range: String = "last7d"
    init() {}
    enum CodingKeys: String, CodingKey { case range }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = c.dflt(String.self, .range, range)
    }
}

// MARK: - Privacy

struct PrivacyConfig: Codable, Equatable {
    var ignoreIncognito:        Bool     = true
    var captureClipboard:       Bool     = false
    var recordAudioWhileLocked: Bool     = false
    var piiRemoval:             Bool     = true
    /// Default blacklist: password managers / sensitive tools. Matched by
    /// exact app name (case-insensitive) in IgnoreGate.
    var ignoredApps:            [String] = [
        "1Password", "Bitwarden", "KeePassXC", "Keychain Access", "Authy",
        "My Portrait",
    ]
    /// Reserved, not enforced yet. Schema / UI / TOML round-trip work, but
    /// IgnoreGate has no allowlist logic — setting this currently does nothing.
    var includedApps:           [String] = []
    var ignoredUrls:            [String] = []
    /// Window-title substrings (case-insensitive contains). A window whose
    /// title contains any of these is masked out of the capture.
    var ignoredWindowTitles:    [String] = []
    /// When true, windows matching ignoredApps / ignoredWindowTitles are
    /// excluded from the ScreenCaptureKit buffer (transparent in the frame).
    /// The frame itself is always captured.
    var maskIgnoredApps:        Bool     = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case ignoreIncognito         = "ignore_incognito"
        case captureClipboard        = "capture_clipboard"
        case recordAudioWhileLocked  = "record_audio_while_locked"
        case piiRemoval              = "pii_removal"
        case ignoredApps             = "ignored_apps"
        case includedApps            = "included_apps"
        case ignoredUrls             = "ignored_urls"
        case ignoredWindowTitles     = "ignored_window_titles"
        case maskIgnoredApps         = "mask_ignored_apps"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ignoreIncognito        = c.dflt(Bool.self,     .ignoreIncognito, ignoreIncognito)
        captureClipboard       = c.dflt(Bool.self,     .captureClipboard, captureClipboard)
        recordAudioWhileLocked = c.dflt(Bool.self,     .recordAudioWhileLocked, recordAudioWhileLocked)
        piiRemoval             = c.dflt(Bool.self,     .piiRemoval, piiRemoval)
        ignoredApps            = c.dflt([String].self, .ignoredApps, ignoredApps)
        includedApps           = c.dflt([String].self, .includedApps, includedApps)
        ignoredUrls            = c.dflt([String].self, .ignoredUrls, ignoredUrls)
        ignoredWindowTitles    = c.dflt([String].self, .ignoredWindowTitles, ignoredWindowTitles)
        maskIgnoredApps        = c.dflt(Bool.self,     .maskIgnoredApps, maskIgnoredApps)
    }
}

// MARK: - Storage

struct StorageConfig: Codable, Equatable {
    var dataDirectory:  String = ""
    var retentionDays:  String = "d30"
    var autoDeleteMode: String = "mediaOnly"
    init() {}
    enum CodingKeys: String, CodingKey {
        case dataDirectory  = "data_directory"
        case retentionDays  = "retention_days"
        case autoDeleteMode = "auto_delete_mode"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataDirectory  = c.dflt(String.self, .dataDirectory, dataDirectory)
        retentionDays  = c.dflt(String.self, .retentionDays, retentionDays)
        autoDeleteMode = c.dflt(String.self, .autoDeleteMode, autoDeleteMode)
    }
}

// MARK: - Chat

struct ChatConfig: Codable, Equatable {
    var redactPii: Bool = false
    init() {}
    enum CodingKeys: String, CodingKey { case redactPii = "redact_pii" }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redactPii = c.dflt(Bool.self, .redactPii, redactPii)
    }
}

// MARK: - Helper — `decodeIfPresent`-with-default

private extension KeyedDecodingContainer {
    func dflt<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }
}
