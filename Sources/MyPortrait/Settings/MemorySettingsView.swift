import SwiftUI

/// Tunable fields for the Memory pipeline. Persists to ~/.myportrait/config.toml
/// via ConfigStore. MemoryBudget / WeightCalculator / Archiver each pull
/// `.fromConfig` so changes take effect on the next rebalance / weight pass /
/// archive run.
struct MemorySettingsView: View {
    private let cfg = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                budgetSection
                decaySection
                archiveSection

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(.system(size: 26, weight: .semibold))
            Text("Tune how the memory system weighs, consolidates, and forgets events. Changes write to `~/.myportrait/config.toml` (debounced).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(cfg.fileURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Reveal in Finder") {
                cfg.revealInFinder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Reset Memory section") {
                cfg.mutate { $0.memory = MemoryConfig() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 8)
    }

    // MARK: - Sections

    private var budgetSection: some View {
        section(
            title: "Weekly consolidation budget",
            blurb: "Mirrors the brain's nightly consolidation cap. When the past N days of LLM-given impacts sum above the budget, the rebalance pass scales them down proportionally. Quiet weeks are not amplified."
        ) {
            doubleRow("Weekly budget (sum of impacts)",
                      value: cfg.binding(\.memory.weeklyBudget),
                      range: 10...200, step: 1)
            doubleRow("Peak protection (raw ≥ this is never scaled)",
                      value: cfg.binding(\.memory.peakProtection),
                      range: 3.0...5.0, step: 0.1)
            intRow("Max re-touches per event before freezing",
                   value: cfg.binding(\.memory.maxRebalances),
                   range: 1...20)
            intRow("Window (days)",
                   value: cfg.binding(\.memory.windowDays),
                   range: 1...30)
        }
    }

    private var decaySection: some View {
        section(
            title: "Weight decay",
            blurb: "weight = impact × (1 + days_since_last_occurrence)^-α × (1 + log(1 + occurrence_days)). Higher α → faster forgetting."
        ) {
            doubleRow("α (decay exponent)",
                      value: cfg.binding(\.memory.alpha),
                      range: 0.05...1.0, step: 0.05)
            doubleRow("Minimum weight floor",
                      value: cfg.binding(\.memory.minWeight),
                      range: 0...0.5, step: 0.01)
        }
    }

    private var archiveSection: some View {
        section(
            title: "Archival rule",
            blurb: "Programmatic, no LLM. All three thresholds must be met (and the file must not live under skills/ or be pinned) for the file to move into _archive/."
        ) {
            doubleRow("Max impact",
                      value: cfg.binding(\.memory.archiveMaxImpact),
                      range: 0.5...4.0, step: 0.1)
            doubleRow("Max weight",
                      value: cfg.binding(\.memory.archiveMaxWeight),
                      range: 0.001...0.5, step: 0.01)
            intRow("Min days idle",
                   value: cfg.binding(\.memory.archiveMinDaysIdle),
                   range: 7...365)
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func section<C: View>(title: String,
                                  blurb: String,
                                  @ViewBuilder body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(blurb)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                body()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func doubleRow(_ label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: 280, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: .infinity)
            TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func intRow(_ label: String,
                        value: Binding<Int>,
                        range: ClosedRange<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: 280, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .frame(maxWidth: .infinity)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
