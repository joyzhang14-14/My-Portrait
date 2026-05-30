import AppKit
import SwiftUI

/// 屏幕右上漂浮的通知浮窗(NSPanel)+ SwiftUI 卡片渲染。
///
/// - NSPanel:`.borderless` + `.nonactivatingPanel`,`.floating` 级别,
///   `canJoinAllSpaces / fullScreenAuxiliary` —— 跨 Space、不抢焦、主窗口
///   隐藏也照常显示。
/// - 内容透传:背景透明(`isOpaque = false`),卡片自带磨砂 + 阴影。
/// - 鼠标:`ignoresMouseEvents` 仅当列表空时 true(避免空浮窗挡住下面 app
///   的点击);有通知时为 false,允许点关 × 和卡片本身。
@MainActor
final class NotificationOverlay {
    static let shared = NotificationOverlay()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotificationOverlayView>?
    /// 单卡最小高度(空 panel/动画启动时给个保底),实际看 SwiftUI 报上来的 size。
    private let minPanelHeight: CGFloat = 60
    /// panel 宽度 —— 固定。
    private let panelWidth: CGFloat = 320
    /// panel 距屏幕顶部的距离(标题栏 + 安全边距)。
    private let topInset: CGFloat = 20

    private init() {}

    /// 有通知时调:lazy 安装 panel + orderFront。idempotent。
    func show() {
        ensureInstalled()
        guard let p = panel else { return }
        // 当前高度保持(已被 onPreferenceChange resize 过)。
        positionPanel(p, height: p.frame.height)
        p.orderFrontRegardless()
    }

    /// 没通知时调:把 panel `orderOut`,屏幕上完全消失(不占空间,
    /// 不接事件,不挡鼠标 hit-test)。panel 实例保留在内存,下次
    /// show 不用重建。
    func hide() {
        panel?.orderOut(nil)
    }

    /// idempotent;构造 panel + hosting view,但不一定显示。
    private func ensureInstalled() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = false   // 让卡片可点

        // 让 SwiftUI overlay 把"卡片 stack 实测高度"回报上来,我们动态
        // resize NSPanel,这样高度跟内容自适应 —— 单卡时小,多卡 / 多行
        // markdown 时长,完全跟着 SwiftUI 算的 intrinsic content size 走。
        let host = NSHostingView(rootView: NotificationOverlayView(
            onContentSizeChange: { [weak self] size in
                self?.resizePanel(toContentHeight: size.height)
            }
        ))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        hostingView = host

        positionPanel(p, height: minPanelHeight)
        panel = p

        // 屏幕配置变化时重定位(分辨率切换、外接显示器拔插)。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.panel else { return }
                self.positionPanel(p, height: p.frame.height)
            }
        }
    }

    /// 钉在主屏幕右上角,留出菜单栏 + 安全边距。高度由 caller 决定。
    private func positionPanel(_ p: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // 屏幕极端短时给个 hard cap,避免 panel 比屏幕还高。
        let h = max(minPanelHeight, min(height, visible.height - 40))
        let x = visible.maxX - panelWidth - 16
        let y = visible.maxY - h - topInset
        p.setFrame(NSRect(x: x, y: y, width: panelWidth, height: h), display: true)
    }

    /// SwiftUI 报上来"卡片 stack 实测高度" → resize panel,top edge 锚定
    /// 不动。size 是 SwiftUI 测量的卡片 VStack 高度(含 padding)。
    fileprivate func resizePanel(toContentHeight contentHeight: CGFloat) {
        guard let p = panel else { return }
        positionPanel(p, height: contentHeight)
    }
}

// MARK: - SwiftUI: overlay container

/// 堆叠卡片的容器。observe NotificationCenterService.active。
struct NotificationOverlayView: View {
    private let service = NotificationCenterService.shared
    /// SwiftUI 测出"卡片 stack 实际高度"后回报给 NSPanel 让它 resize。
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        // **没 Spacer + 不再 maxHeight: .infinity** —— VStack 自然按内容
        // 算高度。背景塞 GeometryReader 读真实尺寸,通过 PreferenceKey
        // 回报上去触发 panel resize。
        VStack(spacing: 8) {
            ForEach(service.active.reversed()) { n in
                NotificationCardView(notification: n) {
                    service.dismiss(n.id)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    )
                )
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ContentSizePreferenceKey.self,
                    value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            onContentSizeChange(size)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: service.active.count)
        // 没卡片时整张 view 透传点击;有卡片时只让卡片接受点击。
        .allowsHitTesting(!service.active.isEmpty)
    }
}

