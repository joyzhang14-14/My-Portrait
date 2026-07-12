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

    /// 用户在裁剪弹窗里框好的**正方形** CGImage → 圆形 clip → 512×512 PNG
    /// (圆外透明,画到主球方形区里天然成圆)→ 落盘 → 发通知。成功 true。
    /// 传入必须是正方形(裁剪弹窗保证),否则圆内会被拉椭圆。
    @discardableResult
    static func write(cropped square: CGImage) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = 512
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: target, height: target,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: target, height: target)
        ctx.clear(rect)
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

    /// 兜底/直传文件路径:解码 → 中心方形裁 → write(cropped:)。当前上传流程
    /// 走裁剪弹窗(见 MainBallPhotoSlot.pick),用户可框选区域,不再调这条。
    @discardableResult
    static func write(from src: URL) -> Bool {
        guard let imgSrc = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else { return false }
        let side = min(cg.width, cg.height)
        let sx = (cg.width - side) / 2, sy = (cg.height - side) / 2
        let square = cg.cropping(to: CGRect(x: sx, y: sy, width: side, height: side)) ?? cg
        return write(cropped: square)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: .mainBallPhotoChanged, object: nil)
    }
}

struct CanvasSettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        // 无页面大标题(07-11 用户:侧栏入口内联,不要标题),只列卡片。
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard(title: "Main ball") {
                    MainBallPhotoSlot()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                SettingsCard(title: "Animation speed") {
                    SpeedLevelSlider(
                        title: "Graph animation speed",
                        caption: "How fast the graph plays its opening animation — the balls spreading out and the meteors lighting up — and how fast the meteor ring glides back into place after you drag a folder ball.",
                        selection: config.binding(\.display.graphAnimationSpeed))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                SettingsCard(title: "Pulse speed") {
                    SpeedLevelSlider(
                        title: "Neural pulse speed",
                        caption: "How fast the pulse travels along the links when you click a ball, and how quickly each ball it reaches flashes on.",
                        selection: config.binding(\.display.graphPulseSpeed))
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
    /// 非 nil = 正在裁剪弹窗里框选这张源图(.sheet(item:) 驱动)。
    @State private var cropTarget: CropTarget? = nil

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
        // 上传流程:选文件 → 弹裁剪弹窗框选圆形区域 → Apply 裁出正方形回写。
        .sheet(item: $cropTarget) { target in
            CircularCropSheet(
                source: target.image,
                onApply: { square in
                    cropTarget = nil                      // 先关弹窗
                    MainBallPhoto.write(cropped: square)  // 512 圆裁+落盘+发通知
                    load()                                 // 刷 64 圆预览(它不听自身通知)
                },
                onCancel: { cropTarget = nil }
            )
        }
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
        // 解码为全分辨率 CGImage → 弹裁剪弹窗让用户框选(不再直接中心裁)。
        guard let imgSrc = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else { return }
        cropTarget = CropTarget(image: cg)
    }
}

/// 5 档速度选择器(07-11 用户:5 档、无数值、Apple 风,英文标签)。图谱动画
/// 与神经脉冲两个设置共用(各自传 title/caption,绑各自的 config 字段)。
/// 速度是"大小量" → 用带刻度 Slider(仿 macOS 系统设置 Tracking speed),
/// 5 档标签用 GeometryReader **精确定位到滑块的 5 个停点分数**(等宽列会把
/// 字中心放在 1/10…9/10,与停点 0…1 天生错位;去掉两端图标消除轨道内缩)。
/// 高亮当前档。默认中等=当前手感。
private struct SpeedLevelSlider: View {
    let title: String
    let caption: String
    @Binding var selection: SpeedLevel

    private static let cases = SpeedLevel.allCases
    private static let maxIdx = cases.count - 1

    /// 单个档位标签(当前档高亮)。
    private func tick(_ s: SpeedLevel) -> some View {
        Text(s.label)
            .font(.system(size: 10))
            .foregroundStyle(s == selection ? Theme.accent
                                            : Theme.textPrimary.opacity(0.40))
            .fixedSize()
    }

    /// 枚举 ↔ Double 桥接:step=1 让滑块吸附到 5 个整点。
    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(Self.cases.firstIndex(of: selection) ?? 2) },
            set: { v in
                let i = min(max(Int(v.rounded()), 0), Self.maxIdx)
                selection = Self.cases[i]
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            Slider(value: sliderValue, in: 0...Double(Self.maxIdx), step: 1)
                .tint(Theme.accent)
            // 5 档标签。中间三档 center 精确钉在滑块停点分数 i/4 上;首尾两档
            // 若也钉 center 会有一半甩出卡片(停点几乎贴轨道端),故改**贴容器
            // 边缘对齐**(左档左对齐/右档右对齐),不越界且仍读作对准两端。
            GeometryReader { geo in
                let w = geo.size.width
                let inset: CGFloat = 7
                let track = w - 2 * inset
                ForEach(Array(Self.cases.enumerated()), id: \.offset) { idx, s in
                    if idx == 0 {
                        tick(s).frame(width: w, height: 14, alignment: .leading)
                    } else if idx == Self.maxIdx {
                        tick(s).frame(width: w, height: 14, alignment: .trailing)
                    } else {
                        tick(s).position(x: inset + track * CGFloat(idx) / CGFloat(Self.maxIdx),
                                         y: 7)
                    }
                }
            }
            .frame(height: 14)
        }
    }
}

