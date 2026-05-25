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

    var body: some View {
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
        .environment(appState)
        .environment(chat)
        .environment(chatStore)
        .environment(ConfigStore.shared)
        .onAppear {
            // Bind chat.providerResolver to the live appState so each new
            // PiAgent spawns against whichever provider the user picked in
            // Connections.
            let resolver: () -> (Provider, String, String?) = {
                // If a default AI preset is configured, it wins — uses its own
                // provider, model, and SecretStore-stored API key ref.
                if let preset = ConfigStore.shared.aiModels.presets.first(where: { $0.isDefault }),
                   let p = Provider(rawValue: preset.provider) {
                    return (p, preset.model, preset.apiKeyRef.isEmpty ? nil : preset.apiKeyRef)
                }
                // Otherwise fall back to the per-tile connection chosen in
                // Connections / the input-bar provider picker.
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
            CronJobExecutor.providerResolver = resolver
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

