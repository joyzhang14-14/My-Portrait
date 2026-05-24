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

    private init() {}

    /// 首次有通知时安装。idempotent。
    func ensureInstalled() {
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
        p.ignoresMouseEvents = false   // 让卡片可点;空列表时 view 自己 allowsHitTesting=false

        let host = NSHostingView(rootView: NotificationOverlayView())
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        hostingView = host

        positionPanel(p)
        p.orderFrontRegardless()
        panel = p

        // 屏幕配置变化时重定位(分辨率切换、外接显示器拔插)。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.panel else { return }
                self.positionPanel(p)
            }
        }
    }

    /// 钉在主屏幕右上角,留出菜单栏 + 安全边距。
    private func positionPanel(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = visible.height - 40   // 给底边留点空气
        let x = visible.maxX - panelWidth - 16
        let y = visible.minY + 20
        p.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}

// MARK: - SwiftUI: overlay container

/// 堆叠卡片的容器。observe NotificationCenterService.active。
struct NotificationOverlayView: View {
    private let service = NotificationCenterService.shared

    var body: some View {
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
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.trailing, 0)
        .padding(.leading, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: service.active.count)
        // 没卡片时整张 view 透传点击;有卡片时只让卡片接受点击。
        .allowsHitTesting(!service.active.isEmpty)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(hover ? 0.9 : 0.0))
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
                .foregroundStyle(.white.opacity(0.93))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            // 进度条(倒计时收缩)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.06))
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
        .background(
            // 磨砂玻璃 + 圆角 + 高光描边
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blending: .behindWindow)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.30))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 6)
        .scaleEffect(pressed ? 0.97 : (hover ? 1.01 : 1.0))
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .padding(.horizontal, 16)
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
        .onAppear {
            // 进度条 ticker:50ms 一次更新 elapsed,驱动条收缩
            let start = Date()
            let timeout = notification.timeout
            tickTask = Task { @MainActor in
                while !Task.isCancelled {
                    let dt = Date().timeIntervalSince(start)
                    elapsed = dt
                    if dt >= timeout { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        .onDisappear { tickTask?.cancel(); tickTask = nil }
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
