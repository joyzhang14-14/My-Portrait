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

    /// Markdown portrait tree (`/personality`, `/skills`, `/emotions`, …).
    static var portraitDir: URL { rootURL.appendingPathComponent("portrait", isDirectory: true) }

    /// VAD-segmented raw audio + transcripts queue (P1 deferred transcription).
    static var audioQueueDir: URL { rootURL.appendingPathComponent("audio_queue", isDirectory: true) }

    /// Daily raw JSON logs (one file per day, batched at sleep).
    static var dailyLogsDir: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }

    /// Lightweight SQLite that indexes the file-system source of truth.
    /// Schema lives in `Schema.swift` once we start writing.
    static var indexDBPath: String { rootURL.appendingPathComponent("index.sqlite").path }

    /// Reserved for future vector sidecar — empty until ~500 portrait files.
    static var embeddingsDir: URL { rootURL.appendingPathComponent(".embeddings", isDirectory: true) }

    /// Make sure the layout exists on disk. Idempotent. Call at app start.
    static func ensureExists() throws {
        let fm = FileManager.default
        for url in [rootURL, portraitDir, audioQueueDir, dailyLogsDir] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
