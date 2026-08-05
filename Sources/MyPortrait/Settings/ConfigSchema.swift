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
        migrateLegacyMemoryProvider(from: c)
    }

    /// 一次性迁移:per-pipeline 化之前,provider 存在全局 `[memory] provider_id`
    /// /`model`/`model_light`。新 schema 已不读这仨 key —— 老用户升级会丢选择。
    /// 这里直接从原始 TOML 把它们读出来,seed 进全部 5 个 pipeline(仅当所有
    /// pipeline 都还没配过 provider 时,避免覆盖用户已自定义的)。读完不回写旧
    /// key,下次保存自动从文件消失。
    private mutating func migrateLegacyMemoryProvider(
        from c: KeyedDecodingContainer<CodingKeys>
    ) {
        enum LegacyKeys: String, CodingKey {
            case providerId = "provider_id"
            case model
            case modelLight = "model_light"
        }
        guard let mem = try? c.nestedContainer(keyedBy: LegacyKeys.self, forKey: .memory)
        else { return }
        let oldProvider = (try? mem.decode(String.self, forKey: .providerId)) ?? ""
        guard !oldProvider.isEmpty else { return }
        let pipelines: [WritableKeyPath<SchedulerSettings, SchedulerConfig>] = [
            \.event, \.portrait, \.personality, \.writingStyle,
        ]
        guard pipelines.allSatisfy({ scheduler[keyPath: $0].providerId.isEmpty }) else { return }
        let oldModel = (try? mem.decode(String.self, forKey: .model)) ?? ""
        let oldModelLight = (try? mem.decode(String.self, forKey: .modelLight)) ?? ""
        for kp in pipelines {
            scheduler[keyPath: kp].providerId = oldProvider
            scheduler[keyPath: kp].model = oldModel
            scheduler[keyPath: kp].modelLight = oldModelLight
        }
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

    // LLM provider/model 已**移到 per-pipeline**(SchedulerConfig.providerId/
    // model/modelLight,各 pipeline 独立),memory 这层不再持有全局 provider。

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

    // 这条 pipeline 自己的 AI provider / 主模型 / 轻模型。**各 pipeline 独立**
    //(原来全部共用 memory.providerId,已下线)。空串 = 未选 → UI 显示
    // "Please select a provider";agent 侧 resolved* 兜底回 chatgpt。
    var providerId:  String = ""
    var model:       String = ""
    var modelLight:  String = ""

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
        case providerId = "provider_id"
        case model
        case modelLight = "model_light"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency  = c.dflt(SchedulerFrequency.self, .frequency,  frequency)
        timeOfDay  = c.dflt(String.self,             .timeOfDay,  timeOfDay)
        dayOfWeek  = c.dflt(Int.self,                .dayOfWeek,  dayOfWeek)
        dayOfMonth = c.dflt(Int.self,                .dayOfMonth, dayOfMonth)
        providerId = c.dflt(String.self,             .providerId, providerId)
        model      = c.dflt(String.self,             .model,      model)
        modelLight = c.dflt(String.self,             .modelLight, modelLight)
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

    /// providerId 不认识就回落到 chatgpt;model 空就用 provider.defaultModel;
    /// modelLight 空就跟 model 同档。agent 调用方用这三个解析实际值。
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

/// 记忆流水线的两个调度器容器。频率各自独立配置。
///   - `event`   ：跑 event 聚类 + impact 评分。
///   - `portrait`：跑 distill（事件 → 画像蒸馏）。
struct SchedulerSettings: Codable, Equatable {
    var event:          SchedulerConfig = .init(frequency: .daily,  timeOfDay: "03:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    /// 旧版 EventClassifier 的独立时间配置，仅为兼容已有 config.json 解码保留；
    /// 当前分类固定在 event job 收尾执行，不再读取这个时间。
    var classify:       SchedulerConfig = .init(frequency: .daily,  timeOfDay: "03:30",
                                                dayOfWeek: 0, dayOfMonth: 1)
    var portrait:       SchedulerConfig = .init(frequency: .weekly, timeOfDay: "04:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    var personality:    SchedulerConfig = .init(frequency: .weekly, timeOfDay: "05:00",
                                                dayOfWeek: 0, dayOfMonth: 1)
    // 07-30:writingCapture 整块从 scheduler 配置里摘掉 —— typing capture 从零
    // 重写,新逻辑不跑模型,既不需要 provider/model 也不需要定时批处理。
    // 旧 config.toml 里残留的 [scheduler.writing_capture] 会被忽略
    //(dflt 解码只认 CodingKeys 里列出的键)。
    /// writing_style 提炼链路。auto 模式 → 直接落 portrait/writing_style/,不审。
    /// 默认 off。
    var writingStyle:    SchedulerConfig = .init(frequency: .off,    timeOfDay: "04:30",
                                                dayOfWeek: 0, dayOfMonth: 1)
    init() {}
    enum CodingKeys: String, CodingKey {
        case event, classify, portrait, personality
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
        // 读不到新 writing_style key 时回退旧 speech_style key,设置不丢
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        writingStyle   = c.dflt(SchedulerConfig.self, .writingStyle,
                                legacy?.dflt(SchedulerConfig.self, .speechStyle, writingStyle) ?? writingStyle)
    }
}

// MARK: - Display

/// 通用的 5 档速度等级(07-11 用户:Apple 风,不显示数值)。图谱里有两个独立
/// 设置复用它,各取各的倍率映射(medium=1.0=各自的现状手感):
///  - `display.graphAnimationSpeed` → `animationScale`(物理动画)
///  - `display.graphPulseSpeed`     → `pulseScale`(神经脉冲,纯渲染)
enum SpeedLevel: String, Codable, CaseIterable, Identifiable, Equatable {
    case verySlow, slow, medium, fast, veryFast
    var id: String { rawValue }

    /// 图谱**物理动画**倍率 → GraphPhysicsEngine.setAnimationSpeedScale。
    /// 控制①开局整图动画(所有球绽放+陨石点亮,缩放隐身沉降期 tick/帧)
    /// ②拖球松手后陨石环归位滑速(缩放 glide cap,这处只作用于陨石)。
    /// ⚠️ 作用域不对称:开局是整图,归位只有陨石。
    /// 极慢只到 0.70 —— 再低会跌破 glide cap 的 24pt 穿透阈值(长途卡半路)。
    var animationScale: Float {
        switch self {
        case .verySlow: return 0.70
        case .slow:     return 0.85
        case .medium:   return 1.00
        case .fast:     return 1.50
        case .veryFast: return 2.20
        }
    }

    /// **神经脉冲**倍率(点 hub 的冲击波 + 抵达点亮)。纯渲染,无物理约束 →
    /// 档距可以比 animationScale 拉得更开。>1 = 更快:主球 pulseSpeed ×它,
    /// folder 行程 pulseHubTravelSeconds ÷它,抵达闪光 pulseArriveFlashSec ÷它。
    var pulseScale: Double {
        switch self {
        case .verySlow: return 0.45
        case .slow:     return 0.70
        case .medium:   return 1.00
        case .fast:     return 1.60
        case .veryFast: return 2.50
        }
    }

    var label: String {
        switch self {
        case .verySlow: return "Very Slow"
        case .slow:     return "Slow"
        case .medium:   return "Medium"
        case .fast:     return "Fast"
        case .veryFast: return "Very Fast"
        }
    }
}

struct DisplayConfig: Codable, Equatable {
    var theme:                   String = "system"
    var hideModelReasoning:      Bool   = false
    /// AI chat:把一条回复里所有 thinking + 工具块压成一个可展开的汇总栏,
    /// 只留最终文本在外。默认开(减少历史消息一次性渲染的块数,更流畅)。
    var compactToolBlocks:       Bool   = true
    var appName:                 String = "My Portrait"
    var customDockIcon:          String = ""
    // 08-01 删 customTrayIcon:菜单栏图标改成三盏实时采集灯,不再可替换。
    var showInMenuBar:           Bool   = true
    /// 是否显示 Dock 图标。false → activation policy .accessory:app 照常后台跑,
    /// 窗口照常能用,只是不出现在 Dock / Cmd-Tab / 顶部 app 菜单栏。默认 true。
    /// ⚠️ 跟 showInMenuBar 都关 + 关窗 → 没可见入口,只能从 Spotlight/Finder
    /// 重启唤回(applicationShouldHandleReopen 处理)。UI 有红字提醒该组合。
    var showDockIcon:            Bool   = true
    /// Memories 列表排序规则:weight(默认)/ created / last_occurred。
    /// 文件夹分组内的 event 也跟随。值取自 MemorySortOrder.rawValue。
    var memorySortOrder:         String = "weight"
    /// 图谱物理动画速度(开局整图绽放 + 陨石归位)。默认中等=当前手感。
    var graphAnimationSpeed:     SpeedLevel = .medium
    /// 神经脉冲速度(点 hub 的冲击波 + 抵达点亮)。默认中等=当前手感。
    var graphPulseSpeed:         SpeedLevel = .medium
    /// 极简观感(07-11 用户):隐藏全部连接线 + 脉冲白杠。**纯前端**——脉冲照常
    /// 级联,球仍按原时序逐个亮起(连锁激活保留),只是传播过程不可见。
    var graphHideLinks:          Bool = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case theme
        case hideModelReasoning       = "hide_model_reasoning"
        case compactToolBlocks        = "compact_tool_blocks"
        case appName                  = "app_name"
        case customDockIcon           = "custom_dock_icon"
        case showInMenuBar            = "show_in_menu_bar"
        case showDockIcon             = "show_dock_icon"
        case memorySortOrder          = "memory_sort_order"
        case graphAnimationSpeed      = "graph_animation_speed"
        case graphPulseSpeed          = "graph_pulse_speed"
        case graphHideLinks           = "graph_hide_links"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme                   = c.dflt(String.self, .theme, theme)
        hideModelReasoning      = c.dflt(Bool.self,   .hideModelReasoning, hideModelReasoning)
        compactToolBlocks       = c.dflt(Bool.self,   .compactToolBlocks, compactToolBlocks)
        appName                 = c.dflt(String.self, .appName, appName)
        customDockIcon          = c.dflt(String.self, .customDockIcon, customDockIcon)
        showInMenuBar           = c.dflt(Bool.self,   .showInMenuBar, showInMenuBar)
        showDockIcon            = c.dflt(Bool.self,   .showDockIcon, showDockIcon)
        memorySortOrder         = c.dflt(String.self, .memorySortOrder, memorySortOrder)
        graphAnimationSpeed     = c.dflt(SpeedLevel.self, .graphAnimationSpeed, graphAnimationSpeed)
        graphPulseSpeed         = c.dflt(SpeedLevel.self, .graphPulseSpeed, graphPulseSpeed)
        graphHideLinks          = c.dflt(Bool.self, .graphHideLinks, graphHideLinks)
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
    // auto_scan_imports 已下线(07-28 用户):Import 页固定手动模式 ——
    // 每个来源显示「未扫描」+ Scan 按钮,点了才扫。旧 config.toml 里
    // 残留的这个键会被忽略(dflt 解码只认 CodingKeys 里列出的键)。
    init() {}
    enum CodingKeys: String, CodingKey {
        case launchAtLogin        = "launch_at_login"
        case autoDownloadUpdates  = "auto_download_updates"
        case onboardingCompleted  = "onboarding_completed"
        case cronJobHistoryLimit  = "cron_job_history_limit"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin       = c.dflt(Bool.self, .launchAtLogin, launchAtLogin)
        autoDownloadUpdates = c.dflt(Bool.self, .autoDownloadUpdates, autoDownloadUpdates)
        onboardingCompleted = c.dflt(Bool.self, .onboardingCompleted, onboardingCompleted)
        cronJobHistoryLimit = c.dflt(Int.self,  .cronJobHistoryLimit, cronJobHistoryLimit)
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
    var typingDebounceMs: Int = 100
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

/// 转录电源门槛(逐档收紧)。always=除电池合盖(机器本就睡)都跑;
/// pluggedIn=需插电(默认);pluggedInLidClosed=只在插电+合盖跑。
enum TranscriptionPowerMode: String, Codable, CaseIterable, Equatable, Sendable {
    case always
    case pluggedIn          = "plugged_in"
    case pluggedInLidClosed = "plugged_in_lid_closed"
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
    /// DEPRECATED → 迁移到 transcriptionPowerMode(true→pluggedIn / false→always)。
    /// 只为解码老 config 保留(同 pauseOnMusicApp 先例;synthesized encode 需 stored prop)。
    var transcribeOnACOnly:      Bool     = true
    /// 转录电源门槛(见 TranscriptionPowerMode)。各档隐含防睡:插电开盖→
    /// IOPMAssertion 挡空闲睡眠;插电合盖→SleepHelper(pmset)保持运行。默认插电。
    var transcriptionPowerMode:  TranscriptionPowerMode = .pluggedIn
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
        case transcribeOnACOnly      = "transcribe_on_ac_only"       // 仅迁移用
        case transcriptionPowerMode  = "transcription_power_mode"
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
        // 老开关迁移:老 transcribeOnACOnly=true → pluggedIn(默认档),=false → always。
        // keep_awake_while_transcribing 合并进各档隐含防睡,舍弃。新 key 缺省时用迁移值。
        transcribeOnACOnly     = c.dflt(Bool.self,     .transcribeOnACOnly, transcribeOnACOnly)
        let migrated: TranscriptionPowerMode = transcribeOnACOnly ? .pluggedIn : .always
        transcriptionPowerMode = TranscriptionPowerMode(rawValue:
            c.dflt(String.self, .transcriptionPowerMode, migrated.rawValue)) ?? migrated
        customVocabulary       = c.dflt([String].self, .customVocabulary, customVocabulary)
        preferredInputDeviceUID = c.dflt(String.self,  .preferredInputDeviceUID, preferredInputDeviceUID)
    }
}

struct ScreenConfig: Codable, Equatable {
    var enabled:         Bool   = true
    // (07-21 删 ocr_accuracy_booster 开关:全分辨率抓帧永远开,不再可配。)
    /// 锁屏 / login window 时跳帧(用户不在电脑前,拍到的只有锁屏壁纸)。
    /// 检测复用 CGSSessionScreenIsLocked,锁屏与 login window 同一信号。
    var pauseWhenLocked: Bool = true
    /// 屏幕亮度调到最低(滑块 0)时跳帧(屏幕黑着,用户没在看)。
    var pauseAtMinBrightness: Bool = true
    /// 桌面壁纸从截图里排除(那块渲染成黑)。原来是靠 privacy.ignoredApps 里
    /// 预置一条 "Wallpaper" 实现的,现在独立成开关 —— ignoredApps 的语义已
    /// 改成"整帧跳过",壁纸再挂在那条名单上就说不通了。
    var transparentWallpaper: Bool = true
    init() {}
    enum CodingKeys: String, CodingKey {
        case enabled
        case pauseWhenLocked      = "pause_when_locked"
        case pauseAtMinBrightness = "pause_at_min_brightness"
        case transparentWallpaper = "transparent_wallpaper"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled              = c.dflt(Bool.self, .enabled, enabled)
        pauseWhenLocked      = c.dflt(Bool.self, .pauseWhenLocked, pauseWhenLocked)
        pauseAtMinBrightness = c.dflt(Bool.self, .pauseAtMinBrightness, pauseAtMinBrightness)
        transparentWallpaper = c.dflt(Bool.self, .transparentWallpaper, transparentWallpaper)
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
    // (07-21 删 ignore_incognito 开关:无痕跳帧永久关闭 —— 需要屏蔽的内容走
    //  ignoredApps/ignoredUrls;IncognitoGate 代码保留但不再接线。)
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
    /// 命中的 app 在**最前台**时整帧不拍;只在后台露一角时那个窗口遮成黑。
    /// ("Wallpaper" 已移出 —— 壁纸走 capture.screen.transparent_wallpaper 开关。)
    var ignoredApps:            [String] = [
        "1Password", "Bitwarden", "KeePassXC", "Keychain Access", "Authy",
        "My Portrait", "Trash",
    ]
    var ignoredUrls:            [String] = []
    /// DEPRECATED —— 与 ignoredUrls 在 IgnoreGate 里行为完全相同(都按窗口标题
    /// 子串遮挡)。只为解码老 config 保留:decode 时把条目并进 ignoredUrls 后清空。
    var ignoredWindowTitles:    [String] = []
    // (07-21 删 mask_ignored_apps 开关:遮挡永远开 —— ignoredApps/ignoredUrls
    //  命中的窗口固定从 SCK buffer 排除(帧照拍、窗口透明),不再可配。)
    /// 屏幕采集「暂停名单」。焦点落在这些 app(名字子串)或 URL(子串)上时,
    /// **暂停整条屏幕采集**(DRMGate)。区别于 ignoredApps(只把窗口遮成透明,
    /// 帧照拍):受保护视频(Netflix 等)在录屏时会被系统黑掉,不停整条 SCStream
    /// 会把用户自己正在看的播放也搞黑屏,所以停整条流。默认预填主流流媒体 app /
    /// 站点,用户可在 Settings → Screen Capture → Pause capture 增删。
    /// 这条闸的总开关。名单本身写死在 `DRMGate.pausedApps / pausedUrls`,
    /// 不可配 —— 关掉时 Services 推空列表给 coordinator。
    /// (原 pause_capture_apps / pause_capture_urls 两个数组字段已下线。)
    var pauseForProtectedVideo: Bool = true
    /// 黑名单 entries —— 每条要么 (bundle_id) 整 app 屏蔽,要么 (bundle_id,
    /// urlPrefix) 屏蔽该 app 下匹配 URL 前缀的页面。前缀比对 case-sensitive,
    /// urlPrefix 留空字符串 = 整个 app(等价老 bundle 列表)。
    /// 与 TypingPrivacyFilter 的 hardcoded 默认黑名单取并集。
    var typingBlacklistEntries: [TypingBlacklistEntry] = []

    init() {}
    enum CodingKeys: String, CodingKey {
        case recordAudioWhileLocked  = "record_audio_while_locked"
        case ignoredApps             = "ignored_apps"
        case ignoredUrls             = "ignored_urls"
        case ignoredWindowTitles     = "ignored_window_titles"
        case pauseForProtectedVideo  = "pause_for_protected_video"
        case typingBlacklistEntries   = "typing_blacklist_entries"
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordAudioWhileLocked = c.dflt(Bool.self,     .recordAudioWhileLocked, recordAudioWhileLocked)
        ignoredApps            = c.dflt([String].self, .ignoredApps, ignoredApps)
        // 迁移:老 config 里预置的 "Wallpaper" 摘掉 —— 壁纸已独立成
        // capture.screen.transparent_wallpaper 开关。留着的话开关关了壁纸
        // 照样被遮,开关就成了摆设。
        ignoredApps.removeAll { $0.lowercased() == "wallpaper" }
        ignoredUrls            = c.dflt([String].self, .ignoredUrls, ignoredUrls)
        ignoredWindowTitles    = c.dflt([String].self, .ignoredWindowTitles, ignoredWindowTitles)
        // DEPRECATED 迁移:ignoredWindowTitles 与 ignoredUrls 行为相同(IgnoreGate
        // 都按窗口标题子串遮挡)→ 老条目并进 ignoredUrls,字段废弃。
        if !ignoredWindowTitles.isEmpty {
            for t in ignoredWindowTitles where !ignoredUrls.contains(t) { ignoredUrls.append(t) }
            ignoredWindowTitles = []
        }
        pauseForProtectedVideo = c.dflt(Bool.self,     .pauseForProtectedVideo, pauseForProtectedVideo)
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
