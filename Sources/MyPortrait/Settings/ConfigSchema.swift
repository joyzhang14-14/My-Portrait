import Foundation

/// Persistent settings file mapped 1:1 to `~/.portrait/config.toml`.
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
    static let currentSchemaVersion = 2

    var schemaVersion: Int   = currentSchemaVersion
    var display:       DisplayConfig       = .init()
    var general:       GeneralConfig       = .init()
    var aiModels:      AIModelsConfig      = .init()
    var capture:       RecordingConfig     = .init()
    var notifications: NotificationsConfig = .init()
    var memory:        MemoryConfig        = .init()
    var scheduler:     SchedulerSettings   = .init()
    var usage:         UsageConfig         = .init()
    var privacy:       PrivacyConfig       = .init()
    var storage:       StorageConfig       = .init()
    var chat:          ChatConfig          = .init()
    var personalInfo:  PersonalInfoConfig  = .init()

    init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case display, general, aiModels = "ai_models", capture, notifications
        case memory, scheduler, usage, privacy, storage, chat
        case personalInfo = "personal_info"
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.dflt(Int.self, .schemaVersion, schemaVersion)
        display       = c.dflt(DisplayConfig.self, .display, display)
        general       = c.dflt(GeneralConfig.self, .general, general)
        aiModels      = c.dflt(AIModelsConfig.self, .aiModels, aiModels)
        capture       = c.dflt(RecordingConfig.self, .capture, capture)
        notifications = c.dflt(NotificationsConfig.self, .notifications, notifications)
        memory        = c.dflt(MemoryConfig.self, .memory, memory)
        scheduler     = c.dflt(SchedulerSettings.self, .scheduler, scheduler)
        usage         = c.dflt(UsageConfig.self, .usage, usage)
        privacy       = c.dflt(PrivacyConfig.self, .privacy, privacy)
        storage       = c.dflt(StorageConfig.self, .storage, storage)
        chat          = c.dflt(ChatConfig.self, .chat, chat)
        personalInfo  = c.dflt(PersonalInfoConfig.self, .personalInfo, personalInfo)
    }
}

// MARK: - Personal Info
//
// 用户自填的基础画像。**全部可选** —— 任何字段空 → 不进 LLM prompt。
// 由 memory pipeline(event / portrait / personality)各 agent 在 buildPrompt
// 时通过 `MemoryPrompts.aboutUserBlock()` 拼到 system prompt 顶部。

/// 性别字段:对 LLM 来说只关心代称(pronoun)。 he / she / they / 空。
enum PersonalInfoGender: String, Codable, Equatable, CaseIterable {
    case unset = ""    // 没填,等于空 —— 不进 prompt
    case he
    case she
    case they

    var displayName: String {
        switch self {
        case .unset: return "—"
        case .he:    return "He"
        case .she:   return "She"
        case .they:  return "They"
        }
    }
}

struct PersonalInfoConfig: Codable, Equatable {
    /// LLM prompt 注入用 —— memory pipeline 各 agent 通过 `aboutUserBlock(_:)`
    /// 拼到 system prompt 顶部。跟 Voice Training 训练声纹用的名字是两回事。
    var firstName:   String = ""
    var middleName:  String = ""
    var lastName:    String = ""
    var alias:       String = ""    // 别名 / 昵称 / 自称
    var gender:      PersonalInfoGender = .unset
    var nationality: String = ""
    var ethnicity:   String = ""
    /// 用户会说的语言。无限添加,空数组 = 不进 prompt。
    var languages:   [String] = []
    /// 出生日期,ISO 8601 'YYYY-MM-DD'。空串 = 没填。
    var birthDate:   String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case firstName   = "first_name"
        case middleName  = "middle_name"
        case lastName    = "last_name"
        case alias
        case gender
        case nationality
        case ethnicity
        case languages
        case birthDate   = "birth_date"
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName   = c.dflt(String.self,   .firstName,   firstName)
        middleName  = c.dflt(String.self,   .middleName,  middleName)
        lastName    = c.dflt(String.self,   .lastName,    lastName)
        alias       = c.dflt(String.self,   .alias,       alias)
        gender      = c.dflt(PersonalInfoGender.self, .gender, gender)
        nationality = c.dflt(String.self,   .nationality, nationality)
        ethnicity   = c.dflt(String.self,   .ethnicity,   ethnicity)
        languages   = c.dflt([String].self, .languages,   languages)
        birthDate   = c.dflt(String.self,   .birthDate,   birthDate)
    }
}

// MARK: - Memory

struct MemoryConfig: Codable, Equatable {
    // MemoryBudget — sleep-consolidation pass. Per-day impact budget.
    var dailyBudget:           Double = 50
    var peakProtection:        Double = 4.5
    var maxRebalances:         Int    = 5
    var windowDays:            Int    = 7

