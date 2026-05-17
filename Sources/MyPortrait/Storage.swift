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

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [rootURL, portraitDir, eventsDir, audioQueueDir, dailyLogsDir, journalDir] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
