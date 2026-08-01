import SwiftUI
import AppKit

struct DisplaySettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        SettingsPage("Display",
                     subtitle: "Theme, window behaviour, and personalization",
                     onResetCurrentPage: { config.mutate { $0.display = .init() } }) {

            AppCustomizeCard()

            MenuBarLampCard()

            SettingsCard(title: "Appearance") {
                SettingsRow("Theme",
                            description: "Match the system or force light / dark.",
                            icon: "paintpalette") {
                    Picker("", selection: config.binding(\.display.theme)) {
                        ForEach(AppTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Show in menu bar",
                            description: "Adds a menu bar icon so you can switch Screen, Audio, and Typing capture on or off without opening the main window.",
                            icon: "menubar.rectangle") {
                    Toggle("", isOn: config.binding(\.display.showInMenuBar))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Show Dock icon",
                            description: "Keep My Portrait in the Dock. Turn off to run without a Dock icon (it also leaves Cmd-Tab and the top menu bar).",
                            icon: "dock.rectangle") {
                    Toggle("", isOn: config.binding(\.display.showDockIcon))
                        .labelsHidden().toggleStyle(.switch)
                }
                // 危险组合:Dock 图标和菜单栏图标都关 → 关窗后没可见入口。
                if !config.current.display.showDockIcon && !config.current.display.showInMenuBar {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Text("No Dock icon and no menu bar icon — once you close the window there's no quick way back. You'll have to relaunch My Portrait from Spotlight or Finder to reopen it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsCard(title: "Chat") {
                SettingsRow("Compact tool blocks",
                            description: "Collapse a reply's thinking + tool steps into one expandable summary bar. Faster to load.",
                            icon: "rectangle.compress.vertical") {
                    Toggle("", isOn: config.binding(\.display.compactToolBlocks))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Hide thinking blocks",
                            description: "Don't show the model's reasoning trace in the transcript.",
                            icon: "brain") {
                    Toggle("", isOn: config.binding(\.display.hideModelReasoning))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

// MARK: - App Customize card

/// Hero card at the top of the Display page. Mirrors Orphies'
/// `app-customize-card.tsx`:
///   1. Editable app name (max 32 chars)
///   2. Dock icon slot — Upload / Replace / Reset
///   3. Menu bar icon slot — same controls
///
/// 默认折叠 —— 多数人不会改这些,展开后 Save 还会重启 app,放收起来
/// 里更不容易误触。Show-in-menu-bar 不需要重启,搬去 Appearance 卡。
///
/// Uploads write into `~/.portrait/customize/`
/// so the icons survive app restarts. Reset deletes the file.
private struct AppCustomizeCard: View {
    @State private var config = ConfigStore.shared

    /// 默认折叠。展开后才显示 name + 两张 icon slot + Save。
    @State private var expanded: Bool = false

    // Staged local edits — committed to ConfigStore only on Save.
    @State private var appName: String = ""
    @State private var dockIconPath: String = ""
    @State private var loaded = false

    private let maxNameLength = 32

    private var hasUnsavedChanges: Bool {
        let d = config.current.display
        return appName != d.appName
            || dockIconPath != d.customDockIcon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 0) {
            // 折叠头 —— 整行可点击切换。
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("App customize")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary.opacity(0.96))
                        Text("Personalize the in-app display name and the Dock icon.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("APP NAME (MAX \(maxNameLength) CHARS)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                    TextField("My Portrait", text: Binding(
                        get: { appName },
                        set: { appName = String($0.prefix(maxNameLength)) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                    )
                    Text("macOS controls the name shown in the menu bar (next to the Apple logo). Changing it here updates the dock title + windows.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Color.primary.opacity(0.08))

                IconSlot(
                    title: "Dock icon",
                    subtitle: "Shown in the Dock and the cmd-Tab switcher.",
                    path: $dockIconPath,
                    fileName: "dock.png"
                )

                // 08-01:菜单栏图标自定义槽位删掉 —— 图标现在是三盏实时采集灯
                // (紫屏幕/黄音频/蓝打字),换成一张静态图会把灯整个盖掉,
                // 那盏"用来自证没在记"的灯就失效了。

                Divider().background(Color.primary.opacity(0.08))

                HStack(spacing: 10) {
                    Text("Saving restarts My Portrait so the new name + icons take effect.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary.opacity(hasUnsavedChanges ? 0.55 : 0.30))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(action: saveAndRestart) {
                        Label("Save", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.40), Color.purple.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.purple.opacity(0.12), radius: 16, x: 0, y: 6)
        )
        .onAppear {
            guard !loaded else { return }
            let d = config.current.display
            appName       = d.appName
            dockIconPath  = d.customDockIcon
            loaded = true
        }
    }

    /// Commit the staged edits, flush the config write, then relaunch the
    /// app — mirrors screenpipe, where saving app-customize restarts so the
    /// process picks up the new name + icons cleanly.
    ///
    /// **必须 await saveNowAndWait**:saveNow 是 fire-and-forget Task,
    /// 立刻被下面 NSApp.terminate 杀掉,配置没真落盘,新 instance 启动
    /// 看到老值,"重启后又变回去"。
    private func saveAndRestart() {
        config.mutate {
            $0.display.appName       = appName
            $0.display.customDockIcon  = dockIconPath
        }
        Task { @MainActor in
            await config.saveNowAndWait()
            Self.relaunch()
        }
    }

    /// 重启 app:先 spawn 一个 detached 进程预定好新 instance 启动,
    /// 再退当前进程。
    ///
    /// **不用 `open <path>`** —— 它走 LaunchServices,dev build 的 .app
    /// 在 DerivedData 下经常没在 LS 注册,抛 -600 procNotFound,结果
    /// app 退了但没自启。
    ///
    /// 改成直接 spawn 可执行文件 `{bundle}/Contents/MacOS/<binary>`,
    /// 绕开 LaunchServices。父进程 sh 立即 exit,子进程在 sleep 1 后
    /// fork+exec binary,这时原 app 已经 NSApp.terminate 退完了。
    private static func relaunch() {
        guard let exec = Bundle.main.executablePath else {
            NSApp.terminate(nil); return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 单引号包路径 + \''\'' escape 内部单引号,容忍路径里的空格 / 特殊字符。
        let escaped = exec.replacingOccurrences(of: "'", with: "'\\''")
        task.arguments = ["-c", "sleep 1; '\(escaped)' &"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Icon slot (Dock / Menu bar)

private struct IconSlot: View {
    let title: String
    let subtitle: String
    @Binding var path: String
    /// On-disk file name to use when copying the picked image into our
    /// support dir (e.g. "dock.png" / "tray.png").
    let fileName: String

    @State private var preview: NSImage? = nil

    var body: some View {
        HStack(spacing: 14) {
            preview64
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
                HStack(spacing: 6) {
                    Button(action: pickFile) {
                        Label(path.isEmpty ? "Upload" : "Replace",
                              systemImage: "arrow.up.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    if !path.isEmpty {
                        Button(action: reset) {
                            Label("Reset", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11))
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear { loadPreview() }
        .onChange(of: path) { loadPreview() }
    }

    @ViewBuilder private var preview64: some View {
        Group {
            if let img = preview {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
                    Text("default")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.14), lineWidth: 0.7))
    }

    // MARK: - File ops

    private func loadPreview() {
        guard !path.isEmpty else { preview = nil; return }
        // NSImage(contentsOfFile:) 是同步磁盘 IO + 解码,大图会卡主线程。
        // 后台读完回主线程赋值。
        let p = path
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: p)
            await MainActor.run { preview = img }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // **只调一次 runModal** —— 旧代码调了两次,第二次又弹一次 panel。
        guard panel.runModal() == .OK, let src = panel.url else { return }
        copyAndSet(src: src)
    }

    private func copyAndSet(src: URL) {
        let dir = AIPaths.supportDir.appendingPathComponent("customize", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        // dock.png 走 macOS squircle 模板裁剪;tray.png 中心 crop + resize 不圆。
        // 仿 My-Orphies app-customize-card.tsx 的 squareCropResize。
        let success: Bool = (fileName == "dock.png")
            ? Self.writeDockIcon(src: src, dest: dest)
            : Self.writeTrayIcon(src: src, dest: dest)
        if success {
            path = dest.path
        } else {
            // Surface in a console log only; the UI just reverts to "default".
            path = ""
        }
    }

    private func reset() {
        // Staged: just clear the path. The actual file is left in place —
        // committing an empty path on Save means "no custom icon"; the
        // orphan PNG is harmless (overwritten on the next upload).
        path = ""
        preview = nil
    }

    // MARK: - Icon processing(仿 My-Orphies app-customize-card.tsx)

    /// macOS Big Sur+ icon 模板:body 占 824/1024 ≈ 80.5% 居中,周围
    /// ~100px 透明 padding(否则 Dock 里比标准 app 大一圈)。
    private static let dockTargetSize: Int = 1024
    private static let dockBodyRatio: CGFloat = 824.0 / 1024.0
    /// 圆角 ≈ body 边长的 22.5%(不是 canvas 边)。macOS squircle 常数。
    private static let dockCornerRadiusRatio: CGFloat = 0.225

    /// tray icon 单纯 center-crop + resize,不圆,菜单栏渲染要 flush。
    private static let trayTargetSize: Int = 128

    /// 把用户上传的图裁成 macOS Dock squircle 模板的 1024×1024 PNG。
    /// 失败返回 false,UI 回退到"无自定义图"。
    static func writeDockIcon(src: URL, dest: URL) -> Bool {
        guard let srcCG = loadCGImage(src) else { return false }
        let cropped = centerSquareCrop(srcCG)
        let size = CGFloat(dockTargetSize)
        let bodySize = size * dockBodyRatio
        let offset = (size - bodySize) / 2
        let radius = bodySize * dockCornerRadiusRatio
        guard let ctx = makeARGBContext(width: dockTargetSize, height: dockTargetSize) else { return false }
        ctx.interpolationQuality = .high
        let bodyRect = CGRect(x: offset, y: offset, width: bodySize, height: bodySize)
        // squircle clip + draw —— ctx 默认 alpha = 0 全透明,clip 外的区域
        // 保持透明 padding。
        let pathRect = CGPath(
            roundedRect: bodyRect,
            cornerWidth: radius, cornerHeight: radius,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(pathRect)
        ctx.clip()
        ctx.draw(cropped, in: bodyRect)
        ctx.restoreGState()
        guard let finalCG = ctx.makeImage() else { return false }
        return writePNG(cg: finalCG, to: dest)
    }

    /// tray icon:center-crop + resize 128×128,无圆角无 padding。
    static func writeTrayIcon(src: URL, dest: URL) -> Bool {
        guard let srcCG = loadCGImage(src) else { return false }
        let cropped = centerSquareCrop(srcCG)
        let target = trayTargetSize
        guard let ctx = makeARGBContext(width: target, height: target) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let finalCG = ctx.makeImage() else { return false }
        return writePNG(cg: finalCG, to: dest)
    }

    // MARK: helpers

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return cg
    }

    private static func centerSquareCrop(_ cg: CGImage) -> CGImage {
        let side = min(cg.width, cg.height)
        let sx = (cg.width - side) / 2
        let sy = (cg.height - side) / 2
        return cg.cropping(to: CGRect(x: sx, y: sy, width: side, height: side)) ?? cg
    }

    private static func makeARGBContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        )
    }

    private static func writePNG(cg: CGImage, to dest: URL) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(
            dest as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dst, cg, nil)
        return CGImageDestinationFinalize(dst)
    }
}

// MARK: - 菜单栏图标说明卡

/// 用 Canvas 按**真实图标几何**画出来的三盏采集灯 + 逐盏实时状态。
///
/// 不是一张说明图 —— 它读的是 `CaptureLampState.shared`,跟菜单栏那个图标同一个
/// 数据源。所以这张卡同时是"这图标什么意思"和"我现在到底在被记什么"的自查面板:
/// 用户切到 1Password 再回来看这一页,能看到灯确实灭过。
private struct MenuBarLampCard: View {
    @ObservedObject private var lamps = CaptureLampState.shared

    var body: some View {
        SettingsCard(title: "Menu bar icon") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Three neural nodes, one per capture channel. A node lights up only while that channel is recording the app you're in right now. It goes dark the moment the channel is switched off, its permission is missing, capture is paused, or the app — or the page — you're in is on that channel's ignore list.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 22) {
                    // 深色底片 —— 模拟菜单栏,白色描边才读得出来。
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
                        LampGlyph(screen: lamps.screen.on,
                                  audio: lamps.audio.on,
                                  typing: lamps.typing.on)
                            .padding(16)
                    }
                    .frame(width: 116, height: 128)

                    VStack(alignment: .leading, spacing: 9) {
                        legendRow("Screen",  LampGlyph.screenColor, lamps.screen)
                        legendRow("Audio",   LampGlyph.audioColor,  lamps.audio)
                        legendRow("Typing",  LampGlyph.typingColor, lamps.typing)
                    }
                    Spacer(minLength: 0)
                }

                // 中心橙点那句说明先不写 —— 它之后要挂功能,现在讲不清楚。
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func legendRow(_ name: String, _ color: Color,
                           _ lamp: CaptureLampState.Lamp) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(lamp.on ? color : Color.clear)
                .overlay(Circle().stroke(color.opacity(lamp.on ? 0 : 0.45), lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(lamp.on ? "lit — recording this app" : (lamp.reason ?? "off"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textPrimary.opacity(lamp.on ? 0.55 : 0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 菜单栏图标本体,Canvas 直接画 —— 几何是从原始手绘模板量出来的,归一化到
/// 单位框(宽为基准),所以任意尺寸都不会变形。
private struct LampGlyph: View {
    var screen: Bool
    var audio: Bool
    var typing: Bool

    static let screenColor = Color(red: 142/255, green: 26/255,  blue: 245/255)
    static let audioColor  = Color(red: 255/255, green: 255/255, blue: 85/255)
    static let typingColor = Color(red: 52/255,  green: 120/255, blue: 245/255)
    static let hubColor    = Color(red: 232/255, green: 159/255, blue: 67/255)

    /// 归一化几何 —— **x 和 y 都除以内容框宽 916**(等比!)。
    /// ⚠️ 一开始 y 除的是高度 1052、x 除的是宽度,非等比 → 整个图被竖向压扁、
    /// 顶部那颗球被推到 y<0 裁掉了(看起来就是"图标偏上、上面被盖住一块")。
    /// y 的取值范围因此是 0…aspect,不是 0…1。
    private static let aspect: CGFloat = 1052.0 / 916.0     // 1.148472
    private static let hub = CGPoint(x: 0.233624, y: 0.749236)
    private static let rHub: CGFloat = 0.228493
    private static let rDot: CGFloat = 0.158734
    private static let stroke: CGFloat = 0.069869
    private static let dots: [(CGPoint, KeyPath<LampGlyph, Bool>, Color)] = [
        (CGPoint(x: 0.477293, y: 0.163646), \.screen, screenColor),
        (CGPoint(x: 0.836135, y: 0.563319), \.audio,  audioColor),
        (CGPoint(x: 0.715284, y: 0.988210), \.typing, typingColor),
    ]

    var body: some View {
        // 亮着的灯做极缓的呼吸(2.6s 一轮),幅度很小 —— 让人一眼看出"这是活的
        // 实时状态",但不至于在设置页里晃眼。
        // ⚠️ 必须写 SwiftUI. 限定名 —— 本工程自己有个 TimelineView(时间线页面),
        // 不限定的话解析到那个,报「TimelineState 没有成员 animation」。
        //
        // ⚠️ 用 .periodic 而不是 .animation:.animation 绑显示链路,**App 不在
        // 前台时会暂停**。而这张卡最重要的用法恰恰是「窗口摆在旁边,切到别的
        // app,盯着看灯灭」—— 一点回 App 前台就变成 My Portrait 了,看到的就
        // 不是你想验证的那个 app。.periodic 走墙钟,后台照跑。
        SwiftUI.TimelineView(.periodic(from: .now, by: 1.0 / 20)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let breathe = 0.5 + 0.5 * sin(t * 2 * .pi / 2.6)   // 0…1
                // 等比放进给定尺寸,居中
                let scale = min(size.width, size.height / Self.aspect)
                let ox = (size.width - scale) / 2
                let oy = (size.height - scale * Self.aspect) / 2
                func P(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: ox + p.x * scale, y: oy + p.y * scale)
                }
                func R(_ r: CGFloat) -> CGFloat { r * scale }
                func disc(_ c: CGPoint, _ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                }

                let hubC = P(Self.hub)
                let sw = R(Self.stroke)

                // 1) 连线 + 各球外圆,统一白色描边(菜单栏用的就是白线版)
                for (p, _, _) in Self.dots {
                    var line = Path()
                    line.move(to: hubC)
                    line.addLine(to: P(p))
                    ctx.stroke(line, with: .color(.white),
                               style: StrokeStyle(lineWidth: sw, lineCap: .round))
                }
                ctx.fill(disc(hubC, R(Self.rHub)), with: .color(.white))
                for (p, _, _) in Self.dots {
                    ctx.fill(disc(P(p), R(Self.rDot)), with: .color(.white))
                }

                // 2) 内圆:中心恒亮橙;三盏灯亮=本色(带辉光)、灭=挖空成底色
                ctx.fill(disc(hubC, R(Self.rHub - Self.stroke)), with: .color(Self.hubColor))
                for (p, kp, color) in Self.dots {
                    let c = P(p)
                    let ri = R(Self.rDot - Self.stroke)
                    if self[keyPath: kp] {
                        // 辉光:同色大圆低透明度垫在下面,呼吸时轻微涨缩
                        let glow = ri * (2.0 + 0.35 * breathe)
                        ctx.fill(disc(c, glow), with: .color(color.opacity(0.16 + 0.08 * breathe)))
                        ctx.fill(disc(c, ri), with: .color(color))
                    } else {
                        // 灭 = 真的挖空(跟真实图标一致:露出菜单栏底色)
                        ctx.blendMode = .destinationOut
                        ctx.fill(disc(c, ri), with: .color(.black))
                        ctx.blendMode = .normal
                    }
                }
            }
        }
        .drawingGroup()      // 挖空需要独立图层,否则 destinationOut 会吃掉卡片背景
    }
}