    // WeightCalculator — power-law decay + log access boost.
    var alpha:                 Double = 0.3
    var minWeight:             Double = 0

    // Archiver — programmatic, no LLM. portrait 不持有 impact，归档只看
    // weight + days_idle（+ pin + protected-category 在代码里）。
    var archiveMaxWeight:      Double = 0.05
    var archiveMinDaysIdle:    Int    = 30

    // PortraitDistiller — weighted-merge evidence threshold. How many new
    // events must support a change before a settled portrait body is rewritten.
    var distillEvidenceThreshold: Int = 3

    // Phase 3 EMA weight — half-life in days. portrait weight decays by half
    // every N days since the file's last modification. Larger = stickier.
    var weightHalfLifeDays:    Int    = 180

    // Scheduler — max unprocessed days handled per event-processing run
    // (manual or automatic). Oldest first.
    var eventDayCap:           Int    = 7

    // LLM provider used by the memory pipeline. providerId 匹配 Provider 的
    // rawValue("chatgpt"/"anthropic"/"claude-code"/...);model 是主任务模型
    //(EventBuilder/Distiller/Personality 等),modelLight 是轻任务模型
    //(Cluster/WritingPass1/Pass3)。
    //
    // **默认全空串 = 用户还没选**:UI(Settings → Parameter / Onboarding)显示
    // "Please select a provider",不预选任何一家(用户原话:选哪个当默认都不
    // 合适)。pipeline 侧 resolvedProvider 仍兜底到 chatgpt 防崩溃;真没连
    // chatgpt 时该 run 自然 auth 失败,跟以前一样。model 空串 = provider.defaultModel。
    var providerId:            String = ""
    var model:                 String = ""
    var modelLight:            String = ""

    init() {}
    enum CodingKeys: String, CodingKey {
        case dailyBudget          = "daily_budget"
        case peakProtection       = "peak_protection"
        case maxRebalances        = "max_rebalances"
        case windowDays           = "window_days"
        case alpha
        case minWeight            = "min_weight"
        case archiveMaxWeight     = "archive_max_weight"
        case archiveMinDaysIdle   = "archive_min_days_idle"
        case distillEvidenceThreshold = "distill_evidence_threshold"
        case weightHalfLifeDays   = "weight_half_life_days"
        case eventDayCap          = "event_day_cap"
        case providerId           = "provider_id"
        case model
        case modelLight           = "model_light"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyBudget          = c.dflt(Double.self, .dailyBudget,          dailyBudget)
        peakProtection       = c.dflt(Double.self, .peakProtection,       peakProtection)
        maxRebalances        = c.dflt(Int.self,    .maxRebalances,        maxRebalances)
        windowDays           = c.dflt(Int.self,    .windowDays,           windowDays)
        alpha                = c.dflt(Double.self, .alpha,                alpha)
        minWeight            = c.dflt(Double.self, .minWeight,            minWeight)
        archiveMaxWeight     = c.dflt(Double.self, .archiveMaxWeight,     archiveMaxWeight)
        archiveMinDaysIdle   = c.dflt(Int.self,    .archiveMinDaysIdle,   archiveMinDaysIdle)
        distillEvidenceThreshold = c.dflt(Int.self, .distillEvidenceThreshold, distillEvidenceThreshold)
        weightHalfLifeDays   = c.dflt(Int.self,    .weightHalfLifeDays,   weightHalfLifeDays)
        eventDayCap          = c.dflt(Int.self,    .eventDayCap,          eventDayCap)
        providerId           = c.dflt(String.self, .providerId,           providerId)
        model                = c.dflt(String.self, .model,                model)
        modelLight           = c.dflt(String.self, .modelLight,           modelLight)
    }

    /// 把 providerId / model / modelLight 解析成 agent 调用方实际要用的值。
    /// providerId 不认识就回落到 chatgpt;model 空就用 provider.defaultModel;
    /// modelLight 空就跟 model 同档。
    var resolvedProvider: Provider {
        Provider(rawValue: providerId) ?? .chatgpt
    }
    var resolvedModel: String {
        model.isEmpty ? resolvedProvider.defaultModel : model
    }
    var resolvedModelLight: String {
        modelLight.isEmpty ? resolvedModel : modelLight
    }
}

// MARK: - Scheduler

/// 一个调度器的运行频率。频率是*配置*，不是身份 —— event / portrait 两个
/// 调度器都能选任意频率（或关掉走纯手动）。
enum SchedulerFrequency: String, Codable, CaseIterable, Equatable, Sendable {
    case off       // 不自动跑，纯手动
    case daily
    case weekly
    case monthly
}

