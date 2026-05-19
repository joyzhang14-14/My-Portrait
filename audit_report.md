# My-Portrait Audit Report
日期: 2026-05-19

## 摘要
- 严重问题数: 4
- 中等问题数: 7
- 轻微问题数: 6
- 项目整体健康度评价：核心采集 / DB / 向量 / 配置链路（Capture → PortraitDBImpl → BGEM3 → HybridSearch → ConfigStore）已经成型，单元测试覆盖关键模块，Sendable / 并发约束写得相当严谨，状态栏会上报 stub。但是 2026-05-19 那次"timeline 合并到 capture schema"（commit c2186c2）只迁移了写入和 PortraitDBImpl 的读，**没有同步迁移消费旧 screenpipe schema 的 SQL 调用方**。`TimelineContext.swift`（聊天上下文）、`SpeakersView.swift` 的数据加载、以及 `TimelineDB.swift` 里 audio 相关函数都还在引用 `ocr_text` / `a.transcription` / `a.timestamp` / `speakers` 等已经不存在的表/列，SQL prepare 失败后被 `else { return [] }` 完全静默吞掉，UI 看不到任何错误，但功能整片失效。这是本次审计最大的一类问题。其次有一组"两个并行的 retention / 配置源" 残留（UserDefaults vs ConfigStore），以及若干注释里承认是"dev tool"的安全占位（master.key 0600 文件存 AES key）。

---

## 严重问题（数据丢失/崩溃/安全风险）

### 问题 1: TimelineContext 全部 4 个 SQL 查询都引用旧 schema，永远返回空
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/AI/TimelineContext.swift:268-274`、`336-341`、`396-404`、`452-459`
**类型**: 字段不一致 / 静默失败
**描述**: 这四个查询（`ocrBlock`、`searchOCR`、`audioBlock`、`speakerTranscripts`）分别引用：
- 旧表 `ocr_text` / 列 `o.text` / `o.frame_id` —— 实际 PortraitDB schema 把 OCR 内联在 `frames.full_text`，没有 `ocr_text` 表（`Sources/MyPortrait/DB/Schema.swift:53-56`、`TimelineDB.swift:167` 注释也已承认）；
- 旧列 `f.timestamp`（ISO 字符串）—— 实际是 `f.timestamp_ms`（Int ms）；
- 旧列 `a.transcription` / `a.timestamp` / `a.is_input_device` —— 实际是 `t.text` / `c.recorded_at_ms` / `c.is_input`；
- 旧表 `speakers` —— 当前 schema 完全没有（`PortraitDBImpl.swift:422` 注释明确承认 "PortraitDB schema 还没有 speakers 表"）。
所有 `sqlite3_prepare_v2` 失败都被 `guard ... else { return ... }` 静默吞掉，调用方 ChatController 拿到空字符串拼进 prompt，LLM 收到的"timeline context"实际上是空的。
**影响**: AI Chat 的 timeline / OCR / audio 上下文功能全部失效，但 UI 不报错。这是聊天模式最重要的卖点之一。
**建议修复**: 把这 4 个查询重写到当前 capture schema：`ocr_text o ON …` → 直接 `f.full_text`；`f.timestamp BETWEEN ?` → `f.timestamp_ms BETWEEN ?`（且改 bind text 为 bind int64）；audio JOIN 走 `audio_transcriptions t JOIN audio_chunks c ON c.id = t.audio_chunk_id`；speakers 部分先短路返回空（schema 加 speakers 表之前没法救），UI 走 "Speaker N" fallback。

### 问题 2: TimelineDB.audioTranscripts 用 `transcribed_at_ms` 当 "时刻附近的转录" 的时间维度
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/TimelineDB.swift:287-298`
**类型**: 字段语义错误
**描述**: schema 里 `transcribed_at_ms` 是"WhisperKit 写完转录的时刻"，而不是录音发生的时刻；`audio_chunks.recorded_at_ms` 才是真正的"音频何时发生"。`PortraitDBImpl.audioTranscriptsAround`（同一份数据，正确路径）用的就是 `c.recorded_at_ms`（`PortraitDBImpl.swift:424-436`）。两个查询返回不一致的窗口语义。WhisperKit 转录有 30s~几分钟延迟，sidebar 显示的 "audio around X" 实际上是"在 X 那一刻完成转录的音频"，对应的录音可能发生在好几分钟前。
**影响**: Timeline 侧边栏的 audio panel 显示错位的转录，用户回看时间线时音频对不上画面。同样的字段错误也污染 `deleteBefore` / `deleteAfter`（`TimelineDB.swift:400`、`427`），保留期裁切会按"转录时间"而不是"录音时间"删，已转录但延迟入库的旧音频会被留下来。
**建议修复**: 用 `audio_chunks JOIN` 拿 `c.recorded_at_ms`，所有时间窗都以 `c.recorded_at_ms` 为准；deleteBefore/After 同步改成 JOIN delete 或 DELETE based on `recorded_at_ms`。

