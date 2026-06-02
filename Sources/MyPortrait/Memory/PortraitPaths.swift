import Foundation

/// Path helpers for the portrait tree. Storage.swift defines the top-level
/// directories; this layer knows about the subfolder taxonomy described in
/// design doc 五（personality / social / skills / …）.
enum PortraitPaths {
    /// The top-level categories we ship with — used for directory seeding +
    /// sidebar UI. New ones can appear later via the classification Agent.
    static let seedCategories: [String] = [
        "personality", "social", "background", "experiences",
        "interests", "writing_style", "skills", "emotions"
    ]

    /// Categories the generic PortraitDistiller loops over — `seedCategories`
    /// MINUS `personality` and `writing_style`. personality is driven by the
    /// independent PersonalityAgent / PersonalityMerger pipeline；writing_style
    /// 由独立的 writing-style 提炼链路负责。两类都要避免被通用 distiller 覆写。
    static let distillCategories: [String] = seedCategories.filter {
        $0 != "personality" && $0 != "writing_style"
    }

    static func categoryDir(_ name: String) -> URL {
        Storage.portraitDir.appendingPathComponent(name, isDirectory: true)
    }

    /// 一次性迁移:portrait/speech_style/ → portrait/writing_style/。
    ///
    /// 1.2.x 之前 writing-style 链路叫 speech_style,文件夹 + 每个 .md 的
    /// frontmatter(category / source / tags)都写死了旧名。改名后启动跑一次:
    /// 把老文件夹内容并进新文件夹,再把所有 .md 里残留的 "speech_style" 改
    /// "writing_style"。幂等:老文件夹没了 + 无残留 frontmatter 即 no-op。
    /// 配套 DB 迁移见 Schema v36,config 旧 key 回退见 ConfigSchema。
    static func migrateSpeechStyleToWritingStyle() {
        let fm = FileManager.default
        let old = Storage.portraitDir.appendingPathComponent("speech_style", isDirectory: true)
        let new = Storage.portraitDir.appendingPathComponent("writing_style", isDirectory: true)

        // 1) 搬文件:老文件夹在就把每个条目并进新文件夹。目标已存在(部分迁移
        //    过)→ 保留新的、跳过老的,不覆盖、不强删用户内容。
        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
            for name in items {
                let src = old.appendingPathComponent(name)
                let dst = new.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
            // 全部搬空了才删空的老文件夹(还有残留就留着)
            if let rest = try? fm.contentsOfDirectory(atPath: old.path), rest.isEmpty {
                try? fm.removeItem(at: old)
            }
        }

        // 2) 重写 frontmatter:递归把 writing_style/ 下所有 .md 里的
        //    "speech_style" 改 "writing_style"(category / source / tags)。只动
        //    含旧名的文件,幂等。
        guard fm.fileExists(atPath: new.path),
              let en = fm.enumerator(at: new, includingPropertiesForKeys: nil)
        else { return }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("speech_style") else { continue }
            let fixed = text.replacingOccurrences(of: "speech_style", with: "writing_style")
            try? fixed.write(to: url, atomically: true, encoding: .utf8)
        }
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
