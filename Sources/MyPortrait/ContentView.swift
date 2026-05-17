import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .timeline
    @State private var appState = AppState()
    @State private var timeline = TimelineState()

    var body: some View {
        // Plain HStack — no NavigationSplitView. The previous
        // NavigationSplitView kept computing a phantom toolbar safe-area
        // inset that shifted the detail content vertically when state
        // changed (e.g. switching dates). A fixed-width HStack has zero
        // navigation magic so layout is fully deterministic.
        HStack(spacing: 0) {
            TimelineSidebar(state: timeline, selection: $selection)
                .frame(width: 300)
                .frame(maxHeight: .infinity)

            Divider()

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(appState)
    }

    @ViewBuilder
    private var mainPane: some View {
        switch selection ?? .home {
        case .home:          HomeView()
        case .timeline:      TimelineView(state: timeline)
        case .connections:   ConnectionsView()
        case .pipes:         NativePlaceholder(title: "Pipes",
                                               systemImage: "puzzlepiece.extension.fill",
                                               subtitle: "Coming soon")
        case .memories:      MemoriesView()
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