### 问题 3: TimelineDB.sampleTranscripts 列名全错，永远返回空
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/TimelineDB.swift:443-451`
**类型**: 字段不一致 / 静默失败
**描述**: SQL 写 `SELECT transcription FROM audio_transcriptions WHERE speaker_id = ? … ORDER BY timestamp DESC`。实际 schema 列名是 `text` 和 `transcribed_at_ms`（`Schema.swift:106-116`）。prepare 失败被 `else { return [] }` 吞。
**影响**: Settings → Speakers → "Organize with AI" 给 LLM 当上下文的样本永远是空数组，AI 命名准确度严重下降甚至无法工作。
**建议修复**: SQL 改成 `SELECT text FROM audio_transcriptions WHERE speaker_id = ? AND text IS NOT NULL AND length(text) > 12 ORDER BY transcribed_at_ms DESC LIMIT ?`。

### 问题 4: ImpactScorer prompt 要求输出 `evidence`，parser 找 `reason`
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Memory/ImpactScorer.swift:204-217` vs `271`
**类型**: prompt schema 与解析字段名不一致
**描述**: Prompt 在 RULES、3 个 Examples、OUTPUT FORMAT 里全部统一用 `evidence` 这个 key。Parser line 271 `let reason = entry["reason"] as? String` 找不到任何东西，所以 `LLMScore.reason` 始终是 nil。impact 评分这次因为 `impact` key 是对的所以核心功能还在工作，但 LLM 提供的 evidence 上下文（用于后续 audit / 调试 / UI 展示 / 二次过滤）全丢。
**影响**: 评分系统的"为什么打这个分"线索永久丢失；将来想根据 evidence 做二次筛选或显示给用户都没数据。
**建议修复**: parser 改读 `entry["evidence"]`，同时把 `LLMScore.reason` 字段重命名为 `evidence` 或落盘到 PortraitFile 的某处。

---

## 中等问题（功能不全/性能/一致性）

### 问题 5: 两套并行的 Retention 系统，老的读 UserDefaults 永远拿不到 ConfigStore 的值
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/DB/RetentionWorker.swift:96-115` vs `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Settings/RetentionRunner.swift:33-48`
**类型**: 配置源不统一 / 死代码
**描述**: `RetentionWorker`（Services 启）用 `UserDefaults.standard.string(forKey: SettingsKeys.retentionDays)` 读配置；`RetentionRunner`（AppDelegate 启）用 `ConfigStore.shared.storage.retentionDays`。ConfigStore 已经是项目里 UI 的单一真相（`ConfigStore.swift:8` "Replaces every Settings @AppStorage"），且只 onceMigrationSeed 时从 UserDefaults 读过一次（`ConfigStore.swift:319`），之后用户改 UI → 只更新 ConfigStore → UserDefaults 那份永不刷新。结果 RetentionWorker 永远跑在 d30 默认值，跟用户实际设置脱节。RetentionRunner 走 ConfigStore 是对的。
**影响**: 用户设 "forever" 或 "d90" 后，RetentionWorker 仍然按 d30 删 DB 行 + 媒体文件，可能误删用户想保留的数据。
**建议修复**: RetentionWorker 改读 `ConfigStore.snapshot`（已有跨 actor 通道，`ConfigStore.swift:92`），或者干脆移除 RetentionWorker（功能跟 RetentionRunner 已重叠），保留单一 Runner。

### 问题 6: DisabledVectorEmbedder 是死代码但仍在 Sources/
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/DB/Vectors/DisabledVectorEmbedder.swift:14`
**类型**: 旧代码残留
**描述**: `Services.swift:79` 已经无条件用 `BGEM3VectorEmbedder`，`DisabledVectorEmbedder` 没有任何调用方但仍编进产物。注释自己说是"临时占位"（line 3）。
**影响**: 死代码增加阅读负担，stub 类被注册在 reporter 通道（`feedback_notimplemented_visibility` 项目 memory 要求所有 stub 高可见），将来误用会绕开红点提醒。
**建议修复**: 删文件，搜索引用确认 Tests/ 无依赖即可。

