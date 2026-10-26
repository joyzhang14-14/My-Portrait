import SwiftUI

/// Settings → Workflow → Local Optimization。Workflow 第 1 层(延后 OCR)的开关和积压状态。
/// 状态由 DeferredOCRWorker 写进 DeferredOCRStatus。
struct LocalOptimizationView: View {
    @State private var config = ConfigStore.shared
    @State private var status = DeferredOCRStatus.shared

    var body: some View {
        SettingsPage("Local Optimization",
                     subtitle: "Workflow runs in steps. Each step finishes before the next one starts.",
                     onResetCurrentPage: { config.mutate { $0.localOptimization = .init() } }) {

            SettingsCard(title: "Step 1 · Screen text") {
                SettingsRow("Run OCR engine while idle",
                            description: backlogText,
                            info: "**Frees around 500 MB of memory while the app is running.**\n\nScreenshots are saved as they're taken, but the text on them is read later — while the Mac is charging and the screen isn't in use:\n\n• the screen brightness is at zero, or the lid is closed\n• no keyboard or mouse input for 5 minutes\n\nIf more than 5 GB of screenshots are waiting, it also runs whenever the Mac is charging.\n\nIt only runs when macOS reports normal memory pressure and at least \(minFree) of memory can be freed right away. Compressed memory and swap don't count.\n\nTurn this off to read all waiting screenshots right away.\n\nEvents, portrait and personality wait until the text of a time range has been read.",
                            icon: "text.viewfinder") {
                    Toggle("", isOn: config.binding(\.localOptimization.deferOCR)).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var minFree: String {
        ByteCountFormatter.string(fromByteCount: Int64(SystemMemory.minFreeBytes), countStyle: .memory)
    }

    private var backlogText: String {
        if status.pendingCount == 0 { return "All caught up." }
        let size = ByteCountFormatter.string(fromByteCount: status.backlogBytes, countStyle: .file)
        var parts = ["\(status.pendingCount) screenshot\(status.pendingCount == 1 ? "" : "s") · \(size)"]
        if let oldest = status.oldestMs {
            let date = Date(timeIntervalSince1970: TimeInterval(oldest) / 1000)
            parts.append("oldest \(date.formatted(.relative(presentation: .named)))")
        }
        if status.running {
            parts.append("reading now")
        } else if let reason = status.waitingReason {
            parts.append(reason.prefix(1).lowercased() + reason.dropFirst())
        }
        return parts.joined(separator: " · ")
    }
}
