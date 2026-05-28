import SwiftUI
import AppKit

/// Chat 输入框 —— SwiftUI 的 TextField(axis: .vertical) 行为是高度跟内容
/// 拉,设了 maxHeight 后空白时仍占满。**用户要的是:框矮(2 行左右),
/// 内容多了内部 NSScrollView 滚,可双指拖**。原生 NSTextView in NSScrollView
/// 是这个 UX 的标准做法,SwiftUI 包一层 NSViewRepresentable 暴露 binding。
///
/// 行为:
///   - 高度由父布局给 `.frame(...)` 决定;内部 NSTextView 不影响外部高度
///   - 内容 > 可视高度 → 自动出滚条 + 鼠标 / 触控板可滚
///   - Enter 提交(通过 onSubmit 回调);Shift+Enter 换行
///   - placeholder 内联绘制(NSTextView 没原生 placeholder)
///   - IME(中/日/韩 候选输入)期间 Enter 让给 IME,不触发 submit
struct ChatInputTextView: NSViewRepresentable {

    @Binding var text: String
    /// NSTextView 测出的内容自然高度,回报给 SwiftUI。外部用它做 frame ——
    /// 空 = 单行,内容增长跟着涨,封顶交给外部 maxHeight 限制(4 行)。
    @Binding var measuredHeight: CGFloat
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 14)
    var onSubmit: () -> Void
    /// 文本任何变化时调一次。用来嗅探 "@" → 弹 picker。
    var onTextChange: ((_ old: String, _ new: String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay

        let textView = PaddedTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.delegate = context.coordinator
        textView.placeholderString = placeholder
        textView.placeholderColor = NSColor.labelColor.withAlphaComponent(0.30)
        textView.coordinator = context.coordinator
        // 自动换行:跟着 scrollView 的 contentSize 走。
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PaddedTextView else { return }
        // 外部 binding 改了文字 —— 同步进 textView。避免在用户输入时反复
        // 写回触发死循环:仅当差异时更新。
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
        }
        tv.placeholderString = placeholder
        tv.font = font
        reportMeasuredHeight(tv)
    }

    private func reportMeasuredHeight(_ tv: PaddedTextView) {
        DispatchQueue.main.async {
            let h = tv.naturalContentHeight()
            if abs(h - measuredHeight) > 0.5 {
                measuredHeight = h
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        init(_ parent: ChatInputTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let old = parent.text
            let new = tv.string
            // 同步到 SwiftUI binding。
            parent.text = new
            parent.onTextChange?(old, new)
            tv.needsDisplay = true   // 让 placeholder 重绘
            if let padded = tv as? PaddedTextView {
                parent.reportMeasuredHeight(padded)
            }
        }

        /// Enter / Return → submit。Shift+Return / Option+Return → 换行。
        /// IME 候选输入中(hasMarkedText())不拦,让事件给 IME。
        func textView(_ textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(self)
                    return true
                }
                if textView.hasMarkedText() { return false }   // IME 选词
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// NSTextView 子类 —— 自己画 placeholder,因为 NSTextView 没原生 placeholder
/// 字段(NSTextField 才有)。
final class PaddedTextView: NSTextView {
    var placeholderString: String = ""
    var placeholderColor: NSColor = .placeholderTextColor
    weak var coordinator: ChatInputTextView.Coordinator?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: placeholderColor,
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: inset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }

    /// 算当前内容的自然渲染高度(含上下 inset)。空 = 单行高 + inset。
    /// 外部 SwiftUI frame 拿这值 clamp 到 [singleLine, 4*line]。
    func naturalContentHeight() -> CGFloat {
        let f = font ?? NSFont.systemFont(ofSize: 14)
        let singleLine = ceil(f.ascender - f.descender + f.leading)
        let insetH = textContainerInset.height * 2
        guard let layout = layoutManager, let container = textContainer else {
            return singleLine + insetH
        }
        // 强制 layout 当前所有 glyphs,再问 used rect。
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let textHeight = max(used.height, singleLine)
        return ceil(textHeight + insetH)
    }
}
