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
    /// 粘贴 / 拖拽进来一组 attachment(图片字节 + 文件 URL 混合)。
    /// SwiftUI 那边把这些 append 到 `attachments` state 即可。
    var onAttachmentsPasted: (([Attachment]) -> Void)? = nil

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

        // 接受图片 / 文件拖入(粘贴走 paste(_:) 那条路,不依赖这里注册的类型)。
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, .pdf])

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

    // MARK: - Paste(图片 / 文件 → attachment,文本 → 默认)

    /// ⌘V 触发。NSTextView 默认 paste 会尝试把图片 / 文件转成 inline 富文本,
    /// 我们 isRichText = false 时它直接吃掉啥也不做。重写一下:
    ///   1. 剪贴板有 file URL → AttachmentStore.wrap 每个 url → 推 attachments
    ///   2. 剪贴板有图片字节 → AttachmentStore.save → 推 attachments
    ///   3. 啥都没有(纯文本) → super.paste(_:) 走默认插入
    /// ⌘V 主拦截。NSTextView 默认有 3 个 paste 入口(paste / pasteAsPlainText
    /// / pasteAsRichText),isRichText=false 时系统选哪个不确定,而且
    /// 剪贴板只有图片字节时它可能直接走"无内容"返回。直接拦键事件最稳。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V (没有 shift / option / control)
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "v" {
            if tryPasteAttachments() { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if tryPasteAttachments() { return }
        super.paste(sender)
    }

    /// isRichText=false 时 macOS 偶尔走这条而不是 paste(_:)。
    override func pasteAsPlainText(_ sender: Any?) {
        if tryPasteAttachments() { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if tryPasteAttachments() { return }
        super.pasteAsRichText(sender)
    }

    /// 真正的 attachment 处理。返 true = 吃掉粘贴,返 false = 让文本走默认。
    private func tryPasteAttachments() -> Bool {
        let pb = NSPasteboard.general
        var attachments: [Attachment] = []

        // 1. 文件 URL —— Finder 拷的文件、Notes app 里拷的附件等
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            for url in urls where url.isFileURL {
                attachments.append(AttachmentStore.wrap(fileURL: url))
            }
        }

        // 2. 没拿到 URL 时,试图片字节(截图 / 浏览器 Copy Image 来的)
        if attachments.isEmpty {
            if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
               !imgs.isEmpty {
                for img in imgs {
                    guard let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:])
                    else { continue }
                    if let att = AttachmentStore.save(
                        data: png, suggestedName: "pasted.png", isImage: true
                    ) {
                        attachments.append(att)
                    }
                }
            }
        }

        guard !attachments.isEmpty else { return false }
        // 主线程 dispatch — onAttachmentsPasted 触碰 SwiftUI state,paste 调用
        // 路径上下文可能不在 main runloop tick,直接改 state 偶发引发布局崩。
        let payload = attachments
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.parent.onAttachmentsPasted?(payload)
        }
        return true
    }

    // MARK: - 拖拽放进来

    /// 用户从 Finder / 浏览器把文件 / 图片直接拖到输入框。复用 paste 的同款分流。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var attachments: [Attachment] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where url.isFileURL {
                attachments.append(AttachmentStore.wrap(fileURL: url))
            }
        }
        if attachments.isEmpty,
           let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for img in imgs {
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }
                if let att = AttachmentStore.save(
                    data: png, suggestedName: "dropped.png", isImage: true
                ) { attachments.append(att) }
            }
        }
        if !attachments.isEmpty {
            coordinator?.parent.onAttachmentsPasted?(attachments)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 接受文件 / 图片拖入。文本拖入仍走 NSTextView 默认。
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: nil)
            || pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return .copy
        }
        return super.draggingEntered(sender)
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
