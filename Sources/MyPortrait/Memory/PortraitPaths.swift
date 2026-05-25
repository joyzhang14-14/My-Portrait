import Foundation

/// Path helpers for the portrait tree. Storage.swift defines the top-level
/// directories; this layer knows about the subfolder taxonomy described in
/// design doc 五（personality / social / skills / …）.
enum PortraitPaths {
    /// The top-level categories we ship with — used for directory seeding +
    /// sidebar UI. New ones can appear later via the classification Agent.
    static let seedCategories: [String] = [
        "personality", "social", "background", "experiences",
        "interests", "speech_style", "skills", "emotions"
    ]

    /// Categories the generic PortraitDistiller loops over — `seedCategories`
    /// MINUS `personality` and `speech_style`. personality is driven by the
    /// independent PersonalityAgent / PersonalityMerger pipeline；speech_style
    /// 由独立的 speech-style 提炼链路负责。两类都要避免被通用 distiller 覆写。
    static let distillCategories: [String] = seedCategories.filter {
        $0 != "personality" && $0 != "speech_style"
    }

    static func categoryDir(_ name: String) -> URL {
        Storage.portraitDir.appendingPathComponent(name, isDirectory: true)
    }

    /// Per-day events directory: ~/.portrait/events/yyyy-MM-dd/
    static func eventsDayDir(for day: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Storage.eventsDir.appendingPathComponent(f.string(from: day), isDirectory: true)
    }

    /// Per-category archive (kept inside the category itself, NOT a global
    /// _archive/, so when you browse `skills/_archive/` you see the history
    /// of THAT category specifically).
    static func archiveDir(under category: String) -> URL {
        categoryDir(category).appendingPathComponent("_archive", isDirectory: true)
    }

    /// Today's journal file (one per UTC day).
    static var todayJournalURL: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let name = f.string(from: Date()) + ".md"
        return Storage.journalDir.appendingPathComponent(name)
    }

    /// Create the seed taxonomy on disk + an INDEX.md per category.
    /// Idempotent — won't clobber existing INDEX.md.
    static func ensureSeedTree() throws {
        let fm = FileManager.default
        try Storage.ensureExists()
        for cat in seedCategories {
            let dir = categoryDir(cat)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let indexURL = dir.appendingPathComponent("INDEX.md")
            if !fm.fileExists(atPath: indexURL.path) {
                let body = "# \(cat)\n\n_Auto-managed index. Files in this category will be listed here as the classification Agent populates them._\n"
                try body.write(to: indexURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