/// 单个调度器的配置（频率可配的容器）。
///   - `timeOfDay`   ："HH:mm" 本地时间，所有非 off 频率都用。
///   - `dayOfWeek`   ：0=周日…6=周六，仅 weekly 用。
///   - `dayOfMonth`  ：1…31，仅 monthly 用。选 31 但当月不足时自动落到当月
///                     最后一天（逻辑里处理，UI 不暴露）。
struct SchedulerConfig: Codable, Equatable {
    var frequency:  SchedulerFrequency = .daily
    var timeOfDay:  String = "03:00"
    var dayOfWeek:  Int    = 0
    var dayOfMonth: Int    = 1

    init() {}
    init(frequency: SchedulerFrequency, timeOfDay: String,
         dayOfWeek: Int, dayOfMonth: Int) {
        self.frequency = frequency
        self.timeOfDay = timeOfDay
        self.dayOfWeek = dayOfWeek
        self.dayOfMonth = dayOfMonth
    }
    enum CodingKeys: String, CodingKey {
        case frequency
        case timeOfDay  = "time_of_day"
        case dayOfWeek  = "day_of_week"
        case dayOfMonth = "day_of_month"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency  = c.dflt(SchedulerFrequency.self, .frequency,  frequency)
        timeOfDay  = c.dflt(String.self,             .timeOfDay,  timeOfDay)
        dayOfWeek  = c.dflt(Int.self,                .dayOfWeek,  dayOfWeek)
        dayOfMonth = c.dflt(Int.self,                .dayOfMonth, dayOfMonth)
    }

    /// "HH:mm" 拆出的小时。
    var hour: Int {
        Int(timeOfDay.split(separator: ":").first ?? "0") ?? 0
    }
    /// "HH:mm" 拆出的分钟。
    var minute: Int {
        let parts = timeOfDay.split(separator: ":")
        return parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
    }
}

/// 记忆流水线的两个调度器容器。频率各自独立配置。
///   - `event`   ：跑 event 聚类 + impact 评分。
///   - `portrait`：跑 distill（事件 → 画像蒸馏）。
struct SchedulerSettings: Codable, Equatable {
    var event:          SchedulerConfig = .init(frequency: .daily,  timeOfDay: "03:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    /// EventClassifier:event 之后 / distill 之前的项目分组(_folders/*.json)。
    /// 默认 daily 跟 event 同节奏 —— event 跑完就有新事件等着分组,等到下一
    /// 个 portrait/personality 触发再 distill 完整,链条对齐。
    var classify:       SchedulerConfig = .init(frequency: .daily,  timeOfDay: "03:30",
                                                dayOfWeek: 0, dayOfMonth: 1)
    var portrait:       SchedulerConfig = .init(frequency: .weekly, timeOfDay: "04:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    var personality:    SchedulerConfig = .init(frequency: .weekly, timeOfDay: "05:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    /// 写作采集 worker(Step 0 + Pass 1 + Pass 3 + Pass 4)。默认 off 因为它需要用户
    /// 在 Pending review 里手动 Approve,完全无人值守不合适。用户开了之后
    /// 自动跑只是「先把 staged 准备好」,等用户审核。
    var writingCapture: SchedulerConfig = .init(frequency: .off,    timeOfDay: "03:30",
                                                dayOfWeek: 0, dayOfMonth: 1)
    /// writing_style 提炼链路。auto 模式 → 直接落 portrait/writing_style/,不审。
    /// 默认 off。
    var writingStyle:    SchedulerConfig = .init(frequency: .off,    timeOfDay: "04:30",
                                                dayOfWeek: 0, dayOfMonth: 1)
    init() {}
    enum CodingKeys: String, CodingKey {
        case event, classify, portrait, personality
        case writingCapture = "writing_capture"
        case writingStyle    = "writing_style"
    }
    /// 旧 key:1.2.x 之前这条链路叫 speech_style,老 config.toml 仍写
    /// [scheduler.speech_style]。单独放,避免污染合成的 encode(to:)
    ///(无对应属性的 CodingKey 会让 Encodable 合成失败)。
    private enum LegacyKeys: String, CodingKey { case speechStyle = "speech_style" }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event          = c.dflt(SchedulerConfig.self, .event,          event)
        classify       = c.dflt(SchedulerConfig.self, .classify,       classify)
        portrait       = c.dflt(SchedulerConfig.self, .portrait,       portrait)
        personality    = c.dflt(SchedulerConfig.self, .personality,    personality)
        writingCapture = c.dflt(SchedulerConfig.self, .writingCapture, writingCapture)
        // 读不到新 writing_style key 时回退旧 speech_style key,设置不丢
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        writingStyle   = c.dflt(SchedulerConfig.self, .writingStyle,
                                legacy?.dflt(SchedulerConfig.self, .speechStyle, writingStyle) ?? writingStyle)
    }
}

// MARK: - Display

struct DisplayConfig: Codable, Equatable {
    var theme:                   String = "system"
    var chatAlwaysOnTop:         Bool   = false
    var translucentSidebar:      Bool   = true
    var hideModelReasoning:      Bool   = false
    /// AI chat:把一条回复里所有 thinking + 工具块压成一个可展开的汇总栏,
    /// 只留最终文本在外。默认开(减少历史消息一次性渲染的块数,更流畅)。
    var compactToolBlocks:       Bool   = true
    var appName:                 String = "My Portrait"
    var customDockIcon:          String = ""
    var customTrayIcon:          String = ""
    var showInMenuBar:           Bool   = true
    /// Memories 列表排序规则:weight(默认)/ created / last_occurred。
    /// 文件夹分组内的 event 也跟随。值取自 MemorySortOrder.rawValue。
    var memorySortOrder:         String = "weight"

