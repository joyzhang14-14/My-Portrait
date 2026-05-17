import SwiftUI

/// Three-column view of the memory system:
///   [scope picker]  [file list]  [detail]
///
///   scope picker → 9 portrait categories + "Events"
///   file list    → portrait files in selected category (or events stream)
///   detail       → selected file's YAML metadata + body
///
/// Toolbar at the top of the middle column has three actions:
///   ↓     Backfill events from screenpipe
///   ✨    Rescore event impacts with LLM
///   🪄    Distill portrait files from events
struct MemoriesView: View {
    @State private var entries: [Entry] = []
    @State private var loading: Bool = false
    @State private var actionStatus: String = ""
    @State private var selected: Entry.ID?
    @State private var scope: Scope = .events

    enum Scope: Hashable, Identifiable {
        case events
        case portrait(category: String)
        var id: String {
            switch self {
            case .events: return "__events__"
            case .portrait(let c): return "portrait:\(c)"
            }
        }
        var displayName: String {
            switch self {
            case .events: return "Events"
            case .portrait(let c): return c.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        var systemImage: String {
            switch self {
            case .events:               return "clock.arrow.circlepath"
            case .portrait("personality"): return "person.fill"
            case .portrait("social"):      return "person.3.fill"
            case .portrait("background"):  return "books.vertical.fill"
            case .portrait("experiences"): return "map.fill"
            case .portrait("interests"):   return "sparkles"
            case .portrait("speech_style"):return "text.bubble.fill"
            case .portrait("habits"):      return "repeat"
            case .portrait("skills"):      return "wrench.adjustable.fill"
            case .portrait("emotions"):    return "heart.fill"
            case .portrait:                return "doc.text"
            }
        }
    }

    struct Entry: Identifiable {
        let id: URL
        let title: String
        let category: String
        let scope: Scope          // events or which portrait category
        let file: PortraitFile
        let modified: Date
    }

    var body: some View {
        HSplitView {
            scopePicker
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

            listColumn
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .task(id: scope) { await reload() }
    }

    // MARK: - Scope picker (left)

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Memories")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 44)
                .padding(.bottom, 10)

            scopeSectionHeader("PORTRAIT")
            ForEach(PortraitPaths.seedCategories, id: \.self) { cat in
                scopeRow(.portrait(category: cat))
            }

            Divider().padding(.vertical, 8)
            scopeSectionHeader("EVENTS")
            scopeRow(.events)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
    }

    private func scopeSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }

    private func scopeRow(_ s: Scope) -> some View {
        Button {
            scope = s
            selected = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(scope == s ? .white : .secondary)
                Text(s.displayName)
                    .font(.system(size: 12, weight: scope == s ? .semibold : .regular))
                    .foregroundStyle(scope == s ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Rectangle()
                    .fill(scope == s ? Color.accentColor.opacity(0.65) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Middle column (toolbar + list)

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(scope.displayName)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(entries.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runBackfill() }
                } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .help("Backfill events from screenpipe")

                Button {
                    Task { await runRescore() }
                } label: { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .help("Rescore event impacts with LLM")

                Button {
                    Task { await runDistill() }
                } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(.borderless)
                .help("Distill portrait files from events")

                Button {
                    Task { await reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload from disk")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            if !actionStatus.isEmpty {
                Text(actionStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color.white.opacity(0.06))

            if entries.isEmpty && !loading {
                EmptyHint(scope: scope)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            EntryRow(entry: entry, selected: selected == entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = entry.id }
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
    }

    // MARK: - Detail (right)

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let entry = entries.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.title)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 44)
                    metadataBlock(entry.file, category: entry.category)
                    Divider().background(Color.white.opacity(0.06))
                    Text(entry.file.body)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: scope.systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an item")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func metadataBlock(_ f: PortraitFile, category: String) -> some View {
        let rows: [(String, String)] = [
            ("category", category),
            ("weight", String(format: "%.4g", f.weight)),
            ("impact", String(format: "%.4g", f.impact)),
            ("impact_source", f.impactSource),
            ("access_count", "\(f.accessCount)"),
            ("created", Self.dayString(f.created)),
            ("last_accessed", f.lastAccessedAt.map { Self.dayString($0) } ?? "—"),
            ("occurrences (days)", "\(f.occurrences.count)"),
            ("member frames", "\(f.memberFrameIds.count)"),
            ("tags", f.tags.joined(separator: ", "))
        ]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 130, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        loading = true
        let currentScope = scope
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.scan(scope: currentScope)
        }.value
        entries = loaded
        loading = false
    }

    @MainActor
    private func runRescore() async {
        actionStatus = "Rescoring impact with LLM…"
        let scorer = ImpactScorer()
        do {
            let r = try await scorer.rescoreAll { p in
                Task { @MainActor in
                    actionStatus = "Rescoring batch \(p.batchIndex)/\(p.batchCount) — \(p.scoredCount)/\(p.totalCount) files"
                }
            }
            actionStatus = "Rescored \(r.scoredCount) (failed \(r.failedCount)) in \(String(format: "%.1f", r.elapsed))s"
            await reload()
        } catch {
            actionStatus = "Rescore failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runBackfill() async {
        actionStatus = "Backfilling events from screenpipe…"
        do {
            let r = try await Backfill.run()
            actionStatus = "\(r.rawFrameCount) frames → \(r.tier1SessionCount) sessions (\(r.emptySessionCount) skipped) → \(r.newEventCount) new events, \(r.joinedSessionCount) joined, LLM-failed days: \(r.llmFailedDays)"
            await reload()
        } catch {
            actionStatus = "Backfill failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runDistill() async {
        actionStatus = "Distilling portrait from events…"
        let distiller = PortraitDistiller()
        do {
            let r = try await distiller.distill { p in
                Task { @MainActor in
                    actionStatus = "Distilling \(p.categoryIndex)/\(p.categoryCount): \(p.category) (\(p.written) written)"
                }
            }
            actionStatus = "Distilled: \(r.portraitFilesWritten) new + \(r.portraitFilesUpdated) updated, \(r.llmFailedCategories) categories failed, \(String(format: "%.1f", r.elapsed))s"
            await reload()
        } catch {
            actionStatus = "Distill failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Disk scan

    /// Walks the appropriate root (events/ or portrait/<cat>/) for the
    /// current scope. Off the main actor.
    nonisolated private static func scan(scope: Scope) -> [Entry] {
        let fm = FileManager.default
        let root: URL
        switch scope {
        case .events:
            root = Storage.eventsDir
        case .portrait(let cat):
            root = Storage.portraitDir.appendingPathComponent(cat, isDirectory: true)
        }
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var out: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let categoryPath = file.category
            let title = file.eventTitle.isEmpty
                ? (extractTitle(from: file.body) ?? url.deletingPathExtension().lastPathComponent)
                : file.eventTitle
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? file.created
            out.append(Entry(
                id: url,
                title: title,
                category: categoryPath,
                scope: scope,
                file: file,
                modified: modified
            ))
        }
        out.sort { $0.file.weight > $1.file.weight }
        return out
    }

    nonisolated private static func extractTitle(from body: String) -> String? {
        for line in body.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    nonisolated private static func dayString(_ d: Date) -> String { dayFmt.string(from: d) }
}

private struct EntryRow: View {
    let entry: MemoriesView.Entry
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3, height: max(4, min(36, CGFloat(entry.file.weight) * 6)))
                Spacer(minLength: 0)
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.category)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("w=\(String(format: "%.2f", entry.file.weight))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("i=\(String(format: "%.1f", entry.file.impact))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("×\(entry.file.occurrences.count)d")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
    }

    private var barColor: Color {
        let w = max(0, min(5, entry.file.weight))
        let hue = (w / 5) * 0.35
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }
}

private struct EmptyHint: View {
    let scope: MemoriesView.Scope
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyText)
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
    private var emptyText: String {
        switch scope {
        case .events:
            return "No events yet.\nClick ↓ to backfill from screenpipe."
        case .portrait:
            return "No portrait entries in this category yet.\nRun events backfill first, then 🪄 to distill."
        }
    }
}