### 问题 7: Storage.swift 多个路径常量无引用（死代码）
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Storage.swift:33`、`36`、`46-53`
**类型**: 旧代码残留
**描述**: `indexDBPath`、`embeddingsDir`、`timelineImportedRoot`、`timelineImportedDBPath` 全项目零引用（rg 验证），是 timeline 合并 schema 之前的产物。
**影响**: 误导后来者以为还有"imported timeline DB"的概念。
**建议修复**: 删这四个 var，Storage.ensureExists 也无需变动（本来就没建这些目录）。

### 问题 8: StorageView 还显示 "~/.portrait/imported/timeline (default)"
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Settings/StorageView.swift:16`、`26`
**类型**: UI 与实际行为不一致
**描述**: 默认 dataDirectory 空时 UI 显示 `~/.portrait/imported/timeline`，但 TimelineDB 实际打开的是 `Storage.portraitDBPath`（即 `~/.portrait/portrait.sqlite`，`TimelineDB.swift:66-75`）。
**影响**: 用户在 Settings 看到的路径跟数据实际在哪儿对不上，"清空 / 重置"操作会让他误以为操作的是另一个目录。
**建议修复**: 默认 fallback 改成 `~/.portrait/`（rootURL）或直接显示 `Storage.portraitDBPath`。

### 问题 9: SpeakersView.loadAll 用 speakers 表 + a.timestamp，永远返回 []
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Settings/SpeakersView.swift:492-501`
**类型**: 字段不一致 / 静默失败
**描述**: SQL 引用 `speakers` 表（schema 不存在）、`a.timestamp` 列（实际 `transcribed_at_ms`）。prepare 失败 → 返回空 → Speakers 设置页永远显示 "no speakers"。
**影响**: 整个 Speakers 设置页不可用，但同页注释承认 "speakers/diarisation pipeline 还没接"，所以严重度算中等而不是严重。
**建议修复**: 接 speakers 表之前直接返回空数组、让 UI 显示 "Speakers will appear after diarisation lands"，避免开启永远 prepare 失败 + silent 的代码路径。

### 问题 10: master.key 用文件 0600 存 AES-256 主密钥，未走 Data Protection Keychain
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/AI/SecretStore.swift:147-180`
**类型**: 安全降级
**描述**: 注释自己承认 "adequate for a dev tool; for a production release we'd switch to a properly-signed app + Keychain with kSecUseDataProtectionKeychain"（line 137-138）。本机 admin 任何进程都能读出主密钥 → 解出所有 secrets（OAuth token / API key）。FileVault 锁屏前关机时密钥是平的。
**影响**: 任何能 read user-owned 文件的进程都可解出整盘 OAuth token / API key。
**建议修复**: 短期至少 kSecUseDataProtectionKeychain + kSecAttrAccessibleWhenUnlockedThisDeviceOnly 存 master key；长期回 Keychain。

### 问题 11: EmbeddingWorker 永远不 embed audio_transcriptions
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/DB/Vectors/EmbeddingWorker.swift:64-87`
**类型**: 功能不全
**描述**: Schema v4 给 `audio_transcriptions` 也加了 embedding / embedding_model 列 + 部分索引（`Schema.swift:148-158`），但 PortraitDB protocol 只提供了 `framesNeedingEmbedding` / `setFrameEmbedding`，没有 transcription 的对应方法；EmbeddingWorker 也只跑 frames。HybridSearchEngine 的 `searchTranscriptions` 早就显式说 "Phase 4.1：先只走 FTS"（`HybridSearchEngine.swift:95`），但 schema 列已经预留 → 这一对索引和列永远是 NULL，占空间没收益。
**影响**: 转录语义搜索无法做；DB 部分索引白占。属于"有意 deferred 但 schema 提前 ship"。
**建议修复**: 要么补 transcription embedding pipeline，要么把 v4 schema 里 audio_transcriptions 的 embedding 列/索引移到下一个 migration，避免误以为已实现。

---

## 轻微问题（代码风格/可读性/注释）

### 问题 12: AppKeyboard.install 里有生产 `print(...)`
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/App.swift:162`
**类型**: 日志风格不一致
**描述**: `print("[Keyboard] keyDown keyCode=...")`，其他所有模块走 OSLog (`Logger(subsystem:...)`)。每次按键都打一次 stdout。
**建议修复**: 改 `Logger(subsystem: "com.myportrait", category: "keyboard").debug(...)`，或干脆删（debug 信号）。

### 问题 13: AIPaths.supportDir 用 `try!`
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/AI/AIPaths.swift:9`
**类型**: 启动期崩溃风险
**描述**: `try! fm.url(for: .applicationSupportDirectory, …)`。Application Support 在沙箱 / 加密卷异常时确实会失败，crash 比静默崩溃更好但建议跟 Services.swift:59 一样附 error msg。
**建议修复**: `fatalError("AIPaths supportDir failed: \(error)")` 形式 do/catch，便于 crashlog 定位。

### 问题 14: HomeView.swift 1958 行 / TimelineView.swift 720 行 — 超长 SwiftUI 视图
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/HomeView.swift`、`TimelineView.swift`、`TimelineSidebar.swift`
**类型**: 可读性
**描述**: 13 个文件 > 400 行，HomeView 单文件 ~2k 行，超出审计阅读范围，未做完整结构梳理。
**建议修复**: HomeView 拆 Recents / Memory scope / Chat 三段为子文件；不紧急。

