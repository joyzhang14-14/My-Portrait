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

    /// Lightweight SQLite that indexes the file-system source of truth.
    /// Schema lives in `Schema.swift` once we start writing.
    static var indexDBPath: String { rootURL.appendingPathComponent("index.sqlite").path }

    /// Reserved for future vector sidecar — empty until ~500 portrait files.
    static var embeddingsDir: URL { rootURL.appendingPathComponent(".embeddings", isDirectory: true) }

    /// Append-only daily action logs from the Memory pipeline (merges,
    /// archives, supersede decisions, weight passes). See design doc 6.6.
    static var journalDir: URL { rootURL.appendingPathComponent("journal", isDirectory: true) }

    /// Imported timeline snapshot. Schema originally came from the
    /// screenpipe project (kept verbatim so existing tables / queries
    /// still apply) — the directory was copied here 2026-05-19 and the
    /// app no longer touches the original `~/.screenpipe` folder.
    static var timelineImportedRoot: URL {
        rootURL.appendingPathComponent("imported/timeline", isDirectory: true)
    }

    /// Convenience: full path to the imported timeline SQLite DB.
    static var timelineImportedDBPath: String {
        timelineImportedRoot.appendingPathComponent("db.sqlite").path
    }

    // MARK: - Capture layer (Capture/ module)

    /// Raw data produced by the capture layer (screen frames + future MP4 chunks).
    /// Owned by `Capture/`. Mirrors screenpipe's `data/` directory but lives
    /// inside ~/.portrait so we never touch ~/.screenpipe.
    static var rawDataDir: URL { rootURL.appendingPathComponent("raw_data", isDirectory: true) }

    /// Per-day JPG snapshot directory. Path:
    /// `~/.portrait/raw_data/frames/YYYY-MM-DD/{ts_ms}_m{monitor}.jpg`.
    /// Hot-cache only — JPGs are compacted into MP4 chunks after ~10 minutes (P3).
    static var framesDir: URL { rawDataDir.appendingPathComponent("frames", isDirectory: true) }

    /// Per-day HEVC MP4 chunk directory (P3+). Path:
    /// `~/.portrait/raw_data/video/YYYY-MM-DD/m{id}_{startTs}.mp4`.
    static var videoDir: URL { rawDataDir.appendingPathComponent("video", isDirectory: true) }

    /// SQLite written by the capture layer (frames / video_chunks / OCR / audio).
    /// Separate file from `indexDBPath` so the capture layer and portrait layer
    /// can evolve schemas independently.
    static var portraitDBPath: String { rootURL.appendingPathComponent("portrait.sqlite").path }

    /// Local model cache (bge-m3 embeddings, future Whisper local cache, etc).
    /// `~/.portrait/models/`.
    static var modelsDir: URL { rootURL.appendingPathComponent("models", isDirectory: true) }

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [
            rootURL, portraitDir, eventsDir, audioQueueDir, dailyLogsDir,
            journalDir, rawDataDir, framesDir, videoDir
        ] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
