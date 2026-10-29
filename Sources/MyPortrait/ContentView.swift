import SwiftUI
import AppKit
import Observation

/// 跟踪系统当前是不是 dark。
///
/// theme = "system" 时**必须**给 SwiftUI 一个具体的 ColorScheme。传 nil
/// 的语义是"随窗口的 effectiveAppearance 走",但 NSHostingView 只在窗口
/// 重新激活(切到别的 app 再切回来)时才回头重读那个值 —— 于是
/// 「Light → System」当场毫无反应,而 AppKit 那层已经切成 dark 了,
/// 侧栏和主区的接缝处就露出一条窗口底色的黑线。
@MainActor
@Observable
final class SystemAppearanceMonitor {
    static let shared = SystemAppearanceMonitor()

    private(set) var isDark: Bool

    /// KVO 观察 NSApp.effectiveAppearance:theme=system 时 NSApp.appearance
    /// 是 nil,effectiveAppearance 就等于系统外观,系统一变它就变。
    @ObservationIgnored private var kvo: NSKeyValueObservation?

    private init() {
        isDark = Self.readIsDark()
        kvo = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Self.readIsDark()
                if now != self.isDark { self.isDark = now }
            }
        }
    }

    private static func readIsDark() -> Bool {
        guard let app = NSApp else { return false }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

struct ContentView: View {
    /// 侧栏页从 config 恢复,切页写回 —— 关窗后视图树会卸掉,重开靠它回到原页。
    @State private var selection: SidebarSection? =
        SidebarSection(rawValue: ConfigStore.shared.current.display.lastPage) ?? .timeline
    @State private var appState = AppState()
    @State private var timeline = TimelineState()
    /// Memories 上次停在哪 —— 从 config 恢复,切换时写回(见
    /// `persistMemoryLanding`)。切走再切回不会被扔回 Events。
    @State private var dataScope: DataScope = MemoryLanding.restoredScope()
    /// Memories 区 text/Neural Graph 查看模式(切换钮在侧栏,内容在 mainPane)。
    @State private var dataViewMode: DataViewMode = MemoryLanding.restoredViewMode()
    /// 图谱浮窗 wr chip 跳转注入:切回 text/Input 后要定位的 record id。
    @State private var memoryInputJump: Int64? = nil
    @State private var settingsSubsection: SettingsSubsection? = {
        let raw = ConfigStore.shared.current.display.lastSettingsPage
        return SettingsSubsection.allCases.first { $0.id == raw } ?? .app(.general)
    }()
    /// 首启 onboarding 状态。绑定 ConfigStore.general.onboardingCompleted。
    /// false → ContentView 起来后立刻弹 onboarding sheet 挡主 UI;
    /// onFinish 把 flag 置 true → sheet 自动关。
    @State private var configStore = ConfigStore.shared
    /// theme = "system" 时用它把系统外观解析成具体的 light/dark。
    @State private var systemAppearance = SystemAppearanceMonitor.shared

    /// health.log 内存采样行用的页面名。data 再分图谱/文字 ——
    /// 排查「停在图谱页内存涨」这类问题时粒度刚好。
    private var pageName: String {
        guard let sel = selection else { return "none" }
        if sel == .data { return "data(\(String(describing: dataViewMode)))" }
        return sel.rawValue
    }

    var body: some View {
        // 首启:onboardingCompleted == false → 主 view 完全不渲染,只显示
        // OnboardingView 填满整个窗口;走完 flag 置 true → SwiftUI 重新计算
        // body 显示主 view。**不用 sheet** 因为:
        //   1. sheet 会让主 view 在背后渲染(白屏闪 / 启动负载,用户能看到)
        //   2. sheet content 不继承父的 .environment(...) 注入,
        //      ConnectAIStep 用 @Environment(AppState) 会 crash:
        //      "No Observable object of type AppState found"
        // Group + if/else 的好处:environment 注入到外层 Group,两个分支都拿得到。
        Group {
            if configStore.current.general.onboardingCompleted {
                mainContent
            } else {
                onboardingContent
            }
        }
        .environment(appState)
        .environment(ConfigStore.shared)
        // **SwiftUI colorScheme 必须显式 .preferredColorScheme()** 强制 ——
        // ConfigApplier 设了 NSApp.appearance 影响 AppKit chrome,但 SwiftUI
        // view tree 不会自动 reload colorScheme,所有 Theme.textPrimary
        // / Color(nsColor:) 等 dynamic 颜色不变。这里读 config.display.theme
        // 直接告诉 SwiftUI 切。"system" → nil 跟 macOS 走。
        .preferredColorScheme(Self.preferredScheme(configStore.current.display.theme,
                                                   systemIsDark: systemAppearance.isDark))
        .onAppear {
            // 存量 folder 颜色一次性固化(07-10 update:没设色的 folder 此前每次
            // 启动换色,详见 EventFolderStore.migrateAssignColors)。幂等。
            EventFolderStore.migrateAssignColors()
            HealthMonitor.shared.currentPage = pageName
        }
        // 内存采样行(health.log 的 MEM)要标当前页面 —— 切页/切图谱模式时更新。
        .onChange(of: selection) { _, sel in
            HealthMonitor.shared.currentPage = pageName
            if let sel { ConfigStore.shared.mutateDeferred { $0.display.lastPage = sel.rawValue } }
        }
        .onChange(of: settingsSubsection) { _, sub in
            if let sub { ConfigStore.shared.mutateDeferred { $0.display.lastSettingsPage = sub.id } }
        }
        .onChange(of: dataViewMode) { _, _ in HealthMonitor.shared.currentPage = pageName }
        // 图谱浮窗 wr chip → 切到 Neural Graph 模式的 Input(打字活动面积图)
        // 并定位该 record。
        .onReceive(NotificationCenter.default.publisher(for: .memoryJumpToInputRecord)) { notif in
            guard let id = notif.object as? Int64 else { return }
            selection = .data
            dataViewMode = .neuralGraph
            dataScope = .input
            memoryInputJump = id
        }
        // Memories 停在哪就记在哪。**两个都要监听** —— 只记 scope 的话,
        // 用户在 Events 上切到图谱视图,下次回来又是文字视图。
        // ConfigStore 的写盘本来就是 debounce 的,切标签的频率不用担心。
        .onChange(of: dataScope) { _, s in
            MemoryLanding.persist(scope: s, mode: dataViewMode)
        }
        .onChange(of: dataViewMode) { _, m in
            MemoryLanding.persist(scope: dataScope, mode: m)
        }
    }

    /// Onboarding 全屏分支。dev mode 下同样挂标题栏警示条 —— replay 是从
    /// dev 卡点进来的,不提示的话很容易忘了自己看的是演示环境。固定橙色
    /// read only:onboarding 写的 onboardingCompleted / 供应商选择等都在
    /// 跟 dev 走的 config section 里,不动真实数据。
    private var onboardingContent: some View {
        onboardingView
            .overlay(alignment: .top) {
                if DevMode.isOn {
                    DevModeTitlebarBanner(live: false)
                }
            }
    }

    /// 标题栏警示条本体 —— mainContent 的注释里有形态/实现的完整来龙去脉
    ///(零高锚点 + background 里 ZStack ignoresSafeArea 向上扩进标题栏)。
    /// 抽成组件是因为 onboarding 分支也要挂(08-09 update)。
    private struct DevModeTitlebarBanner: View {
        let live: Bool
        var body: some View {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .background {
                    ZStack {
                        Rectangle().fill(live ? Color.red.opacity(0.80)
                                              : Color.orange.opacity(0.85))
                        Text(live ? "DEV MODE · THIS PAGE WRITES YOUR REAL DATA"
                                  : "DEV MODE · demo data")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(live ? Color.white.opacity(0.95)
                                                  : Color.black.opacity(0.8))
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)   // 纯标识,别挡下面内容的点击
        }
    }

    private var onboardingView: some View {
        OnboardingView {
                    // 写 flag + 立即 flush —— debounced 写默认 ~1s 才落盘,
                    // 用户 Finish 后秒退应用就会丢这条记录,下次启动又看到 onboarding。
                    configStore.mutate { $0.general.onboardingCompleted = true }
                    configStore.saveNow()
                    // **Replay onboarding 场景**:OnboardingView 比 mainContent
                    // intrinsic 小,SwiftUI 切回 mainContent 那一刻 NSHostingView
                    // 第一帧 layout 报小尺寸,window 被收到 onboarding size。
                    // 虽然 hosting.sizingOptions=[] 禁了持续反馈,但 swap 时
                    // 那一帧仍会触发 setContentSize。这里 finish 后主动复位回
                    // App.swift 启动时设的 1200×835。用户不需要再点 Timeline 才正常。
                    DispatchQueue.main.async {
                        if let win = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                            win.setContentSize(NSSize(width: 1200, height: 835))
                            win.center()
                        }
                    }
        }
    }

    /// 把 config.display.theme 字符串("system" / "light" / "dark")映射到
     /// SwiftUI 的 preferredColorScheme。"system" → nil(跟 macOS 走)。
    /// **system 也返回具体值,不返回 nil** —— 见 SystemAppearanceMonitor 顶部
    /// 注释:nil 会让切回 system 时 view tree 不刷新。
    private static func preferredScheme(_ raw: String, systemIsDark: Bool) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return systemIsDark ? .dark : .light
        }
    }

    /// 主 view 本体 —— 用户完成 onboarding 后渲染。封成 computed property
    /// 让 body 的 if/else 干净。
    private var mainContent: some View {
        // dev mode 常驻提示条 —— 界面读的是 ~/.portrait-dev 的编造数据,
        // 且采集/隐私/存储/调度/记忆那几页是只读的。没有它很容易忘了自己
        // 在 dev 里,对着假数据排查真问题。
        //
        // 形态(08-09 update):把标题栏本身染成警示条 —— 不在内容区加任何一行,
        // 零额外高度,橙色区域 = 标题栏,红绿灯照常(系统把窗口按钮画在内容之上),
        // 文字垂直居中在标题栏那一行里。
        //
        // 实现:锚点是 overlay 顶端一个**零高**的透明视图(不占布局、不遮
        // 内容),它的 background 里放 ZStack + ignoresSafeArea(.top) ——
        // 零高视图贴着安全区上沿,ZStack 从那里向上扩进标题栏,恰好铺满它,
        // 文字也随 ZStack 居中在标题栏内。
        mainSplit
            .overlay(alignment: .top) {
                if DevMode.isOn {
                    DevModeTitlebarBanner(live: paneTouchesRealData)
                }
            }
            .frame(minWidth: 1200, minHeight: 835)
    }

    /// 当前这一屏**能不能动到真实数据** —— dev mode 顶条据此变红。
    ///
    /// dev mode 保护的是"存在 config.toml 里的设置"和"events / portrait
    /// 两份数据",这几处不在保护范围内、且是有意为之:
    ///   - Connections / Downloads → 凭据在 `secrets.sqlite`,**永远是真实那份**
    ///     (这正是"切过去不用重新绑定供应商"的前提)
    ///   - Notifications → 跟真实配置跑
    /// 灰不掉也不该灰,所以改成把风险写在脸上。
    private var paneTouchesRealData: Bool {
        switch selection ?? .timeline {
        case .settings:
            switch settingsSubsection ?? .app(.general) {
            case .app(.connections), .app(.downloads), .app(.notifications):
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private var mainSplit: some View {
        HStack(spacing: 0) {
            TimelineSidebar(state: timeline,
                            selection: $selection,
                            dataScope: $dataScope,
                            dataViewMode: $dataViewMode,
                            settingsSubsection: $settingsSubsection)
                .frame(width: 300)
                .frame(maxHeight: .infinity)

            // Hairline separator. A plain `Divider()` stops at the title-bar
            // safe-area inset, leaving a 1px gap there through which the
            // window's black background shows — so use a Rectangle that
            // ignores the safe area and runs the full window height.
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1)
                .ignoresSafeArea()

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 右侧画布拖窗。底图(SidebarBackdrop / AmbientBackground)上
                // 那份手势只在没有 ScrollView 压着时才收得到事件 —— 设置类
                // 页面整页都是 ScrollView,画布空白因此拖不动。挂在 pane 这
                // 一层就绕过了:SwiftUI 里**子视图的手势优先于父视图**,所以
                // 按钮 / 开关 / 输入框 / 列表行 / 图谱照样自己吃掉拖拽,只有
                // 没人认领的空白才落到这条手势上。
                .gesture(WindowDragGesture())
        }
        // 最小尺寸约束在外层 mainContent 上(dev 提示条也算进去)。否则首启 /
        // Replay onboarding finish 时 NSHostingView 第一帧 layout 报 pane 自身
        // intrinsic(Home / Settings 等较小),触发 window 缩小一瞬。
    }

    @ViewBuilder
    private var mainPane: some View {
        switch selection ?? .timeline {
        case .timeline:      TimelineView(state: timeline)
        case .data:
            // Neural Graph 模式覆盖 events/portrait/input;personalInfo 走专属表单。
            if dataViewMode == .text, dataScope == .textSettings {
                DataTextSettingsView()
            } else if dataViewMode == .neuralGraph, dataScope == .neuralGraphSettings {
                // Neural Graph 侧栏 GRAPH 下的设置入口(主球照片等)。
                NeuralGraphSettingsView()
            } else if dataViewMode == .neuralGraph,
                      DataViewMode.supportsNeuralGraph(dataScope) {
                // input 的图谱形态是打字活动面积图,不走力导向 GraphRootView。
                if dataScope == .input {
                    InputActivityChartView(jumpToRecordId: $memoryInputJump)
                } else {
                    GraphRootView(scope: $dataScope)
                }
            } else {
                DataView(scope: $dataScope,
                             externalInputJump: $memoryInputJump)
            }
        case .settings:      SettingsPane(subsection: $settingsSubsection)
        }
    }
}
