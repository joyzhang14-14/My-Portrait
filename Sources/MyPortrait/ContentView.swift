import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .home
    @State private var appState = AppState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NativeSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            mainPane
                .frame(minWidth: 600, minHeight: 400)
        }
        // No custom black background — let macOS materials show through.
        // Adapts to light/dark and respects the user's system tint.
        .environment(appState)
    }

    @ViewBuilder
    private var mainPane: some View {
        switch selection ?? .home {
        case .home:          HomeView()
        case .timeline:      TimelineView()
        case .connections:   ConnectionsView()
        case .pipes:         NativePlaceholder(title: "Pipes",
                                               systemImage: "puzzlepiece.extension.fill",
                                               subtitle: "Coming soon")
        case .memories:      NativePlaceholder(title: "Memories",
                                               systemImage: "sparkles",
                                               subtitle: "Coming soon")
        }
    }
}

// MARK: - Native sidebar (List + .sidebar style + Material)

private struct NativeSidebar: View {
    @Binding var selection: SidebarSection?

    var body: some View {
        List(selection: $selection) {
            // Top: workspace identity
            Section {
                EmptyView()
            } header: {
                HStack {
                    Text("My Portrait")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .textCase(nil)
            }

            // Quick actions
            Section {
                Label {
                    Text("New chat").fontWeight(.medium)
                } icon: {
                    Image(systemName: "plus.bubble")
                        .symbolRenderingMode(.hierarchical)
                }
            } header: {
                Text("Quick")
            }

            // Navigation
            Section {
                ForEach([SidebarSection.timeline, .memories, .pipes, .connections], id: \.self) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.symbol)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            } header: {
                Text("Library")
            }

            // Recents
            Section {
                ForEach(Mock.recents.prefix(8), id: \.self) { title in
                    Label {
                        Text(title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Recents")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Solid backing so the timeline / home content next door doesn't bleed
        // through the Liquid Glass sidebar edge.
        .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)   // no top bar — date isn't covered
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
