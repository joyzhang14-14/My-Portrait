import Foundation

/// CLI 入口:从命令行触发 speech_style 提炼 —— UI Run 按钮的等价物。
///
/// 用法:
///   swift run MyPortrait --speech-style-run --manual   # staged + pending review
///   swift run MyPortrait --speech-style-run --auto     # 直接落 portrait/speech_style/
///   swift run MyPortrait --speech-style-list           # 列 pending_review 的 run
///   swift run MyPortrait --speech-style-approve <runId>
///   swift run MyPortrait --speech-style-reject  <runId>
enum SpeechStyleCLI {

    static func run(mode: SpeechStyleMode) {
        Task {
            do {
                let distiller = try await MainActor.run { try makeDistiller() }
                print("[speech-style] running mode=\(mode.rawValue)…")
                let summary = try await runOnDistiller(distiller, mode: mode)
                printSummary(summary)
                if summary.status == .pendingReview {
                    let store = distiller.store
                    let drafts = try store.fetchStaged(runId: summary.runId)
                    printDrafts(drafts)
                }
                exit(0)
            } catch {
                fputs("[speech-style] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func list() {
        Task {
            do {
                let distiller = try await MainActor.run { try makeDistiller() }
                let pending = try distiller.store.fetchPendingReviewRuns()
                if pending.isEmpty {
                    print("[speech-style] no runs in pending_review")
                } else {
                    print("[speech-style] \(pending.count) run(s) pending review:")
                    for r in pending {
                        let ts = Date(timeIntervalSince1970: TimeInterval(r.startedAt) / 1000)
                        print("  run=\(r.runId.prefix(8))  started=\(ts)  records=\(r.recordsCount ?? 0)  drafts=\(r.draftsCount ?? 0)")
                    }
                }
                exit(0)
            } catch {
                fputs("[speech-style] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func approve(runId: String) {
        Task {
            do {
                let distiller = try await MainActor.run { try makeDistiller() }
                let n = try await MainActor.run { try distiller.approveStaged(runId: runId) }
                print("[speech-style] approved \(runId.prefix(8)) — \(n) draft(s) applied to portrait/speech_style/")
                exit(0)
            } catch {
                fputs("[speech-style] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func reject(runId: String) {
        Task {
            do {
                let distiller = try await MainActor.run { try makeDistiller() }
                try await MainActor.run { try distiller.rejectStaged(runId: runId) }
                print("[speech-style] rejected \(runId.prefix(8)) — staged cleared, records left unprocessed")
                exit(0)
            } catch {
                fputs("[speech-style] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    // MARK: - 实现

    /// MainActor + async 隔离调起 distiller.run* 的胶水。CLI 里两条路径同样
    /// 是 throws,各 case 单独 await 一次。
    @MainActor
    private static func runOnDistiller(
        _ distiller: SpeechStyleDistiller, mode: SpeechStyleMode
    ) async throws -> SpeechStyleRunSummary {
        switch mode {
        case .manual: return try await distiller.runManual()
        case .auto:   return try await distiller.runAuto()
        }
    }

    @MainActor
    private static func makeDistiller() throws -> SpeechStyleDistiller {
        let dbImpl = try PortraitDBImpl()
        let store = SpeechStyleStore(dbPool: dbImpl.dbPool)
        Self.dbHolder = dbImpl
        return SpeechStyleDistiller(store: store)
    }

    nonisolated(unsafe) private static var dbHolder: PortraitDBImpl?

    // MARK: - 打印

    private static func printSummary(_ s: SpeechStyleRunSummary) {
        print("")
        print("=== Run summary ===")
        print("  run=\(s.runId.prefix(8))  mode=\(s.mode.rawValue)  status=\(s.status.rawValue)")
        print("  records=\(s.recordsCount)  drafts=\(s.draftsCount)")
        if let err = s.errorMessage { print("  ERROR=\(err)") }
        print("")
    }

    private static func printDrafts(_ rows: [SpeechStyleStagedRow]) {
        print("=== Staged drafts (\(rows.count)) ===")
        for (i, r) in rows.enumerated() {
            print("--- [\(i + 1)/\(rows.count)] ---")
            print("  action: \(r.action.rawValue)")
            print("  slug:   \(r.slug)\(r.existingSlug.map { " (was \($0))" } ?? "")")
            print("  title:  \(r.title)")
            print("  source_record_ids: \(r.sourceRecordIds.count) ids")
            let preview = r.body.count > 400
                ? String(r.body.prefix(400)) + "…(truncated, total \(r.body.count) chars)"
                : r.body
            print("  body:")
            for line in preview.split(separator: "\n", omittingEmptySubsequences: false) {
                print("    \(line)")
            }
        }
        print("")
        print("Approve / Reject:")
        print("  swift run MyPortrait --speech-style-approve <runId>")
        print("  swift run MyPortrait --speech-style-reject  <runId>")
    }
}
