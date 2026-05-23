import Foundation

/// Single source of truth for where on disk My Portrait keeps its data.
///
/// Top level is a hidden folder under $HOME (`~/.portrait`) so it does
/// not clutter the Finder sidebar but is still openable via `cmd+shift+G`.
enum Storage {
    /// `~/.portrait` — top-level hidden root.
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portrait", isDirectory: true)
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

    /// SQLite written by the capture layer (frames / video_chunks / OCR / audio).
    static var portraitDBPath: String { rootURL.appendingPathComponent("portrait.sqlite").path }

    /// Local model cache (bge-m3 embeddings, future Whisper local cache, etc).
    /// `~/.portrait/models/`.
    static var modelsDir: URL { rootURL.appendingPathComponent("models", isDirectory: true) }

    /// AI pipes — one directory per pipe (`<slug>/pipe.md` + `runs.json`).
    /// `~/.portrait/pipes/`.
    static var cronJobsDir: URL { rootURL.appendingPathComponent("pipes", isDirectory: true) }

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [
            rootURL, portraitDir, eventsDir, audioQueueDir, dailyLogsDir,
            journalDir, personalityDailyDir, rawDataDir, framesDir, videoDir
        ] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