    init() {}
    enum CodingKeys: String, CodingKey {
        case theme
        case chatAlwaysOnTop          = "chat_always_on_top"
        case translucentSidebar       = "translucent_sidebar"
        case hideModelReasoning       = "hide_model_reasoning"
        case compactToolBlocks        = "compact_tool_blocks"
        case appName                  = "app_name"
        case customDockIcon           = "custom_dock_icon"
        case customTrayIcon           = "custom_tray_icon"
        case showInMenuBar            = "show_in_menu_bar"
        case memorySortOrder          = "memory_sort_order"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme                   = c.dflt(String.self, .theme, theme)
        chatAlwaysOnTop         = c.dflt(Bool.self,   .chatAlwaysOnTop, chatAlwaysOnTop)
        translucentSidebar      = c.dflt(Bool.self,   .translucentSidebar, translucentSidebar)
        hideModelReasoning      = c.dflt(Bool.self,   .hideModelReasoning, hideModelReasoning)
        compactToolBlocks       = c.dflt(Bool.self,   .compactToolBlocks, compactToolBlocks)
        appName                 = c.dflt(String.self, .appName, appName)
        customDockIcon          = c.dflt(String.self, .customDockIcon, customDockIcon)
        customTrayIcon          = c.dflt(String.self, .customTrayIcon, customTrayIcon)
        showInMenuBar           = c.dflt(Bool.self,   .showInMenuBar, showInMenuBar)
        memorySortOrder         = c.dflt(String.self, .memorySortOrder, memorySortOrder)
    }
}

// MARK: - General

struct GeneralConfig: Codable, Equatable {
    var launchAtLogin:       Bool = false
    var autoDownloadUpdates: Bool = true
    /// 首启 onboarding 是否走完(或被用户 Skip 到最后 Finish)。false → app
    /// 启动时 ContentView 弹 onboarding sheet 挡住主 UI;走完 sheet 自动关。
    /// 默认 false → 全新安装自动看到 onboarding。Settings → General → Onboarding
    /// 里的 "Show" 按钮不动这个 flag,只临时预览。
    var onboardingCompleted: Bool = false
    /// CronJob 历史记录保留上限 —— sidebar CRON JOB HISTORY 区只显示前 N 条,
    /// CronJobStore.appendRun 按这个值裁 runs.json。
    /// 0 = no limit(runs.json 会无限增长,慎选)。
    /// 合法值:5 / 10 / 20 / 50 / 0,UI 下拉只暴露这几档。
    var cronJobHistoryLimit: Int = 20
    /// Import 页打开时是否自动扫描所有来源(screenpipe / Claude Code / Codex)。
    /// 关 → Import 页每个来源显示「未扫描」+ Scan 按钮,点了才扫。默认开(保持现状)。
    var autoScanImports:     Bool = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case launchAtLogin        = "launch_at_login"
        case autoDownloadUpdates  = "auto_download_updates"
        case onboardingCompleted  = "onboarding_completed"
        case cronJobHistoryLimit  = "cron_job_history_limit"
        case autoScanImports      = "auto_scan_imports"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin       = c.dflt(Bool.self, .launchAtLogin, launchAtLogin)
        autoDownloadUpdates = c.dflt(Bool.self, .autoDownloadUpdates, autoDownloadUpdates)
        onboardingCompleted = c.dflt(Bool.self, .onboardingCompleted, onboardingCompleted)
        cronJobHistoryLimit = c.dflt(Int.self,  .cronJobHistoryLimit, cronJobHistoryLimit)
        autoScanImports     = c.dflt(Bool.self, .autoScanImports, autoScanImports)
    }
}

// MARK: - AI models

struct AIModelsConfig: Codable, Equatable {
    var presets: [AIPresetSpec] = []

