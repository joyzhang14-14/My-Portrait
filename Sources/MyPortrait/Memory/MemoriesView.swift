import SwiftUI

/// Replaces the "Memories — Coming soon" placeholder. Loads every .md file
/// under ~/.portrait/portrait/, sorts by weight desc, and shows a list with
/// a detail pane on the right.
struct MemoriesView: View {
    @State private var entries: [Entry] = []
    @State private var loading: Bool = false
    @State private var backfillStatus: String = ""
    @State private var selected: Entry.ID?

    struct Entry: Identifiable {
        let id: URL                       // file URL is naturally unique
        let title: String
        let category: String
        let file: PortraitFile
        let modified: Date
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .task { await reload() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Memories")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(entries.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runBackfill() }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Backfill from screenpipe (last 14 days)")

                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload from disk")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)            // clear traffic-light strip
            .padding(.bottom, 8)

            if !backfillStatus.isEmpty {
                Text(backfillStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider().background(Color.white.opacity(0.06))

            if entries.isEmpty && !loading {
                EmptyHint()
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
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
    }

    // MARK: - Detail

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
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a memory")
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
            ("access_count", "\(f.accessCount)"),
            ("created", Self.dayString(f.created)),
            ("last_accessed", f.lastAccessedAt.map { Self.dayString($0) } ?? "—"),
            ("occurrences", "\(f.occurrences.count)"),
            ("tags", f.tags.joined(separator: ", "))
        ]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 100, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Loading

    @MainActor
    private func reload() async {
        loading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.scan()
        }.value
        entries = loaded
        loading = false
    }

    @MainActor
    private func runBackfill() async {
        backfillStatus = "Backfilling from screenpipe…"
        let result: Result<Backfill.Result, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try Backfill.run()) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let r):
            backfillStatus = "\(r.rawFrameCount) frames → \(r.mergedSessionCount) sessions → wrote \(r.writtenFileCount) (skipped \(r.skippedExisting) existing, archived \(r.archiverResult.archivedCount))"
            await reload()
        case .failure(let e):
            backfillStatus = "Backfill failed: \(e.localizedDescription)"
        }
    }

    /// Walks ~/.portrait/portrait/ off the main thread.
    nonisolated private static func scan() -> [Entry] {
        let fm = FileManager.default
        let root = Storage.portraitDir
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var out: [Entry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let category = url.path
                .replacingOccurrences(of: root.path + "/", with: "")
                .split(separator: "/").first.map(String.init) ?? "?"
            let title = extractTitle(from: file.body) ?? url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? file.created
            out.append(Entry(id: url, title: title, category: category, file: file, modified: modified))
        }
        // Sort by weight desc (the whole point of the algorithm).
        out.sort { $0.file.weight > $1.file.weight }
        return out
    }

    /// Pull the first `#` heading from the body for a friendly display title.
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
            // Weight bar — visual proxy for relative importance.
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
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.category)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("w=\(String(format: "%.2f", entry.file.weight))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("i=\(String(format: "%.0f", entry.file.impact))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("×\(entry.file.occurrences.count)")
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
        // Hue maps weight: red (low) → green (high)
        let w = max(0, min(5, entry.file.weight))
        let hue = (w / 5) * 0.35              // 0 (red) → 0.35 (green)
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No portrait files yet.\nClick the ↓ button to backfill from screenpipe.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}