/// 待裁剪的源图。Identifiable 供 `.sheet(item:)` 驱动(避免图未就位先弹空白帧)。
private struct CropTarget: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// 方形挖圆洞(even-odd 填充 → 圆外压暗)。
private struct CropDimHole: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addEllipse(in: r)
        return p
    }
}

/// Discord 式圆形头像裁剪弹窗(07-11 用户:上传主球照片时框选区域)。
/// 圆形取景框固定居中,用户拖拽平移 + 捏合/滑块缩放定位,Apply 裁出正方形回传。
/// 坐标系:SwiftUI 视口(左上、y 向下)与 CGImage 像素栅格一致 → 全程不翻 y。
private struct CircularCropSheet: View {
    let source: CGImage
    var onApply: (CGImage) -> Void
    var onCancel: () -> Void

    private let preview: NSImage
    private let iw: CGFloat
    private let ih: CGFloat
    private let viewport: CGFloat = 280   // V:方形视口 = 圆的外接正方形(pt)

    init(source: CGImage, onApply: @escaping (CGImage) -> Void, onCancel: @escaping () -> Void) {
        self.source = source
        self.onApply = onApply
        self.onCancel = onCancel
        self.iw = CGFloat(source.width)
        self.ih = CGFloat(source.height)
        self.preview = NSImage(cgImage: source,
                               size: NSSize(width: source.width, height: source.height))
    }

    /// aspect-fill 基准缩放:zoom=1 时图的短边刚好铺满视口(圆内不露空)。
    private var base: CGFloat { viewport / min(iw, ih) }

    @State private var zoom: CGFloat = 1        // 相对下限 1×…3×
    @State private var offset: CGSize = .zero   // 视口点坐标,已 clamp
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private func liveZoom() -> CGFloat { max(1, min(3, zoom * pinch)) }

    /// 硬夹紧:图四边必须始终盖住视口方形,否则圆内露空。
    private func clampOffset(_ o: CGSize, _ z: CGFloat) -> CGSize {
        let s = base * z
        let mx = max(0, (s * iw - viewport) / 2)
        let my = max(0, (s * ih - viewport) / 2)
        return CGSize(width: min(max(o.width, -mx), mx),
                      height: min(max(o.height, -my), my))
    }

    private func liveOffset() -> CGSize {
        clampOffset(CGSize(width: offset.width + drag.width,
                           height: offset.height + drag.height), liveZoom())
    }

    var body: some View {
        let V = viewport
        let z = liveZoom()
        let off = liveOffset()
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust photo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
            Text("Drag to reposition, pinch or use the slider to zoom.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.5))

            ZStack {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: V, height: V)
                    .scaleEffect(z)                       // .center 锚点
                    .offset(x: off.width, y: off.height)  // 字面视口点(在 scaleEffect 外层)
                    .frame(width: V, height: V)
                    .clipped()
                CropDimHole()
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .frame(width: V, height: V)
                    .allowsHitTesting(false)
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: V, height: V)
                    .allowsHitTesting(false)
            }
            .frame(width: V, height: V)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { v, st, _ in st = v.translation }
                    .onEnded { v in
                        offset = clampOffset(CGSize(width: offset.width + v.translation.width,
                                                    height: offset.height + v.translation.height),
                                             liveZoom())
                    }
                    .simultaneously(with:
                        MagnifyGesture()                  // 部署目标 macOS 15;value.magnification=相对起始倍率
                            .updating($pinch) { v, st, _ in st = v.magnification }
                            .onEnded { v in
                                zoom = max(1, min(3, zoom * v.magnification))
                                offset = clampOffset(offset, zoom)
                            }
                    )
            )

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
                Slider(value: Binding(get: { zoom },
                                      set: { zoom = max(1, min(3, $0)); offset = clampOffset(offset, zoom) }),
                       in: 1...3)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { applyCrop() } label: {
                    Label("Apply", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)   // 回车 = Apply
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 360, height: 480)
        .background(SidebarBackdrop().ignoresSafeArea())
    }

    /// 用已提交(已 clamp)的 zoom/offset 反投影出源像素裁剪方形。
    private func applyCrop() {
        let z = zoom, ox = offset.width, oy = offset.height
        let s = base * z
        let side = viewport / s                                // = min(iw,ih)/z 源像素
        let x0 = iw / 2 - (viewport / 2 + ox) / s
        let y0 = ih / 2 - (viewport / 2 + oy) / s              // 不翻 y(CGImage 栅格=左上)
        var rect = CGRect(x: x0, y: y0, width: side, height: side).integral
        rect = rect.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))  // 数值兜底
        guard !rect.isEmpty, let square = source.cropping(to: rect) else { return }
        onApply(square)
    }
}