/// 把 SwiftUI 测出的卡片 stack 实际大小往上传 —— NSPanel 根据这个值
/// resize 自己,实现"banner 多大,浮窗就多大"。
private struct ContentSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - SwiftUI: card

/// 单条通知卡片。磨砂背景 + 圆角 + 阴影,markdown 渲染,自动收缩进度条。
struct NotificationCardView: View {
    let notification: InAppNotification
    let onDismiss: () -> Void

    @State private var hover = false
    @State private var pressed = false
    @State private var elapsed: TimeInterval = 0
    @State private var tickTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private var progress: Double {
        max(0, min(1, 1 - elapsed / notification.timeout))
    }

    private var bodyAttributed: AttributedString {
        // .inlineOnlyPreservingWhitespace:保留换行,只渲染行内 markdown
        // (粗体/code/链接);避免 block 语法把 # 当标题等。
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: notification.body, options: opts))
            ?? AttributedString(notification.body)
    }

    /// 跟 colorScheme 切的 fill/stroke/shadow。原来钉死的全是 dark
     /// 风格(black 30% 底 + white stroke + black 38% shadow),在 light
     /// 主题下看着是"灰底 + 黑影晕开",非常突兀。
    private var bgFill: Color {
        colorScheme == .light ? Color.white.opacity(0.85) : Color.black.opacity(0.30)
    }
    private var strokeColors: [Color] {
        colorScheme == .light
            ? [Color.black.opacity(0.08), Color.black.opacity(0.03)]
            : [Color.white.opacity(0.20), Color.white.opacity(0.05)]
    }
    private var shadowColor: Color {
        colorScheme == .light ? .black.opacity(0.10) : .black.opacity(0.38)
    }
    private var progressTrackColor: Color {
        colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Mute 按钮:只对 cron job 通知出现,hover 才显形(跟 dismiss 同款)。
                // 点击后把这条 cron job 标 muted=true,本条 banner 也一并 dismiss。
                if let jobId = notification.cronJobId {
                    Button {
                        CronJobStore.shared.setMuted(jobId, true)
                        onDismiss()
                    } label: {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.85 : 0.0))
                    }
                    .buttonStyle(.plain)
                    .help("Mute this cron job")
                    .animation(.easeOut(duration: 0.15), value: hover)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.9 : 0.0))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .animation(.easeOut(duration: 0.15), value: hover)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // body markdown
            Text(bodyAttributed)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.93))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            // 进度条(倒计时收缩)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(progressTrackColor)
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [Color.purple.opacity(0.65), Color.blue.opacity(0.55)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **clipShape 套在 VStack 整体上**——之前只 clip 了 background,
        // 内容里的进度条 Rectangle 在底部直边,会"漏"出圆角之外露白。
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            // 磨砂玻璃 + 圆角 + 高光描边。stroke 加在 background 里跟
            // 内容一起被 clipShape 裁。
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blending: .behindWindow)
                RoundedRectangle(cornerRadius: 12)
                    .fill(bgFill)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: strokeColors,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .shadow(color: shadowColor, radius: 14, x: 0, y: 6)
        .scaleEffect(pressed ? 0.97 : (hover ? 1.01 : 1.0))
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .padding(.horizontal, 10)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation { pressed = false }
                notification.onTap?()
                onDismiss()
            }
        }
        // 进度条 + 自动消失由这个(可暂停)tick 驱动:hover 时暂停累加 elapsed
        // (见下面 onChange),跑满 timeout → service.timeoutReached 触发
        // onTimeout + dismiss。原来用墙钟,hover 停不下来。
        .onAppear { startTick() }
        .onDisappear { stopTick() }
        .onChange(of: hover) { _, hovering in
            // 鼠标悬停 → 暂停倒计时 + 进度条;移开 → 从当前进度继续。
            if hovering { stopTick() } else { startTick() }
        }
    }

    /// 启动/继续进度条 tick:每 50ms 累加 0.05s。hover 暂停后 resume 时
    /// 从当前 elapsed 续跑(不重置)。跑满 → 回调 service 完成消失。
    private func startTick() {
        guard tickTask == nil else { return }   // 已在跑就别重复起
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                elapsed += 0.05
                if elapsed >= notification.timeout {
                    tickTask = nil
                    NotificationCenterService.shared.timeoutReached(notification.id)
                    return
                }
            }
        }
    }
    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }
}

// MARK: - NSVisualEffectView SwiftUI bridge

/// SwiftUI 包 NSVisualEffectView。`.hudWindow` material 在浮窗上看起来跟原生
/// 通知中心一致(深色磨砂 + 透光)。`.behindWindow` 让它真的磨屏幕底下的内容。
struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
