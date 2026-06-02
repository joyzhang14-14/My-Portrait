import Foundation

/// CLI 入口:从命令行触发 writing_style 提炼 —— UI Run 按钮的等价物。
///
/// 用法:
///   swift run MyPortrait --writing-style-run --manual   # staged + pending review
///   swift run MyPortrait --writing-style-run --auto     # 直接落 portrait/writing_style/
///   swift run MyPortrait --writing-style-list           # 列 pending_review 的 run
///   swift run MyPortrait --writing-style-approve <runId>
///   swift run MyPortrait --writing-style-reject  <runId>
enum WritingStyleCLI {

    static func run(mode: WritingStyleMode) {
        Task {
            do {
                let distiller = try await MainActor.run { try makeDistiller() }
                print("[writing-style] running mode=\(mode.rawValue)…")
                let summary = try await runOnDistiller(distiller, mode: mode)
                printSummary(summary)
                if summary.status == .pendingReview {
                    let store = distiller.store
                    let drafts = try store.fetchStaged(runId: summary.runId)
                    printDrafts(drafts)
                }
                exit(0)
            } catch {
                fputs("[writing-style] ERROR: \(error.localizedDescription)\n", stderr)
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
                    print("[writing-style] no runs in pending_review")
                } else {
                    print("[writing-style] \(pending.count) run(s) pending review:")
                    for r in pending {
                        let ts = Date(timeIntervalSince1970: TimeInterval(r.startedAt) / 1000)
                        print("  run=\(r.runId.prefix(8))  started=\(ts)  records=\(r.recordsCount ?? 0)  drafts=\(r.draftsCount ?? 0)")
                    }
                }
                exit(0)
            } catch {
                fputs("[writing-style] ERROR: \(error.localizedDescription)\n", stderr)
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
                print("[writing-style] approved \(runId.prefix(8)) — \(n) draft(s) applied to portrait/writing_style/")
                exit(0)
            } catch {
                fputs("[writing-style] ERROR: \(error.localizedDescription)\n", stderr)
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
                print("[writing-style] rejected \(runId.prefix(8)) — staged cleared, records left unprocessed")
                exit(0)
            } catch {
                fputs("[writing-style] ERROR: \(error.localizedDescription)\n", stderr)
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
        _ distiller: WritingStyleDistiller, mode: WritingStyleMode
    ) async throws -> WritingStyleRunSummary {
        switch mode {
        case .manual: return try await distiller.runManual()
        case .auto:   return try await distiller.runAuto()
        }
    }

    @MainActor
    private static func makeDistiller() throws -> WritingStyleDistiller {
        let dbImpl = try PortraitDBImpl()
        let store = WritingStyleStore(dbPool: dbImpl.dbPool)
        Self.dbHolder = dbImpl
        return WritingStyleDistiller(store: store)
    }

    nonisolated(unsafe) private static var dbHolder: PortraitDBImpl?

    // MARK: - 打印

    private static func printSummary(_ s: WritingStyleRunSummary) {
        print("")
        print("=== Run summary ===")
        print("  run=\(s.runId.prefix(8))  mode=\(s.mode.rawValue)  status=\(s.status.rawValue)")
        print("  records=\(s.recordsCount)  drafts=\(s.draftsCount)")
        if let err = s.errorMessage { print("  ERROR=\(err)") }
        print("")
    }

    private static func printDrafts(_ rows: [WritingStyleStagedRow]) {
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
        print("  swift run MyPortrait --writing-style-approve <runId>")
        print("  swift run MyPortrait --writing-style-reject  <runId>")
    }
}
