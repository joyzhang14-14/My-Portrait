import Foundation

/// CLI 入口:从命令行触发写作采集 worker —— UI Run now 的等价物。
///
/// 用法:
///   swift run MyPortrait --writing-capture-run           # 跑所有未处理的天
///   swift run MyPortrait --writing-capture-run YYYY-MM-DD # 跑指定那天
///   swift run MyPortrait --writing-capture-list           # 列 pending_review 的天
///   swift run MyPortrait --writing-capture-approve YYYY-MM-DD
///   swift run MyPortrait --writing-capture-reject  YYYY-MM-DD
///
/// 跟 UI 的 Process writing capture / Pending review 等效。给我(Claude)远程
/// 帮忙测试 / 用户没 codex 额度时用。
enum WritingCaptureCLI {

    // MARK: - 入口

    /// 跑所有未处理的天 → 打印 summary → exit。
    static func run(specificDate: String? = nil) {
        Task {
            do {
                let worker = try await MainActor.run { try makeWorker() }
                let summaries: [WritingCaptureDayRunSummary]
                if let date = specificDate {
                    print("[writing-capture] running specific day: \(date)")
                    let s = try await worker.runDay(date: date)
                    summaries = [s]
                } else {
                    print("[writing-capture] running all unprocessed days…")
                    summaries = try await worker.runUnprocessedDays()
                }
                printSummaries(summaries)
                printStagedRecords(worker: worker, dates: summaries.compactMap {
                    $0.status == .pendingReview ? $0.date : nil
                })
                exit(0)
            } catch {
                fputs("[writing-capture] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// 列 pending_review 状态的天。
    static func list() {
        Task {
            do {
                let worker = try await MainActor.run { try makeWorker() }
                let pending = try worker.store.fetchPendingReviewDays()
                if pending.isEmpty {
                    print("[writing-capture] no days in pending_review")
                } else {
                    print("[writing-capture] \(pending.count) day(s) pending review:")
                    for r in pending {
                        print(formatRunLine(r))
                    }
                }
                exit(0)
            } catch {
                fputs("[writing-capture] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// Approve 某日 staged → writing_records。
    static func approve(date: String) {
        Task {
            do {
                let worker = try await MainActor.run { try makeWorker() }
                let copied = try await worker.approveDay(date: date)
                print("[writing-capture] approved \(date) — \(copied) record(s) moved to writing_records")
                exit(0)
            } catch {
                fputs("[writing-capture] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// Reject 某日:清 staged + 标 rejected_for_rerun。
    static func reject(date: String) {
        Task {
            do {
                let worker = try await MainActor.run { try makeWorker() }
                try await worker.rejectDay(date: date)
                print("[writing-capture] rejected \(date) — staged dropped, will re-run next time")
                exit(0)
            } catch {
                fputs("[writing-capture] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    // MARK: - 实现

    @MainActor
    private static func makeWorker() throws -> WritingCaptureWorker {
        let dbImpl = try PortraitDBImpl()
        let store = WritingCaptureStore(dbPool: dbImpl.dbPool)
        // 让 Worker.shared 也被设上(其他代码可能依赖,虽然 CLI 路径不该用到)
        let worker = WritingCaptureWorker(store: store)
        WritingCaptureWorker.shared = worker
        // 持引用防止 dbImpl 被回收(进程退出前)
        Self.dbHolder = dbImpl
        return worker
    }

    /// CLI 进程生命周期内,持有 dbImpl 防 GC。
    nonisolated(unsafe) private static var dbHolder: PortraitDBImpl?

    // MARK: - 打印

    private static func printSummaries(_ summaries: [WritingCaptureDayRunSummary]) {
        if summaries.isEmpty {
            print("[writing-capture] no unprocessed days — nothing to run")
            return
        }
        print("")
        print("=== Run summary ===")
        for s in summaries {
            var line = "  \(s.date)  status=\(s.status.rawValue)"
                + "  records=\(s.recordsCount)  discarded=\(s.discardedCount)"
            if !s.runId.isEmpty { line += "  run=\(s.runId.prefix(8))" }
            if let err = s.errorMessage { line += "  ERROR=\(err)" }
            print(line)
        }
        print("")
    }

    private static func formatRunLine(_ r: WritingCaptureRun) -> String {
        var line = "  \(r.dateUtc)  status=\(r.status)"
        if let n = r.recordsCount { line += "  records=\(n)" }
        if let n = r.discardedCount { line += "  discarded=\(n)" }
        if let id = r.runId { line += "  run=\(id.prefix(8))" }
        if let err = r.errorMessage { line += "  ERROR=\(err)" }
        return line
    }

    /// 跑完后 dump 每个 pending_review 天的 staged records,给我看 LLM 输出对不对。
    private static func printStagedRecords(worker: WritingCaptureWorker, dates: [String]) {
        guard !dates.isEmpty else { return }
        for date in dates {
            do {
                let rows = try worker.store.fetchStagedRecords(date: date)
                print("=== Staged records · \(date) (\(rows.count)) ===")
                if rows.isEmpty {
                    print("  (no records)")
                    continue
                }
                for (i, row) in rows.enumerated() {
                    print("--- [\(i + 1)/\(rows.count)] ---")
                    print("  app:        \(row.app)")
                    if let u = row.url, !u.isEmpty { print("  url:        \(u)") }
                    print("  source:     \(row.source)")
                    print("  confidence: \(String(format: "%.2f", row.confidence))")
                    if let cs = row.contextSummary, !cs.isEmpty {
                        print("  context:    \(cs)")
                    }
                    print("  time:       \(row.startTs) ~ \(row.endTs) (UTC ms)")
                    let preview = row.text.count > 400
                        ? String(row.text.prefix(400)) + "…(truncated, total \(row.text.count) chars)"
                        : row.text
                    print("  text:       \(preview)")
                    print("  edit_log:   \(row.editLog.count) chars JSON")
                }
            } catch {
                fputs("[writing-capture] failed to read staged for \(date): \(error)\n", stderr)
            }
        }
        print("")
        print("Approve / Reject via UI(Settings → Memory → Scheduler → Pending review)")
        print("或者 CLI:swift run MyPortrait --writing-capture-{approve,reject} \(dates.first ?? "<date>")")
    }
}
