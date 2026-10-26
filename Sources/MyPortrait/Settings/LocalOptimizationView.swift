import SwiftUI

/// Settings → Workflow → Local Optimization。Workflow 第 1 层(延后 OCR)的开关、
/// 内存门槛(固定值,只显示)和积压状态。状态由 DeferredOCRWorker 写进 DeferredOCRStatus。
struct LocalOptimizationView: View {
    @State private var config = ConfigStore.shared
    @State private var status = DeferredOCRStatus.shared

    var body: some View {
        SettingsPage("Local Optimization",
                     subtitle: "Workflow runs in steps. Each step finishes before the next one starts.",
                     onResetCurrentPage: { config.mutate { $0.localOptimization = .init() } }) {

            SettingsCard(title: "Step 1 · Screen text") {
                SettingsRow("Read screen text later",
                            description: "Keeps My Portrait light while you work.",
                            info: "Screenshots are saved as they're taken, but the text on them is read later — while the Mac is charging and the screen isn't in use:\n\n• the screen brightness is at zero, or the lid is closed\n• no keyboard or mouse input for 5 minutes\n\nIf more than 5 GB of screenshots are waiting, it also runs whenever the Mac is charging.\n\nEvents, portrait and personality wait until the text of a time range has been read.",
                            icon: "text.viewfinder") {
                    Toggle("", isOn: config.binding(\.localOptimization.deferOCR)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Waiting screenshots", description: backlogText, icon: "photo.stack") {
                    Button("Run now") {
                        Task { await status.worker?.runNow() }
                    }
                    .font(.system(size: 11))
                    .disabled(status.pendingCount == 0 || status.running)
                }
            }

            SettingsCard(title: "Memory") {
                SettingsRow("Minimum free memory",
                            info: "Background work only starts when macOS reports normal memory pressure and at least this much memory can be freed right away. Compressed memory and swap don't count.",
                            icon: "memorychip") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(SystemMemory.minFreeBytes), countStyle: .memory))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
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
