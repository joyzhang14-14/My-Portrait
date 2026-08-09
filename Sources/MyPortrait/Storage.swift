import Foundation

/// Single source of truth for where on disk My Portrait keeps its data.
///
/// Top level is a hidden folder under $HOME (`~/.portrait`) so it does
/// not clutter the Finder sidebar but is still openable via `cmd+shift+G`.
enum Storage {
    /// `~/.portrait` — top-level hidden root. **真实数据**:采集写它、pipeline
    /// 读写它、凭据(secrets.sqlite)存它。dev mode 也不换 —— 见 `uiRootURL`。
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portrait", isDirectory: true)
    }

    // MARK: - 界面用的根(dev mode)

    /// **界面展示 / 编辑**用的根。dev mode 开启后指向 `~/.portrait-dev`。
    ///
    /// ⚠️ 采集层与 pipeline **绝不能**用这一族路径,它们一律用 `rootURL`。
    /// 判断标准很简单:这段代码是"给人看的 / 人点出来的",还是"定时器和
    /// 采集线程自己在跑的"?后者一律 `rootURL`。
    static var uiRootURL: URL { DevMode.isOn ? DevMode.rootURL : rootURL }

    /// events / portrait 的界面版。AI chat 的 `chat.sqlite`、`agent_sessions/`
    /// 在 `AIPaths` 里切。
    ///
    /// **不切**的两个:
    ///   - `cron_jobs/` —— 定时 AI 任务跟真实配置跑(08-09 用户定)。切了的话
    ///     dev mode 期间你本人的定时任务会停摆,而它们是真的要按时出结果的。
    ///   - `personality_daily/` —— 查过调用方,只有 pipeline 在写、UI 不读。
    static var uiEventsDir: URL { uiRootURL.appendingPathComponent("events", isDirectory: true) }
    static var uiPortraitDir: URL { uiRootURL.appendingPathComponent("portrait", isDirectory: true) }

    /// dev 根下的目录骨架。只在 dev mode 开着时调 —— 平时一个字节都不碰
    /// `~/.portrait-dev`(它不存在就等于这个功能不存在,见 `DevMode.isAvailable`)。
    static func ensureDevExists() throws {
        guard DevMode.isOn else { return }
        let fm = FileManager.default
        for url in [DevMode.rootURL, uiEventsDir, uiPortraitDir] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Portrait layer — long-term "who is this person" distilled by
    /// PortraitDistiller. Subdirs are the 9 seed categories
    /// (personality / skills / emotions / …).
    static var portraitDir: URL { rootURL.appendingPathComponent("portrait", isDirectory: true) }

    /// Event layer — raw activity records (one file per semantic event,
    /// possibly spanning apps within a day). Source material the
    /// PortraitDistiller reads to produce portrait entries.
    /// Subdirs are dates (yyyy-MM-dd).
    static var eventsDir: URL { rootURL.appendingPathComponent("events", isDirectory: true) }

    /// VAD-segmented raw audio + transcripts queue (P1 deferred transcription).
    static var audioQueueDir: URL { rootURL.appendingPathComponent("audio_queue", isDirectory: true) }

    /// Daily raw JSON logs (one file per day, batched at sleep).
    static var dailyLogsDir: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }

    /// Append-only daily action logs from the Memory pipeline (merges,
    /// archives, supersede decisions, weight passes). See design doc 6.6.
    static var journalDir: URL { rootURL.appendingPathComponent("journal", isDirectory: true) }

    /// Per-day personality snapshots (one file per day, `YYYY-MM-DD.md`),
    /// produced by PersonalityAgent. Kept separate from the portrait tree —
    /// these are transient daily reads, not long-term concepts.
    static var personalityDailyDir: URL {
        rootURL.appendingPathComponent("personality_daily", isDirectory: true)
    }

    // MARK: - Capture layer (Capture/ module)

    /// Raw data produced by the capture layer (screen frames + MP4 chunks).
    /// Owned by `Capture/`. All paths inside this tree are stored RELATIVE
    /// to `rootURL` so the whole `~/.portrait` folder can be moved or
    /// shipped to a different user without rewriting any path.
    static var rawDataDir: URL { rootURL.appendingPathComponent("raw_data", isDirectory: true) }

    /// Per-day JPG snapshot directory. Path:
    /// `~/.portrait/raw_data/frames/YYYY-MM-DD/{ts_ms}_m{monitor}.jpg`.
    /// Hot-cache only — JPGs are compacted into MP4 chunks after ~10 minutes (P3).
    static var framesDir: URL { rawDataDir.appendingPathComponent("frames", isDirectory: true) }

    /// Per-day HEVC MP4 chunk directory (P3+). Path:
    /// `~/.portrait/raw_data/video/YYYY-MM-DD/m{id}_{startTs}.mp4`.
    static var videoDir: URL { rawDataDir.appendingPathComponent("video", isDirectory: true) }

    /// Per-day imported-audio directory. Path:
    /// `~/.portrait/raw_data/audio/YYYY-MM-DD/imported_<basename>`.
    /// 只放 screenpipe import 拷进来的音频副本 —— 让 retention 只删 ~/.portrait
    /// 里的副本,永不碰只读的 ~/.screenpipe 原始文件。
    static var audioDir: URL { rawDataDir.appendingPathComponent("audio", isDirectory: true) }

    /// SQLite written by the capture layer (frames / video_chunks / OCR / audio).
    static var portraitDBPath: String { rootURL.appendingPathComponent("portrait.sqlite").path }

    /// Local model cache (bge-m3 embeddings, future Whisper local cache, etc).
    /// `~/.portrait/models/`.
    static var modelsDir: URL { rootURL.appendingPathComponent("models", isDirectory: true) }

    /// AI cron jobs — one directory per cron job (`<slug>/cron_job.md` + `runs.json`).
    /// `~/.portrait/cron_jobs/`.
    static var cronJobsDir: URL { rootURL.appendingPathComponent("cron_jobs", isDirectory: true) }

    /// Voice training 录音 WAV (`<speaker_id>.wav`)。每次重训覆盖。
    /// 给 SpeakersView 试听 + 给 maintainer 排查训练质量用。
    static var voiceTrainingDir: URL {
        rootURL.appendingPathComponent("voice_training", isDirectory: true)
    }

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [
            rootURL, portraitDir, eventsDir, audioQueueDir, dailyLogsDir,
            journalDir, personalityDailyDir, rawDataDir, framesDir, videoDir,
            voiceTrainingDir,
        ] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Spotlight 排除标记 —— Apple 文档:目录根放个空的 `.metadata_never_index`
        // 文件,Spotlight 跳过整目录。`~/.portrait` 堆 GB 级 OCR 文本 + audio +
        // 帧图,被 mdworker 全文索引会持续烧 CPU / 硬盘 I/O。
        // 借鉴 upstream screenpipe commit 6bed20eb9。idempotent。
        let marker = rootURL.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
    }
}