    init() {}
    enum CodingKeys: String, CodingKey {
        case presets
    }
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
    /// Typing 采集「键盘活动关联判据」时间窗（毫秒）：value 变化前若
    /// 这段时间内没有物理按键，则判定非用户打字、丢弃。
    /// 默认 200 = max(insert 120, delete 200)；UI 可调 50–500ms。
    var typingKeyCorrelationWindowMs: Int = 200
    /// Typing 采集总开关。默认 false —— 读用户全部打字，隐私敏感，须用户显式开。
    /// true → 正常 app 启动时 TypingObserver 跟随权限门禁运行。
    var typingCaptureEnabled: Bool = false
    /// AX 内容稳定多久（毫秒）才记一个编辑窗口 —— 收敛 IME 拼音中间态。
    var typingDebounceMs: Int = 350
    /// 停打多久（秒）这段输入 session 落库。
    var typingFlushIdleSec: Int = 5
    /// 回车后多久内（毫秒）输入框清空才算「发送」。
    var typingSubmitWindowMs: Int = 1000
    /// 剪贴板内容短于这么多字不参与粘贴匹配 —— 避免「打的字恰好等于剪贴板」误判。
    var typingPasteMinChars: Int = 6
    /// 打字采集是否把粘贴(⌘V / 程序粘贴 / 剪贴板匹配)记进 editLog(kind="paste")。
    /// 默认 true —— 用户工作流常粘贴大段(笔记 / Claude Desktop),不记会丢内容。
    /// false → 旧行为:粘贴段进黑名单不进 editLog。
    var typingRecordPasteEvents: Bool = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case audio, screen, system
        case typingKeyCorrelationWindowMs = "typing_key_correlation_window_ms"
        case typingCaptureEnabled = "typing_capture_enabled"
        case typingDebounceMs     = "typing_debounce_ms"
        case typingFlushIdleSec   = "typing_flush_idle_sec"
        case typingSubmitWindowMs = "typing_submit_window_ms"
        case typingPasteMinChars  = "typing_paste_min_chars"
        case typingRecordPasteEvents = "typing_record_paste_events"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio  = c.dflt(AudioConfig.self,  .audio, audio)
        screen = c.dflt(ScreenConfig.self, .screen, screen)
        system = c.dflt(SystemConfig.self, .system, system)
        typingKeyCorrelationWindowMs = c.dflt(Int.self, .typingKeyCorrelationWindowMs, typingKeyCorrelationWindowMs)
        typingCaptureEnabled = c.dflt(Bool.self, .typingCaptureEnabled, typingCaptureEnabled)
        typingDebounceMs     = c.dflt(Int.self, .typingDebounceMs, typingDebounceMs)
        typingFlushIdleSec   = c.dflt(Int.self, .typingFlushIdleSec, typingFlushIdleSec)
        typingSubmitWindowMs = c.dflt(Int.self, .typingSubmitWindowMs, typingSubmitWindowMs)
        typingPasteMinChars  = c.dflt(Int.self, .typingPasteMinChars, typingPasteMinChars)
        typingRecordPasteEvents = c.dflt(Bool.self, .typingRecordPasteEvents, typingRecordPasteEvents)
    }
}

