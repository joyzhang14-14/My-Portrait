import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 把整个 chat pane(HomeView 所占的右侧区域)包成一个文件 / 图片接收靶。
/// 用户从 Finder / 浏览器拖文件进来,全屏暗罩 + 中央 "Drop files here to
/// add to chat" 提示,松手后通过 `.chatAttachmentsDropped` 通知 HomeView。
///
/// 模仿 Claude desktop 的拖放 UX,sidebar 不参与(ContentView 只把这个
/// 修饰符挂在 mainPane 上,且仅 selection == .home 时启用)。
struct ChatDropZoneModifier: ViewModifier {
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image, .png, .tiff, .pdf],
                    isTargeted: $isTargeted) { providers in
                Self.handle(providers: providers)
                return true
            }
            .overlay {
                if isTargeted {
                    ZStack {
                        Color.black.opacity(0.55)
                            .ignoresSafeArea()
                        VStack(spacing: 14) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 42, weight: .light))
                                .foregroundStyle(Color.white.opacity(0.95))
                            Text("Drop files here to add to chat")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.95))
                        }
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)   // 不挡放下事件本身
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    /// 多源 provider → Attachment 列表 → broadcast。
    /// 文件 URL 优先(Finder 拖文件 / 浏览器拖链接);否则取 NSImage 字节。
    private static func handle(providers: [NSItemProvider]) {
        Task { @MainActor in
            var collected: [Attachment] = []
            for p in providers {
                if let url = await loadFileURL(p) {
                    collected.append(AttachmentStore.wrap(fileURL: url))
                    continue
                }
                if let img = await loadImage(p),
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]),
                   let att = AttachmentStore.save(
                       data: png, suggestedName: "dropped.png", isImage: true
                   ) {
                    collected.append(att)
                }
            }
            guard !collected.isEmpty else { return }
            NotificationCenter.default.post(
                name: .chatAttachmentsDropped, object: collected)
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                cont.resume(returning: img as? NSImage)
            }
        }
    }
}

extension View {
    /// 给 chat pane(HomeView 区域)挂一个全区域文件 / 图片拖拽接收靶。
    /// 仅当 enabled = true 时启用 —— ContentView 用 selection == .home 控制。
    func chatDropZone(enabled: Bool) -> some View {
        Group {
            if enabled {
                self.modifier(ChatDropZoneModifier())
            } else {
                self
            }
        }
    }
}
