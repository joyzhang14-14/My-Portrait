import SwiftUI

/// Settings → Screen Capture 里的 Screen Text Recognition 卡。Workflow 第 1 层(延后 OCR)的
/// 开关、时机和积压状态。状态由 DeferredOCRWorker 写进 DeferredOCRStatus。
struct ScreenTextRecognitionCard: View {
    @State private var config = ConfigStore.shared
    @State private var status = DeferredOCRStatus.shared

    var body: some View {
        SettingsCard(title: "Screen Text Recognition") {
            SettingsRow("When to OCR",
                        description: backlogText,
                        info: "Screenshots are saved as they're taken; the text on them is read at the time picked here.\n\n• **Always**: read right away, any time.\n• **Only while charging**: any time the Mac is charging.\n• **Only while charging & lid closed**: the lid is closed.\n• **Only while charging & idle**: the lid is closed, the screen brightness is at zero, or there's been no keyboard or mouse input for 5 minutes.\n\nThe last three free around 500 MB of memory while you use the Mac. If more than 5 GB of screenshots are waiting, they run whenever the Mac is charging. OCR only runs when macOS reports normal memory pressure and at least \(minFree) of memory can be freed right away.\n\nEvents, portrait and personality — and anything sent to My Portrait Premium — wait until the text of a time range has been read.",
                        icon: "text.viewfinder") {
                Picker("", selection: whenBinding) {
                    Text("Always").tag(When.always)
                    Text("Only while charging").tag(When.mode(.charging))
                    Text("Only while charging & lid closed").tag(When.mode(.chargingLidClosed))
                    Text("Only while charging & idle").tag(When.mode(.chargingIdle))
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 240)
            }
        }
    }

    /// 四档合成一个下拉:Always = 不延后(deferOCR 关);其余三档 = 延后 + 对应时机。
    private enum When: Hashable {
        case always
        case mode(OCRPowerMode)
    }

    private var whenBinding: Binding<When> {
        Binding(
            get: {
                let c = config.current.capture.screen
                return c.deferOCR ? .mode(c.ocrPowerMode) : .always
            },
            set: { w in
                switch w {
                case .always:
                    config.mutate { $0.capture.screen.deferOCR = false }
                case .mode(let m):
                    config.mutate {
                        $0.capture.screen.deferOCR = true
                        $0.capture.screen.ocrPowerMode = m
                    }
                    // 合盖补 OCR 靠 helper → 改档即幂等注册(未批准则引导系统设置)。
                    SleepHelperClient.shared.enable()
                }
            })
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
