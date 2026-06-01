import Foundation

/// CLI 等价于 UI Memory → Scheduler → Run Events 按钮 —— 走 staging,
/// 跑完结果在 .staging/events_backup,**不入库**,等用户在 UI 上 Approve/Reject。
///
/// 用法:
///   ./MyPortrait --event-staged
///
/// 退出码:
///   0 = 跑通(结果待审)/  noWork(无活直接退)
///   2 = pending 已存在(上次 staged run 没审)
///   1 = scheduler busy / 其他错误
enum EventJobStagedCLI {

    static func run() {
        Task {
            do {
                try await runImpl()
                exit(0)
            } catch let exitErr as ExitError {
                fputs("[event-staged] \(exitErr.msg)\n", stderr)
                exit(exitErr.code)
            } catch {
                fputs("[event-staged] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private struct ExitError: Error { let code: Int32; let msg: String }

    @MainActor
    private static func runImpl() async throws {
        // 拒绝条件:已有 pending review,UI 还没拍板,不该再跑覆盖。
        if MemoryStaging.hasPending(.events) {
            throw ExitError(code: 2, msg: "events kind has pending review — Approve/Reject in UI first.")
        }
        guard MemoryScheduler.shared.eventJobHasWork() else {
            print("[event-staged] no pending days — nothing to do.")
            return
        }

        try MemoryStaging.beginRun(.events)
        print("[event-staged] beginRun OK — backup at ~/.portrait/.staging/events_backup")
        print("[event-staged] running scheduler.runEventJob…")

        let outcome = await MemoryScheduler.shared.runEventJob()
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.events, days: days)
            print("[event-staged] ✅ run complete — \(days.count) day(s): \(days.joined(separator: ", "))")
            print("[event-staged] open UI → Memory → Scheduler → Pending review to Approve or Reject.")
        case .noWork:
            try? MemoryStaging.approve(.events)
            print("[event-staged] no work — staging discarded.")
        case .busy:
            try? MemoryStaging.approve(.events)
            throw ExitError(code: 1, msg: "scheduler reports busy — another job already running.")
        }
    }
}
