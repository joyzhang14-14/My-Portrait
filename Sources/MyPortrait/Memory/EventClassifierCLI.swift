import Foundation

/// CLI 入口:**Dry-run** event classifier — 跑一遍但不写任何 _folders/*.json。
/// 看 LLM 会怎么分,有问题随手回滚。
///
/// 用法:
///   swift run MyPortrait --classify-dry-run
///
/// 退出码:
///   0 = 跑通(无论 LLM 提了多少分组)
///   1 = 报错(spawn / timeout / 解析失败)
enum EventClassifierCLI {

    static func dryRun() {
        Task {
            do {
                try await runImpl()
                exit(0)
            } catch {
                fputs("[classify-dry-run] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// 真跑(写盘)入口。等价于 UI Run now 按钮 —— 调 scheduler runClassifierJob,
    /// 它会持锁 + 心跳 + 自动循环到 unclassified 清空。结果同时落进
    /// MemoryScheduler.lastClassifyResult,UI 打开 Memory→Scheduler 就能看见。
    static func runAll() {
        Task {
            do {
                try await runAllImpl()
                exit(0)
            } catch {
                fputs("[classify-run] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    @MainActor
    private static func runAllImpl() async throws {
        print("[classify-run] kicking MemoryScheduler.runClassifierJob…")
        let outcome = await MemoryScheduler.shared.runClassifierJob()
        switch outcome {
        case .busy:
            print("[classify-run] scheduler reports busy — another classify task is already running")
            return
        case .noWork:
            print("[classify-run] no unclassified events — nothing to do")
            return
        case .ran:
            guard let r = MemoryScheduler.shared.lastClassifyResult else {
                print("[classify-run] ran but no result was recorded (likely failed mid-run — see scheduler log)")
                return
            }
            print("")
            print("=== classify-run summary ===")
            print("total-unclassified-at-start: \(r.totalUnclassified)")
            print("classified-this-run:        \(r.classifiedInThisRun)")
            print("new-folders-created:        \(r.newFoldersCreated)")
            print("existing-folders-updated:   \(r.existingFoldersUpdated)")
            print("still-ungrouped:            \(r.stillUngrouped)")
            print("")
            print("=== folder deltas (sorted by count) ===")
            for d in r.folderDeltas {
                let marker = d.kind == .created ? "NEW    " : "UPDATED"
                print("  \(marker)  \(d.name.padding(toLength: 32, withPad: " ", startingAt: 0))  +\(d.addedCount)")
            }
            print("")
            print("Folders live at: ~/.portrait/events/_folders/*.json")
        }
    }

    @MainActor
    private static func runImpl() async throws {
        // 用跟 scheduler 一样的 provider/model。
        let cfg = ConfigStore.shared.current.memory
        let classifier = EventClassifierDryRunner(
            provider: cfg.resolvedProvider,
            model: cfg.resolvedModel
        )
        let decision = try await classifier.dryRun()

        print("")
        print("=== EventClassifier dry-run ===")
        print("provider=\(cfg.resolvedProvider.rawValue)  model=\(cfg.resolvedModel)")
        print("classified-already=\(decision.alreadyClassifiedCount)")
        print("unclassified-total=\(decision.totalUnclassified)")
        print("batched-this-run=\(decision.batchedThisRun)")
        print("existing-folders=\(decision.existingFolders.count)")
        for f in decision.existingFolders {
            print("  · \(f.name)  (slug=\(f.slug), \(f.count) events)")
        }
        print("")
        print("=== LLM decision ===")
        if decision.appendToExisting.isEmpty && decision.newFolders.isEmpty {
            print("  (LLM proposed no changes)")
        }
        if !decision.appendToExisting.isEmpty {
            print("append-to-existing:")
            for a in decision.appendToExisting {
                print("  → folder=\(a.folderSlug)  count=\(a.eventPaths.count)")
                for p in a.eventPaths.prefix(20) {
                    print("      \(p)")
                }
                if a.eventPaths.count > 20 {
                    print("      ... (\(a.eventPaths.count - 20) more)")
                }
            }
        }
        if !decision.newFolders.isEmpty {
            print("new-folders:")
            for n in decision.newFolders {
                let marker = n.eventPaths.count >= EventClassifier.defaultMinNewFolderEvents
                    ? "✓ CREATE" : "✗ skip (below threshold)"
                print("  \(marker)  name=\"\(n.name)\"  count=\(n.eventPaths.count)")
                print("      desc: \(n.description)")
                for p in n.eventPaths.prefix(20) {
                    print("      \(p)")
                }
                if n.eventPaths.count > 20 {
                    print("      ... (\(n.eventPaths.count - 20) more)")
                }
            }
        }
        print("")
        print("Estimated leftover ungrouped after this run: \(decision.estimatedLeftover)")
        print("")
        print("(dry-run: nothing written to disk)")
    }
}

/// EventClassifier 的"只跑 LLM、不落盘"包装。跟生产 EventClassifier 共用
/// scan + prompt + parse,只把最后一步 `EventFolderStore.save` 拿掉,改成
/// 返回 LLM 的原始决议给 CLI 打印。
///
/// 不动 EventClassifier 本身 → 生产路径完全不变,dry-run 跟它 100% 同源。
@MainActor
private final class EventClassifierDryRunner {

    struct DryRunDecision {
        let alreadyClassifiedCount: Int
        let totalUnclassified: Int
        let batchedThisRun: Int
        let existingFolders: [EventFolder]
        let appendToExisting: [Assignment]
        let newFolders: [NewFolderSpec]
        let estimatedLeftover: Int

        struct Assignment { let folderSlug: String; let eventPaths: [String] }
        struct NewFolderSpec { let name: String; let description: String; let eventPaths: [String] }
    }

    private let classifier: EventClassifier

    init(provider: Provider, model: String) {
        self.classifier = EventClassifier(provider: provider, model: model)
    }

    /// dry-run:跟 EventClassifier.classify() 走 90% 同样的步骤,最后一步落盘
    /// 替换成返回 raw decision。
    func dryRun() async throws -> DryRunDecision {
        let scan = classifier.dryRunScan()
        let existing = EventFolderStore.loadAll()
        // 没活就早退。
        guard !scan.unclassified.isEmpty else {
            return DryRunDecision(
                alreadyClassifiedCount: scan.classifiedCount,
                totalUnclassified: 0,
                batchedThisRun: 0,
                existingFolders: existing,
                appendToExisting: [],
                newFolders: [],
                estimatedLeftover: 0
            )
        }
        let batch = Array(scan.unclassified.prefix(classifier.batchCap))
        let raw = try await classifier.dryRunLLM(unclassified: batch,
                                                  existingFolders: existing)
        // 算 leftover:本批 LLM 没提到的 + new folder 不到阈值的。
        let proposedPaths: Set<String> = {
            var s = Set<String>()
            for a in raw.appendToExisting { for p in a.eventPaths { s.insert(p) } }
            for n in raw.newFolders where n.eventPaths.count >= classifier.minEventsForNewFolder {
                for p in n.eventPaths { s.insert(p) }
            }
            return s
        }()
        let batchPaths = Set(batch.map(\.path))
        let leftoverThisRun = batchPaths.subtracting(proposedPaths).count
        let beyondBatch = scan.unclassified.count - batch.count

        return DryRunDecision(
            alreadyClassifiedCount: scan.classifiedCount,
            totalUnclassified: scan.unclassified.count,
            batchedThisRun: batch.count,
            existingFolders: existing,
            appendToExisting: raw.appendToExisting.map {
                .init(folderSlug: $0.folderSlug, eventPaths: $0.eventPaths)
            },
            newFolders: raw.newFolders.map {
                .init(name: $0.name, description: $0.description, eventPaths: $0.eventPaths)
            },
            estimatedLeftover: leftoverThisRun + beyondBatch
        )
    }
}
