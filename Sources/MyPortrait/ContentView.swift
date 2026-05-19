import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .timeline
    @State private var appState = AppState()
    @State private var timeline = TimelineState()
    @State private var chat = ChatController()
    @State private var chatStore = ChatStore.shared
    @State private var memoryScope: MemoryScope = .events
    @State private var pipeSelection: UUID? = nil
    @State private var settingsSubsection: SettingsSubsection? = .general

    var body: some View {
        HStack(spacing: 0) {
            TimelineSidebar(state: timeline,
                            selection: $selection,
                            chat: chat,
                            memoryScope: $memoryScope,
                            pipeSelection: $pipeSelection,
                            settingsSubsection: $settingsSubsection)
                .frame(width: 300)
                .frame(maxHeight: .infinity)

            Divider()

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
            let resolver: () -> (Provider, String) = {
                guard let id = appState.activeAIId,
                      let p = Provider.from(integrationId: id)
                else { return (.chatgpt, Provider.chatgpt.defaultModel) }
                return (p, appState.currentModel(forIntegrationId: id))
            }
            chat.providerResolver = resolver
            SuggestionEngine.shared.providerResolver = resolver

            // Wire the scheduler so it can fire templates + pipes into the
            // chat / pipe-store when their cadence ticks.
            ScheduleRunner.shared.dispatch = { template in
                chat.switchTo(nil)
                let chips = [template.window.resolveChip()].compactMap { $0 }
                chat.send(template.prompt, chips: chips)
            }
            ScheduleRunner.shared.dispatchPipe = { pipe in
                PipeExecutor.run(pipe)
            }
            PipeExecutor.providerResolver = resolver
            ScheduleRunner.shared.start()
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
        case .connections:   ConnectionsView()
        case .pipes:         PipesView(selection: $pipeSelection)
        case .memories:      MemoriesView(scope: $memoryScope)
        case .settings:      SettingsPane(subsection: $settingsSubsection)
        }
    }
}

// MARK: - Native placeholder

private struct NativePlaceholder: View {
    let title: String
    let systemImage: String
    let subtitle: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let subtitle {
                Text(subtitle)
            }
        }
    }
}
