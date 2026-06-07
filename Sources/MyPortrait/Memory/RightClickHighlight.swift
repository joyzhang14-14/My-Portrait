import SwiftUI
import AppKit

/// 右键(及 ctrl-左键)弹 contextMenu 时,给被点的行套一圈蓝框 —— 像 Finder
/// 右键文件那样明确"菜单作用在这一项"。SwiftUI 的 `.contextMenu` 没有
/// open/close 回调,所以自己用一个透明 AppKit 探测层捕获 rightMouseDown /
/// ctrl+leftMouseDown,翻 `active`;菜单关闭后(NSView 收到 menuDidClose,
/// 或下一次别处右键)清掉。
///
/// 用法:
///   row
///     .contextHighlight(cornerRadius: 8) { theMenuContent }
/// 内部已经挂了 `.contextMenu`,调用方只给菜单内容,不用再单独 `.contextMenu`。
extension View {
    func contextHighlight<M: View>(
        cornerRadius: CGFloat = 8,
        @ViewBuilder menu: () -> M
    ) -> some View {
        modifier(ContextHighlightModifier(cornerRadius: cornerRadius, menu: menu()))
    }
}

private struct ContextHighlightModifier<M: View>: ViewModifier {
    let cornerRadius: CGFloat
    let menu: M
    @State private var active = false

    func body(content: Content) -> some View {
        content
            .background(RightClickProbe(active: $active))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.accent, lineWidth: active ? 2 : 0)
            )
            .contextMenu { menu }
    }
}

/// 透明覆盖层:捕获自身区域内的右键 / ctrl-左键按下 → 翻 active=true;
/// 它挂的菜单关闭时翻回 false。**只探测,不吞事件** —— hitTest 返回 nil
/// 让点击继续透传给底下的 SwiftUI 行(选中 / 展开照常工作)。
private struct RightClickProbe: NSViewRepresentable {
    @Binding var active: Bool

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = { active = $0 }
        return v
    }
    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { active = $0 }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?

        // 不参与 hit-test:鼠标事件穿透到底下 SwiftUI,左键选中/展开不受影响。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // 全局监听:right-down 或 ctrl+left-down 落在本 view 区域内 → 高亮;
        // 任意 mouse-down 落在区域外 → 取消高亮(点别处 / 菜单关掉)。
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { teardown(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] ev in
                guard let self, let win = self.window, ev.window == win else { return ev }
                let p = self.convert(ev.locationInWindow, from: nil)
                let inside = self.bounds.contains(p)
                let isContext = ev.type == .rightMouseDown
                    || (ev.type == .leftMouseDown && ev.modifierFlags.contains(.control))
                if inside, isContext {
                    self.onChange?(true)
                } else {
                    // 点到别处(含菜单消失后点空白 / 切到别的行)→ 取消高亮。
                    self.onChange?(false)
                }
                return ev   // 不吞,原样放行
            }
        }

        private func teardown() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            onChange?(false)
        }
        deinit { teardown() }
    }
}