struct AudioConfig: Codable, Equatable {
    var enabled:                 Bool     = true
    var engine:                  String   = "whisper"
    var whisperModel:            String   = "openai_whisper-large-v3-v20240930"
    /// engine = "qwen" 时用的模型 variant（HF id）。默认 1.7B-8bit（实测质量达标）。
    var qwenModel:               String   = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    var deepgramApiKeyRef:       String   = ""
    /// Whisper 引擎的语言选择(历史字段名 `languages` 保留,免迁移)。
    var languages:               [String] = []
    /// Qwen 引擎的语言选择，跟 whisper 的 `languages` 分开存（两者支持的语言集不同）。
    var qwenLanguages:           [String] = []
    /// Deepgram 引擎的语言选择,独立存 —— 切 engine 不该把 whisper 的选择带过去。
    var deepgramLanguages:       [String] = []
    /// Custom endpoint 引擎的语言选择,独立存。
    var customLanguages:         [String] = []
    var captureSystemAudio:      Bool     = true
    var speakerIdEnabled:        Bool     = true
    /// 说话人识别用的声纹模型:`en_campplus`(英文 512维,默认)/ `zh_campplus`
    /// (中文 192维)/ `zh_eres2netv2`(中文 192维)。⚠️ 切换会让现有声纹登记
    /// (维度不同)全部失配,需重训说话人 + 重跑历史识别。
    var speakerEmbeddingModel:   String   = "en_campplus"
    var filterMusic:             Bool     = false
    /// 暂停名单（黑名单）：这些 app(bundle id) 或 类别(LSApplicationCategoryType,
    /// 如 public.app-category.music) 在输出音频时,整体暂停音频采集（比 filterMusic
    /// 更彻底,从源头不录。命中任一即暂停;两个名单都空 = 不暂停。`games` 类别特殊:
    /// 匹配任意 *-games 子类）。
    var pauseAudioApps:          [String] = []
    var pauseAudioCategories:    [String] = []
    /// DEPRECATED → 迁移到 pauseAudioCategories(music)。只为解码老 config 保留。
    var pauseOnMusicApp:         Bool     = false
    /// 只在 AC 供电时转录(省电池;音频照常录,插电后补转)。关 → 不管电源都转。
    var transcribeOnACOnly:      Bool     = true
    /// 转录有积压且在 AC 供电时,阻止系统空闲睡眠,把积压全速跑完再放行睡眠
    /// (只挡空闲睡眠;合盖走独立路径这条断言挡不住,但合盖后任务仍会在
    /// DarkWake 窗口里继续推进,只是变慢)。默认关。
    var keepAwakeWhileTranscribing: Bool  = false
    var customVocabulary:        [String] = []
    /// 用户**锁定**的输入设备 UID (CoreAudio kAudioDevicePropertyDeviceUID)。
    /// 空 = 跟随系统默认(插耳机会跟着切,macOS 标准行为)。
    /// 非空 = AudioCaptureService 启 engine 时把 AUHAL inputNode 绑到这个
    /// device,**不受系统 default 变化影响** —— 解 issue #10。
    /// 设备拔了 fallback 系统默认 + UI 报警。
    var preferredInputDeviceUID: String   = ""
    /// engine = "custom" 时用：OpenAI 兼容转录服务端点 / 模型 / API key 引用。
    var customEndpoint:          String   = ""
    var customModel:             String   = "whisper-1"
    var customApiKeyRef:         String   = ""
    init() {}
    enum CodingKeys: String, CodingKey {
        case enabled
        case engine
        case whisperModel            = "whisper_model"
        case qwenModel               = "qwen_model"
        case deepgramApiKeyRef       = "deepgram_api_key_ref"
        case customEndpoint          = "custom_endpoint"
        case customModel             = "custom_model"
        case customApiKeyRef         = "custom_api_key_ref"
        case languages
        case qwenLanguages           = "qwen_languages"
        case deepgramLanguages       = "deepgram_languages"
        case customLanguages         = "custom_languages"
        case captureSystemAudio      = "capture_system_audio"
        case speakerIdEnabled        = "speaker_id_enabled"
        case speakerEmbeddingModel   = "speaker_embedding_model"
        case filterMusic             = "filter_music"
        case pauseAudioApps          = "pause_audio_apps"
        case pauseAudioCategories    = "pause_audio_categories"
        case pauseOnMusicApp         = "pause_on_music_app"
        case transcribeOnACOnly      = "transcribe_on_ac_only"
        case keepAwakeWhileTranscribing = "keep_awake_while_transcribing"
        case customVocabulary        = "custom_vocabulary"
        case preferredInputDeviceUID = "preferred_input_device_uid"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled                = c.dflt(Bool.self,     .enabled, enabled)
        engine                 = c.dflt(String.self,   .engine, engine)
        whisperModel           = c.dflt(String.self,   .whisperModel, whisperModel)
        qwenModel              = c.dflt(String.self,   .qwenModel, qwenModel)
        deepgramApiKeyRef      = c.dflt(String.self,   .deepgramApiKeyRef, deepgramApiKeyRef)
        customEndpoint         = c.dflt(String.self,   .customEndpoint, customEndpoint)
        customModel            = c.dflt(String.self,   .customModel, customModel)
        customApiKeyRef        = c.dflt(String.self,   .customApiKeyRef, customApiKeyRef)
        languages              = c.dflt([String].self, .languages, languages)
        qwenLanguages          = c.dflt([String].self, .qwenLanguages, qwenLanguages)
        deepgramLanguages      = c.dflt([String].self, .deepgramLanguages, deepgramLanguages)
        customLanguages        = c.dflt([String].self, .customLanguages, customLanguages)
        captureSystemAudio     = c.dflt(Bool.self,     .captureSystemAudio, captureSystemAudio)
        speakerIdEnabled       = c.dflt(Bool.self,     .speakerIdEnabled, speakerIdEnabled)
        speakerEmbeddingModel  = c.dflt(String.self,   .speakerEmbeddingModel, speakerEmbeddingModel)
        filterMusic            = c.dflt(Bool.self,     .filterMusic, filterMusic)
        pauseAudioApps         = c.dflt([String].self, .pauseAudioApps, pauseAudioApps)
        pauseAudioCategories   = c.dflt([String].self, .pauseAudioCategories, pauseAudioCategories)
        pauseOnMusicApp        = c.dflt(Bool.self,     .pauseOnMusicApp, pauseOnMusicApp)
        // 老开关迁移:pauseOnMusicApp=true 且新名单为空 → 预填 music 类别,保住行为。
        if pauseOnMusicApp, pauseAudioApps.isEmpty, pauseAudioCategories.isEmpty {
            pauseAudioCategories = ["public.app-category.music"]
            pauseOnMusicApp = false
        }
        transcribeOnACOnly     = c.dflt(Bool.self,     .transcribeOnACOnly, transcribeOnACOnly)
        keepAwakeWhileTranscribing = c.dflt(Bool.self, .keepAwakeWhileTranscribing, keepAwakeWhileTranscribing)
        customVocabulary       = c.dflt([String].self, .customVocabulary, customVocabulary)
        preferredInputDeviceUID = c.dflt(String.self,  .preferredInputDeviceUID, preferredInputDeviceUID)
    }
}

