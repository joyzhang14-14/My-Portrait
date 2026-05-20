/// TypingStatusItem —— 菜单栏常驻的 Typing 采集暂停开关。
///
/// 一个 NSStatusItem，点击直接 toggle `recording.typingCapturePaused`：
///   - 采集中 = 亮色 `keyboard` 图标
///   - 暂停   = 带感叹号的 `keyboard.badge.exclamationmark` 图标 + dimmed 灰
///
/// 暂停状态的单一真相是 ConfigStore（持久化到 TOML、跨重启保留）。本类只是
/// 它的视图 + 一个写入口。vim 改 TOML / 别处改也要同步图标 —— 用
/// `withObservationTracking` 递归重注册监听（同款于 CaptureSettings）。

import AppKit
import Foundation

@MainActor
final class TypingStatusItem {

    /// 菜单栏常驻 item。install() 时创建，remove() 时移除。
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
        }
        statusItem = item
        refreshIcon()
        startObservingConfig()
    }

    func remove() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// 点击 statusItem —— 直接翻转暂停标志。ConfigStore.mutate 会持久化 TOML
    /// 并触发 withObservationTracking → refreshIcon。
    @objc private func toggle() {
        ConfigStore.shared.mutate { $0.recording.typingCapturePaused.toggle() }
        refreshIcon()
    }

    /// 用 Observation 框架追踪 `typingCapturePaused`。变化（vim 改 TOML /
    /// 别处改）→ 刷新图标。withObservationTracking 是一次性的，onChange 里递归重注册。
    private func startObservingConfig() {
        let store = ConfigStore.shared
        withObservationTracking {
            _ = store.recording.typingCapturePaused
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshIcon()
                self.startObservingConfig()
            }
        }
    }

    /// 按当前暂停状态刷新图标 + tooltip。
    ///   active → `keyboard`，亮色（默认 contentTintColor）
    ///   paused → `keyboard.badge.exclamationmark`，灰色 dimmed
    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let paused = ConfigStore.shared.recording.typingCapturePaused
        let symbol = paused ? "keyboard.badge.exclamationmark" : "keyboard"
        let desc = paused ? "Typing capture: paused" : "Typing capture: active"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        image?.isTemplate = true   // template 随菜单栏样式自动着色
        button.image = image
        button.contentTintColor = paused ? .disabledControlTextColor : nil
        button.toolTip = desc
    }
}
