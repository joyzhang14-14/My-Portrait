import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// 主球照片被上传/移除 → canvas 立即重载贴图(GraphRootView 监听)。
    static let mainBallPhotoChanged = Notification.Name("MyPortrait.MainBallPhotoChanged")
}

/// 主球照片的落盘位置 + 圆形裁剪工具(07-11 用户:自定义主球照片,
/// 上传后程序裁成圆形贴主球)。不进 config schema —— 文件在=已设,
/// 上传/移除即时生效(发通知让 canvas 重载,不重启 app)。
enum MainBallPhoto {
    /// ~/.portrait/customize/main-ball.png(与 App customize 的 icon 同目录)。
    static var url: URL {
        Storage.rootURL
            .appendingPathComponent("customize", isDirectory: true)
            .appendingPathComponent("main-ball.png")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 把用户上传的图:中心方形裁 → 圆形 clip → 512×512 PNG(圆外透明,
    /// 画到主球方形区里天然成圆)。成功 true。
    @discardableResult
    static func write(from src: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let imgSrc = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else { return false }
        // 中心方形裁
        let side = min(cg.width, cg.height)
        let sx = (cg.width - side) / 2, sy = (cg.height - side) / 2
        let square = cg.cropping(to: CGRect(x: sx, y: sy, width: side, height: side)) ?? cg
        let target = 512
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: target, height: target,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: target, height: target)
        ctx.addEllipse(in: rect)   // 圆形 clip,圆外保持透明
        ctx.clip()
        ctx.draw(square, in: rect)
        guard let out = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dst, out, nil)
        guard CGImageDestinationFinalize(dst) else { return false }
        NotificationCenter.default.post(name: .mainBallPhotoChanged, object: nil)
        return true
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: .mainBallPhotoChanged, object: nil)
    }
}

struct CanvasSettingsView: View {
    var body: some View {
        // 无页面大标题(07-11 用户:侧栏入口内联,不要标题),只列卡片。
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard(title: "Main ball") {
                    MainBallPhotoSlot()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
    }
}

/// 主球照片上传槽(仿 Display 的 App customize icon slot,圆形预览)。
private struct MainBallPhotoSlot: View {
    @State private var preview: NSImage? = nil

    var body: some View {
        HStack(spacing: 14) {
            preview64
            VStack(alignment: .leading, spacing: 4) {
                Text("Main ball photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                Text("Upload a photo — it's cropped to a circle and shown on the center ball of the graph.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(action: pick) {
                        Label(preview == nil ? "Upload" : "Replace", systemImage: "arrow.up.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    if preview != nil {
                        Button(role: .destructive) {
                            MainBallPhoto.clear(); load()
                        } label: {
                            Label("Remove", systemImage: "trash").font(.system(size: 11))
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var preview64: some View {
        Group {
            if let img = preview {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                // default:纯蓝(仿主球),不加图标(07-11 用户)。
                Circle().fill(Color(red: 0.3, green: 0.6, blue: 1).opacity(0.85))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
    }

    private func load() {
        guard MainBallPhoto.exists else { preview = nil; return }
        let p = MainBallPhoto.url.path
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: p)
            await MainActor.run { preview = img }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        MainBallPhoto.write(from: src)
        load()
    }
}