struct ScreenConfig: Codable, Equatable {
    var enabled:         Bool   = true
    /// 按物理像素(Retina 2x)抓帧,OCR 吃满分辨率 —— 默认关(抓 1x point 分辨率)。
    /// 只影响 OCR 输入;存盘 JPG 仍被 jpegMaxWidth cap,体积基本不变。
    var ocrAccuracyBooster: Bool = false
    init() {}
    enum CodingKeys: String, CodingKey {
        case enabled
        case ocrAccuracyBooster = "ocr_accuracy_booster"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled         = c.dflt(Bool.self,   .enabled, enabled)
        ocrAccuracyBooster = c.dflt(Bool.self, .ocrAccuracyBooster, ocrAccuracyBooster)
    }
}

struct SystemConfig: Codable, Equatable {
    var powerMode:     String = "auto"
    init() {}
    enum CodingKeys: String, CodingKey {
        case powerMode     = "power_mode"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        powerMode     = c.dflt(String.self, .powerMode, powerMode)
    }
}

// MARK: - Notifications

struct NotificationsConfig: Codable, Equatable {
    var appUpdates:             Bool     = true
    var cronJobAlerts:             Bool     = true
    var captureStalls:          Bool     = false
    /// Pipeline **progress** 通知:跑完(⚙️)+ 中断后自动重启(🔁)。告知性,
    /// 不需要用户做什么。默认 ON。toml key 沿用 `scheduler_alerts`(老字段)
    /// 不改名以保持向后兼容,语义在 UI 文案里说清楚。
    var schedulerAlerts:        Bool     = true
    /// Pipeline **error** 通知:🛑 需要用户介入(quota / auth / model / DB /
    /// ctx overflow)+ 🔁 transient 自动重试(network / 429 / schema)。
    /// 重要,默认 ON。用户可单独关掉 progress 但保留 error,反之亦可。
    var pipelineErrorAlerts:    Bool     = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case appUpdates             = "app_updates"
        case cronJobAlerts             = "cron_job_alerts"
        case captureStalls          = "capture_stalls"
        case schedulerAlerts        = "scheduler_alerts"
        case pipelineErrorAlerts    = "pipeline_error_alerts"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appUpdates             = c.dflt(Bool.self,     .appUpdates, appUpdates)
        cronJobAlerts             = c.dflt(Bool.self,     .cronJobAlerts, cronJobAlerts)
        captureStalls          = c.dflt(Bool.self,     .captureStalls, captureStalls)
        schedulerAlerts        = c.dflt(Bool.self,     .schedulerAlerts, schedulerAlerts)
        pipelineErrorAlerts    = c.dflt(Bool.self,     .pipelineErrorAlerts, pipelineErrorAlerts)
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
    var recordAudioWhileLocked: Bool     = false
    /// Default blacklist applied to every new install.
    ///
    /// Case-insensitive substring match against a window's app name or
    /// title in IgnoreGate("wallpaper" catches the desktop window whose
    /// title is "Wallpaper-<UUID>";"Trash" catches the empty/full-trash
    /// preview windows users would never want recorded).
    ///
    /// Categories included by default:
    ///   - Password managers / 2FA: 1Password / Bitwarden / KeePassXC / Authy
    ///   - macOS sensitive surfaces: Keychain Access / Wallpaper / Trash
    ///   - Self: My Portrait — we don't want to log the app's own UI
    ///
    /// New users get these out-of-the-box;they can add / remove from
    /// Settings → Privacy → Ignored apps.
    var ignoredApps:            [String] = [
        "1Password", "Bitwarden", "KeePassXC", "Keychain Access", "Authy",
        "My Portrait", "Wallpaper", "Trash",
    ]
    var ignoredUrls:            [String] = []
    /// DEPRECATED —— 与 ignoredUrls 在 IgnoreGate 里行为完全相同(都按窗口标题
    /// 子串遮挡)。只为解码老 config 保留:decode 时把条目并进 ignoredUrls 后清空。
    var ignoredWindowTitles:    [String] = []
    /// When true, windows matching ignoredApps / ignoredUrls are
    /// excluded from the ScreenCaptureKit buffer (transparent in the frame).
    /// The frame itself is always captured.
    var maskIgnoredApps:        Bool     = true
    /// 屏幕采集「暂停名单」。焦点落在这些 app(名字子串)或 URL(子串)上时,
    /// **暂停整条屏幕采集**(DRMGate)。区别于 ignoredApps(只把窗口遮成透明,
    /// 帧照拍):受保护视频(Netflix 等)在录屏时会被系统黑掉,不停整条 SCStream
    /// 会把用户自己正在看的播放也搞黑屏,所以停整条流。默认预填主流流媒体 app /
    /// 站点,用户可在 Settings → Screen Capture → Pause capture 增删。
    var pauseCaptureApps:       [String] = [
        "Netflix", "Disney+", "Hulu", "Prime Video", "Apple TV",
        "Peacock", "Paramount+", "HBO Max", "Crunchyroll", "DAZN",
        "Horizon Client",
    ]
    var pauseCaptureUrls:       [String] = [
        "netflix.com", "disneyplus.com", "hulu.com", "primevideo.com",
        "tv.apple.com", "peacocktv.com", "paramountplus.com",
        "play.max.com", "crunchyroll.com", "dazn.com", "amazon.com/gp/video/",
    ]
    /// 黑名单 entries —— 每条要么 (bundle_id) 整 app 屏蔽,要么 (bundle_id,
    /// urlPrefix) 屏蔽该 app 下匹配 URL 前缀的页面。前缀比对 case-sensitive,
    /// urlPrefix 留空字符串 = 整个 app(等价老 bundle 列表)。
    /// 与 TypingPrivacyFilter 的 hardcoded 默认黑名单取并集。
    var typingBlacklistEntries: [TypingBlacklistEntry] = []

