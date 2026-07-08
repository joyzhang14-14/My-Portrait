import SwiftUI
import AppKit

struct ContentView: View {
    @State private var selection: SidebarSection? = .timeline
    @State private var appState = AppState()
    @State private var timeline = TimelineState()
    @State private var chat = ChatController()
    @State private var chatStore = ChatStore.shared
    @State private var memoryScope: MemoryScope = .events
    /// Memories 区 text/canvas 查看模式(切换钮在侧栏,内容在 mainPane)。
    @State private var memoryViewMode: MemoryViewMode = .text
    /// 图谱浮窗 wr chip 跳转注入:切回 text/Input 后要定位的 record id。
    @State private var memoryInputJump: Int64? = nil
    @State private var cronJobSelection: UUID? = nil
    @State private var settingsSubsection: SettingsSubsection? = .app(.general)
    /// 首启 onboarding 状态。绑定 ConfigStore.general.onboardingCompleted。
    /// false → ContentView 起来后立刻弹 onboarding sheet 挡主 UI;
    /// onFinish 把 flag 置 true → sheet 自动关。
    @State private var configStore = ConfigStore.shared

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
        }
        .environment(appState)
        .environment(chat)
        .environment(chatStore)
        .environment(ConfigStore.shared)
        // **SwiftUI colorScheme 必须显式 .preferredColorScheme()** 强制 ——
        // ConfigApplier 设了 NSApp.appearance 影响 AppKit chrome,但 SwiftUI
        // view tree 不会自动 reload colorScheme,所有 Theme.textPrimary
        // / Color(nsColor:) 等 dynamic 颜色不变。这里读 config.display.theme
        // 直接告诉 SwiftUI 切。"system" → nil 跟 macOS 走。
        .preferredColorScheme(Self.preferredScheme(configStore.current.display.theme))
        .onAppear {
            // Bind chat.providerResolver to the live appState so each new
            // PiAgent spawns against whichever provider the user picked in
            // Connections.
            //
            // 优先级:
            //   1. 当前 conv 有锁定 (providerId/model 非 NULL) → 用 conv 的
            //      这条让"切回老 conv,picker 显示当时选过的 model"成立。
            //   2. AI preset 标了 default → 用 preset(单一全局默认)
            //   3. fallback appState.activeAIId(全局 picker 选择)
            let resolver: (UUID?) -> (Provider, String, String?) = { convId in
                if let convId,
                   case let (lockedProvider, lockedModel) = chatStore.conversationModel(id: convId),
                   let pid = lockedProvider,
                   let model = lockedModel,
                   let p = Provider(rawValue: pid) {
                    return (p, model, nil)
                }
                if let preset = ConfigStore.shared.aiModels.presets.first(where: { $0.isDefault }),
                   let p = Provider(rawValue: preset.provider) {
                    return (p, preset.model, preset.apiKeyRef.isEmpty ? nil : preset.apiKeyRef)
                }
                guard let id = appState.activeAIId,
                      let p = Provider.from(integrationId: id)
                else { return (.chatgpt, Provider.chatgpt.defaultModel, nil) }
                return (p, appState.currentModel(forIntegrationId: id), nil)
            }
            chat.providerResolver = resolver

            // Wire the scheduler so it can fire templates + cronJobs into the
            // chat / cronJob-store when their cadence ticks.
            ScheduleRunner.shared.dispatch = { template in
                chat.switchTo(nil)
                let chips = [template.window.resolveChip()].compactMap { $0 }
                chat.send(template.prompt, chips: chips)
            }
            ScheduleRunner.shared.dispatchCronJob = { cronJob in
                CronJobExecutor.run(cronJob)
            }
            // CronJobExecutor 不属于任何 conv,永远走全局(nil convId 让
            // resolver 跳过 per-conv lock 那条分支)。
            CronJobExecutor.providerResolver = { resolver(nil) }
            // cron 跑的时候每次落盘 → 若用户正看这条 conv,live 重读让前端
            // 像普通 chat 一样逐段刷 thinking / 指令。
            CronJobExecutor.onConvUpdated = { convId in
                chat.liveReloadIfViewing(convId)
            }
            ScheduleRunner.shared.start()

            // 点 cron job 通知卡片 → 切 conv + 主窗口拉到前台。
            NotificationCenterService.shared.onCronJobTap = { convId in
                chat.switchTo(convId)
                selection = .home
                (NSApp.delegate as? AppDelegate)?.showMainWindow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selection = .home
        }
        // 图谱浮窗 wr chip → 切回 text 模式的 Input 并定位该 record(需求 §5.1)。
        .onReceive(NotificationCenter.default.publisher(for: .memoryJumpToInputRecord)) { notif in
            guard let id = notif.object as? Int64 else { return }
            selection = .memories
            memoryViewMode = .text
            memoryScope = .input
            memoryInputJump = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTimelineAt)) { notif in
            guard let date = notif.object as? Date else { return }
            selection = .timeline
            timeline.seek(to: date)
        }
    }

    /// 把 config.display.theme 字符串("system" / "light" / "dark")映射到
     /// SwiftUI 的 preferredColorScheme。"system" → nil(跟 macOS 走)。
    private static func preferredScheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    /// 主 view 本体 —— 用户完成 onboarding 后渲染。封成 computed property
    /// 让 body 的 if/else 干净。
    private var mainContent: some View {
        HStack(spacing: 0) {
            TimelineSidebar(state: timeline,
                            selection: $selection,
                            chat: chat,
                            memoryScope: $memoryScope,
                            memoryViewMode: $memoryViewMode,
                            cronJobSelection: $cronJobSelection,
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
                // 仅 chat 区(Home)启用全区域文件 / 图片拖拽接收靶。
                // 把文件 / 图片拖到 sidebar 之外的任何 chat 空白处都 OK,
                // 拖到输入框 / 消息上也 OK(allowsHitTesting=false 不挡)。
                .chatDropZone(enabled: (selection ?? .home) == .home)
        }
        // 强制 mainContent intrinsic 不小于启动默认 size。否则首启 / Replay
        // onboarding finish 时 NSHostingView 第一帧 layout 报 pane 自身
        // intrinsic(Home / Settings 等较小),触发 window 缩小一瞬。
        // Timeline 自带很大 intrinsic 所以切到它能立刻恢复 —— 但用户进任何
        // 其他 pane 时窗口都该一开始就完整。
        .frame(minWidth: 1200, minHeight: 835)
    }

    @ViewBuilder
    private var mainPane: some View {
        switch selection ?? .home {
        case .home:          HomeView()
        case .timeline:      TimelineView(state: timeline)
        case .cronJobs:         CronJobsView(selection: $cronJobSelection)
        case .memories:
            // canvas 模式只覆盖 events/portrait;personalInfo/input 没有图谱
            // 形态,即便 mode==canvas 也走列表(侧栏点击它们时会把 mode 拨回 text)。
            if memoryViewMode == .canvas, MemoryViewMode.supportsCanvas(memoryScope) {
                // input 的图谱形态是打字活动面积图,不走力导向 GraphRootView。
                if memoryScope == .input {
                    InputActivityChartView()
                } else {
                    GraphRootView(scope: $memoryScope)
                }
            } else {
                MemoriesView(scope: $memoryScope,
                             onEditEntity: { url in
                                 chat.startEditConversation(originalURL: url)
                                 selection = .home
                             },
                             externalInputJump: $memoryInputJump)
            }
        case .settings:      SettingsPane(subsection: $settingsSubsection)
        }
    }
}

