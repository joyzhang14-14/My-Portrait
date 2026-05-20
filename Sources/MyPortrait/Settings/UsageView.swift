import SwiftUI

/// Aggregates the token / conversation / pipe-run counters we already track
/// in memory so the user can see how much they've used. No charts — just
/// concrete numbers in glass cards.
struct UsageSettingsView: View {
    @State private var config = ConfigStore.shared
    @Environment(ChatController.self) private var chat
    @Environment(ChatStore.self) private var chatStore
    @State private var pipeStore = PipeStore.shared

    var body: some View {
        SettingsPage("Usage", subtitle: "What you've put through My Portrait") {

            HStack(spacing: 8) {
                ForEach(UsageRange.allCases) { r in
                    UsageRangeChip(label: r.label, active: config.current.usage.range == r.rawValue) {
                        config.mutate { $0.usage.range = r.rawValue }
                    }
                }
                Spacer()
            }
            .padding(.bottom, 4)

            HStack(spacing: 14) {
                MetricTile(label: "Conversations",
                           value: "\(filteredConvs.count)",
                           icon: "bubble.left.and.bubble.right",
                           accent: .purple)
                MetricTile(label: "Pipes configured",
                           value: "\(pipeStore.pipes.count)",
                           icon: "antenna.radiowaves.left.and.right",
                           accent: .cyan)
                MetricTile(label: "Pipe runs",
                           value: "\(pipeRunTotal)",
                           icon: "play.circle",
                           accent: .pink)
            }

            SettingsCard(title: "Tokens by conversation",
                         footnote: "Counts are estimated from text length when the provider doesn't report usage.") {
                if chat.tokenUsageByConv.isEmpty && chatStore.conversations.isEmpty {
                    Text("No conversations yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(Array(filteredConvs.prefix(20))) { conv in
                        SettingsRow(conv.title,
                                    description: usageLine(for: conv.id),
                                    icon: "text.bubble") {
                            Text("\(chat.tokenTotal(for: conv.id))")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if conv.id != filteredConvs.prefix(20).last?.id {
                            SettingsDivider()
                        }
                    }
                }
            }

            SettingsCard(title: "Recent pipe runs") {
                let runs = recentPipeRuns()
                if runs.isEmpty {
                    Text("No pipe runs yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(Array(runs.prefix(10).enumerated()), id: \.offset) { idx, row in
                        SettingsRow(row.pipeName,
                                    description: row.subtitle,
                                    icon: "play.fill") {
                            Text(row.timeAgo)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if idx < min(runs.count, 10) - 1 { SettingsDivider() }
                    }
                }
            }
        }
    }

    // MARK: helpers

    /// Convert the selected chip into an inclusive "since" date. `nil` = all-time.
    private var rangeStart: Date? {
        let raw = config.current.usage.range
        guard let r = UsageRange(rawValue: raw) else { return nil }
        switch r {
        case .last24h: return Date().addingTimeInterval(-24 * 3600)
        case .last7d:  return Date().addingTimeInterval(-7 * 86_400)
        case .last30d: return Date().addingTimeInterval(-30 * 86_400)
        case .all:     return nil
        }
    }

    /// Conversations whose `updatedAt` is inside the selected window.
    private var filteredConvs: [Conversation] {
        guard let since = rangeStart else { return chatStore.conversations }
        return chatStore.conversations.filter { $0.updatedAt >= since }
    }

    private var pipeRunTotal: Int {
        if let since = rangeStart {
            return pipeStore.pipes.reduce(0) { $0 + $1.runs.filter { $0.startedAt >= since }.count }
        }
        return pipeStore.pipes.reduce(0) { $0 + $1.runs.count }
    }

    private func usageLine(for convId: UUID) -> String? {
        if let u = chat.tokenUsageByConv[convId] {
            return "in \(u.input) · out \(u.output)"
        }
        return "estimated"
    }

    private struct RunRow { let pipeName: String; let subtitle: String; let timeAgo: String; let when: Date }

    private func recentPipeRuns() -> [RunRow] {
        let since = rangeStart
        var all: [RunRow] = []
        for p in pipeStore.pipes {
            for r in p.runs {
                if let since, r.startedAt < since { continue }
                let df = RelativeDateTimeFormatter(); df.unitsStyle = .short
                all.append(RunRow(
                    pipeName: p.name,
                    subtitle: r.preview.isEmpty ? "(empty)" : r.preview,
                    timeAgo: df.localizedString(for: r.startedAt, relativeTo: Date()),
                    when: r.startedAt
                ))
            }
        }
        return all.sorted { $0.when > $1.when }
    }
}

private struct UsageRangeChip: View {
    let label: String; let active: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(active ? .white : .white.opacity(hover ? 0.85 : 0.55))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Color.purple.opacity(0.35), Color.blue.opacity(0.22)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.white.opacity(hover ? 0.06 : 0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let icon: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent.opacity(0.85))
                Spacer()
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.50))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.20), lineWidth: 0.8)
                )
        )
    }
}
