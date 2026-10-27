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
                            info: "**Frees around 500 MB of memory while the app is running.**\n\nScreenshots are saved as they're taken, but the text on them is read later, at the time picked below.\n\nIt only runs when macOS reports normal memory pressure and at least \(minFree) of memory can be freed right away. Compressed memory and swap don't count.\n\nTurn this off to read all waiting screenshots right away.\n\nEvents, portrait and personality wait until the text of a time range has been read.",
                            icon: "text.viewfinder") {
                    Toggle("", isOn: config.binding(\.localOptimization.deferOCR)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Schedule") {
                SettingsRow("When to run OCR",
                            info: "• **Charging**: any time the Mac is charging.\n• **Charging & lid closed**: the lid is closed or the screen brightness is at zero.\n• **Charging & idle**: also when there's been no keyboard or mouse input for 5 minutes.\n\nIf more than 5 GB of screenshots are waiting, it runs whenever the Mac is charging. With the lid closed it keeps running via a background helper.",
                            icon: "powerplug") {
                    Picker("", selection: config.binding(\.localOptimization.ocrPowerMode)) {
                        Text("Only while charging").tag(OCRPowerMode.charging)
                        Text("Only while charging & lid closed").tag(OCRPowerMode.chargingLidClosed)
                        Text("Only while charging & idle").tag(OCRPowerMode.chargingIdle)
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 240)
                    .onChange(of: config.current.localOptimization.ocrPowerMode) { _, _ in
                        // 合盖补 OCR 靠 helper → 改档即幂等注册(未批准则引导系统设置)。
                        SleepHelperClient.shared.enable()
                    }
                }
            }
            .disabled(!config.current.localOptimization.deferOCR)
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
