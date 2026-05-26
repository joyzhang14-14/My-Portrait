import SwiftUI
import AppKit

struct DisplaySettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        SettingsPage("Display", subtitle: "Theme, window behaviour, and personalization") {

            AppCustomizeCard()

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
                SettingsRow("Translucent sidebar",
                            description: "Frosted glass effect on the left rail (macOS only).",
                            icon: "rectangle.lefthalf.inset.filled") {
                    Toggle("", isOn: config.binding(\.display.translucentSidebar))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Show in menu bar",
                            description: "Adds a quick-access menu next to the clock for capture toggles (Screen / Audio / Typing) and opening ~/.portrait/. Useful when the main window is closed.",
                            icon: "menubar.rectangle") {
                    Toggle("", isOn: config.binding(\.display.showInMenuBar))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Window") {
                SettingsRow("Keep app window on top",
                            description: "Pin the entire My Portrait window above other apps. Useful when watching a video or reading docs while chatting in the side.",
                            icon: "macwindow.on.rectangle") {
                    Toggle("", isOn: config.binding(\.display.chatAlwaysOnTop))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Chat") {
                SettingsRow("Hide thinking blocks",
                            description: "Don't show the model's reasoning trace in the transcript.",
                            icon: "brain") {
                    Toggle("", isOn: config.binding(\.display.hideModelReasoning))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Recording overlays") {
                SettingsRow("Show overlay in screen recording",
                            description: "Include the chat overlay in captured frames.",
                            icon: "rectangle.dashed") {
                    Toggle("", isOn: config.binding(\.display.showOverlayInRecording))
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
    @State private var trayIconPath: String = ""
    @State private var loaded = false

    private let maxNameLength = 32

    private var hasUnsavedChanges: Bool {
        let d = config.current.display
        return appName != d.appName
            || dockIconPath != d.customDockIcon
            || trayIconPath != d.customTrayIcon
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
                            .foregroundStyle(.white.opacity(0.96))
                        Text("Personalize the in-app display name and the Dock + menu bar icons.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
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
                        .foregroundStyle(.white.opacity(0.45))
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
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Color.white.opacity(0.08))

                IconSlot(
                    title: "Dock icon",
                    subtitle: "Shown in the Dock and the cmd-Tab switcher.",
                    path: $dockIconPath,
                    fileName: "dock.png"
                )

                IconSlot(
                    title: "Menu bar icon",
                    subtitle: "Used by the status item next to the clock.",
                    path: $trayIconPath,
                    fileName: "tray.png"
                )

                Divider().background(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    Text("Saving restarts My Portrait so the new name + icons take effect.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(hasUnsavedChanges ? 0.55 : 0.30))
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
            trayIconPath  = d.customTrayIcon
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
            $0.display.customTrayIcon  = trayIconPath
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
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
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
                        .foregroundStyle(.white.opacity(0.55))
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