    init() {}
    enum CodingKeys: String, CodingKey {
        case ignoreIncognito         = "ignore_incognito"
        case recordAudioWhileLocked  = "record_audio_while_locked"
        case ignoredApps             = "ignored_apps"
        case ignoredUrls             = "ignored_urls"
        case ignoredWindowTitles     = "ignored_window_titles"
        case maskIgnoredApps         = "mask_ignored_apps"
        case pauseCaptureApps        = "pause_capture_apps"
        case pauseCaptureUrls        = "pause_capture_urls"
        case typingBlacklistEntries   = "typing_blacklist_entries"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ignoreIncognito        = c.dflt(Bool.self,     .ignoreIncognito, ignoreIncognito)
        recordAudioWhileLocked = c.dflt(Bool.self,     .recordAudioWhileLocked, recordAudioWhileLocked)
        ignoredApps            = c.dflt([String].self, .ignoredApps, ignoredApps)
        ignoredUrls            = c.dflt([String].self, .ignoredUrls, ignoredUrls)
        ignoredWindowTitles    = c.dflt([String].self, .ignoredWindowTitles, ignoredWindowTitles)
        // DEPRECATED 迁移:ignoredWindowTitles 与 ignoredUrls 行为相同(IgnoreGate
        // 都按窗口标题子串遮挡)→ 老条目并进 ignoredUrls,字段废弃。
        if !ignoredWindowTitles.isEmpty {
            for t in ignoredWindowTitles where !ignoredUrls.contains(t) { ignoredUrls.append(t) }
            ignoredWindowTitles = []
        }
        maskIgnoredApps        = c.dflt(Bool.self,     .maskIgnoredApps, maskIgnoredApps)
        pauseCaptureApps       = c.dflt([String].self, .pauseCaptureApps, pauseCaptureApps)
        pauseCaptureUrls       = c.dflt([String].self, .pauseCaptureUrls, pauseCaptureUrls)
        typingBlacklistEntries   = c.dflt([TypingBlacklistEntry].self, .typingBlacklistEntries, typingBlacklistEntries)
    }
}

/// 打字黑名单一条 entry。`urlPrefix` 空 = 整 app 屏蔽;非空 = 该 app 下 URL
/// 以这个前缀开头的 typing event 屏蔽(前缀比对 case-sensitive,字面前缀,
/// 不是 glob/regex)。
struct TypingBlacklistEntry: Codable, Equatable, Hashable, Sendable {
    var bundleId: String
    var urlPrefix: String = ""

    enum CodingKeys: String, CodingKey {
        case bundleId  = "bundle_id"
        case urlPrefix = "url_prefix"
    }
}

// MARK: - Storage

struct StorageConfig: Codable, Equatable {
    var dataDirectory:  String = ""
    var retentionDays:  String = "d30"
    var autoDeleteMode: String = "mediaOnly"
    /// 自动删除时,还没转录的音频文件先留着,等转录完成后下一轮再删 ——
    /// 否则转录积压超过保留期时,mediaOnly 承诺保留的文本永久丢失。
    /// 关掉 = 到期无条件删。
    var waitForTranscription: Bool = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case dataDirectory  = "data_directory"
        case retentionDays  = "retention_days"
        case autoDeleteMode = "auto_delete_mode"
        case waitForTranscription = "wait_for_transcription"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataDirectory  = c.dflt(String.self, .dataDirectory, dataDirectory)
        retentionDays  = c.dflt(String.self, .retentionDays, retentionDays)
        autoDeleteMode = c.dflt(String.self, .autoDeleteMode, autoDeleteMode)
        waitForTranscription = c.dflt(Bool.self, .waitForTranscription, waitForTranscription)
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
