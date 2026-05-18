import AppKit
import Combine

/// macOS 屏幕顶部状态栏的 "Dev Mode" 红点。
///
/// 默认隐藏。当 `UnimplementedReporter.callCount > 0` 时显示，
/// 用户立刻能看到"采集层有 stub 被命中"。
///
/// release build 上线后这个永远不应该出现。一旦看到，立刻查 log。
@MainActor
final class DevModeStatusItem {
    private let item: NSStatusItem
    private var cancellable: AnyCancellable?

    init(reporter: UnimplementedReporter) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = false
        item.button?.title = "🔴 Dev"
        item.button?.toolTip = "Capture layer has unimplemented stubs"

        cancellable = reporter.$callCount.sink { [weak item] count in
            guard let item else { return }
            item.isVisible = count > 0
            item.button?.toolTip = "Unimplemented stubs called \(count)× — see logs"
        }
    }
}