### 问题 15: PortraitFileIO `optionalString` 双 `??` 链
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Memory/PortraitFileIO.swift:65`、`78-83`
**类型**: 可读性
**描述**: `(try? optionalString(fields, "event_title")) ?? nil ?? ""`，三层兜底链让人困惑。`try?` 把 throw 变 nil，再 `?? nil` 是 no-op，最后 `?? ""` 才有意义。
**建议修复**: 把 helper 改成 `nonThrowingOptional` 直接返回 `String?`，省一层 `?? nil`。

### 问题 16: PiAgent.eventLog 写入用 try? 链吞错
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/AI/PiAgent.swift:313-323`
**类型**: 错误处理偷懒
**描述**: 4 个连续 `try?` 写日志文件，磁盘满 / 权限错都看不到。诊断 Pi 子进程异常时 log 写不进去会非常难查。
**建议修复**: 把第一次 open / write 失败 logger.warning 一次（之后再降级 try? 防刷屏）。

### 问题 17: PortraitFile.category 已 deprecated 但仍在 prompt meta 里输出
**位置**: `/Users/joyzhang14/Projects/My-Portrait/Sources/MyPortrait/Memory/ImpactScorer.swift:236`
**类型**: 字段语义残留
**描述**: prompt 里仍打印 `category=\(f.category)`，但 `PortraitFile.category` 是 deprecated（`PortraitFile.swift:53` "DEPRECATED. Kept for backward-compat"），新文件 category 是 ""。给 LLM 喂一个空字段没意义。
**建议修复**: 从 ImpactScorer prompt 移掉 category 行，改成 `portrait_facets`（line 49）。

---

## 检查项覆盖情况
| # | 检查项 | 发现 |
|---|---|---|
| 1 | 绝对路径 / 硬编码 | 1（问题 8 UI 默认串误导；其他 `~/Library/Application Support/MyPortrait` 走 AIPaths/Storage 集中常量，OK） |
| 2 | 字段删减/不一致 | 4 严重（问题 1/2/3/4/9） |
| 3 | Stub/占位遗留 | 2（问题 6 DisabledVectorEmbedder，问题 7 死路径） |
| 4 | 错误处理偷懒 | 1 中等 + 1 轻微（PiAgent log 链 + 几处 try? 文件清理，多数有合理理由） |
| 5 | Sendable / 并发 | 0 严重（@unchecked Sendable 共 19 处都配 NSLock / actor，注释充分；deinit 不写也已在 CaptureSettings:155 解释） |
| 6 | 资源泄漏 | 0（observer 都有 stop()，Timer 用 [weak self]，BGEM3 ModelContainer 走 actor lifetime） |
| 7 | 配置默认值 | 1 严重（问题 5 双 retention 源） |
| 8 | 数据库 | 0 严重（无 SELECT *，所有写入走事务；FTS5 同步 trigger GRDB 自动；WAL checkpoint 走 GRDB 默认 autocheckpoint，未显式但 GRDB DatabasePool 默认 OK） |
| 9 | Prompt 工程 | 1 严重（问题 4 evidence vs reason） |
| 10 | 测试覆盖 | OK：PortraitDBImpl / HybridSearch / BGEM3 / NLEmbedding 都有；StubPortraitDB 在 Tests/Fixtures，未跑 CI 状态 |
| 11 | UI 层 | 0 严重（@AppStorage 已全替换为 ConfigStore；@MainActor 用一致；不过分页未抽查） |
| 12 | 可疑模式 | 1（问题 12 print；13 个 > 400 行文件） |
| 13 | 项目特定 | screenpipe schema 残留就是问题 1/2/3/9 的总根；FTS5 用 FoundationTokenizer（ICU-equivalent）正确；impact 双字段正常；portrait_facets 已替代 category（除了问题 17 prompt 残留） |

---

## 没检查的盲区
- `HomeView.swift`（1958 行）只扫了关键引用未通读，可能藏着上下文 fetch 与旧 schema 撞同样的问题。
- `Capture/` 模块的并发模型（CaptureCoordinator + 各 watcher）只扫了 deinit / observer 不算细看，AVAudioEngine / SCStream 生命周期没深入。
- `BGEM3VectorEmbedder` 的 MLX forward pass 算法正确性（XLM-R position shift workaround）只信注释里的"对齐 0.999999"声明，没运行验证。
- 测试是否真在 CI 跑 / 通过率没看（只看了文件存在）。
- `Package.swift` 依赖版本审查没做。
- `Memory/Backfill.swift` 的全量回灌路径与 EventBuilder 间的 LLM prompt 没逐字段对核（同类型问题 4 的隐患不能排除）。
- `ConfigSchema.swift` 完整字段列表 vs UI 真实暴露范围没对齐，可能有 UI 漏 expose 的隐藏 toggle。
