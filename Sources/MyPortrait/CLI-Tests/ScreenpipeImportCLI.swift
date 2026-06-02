import Foundation

/// CLI 入口:从 ~/.screenpipe(或指定路径)把 frames + audio transcripts
/// 搬到 My-Portrait。只导比 My-Portrait 最早数据老的部分,不动现有数据。
///
/// 用法:
///   swift run MyPortrait --import-screenpipe
///   swift run MyPortrait --import-screenpipe /Custom/Path/.screenpipe
enum ScreenpipeImportCLI {

    static func run(sourcePath: String? = nil) {
        Task {
            do {
                let sourceURL: URL = sourcePath.map { URL(fileURLWithPath: $0) }
                    ?? ScreenpipeImporter.defaultSourceDir
                let dbImpl = try await MainActor.run { try PortraitDBImpl() }
                Self.dbHolder = dbImpl

                print("[screenpipe-import] source: \(sourceURL.path)")
                print("[screenpipe-import] scanning…")
                let importer = ScreenpipeImporter(sourceDir: sourceURL)
                let r = try await importer.run(into: dbImpl.dbPool)
                printReport(r)
                exit(0)
            } catch {
                fputs("[screenpipe-import] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    nonisolated(unsafe) private static var dbHolder: PortraitDBImpl?

    private static func printReport(_ r: ScreenpipeImporter.Report) {
        let cutoffStr: String
        if let ms = r.cutoffMs {
            let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            cutoffStr = "\(d) (\(ms) ms)"
        } else {
            cutoffStr = "no cutoff (My-Portrait empty, imported everything)"
        }
        print("")
        print("=== Import summary ===")
        print("  cutoff:                \(cutoffStr)")
        print("  frames imported:       \(r.framesImported)")
        print("  frames skipped (no OCR): \(r.skippedFramesNoOCR)")
        print("  audio chunks imported: \(r.audioChunksImported)")
        print("  audio transcripts:     \(r.audioTranscriptsImported)")
        if let err = r.errorMessage { print("  ERROR: \(err)") }
        print("")
        print("Next:  Settings → Memory → Scheduler → Process events (will pick up new data).")
    }
}
