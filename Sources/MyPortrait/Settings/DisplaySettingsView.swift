import SwiftUI
import AppKit

struct DisplaySettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        SettingsPage("Display",
                     onResetCurrentPage: { config.mutate { $0.display = .init() } }) {

            AppCustomizeCard()

            SettingsCard(title: "Appearance") {
                SettingsRow("Theme",
                            icon: "paintpalette") {
                    Picker("", selection: config.binding(\.display.theme)) {
                        ForEach(AppTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Show in menu bar",
                            icon: "menubar.rectangle") {
                    Toggle("", isOn: config.binding(\.display.showInMenuBar))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Show Dock icon",
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

            MenuBarLampCard()
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
    @State private var dockIconPath: String = ""
    @State private var loaded = false

    private var hasUnsavedChanges: Bool {
        dockIconPath != config.current.display.customDockIcon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 0) {
            // 折叠头 —— 整行可点击切换。
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 16) {
                    Text("App customize")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.96))
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
                IconSlot(
                    title: "Dock icon",
                    path: $dockIconPath,
                    fileName: "dock.png"
                )

                // 08-01 update:菜单栏图标没有自定义槽位 —— 图标是三盏实时采集灯
                // (紫屏幕/黄音频/蓝打字),换成静态图会把灯盖掉,那盏"用来
                // 自证没在记"的灯就失效了。

                Divider().background(Color.primary.opacity(0.08))

                HStack(spacing: 10) {
                    Text("Saving restarts My Portrait so the new icon takes effect.")
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
            dockIconPath = config.current.display.customDockIcon
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
        // 重置成默认图标 → 存着的那张也删掉,不留没人用的图(10-27 update)。
        if dockIconPath.isEmpty {
            try? FileManager.default.removeItem(
                at: AIPaths.supportDir.appendingPathComponent("customize/dock.png"))
        }
        config.mutate {
            $0.display.customDockIcon = dockIconPath
        }
        Task { @MainActor in
            await config.saveNowAndWait()
            AppRelaunch.run()
        }
    }

}

/// 重启 app:先 spawn 一个 detached 进程预定好新 instance 启动,再退当前进程。
///
/// **不用 `open <path>`** —— 它走 LaunchServices,dev build 的 .app 在
/// DerivedData 下经常没在 LS 注册,抛 -600 procNotFound,结果 app 退了但没自启。
///
/// 改成直接 spawn 可执行文件 `{bundle}/Contents/MacOS/<binary>`,绕开
/// LaunchServices。
///
/// **等旧进程真的没了再拉新的**(08-09 update):轮询 `kill -0`(只探测进程
/// 存在性,不发任何信号),旧窗口消失后新窗口才出现,避免新旧两窗口同屏。
/// 10 秒封顶,免得 terminate 卡住时永远不重启。
///
/// dev mode 切换也要重启,与 AppCustomizeCard 共用这份逻辑。
enum AppRelaunch {
    static func run() {
        guard let exec = Bundle.main.executablePath else {
            NSApp.terminate(nil); return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 单引号包路径 + \''\'' escape 内部单引号,容忍路径里的空格 / 特殊字符。
        let escaped = exec.replacingOccurrences(of: "'", with: "'\\''")
        task.arguments = ["-c", """
            n=0
            while kill -0 \(pid) 2>/dev/null && [ $n -lt 100 ]; do
              sleep 0.1
              n=$((n+1))
            done
            '\(escaped)' &
            """]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Icon slot (Dock / Menu bar)

private struct IconSlot: View {
    let title: String
    @Binding var path: String
    /// On-disk file name to use when copying the picked image into our
    /// support dir (e.g. "dock.png").
    let fileName: String

    @State private var preview: NSImage? = nil

    var body: some View {
        HStack(spacing: 14) {
            preview64
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
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
        // 走 macOS squircle 模板裁剪(仿 My-Orphies app-customize-card.tsx)。
        let success = Self.writeDockIcon(src: src, dest: dest)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsCard(
            title: "Menu bar icon",
            info: "Three rings, one per capture channel — screen outside, audio in the middle, typing inside. A ring lights up only while that channel is recording the app you're in right now. It turns gray the moment the channel is switched off, its permission is missing, capture is paused, or the app — or the page — you're in is on that channel's ignore list. When **All Capture** is switched off, the whole icon turns red."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // ⚠️ **拉取式,不是 @ObservedObject 推送式**。
                // 这张卡最关键的用法是「窗口摆旁边,切到别的 app 盯着看灯灭」——
                // 而 App 不在前台时,SwiftUI 会把后台窗口的 objectWillChange
                // 合并/延后到窗口重新激活,卡片就冻在切走那一刻(实测:切到微信、
                // Spotify 之后仍显示 "Terminal is a terminal")。
                // 墙钟 TimelineView 每 tick 重新求值 body,直接读单例当前值,
                // 绕开推送这一层。
                SwiftUI.TimelineView(.periodic(from: .now, by: 1.0 / 20)) { tl in
                    let lamps = CaptureLampState.shared
                    HStack(alignment: .center, spacing: 22) {
                        // 底片模拟菜单栏,**跟随系统外观**:深色模式深底、浅色模式浅底,
                        // 色板也跟着换 —— 和菜单栏里真正显示的那一版(Assets 里
                        // Any / Dark 两套)始终一致,不然用户在这张卡上看到的和
                        // 抬头看到的对不上。
                        let dark = colorScheme == .dark
                        let pal = LampGlyph.palette(dark: dark)
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(dark ? Color(red: 0.11, green: 0.11, blue: 0.12)
                                           : Color(red: 0.97, green: 0.97, blue: 0.98))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(dark ? Color.white.opacity(0.10)
                                                     : Color.black.opacity(0.10), lineWidth: 1))
                            LampGlyph(screen: lamps.screen.on,
                                      audio: lamps.audio.on,
                                      typing: lamps.typing.on,
                                      paused: lamps.masterOff,
                                      dark: dark,
                                      now: tl.date)
                                .padding(8)
                        }
                        .frame(width: 128, height: 128)

                        VStack(alignment: .leading, spacing: 9) {
                            // 总开关:开着不占颜色;关掉 = 暂停,整个图标变红。
                            // 灭的那句说明放这里(三盏灯灭时只说"被总开关关掉",不再各自重复)。
                            legendRow("All Capture", pal.paused,
                                      CaptureLampState.Lamp(
                                          on: !lamps.masterOff,
                                          reason: "All capture is switched off — the icon turns red."),
                                      onText: "On — every capture channel is allowed to run.",
                                      offFilled: true)
                            legendRow("Screen",  pal.screen, lamps.screen)
                            legendRow("Audio",   pal.audio,  lamps.audio)
                            legendRow("Typing",  pal.typing, lamps.typing)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    /// `offFilled`:总开关那一行反过来 —— 关掉(暂停)才是实心红,开着是空心。
    private func legendRow(_ name: String, _ color: Color,
                           _ lamp: CaptureLampState.Lamp,
                           onText: String = "Recording this app right now.",
                           offFilled: Bool = false) -> some View {
        let filled = offFilled ? !lamp.on : lamp.on
        return HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(filled ? color : Color.clear)
                .overlay(Circle().stroke(color.opacity(filled ? 0 : 0.45), lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(lamp.on ? onText : (lamp.reason ?? "Off."))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textPrimary.opacity(lamp.on ? 0.55 : 0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 菜单栏图标的大号版:同心三圈星尘带(实心带外缘 7.8 / 内缘 4.68,单位是 18pt 图标),
/// 色板与 Assets 里 MenuBarLamp-* 两套 PNG 一致。菜单栏那版是静态的星云底 + 星尘;
/// 这里尺寸大,颗粒更细更密;每圈往相邻那圈渗半个环宽(交界处颜色融在一起),
/// 最外圈像 app 图标那圈一样往外散(越远越稀、越小、越淡,但更稀疏),空心内缘也散进去一点;
/// 三圈颗粒都在自己的范围里漂浮(不越出这个范围、不整体转)—— 灰环和红环也漂:
/// 看这张卡时前台就是本 app,它通常在忽略名单里,三圈多半是灰的。
private struct LampGlyph: View {
    var screen: Bool
    var audio: Bool
    var typing: Bool
    /// 总开关关(暂停)= 三圈全红。
    var paused: Bool
    var dark: Bool
    /// 漂浮相位由外层墙钟 TimelineView 传进来(外层已保证后台也在 tick)。
    var now: Date

    struct Palette { let screen, audio, typing, off, paused: Color }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// 浅色底用偏深、偏饱和的色;深色底用偏亮的色。
    static func palette(dark: Bool) -> Palette {
        dark ? Palette(screen: rgb(0xB07CFF), audio: rgb(0xFFD84D),
                       typing: rgb(0x6AA8FF), off: rgb(0x66666C),
                       paused: rgb(0xFF5A52))
             : Palette(screen: rgb(0x7A1FE0), audio: rgb(0xE0A800),
                       typing: rgb(0x2563EB), off: rgb(0xB4B4BA),
                       paused: rgb(0xE0342B))
    }

    /// 一颗星尘:极坐标位置 + 大小/透明度 + 漂浮的频率与相位。
    private struct Dust {
        let angle, radius, size, alpha: Double
        let r1, r2: Double                 // 这颗能待的内外半径(本圈带子外扩半个环宽,夹在空心与外缘之间)
        let fa, pa, fr, pr: Double         // 沿环 / 径向两个方向的摆动频率与相位
    }

    /// 三圈颗粒一次生成、固定种子:带内按面积均匀撒,渗进相邻那圈的部分越远越稀。
    /// 画布半宽(图标坐标):装下往外散的颗粒,再留一点漂浮余量。
    private static let extent = 7.8 + 3.0 * 1.2

    private static let dust: [[Dust]] = {
        // 实心带外缘 7.8 / 内缘 4.68(和菜单栏图标同宽);三圈互渗半个环宽;最外圈像 app 图标那圈一样往外散 3
        // (大多挤在环边,越外越少越小越淡,只是更稀疏),最内圈往空心里散 1
        let outer = 7.8, hole = 4.68, w = (outer - hole) / 3
        let blend = 0.5, spillOut = 3.0, spillIn = 1.0, spillFrac = 0.9
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {          // SplitMix64
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        return (0..<3).map { i in
            let r2 = outer - Double(i) * w, r1 = r2 - w
            let lo = max(hole, r1 - blend * w), hi = min(outer, r2 + blend * w)
            let n = Int(16 * Double.pi * (r2 * r2 - r1 * r1) * (1 + blend))
            // fade:散出边缘的程度(0 = 带内),越大颗粒越小越淡;漂浮范围包住它自己的位置
            func dust(_ r: Double, _ fade: Double) -> Dust {
                Dust(angle: next() * 2 * .pi,
                     radius: r,
                     size: (0.08 + next() * 0.16) * (1 - 0.5 * fade),
                     alpha: (0.55 + next() * 0.45) * (1 - 0.8 * fade),
                     r1: min(r, lo), r2: max(r, hi),
                     fa: 0.15 + next() * 0.25, pa: next() * 2 * .pi,
                     fr: 0.2 + next() * 0.3, pr: next() * 2 * .pi)
            }
            var ring: [Dust] = (0..<n).map { _ in
                var r = 0.0
                while true {
                    r = (lo * lo + next() * (hi * hi - lo * lo)).squareRoot()
                    let out = r < r1 ? (r1 - r) / (blend * w) : r > r2 ? (r - r2) / (blend * w) : 0
                    if next() > out { break }
                }
                return dust(r, 0)
            }
            // 边缘散开:越远越稀(u² 偏向边缘)
            let extra = Int(Double(n) * spillFrac)
            if i == 0 { for _ in 0..<extra { let u = pow(next(), 2.8); ring.append(dust(outer + u * spillOut, u)) } }
            if i == 2 { for _ in 0..<extra { let u = pow(next(), 2); ring.append(dust(hole - u * spillIn, u)) } }
            return ring
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            let pal = Self.palette(dark: dark)
            let k = min(size.width, size.height) / (2 * Self.extent)
            let cx = size.width / 2, cy = size.height / 2
            let t = now.timeIntervalSinceReferenceDate
            let rings: [(Bool, Color)] = [(screen, pal.screen), (audio, pal.audio), (typing, pal.typing)]
            for (i, ring) in rings.enumerated() {
                let lit = !paused && ring.0
                let color = paused ? pal.paused : (lit ? ring.1 : pal.off)
                for d in Self.dust[i] {
                    var a = d.angle, r = d.radius
                    // 沿环来回漂 + 径向晃,半径夹在自己的范围里
                    let ts = t * 2
                    a += 0.18 * sin(ts * d.fa + d.pa)
                    r = min(d.r2 - d.size, max(d.r1 + d.size, r + 0.66 * sin(ts * d.fr + d.pr)))
                    let x = cx + cos(a) * r * k, y = cy + sin(a) * r * k, rr = d.size * k
                    ctx.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: 2 * rr, height: 2 * rr)),
                             with: .color(color.opacity(d.alpha)))
                }
            }
        }
    }
}
