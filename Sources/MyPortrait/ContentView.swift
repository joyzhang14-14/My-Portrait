import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .timeline
    @State private var appState = AppState()
    @State private var timeline = TimelineState()
    @State private var chat = ChatController()
    @State private var chatStore = ChatStore.shared
    @State private var memoryScope: MemoryScope = .events
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
                }
            }
        }
        .environment(appState)
        .environment(chat)
        .environment(chatStore)
        .environment(ConfigStore.shared)
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTimelineAt)) { notif in
            guard let date = notif.object as? Date else { return }
            selection = .timeline
            timeline.seek(to: date)
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
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch selection ?? .home {
        case .home:          HomeView()
        case .timeline:      TimelineView(state: timeline)
        case .cronJobs:         CronJobsView(selection: $cronJobSelection)
        case .memories:      MemoriesView(scope: $memoryScope,
                                          onEditEntity: { url in
                                              chat.startEditConversation(originalURL: url)
                                              selection = .home
                                          })
        case .settings:      SettingsPane(subsection: $settingsSubsection)
        }
    }
}

