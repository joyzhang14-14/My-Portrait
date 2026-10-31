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

    /// events / portrait 的界面版。
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

    /// 待转录的录音段(VAD 切好的 WAV + .meta.json),`~/.portrait/metadata/audio_queue/`。
    /// 转录完就搬进 `audioDir/<日>/`,这里只剩还没转的。
    static var audioQueueDir: URL { metadataDir.appendingPathComponent("audio_queue", isDirectory: true) }

    /// 转录结果的 JSON 副本,`metadata/transcript/<日>/<段名>.transcript.json`。
    /// 正本在 audio.sqlite(audio_transcriptions),这里只是按文件翻看用。
    static var transcriptDir: URL {
        metadataDir.appendingPathComponent("transcript", isDirectory: true)
    }

    /// 一段录音的转录副本位置,按文件名里的日期(`seg_YYYY-MM-DD…`)分目录。
    /// 写入、搬家、隐私删除、保留清理都用它定位,不是录音段文件名时返回 nil。
    static func transcriptURL(forAudio path: String) -> URL? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard name.hasPrefix("seg_"), name.count >= 14 else { return nil }
        let day = String(name.dropFirst(4).prefix(10))
        return transcriptDir.appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(name + ".transcript.json")
    }

    /// Daily raw JSON logs (one file per day, batched at sleep).
    static var dailyLogsDir: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }

    /// 流水线的维护日志(周预算 rebalance、归档等),一天一个 `<UTC 日>.md`,只追加。
    /// `~/.portrait/pipeline/logs/`(10-27 update,原 `~/.portrait/journal/`)。
    static var pipelineLogsDir: URL {
        rootURL.appendingPathComponent("pipeline/logs", isDirectory: true)
    }

    /// 模型回复解析不了时存的原始回复,排查用(`~/.portrait/pipeline/llm_dump/`,
    /// 10-27 update,原 `~/.portrait/llm_dump/`)。空回复不存。
    static var llmDumpDir: URL {
        rootURL.appendingPathComponent("pipeline/llm_dump", isDirectory: true)
    }

    // MARK: - 采集数据(metadata/)和 workflow 数据(pipeline/)

    /// `~/.portrait/metadata/` —— 采集到的原始数据:三个库和它们引用的截图、视频、录音。
    /// 库里存的媒体路径都相对 `rootURL`(`metadata/…`),整个 `~/.portrait` 可以整体搬走。
    static var metadataDir: URL { rootURL.appendingPathComponent("metadata", isDirectory: true) }

    /// `~/.portrait/pipeline/` —— workflow 加工出来的台账和结果。
    static var pipelineDir: URL { rootURL.appendingPathComponent("pipeline", isDirectory: true) }

    /// 每天的 JPG 截图:`metadata/frames/YYYY-MM-DD/{ts_ms}_m{monitor}.jpg`。
    /// 只是热缓存,约 10 分钟后压进 MP4。
    static var framesDir: URL { metadataDir.appendingPathComponent("frames", isDirectory: true) }

    /// 每天的 HEVC MP4:`metadata/video/YYYY-MM-DD/m{id}_{startTs}.mp4`。
    static var videoDir: URL { metadataDir.appendingPathComponent("video", isDirectory: true) }

    /// 留存的录音,`metadata/audio/YYYY-MM-DD/`:转录完从 `audioQueueDir` 搬来的
    /// WAV + .meta.json,以及 screenpipe import 拷进来的音频副本(retention 只删
    /// ~/.portrait 里的副本,永不碰只读的 ~/.screenpipe 原始文件)。
    static var audioDir: URL { metadataDir.appendingPathComponent("audio", isDirectory: true) }

    /// 屏幕采集:帧、帧全文索引、视频块、OCR 队列。
    static var screenDBPath: String { metadataDir.appendingPathComponent("screen.sqlite").path }
    /// 音频采集:录音段、转录、转录全文索引、说话人、声纹。
    static var audioDBPath: String { metadataDir.appendingPathComponent("audio.sqlite").path }
    /// 输入采集:击键、鼠标、打字事件、剪贴板。
    static var inputDBPath: String { metadataDir.appendingPathComponent("input.sqlite").path }
    /// workflow 的台账和结果:事件区间、性格日、处理台账、写作风格。
    static var workflowDBPath: String { pipelineDir.appendingPathComponent("workflow.sqlite").path }

    /// 拆库之前的单库和剪贴板库,只给一次性拆库迁移(`DBSplitMigration`)用。
    static var legacyPortraitDBPath: String { rootURL.appendingPathComponent("portrait.sqlite").path }
    static var legacyClipboardDBPath: String { rootURL.appendingPathComponent("clipboard.sqlite").path }

    /// 拆库的锁和进度标记(`~/.portrait/.staging/`)。实验室脚本也读这个标记。
    static var stagingDir: URL { rootURL.appendingPathComponent(".staging", isDirectory: true) }
    static var dbSplitLockPath: String { stagingDir.appendingPathComponent("db-split.lock").path }
    static var dbSplitMarkerPath: String { stagingDir.appendingPathComponent("db-split.json").path }

    /// Local model cache (bge-m3 embeddings, future Whisper local cache, etc).
    /// `~/.portrait/models/`.
    static var modelsDir: URL { rootURL.appendingPathComponent("models", isDirectory: true) }

    /// Voice training 录音 WAV (`<speaker_id>.wav`)。每次重训覆盖。
    /// 给 SpeakersView 试听 + 给 maintainer 排查训练质量用。
    /// `~/.portrait/metadata/voice_training/`(10-27 update,原 `~/.portrait/voice_training/`)。
    static var voiceTrainingDir: URL {
        rootURL.appendingPathComponent("metadata/voice_training", isDirectory: true)
    }

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [
            rootURL, portraitDir, eventsDir, audioQueueDir, dailyLogsDir,
            pipelineLogsDir, transcriptDir, metadataDir, pipelineDir, framesDir, videoDir,
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
