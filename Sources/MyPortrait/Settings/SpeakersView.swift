import SwiftUI
import SQLite3

/// Speakers — voices captured from your microphone + system audio.
/// Polished rewrite: progress header, attention banner for unidentified
/// clusters, a dense identified roster with avatar + sample count + last
/// heard + hover actions, search + "Organize w/ AI" button.
///
/// Reads `speakers JOIN audio_transcriptions` live from timeline DB.
struct SpeakersSettingsView: View {
    @State private var rows: [SpeakerRow] = []
    @State private var search = ""
    @State private var organizing = false
    @State private var organizeError: String? = nil
    @State private var showCountdown = false

    private var filtered: [SpeakerRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { ($0.name ?? "").lowercased().contains(q) }
    }
    private var identified:   [SpeakerRow] { filtered.filter { ($0.name ?? "").isEmpty == false } }
    private var unidentified: [SpeakerRow] { filtered.filter { ($0.name ?? "").isEmpty } }

    var body: some View {
        SettingsPage("Speakers",
                     subtitle: "Voices captured from your microphone and system audio") {

            ProgressHeader(identified: identified.count, total: rows.count)

            VoiceTrainingCard(
                existingNames: rows.compactMap { $0.name }.filter { !$0.isEmpty },
                onStart: { showCountdown = true }
            )

            if !unidentified.isEmpty {
                AttentionBanner(count: unidentified.count)
            }

            if let err = organizeError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            toolbar

            if !unidentified.isEmpty {
                SectionLabel("UNIDENTIFIED CLUSTERS",
                             subtitle: "Name these voice clusters so they're linked across recordings.")
                VStack(spacing: 8) {
                    ForEach(unidentified) { r in
                        UnidentifiedCard(row: r,
                                         onName: { newName in rename(r, to: newName) },
                                         onHallucination: { markHallucination(r) })
                    }
                }
            }

            SectionLabel("IDENTIFIED",
                         subtitle: identified.isEmpty
                            ? "None yet — name your first cluster above."
                            : "\(identified.count) speaker\(identified.count == 1 ? "" : "s") recognised.")
            if !identified.isEmpty {
                VStack(spacing: 6) {
                    ForEach(identified) { r in
                        IdentifiedRow(row: r,
                                      onRename: { newName in rename(r, to: newName) },
                                      onDelete: { markHallucination(r) },
                                      onMerge: { similarId in merge(r, with: similarId) })
                    }
                }
            }
        }
        .task { reload() }
        .sheet(isPresented: $showCountdown) {
            VoiceTrainingSheet(
                onFinish: {
                    showCountdown = false
                    VoiceTrainer.shared.assign(
                        name: ConfigStore.shared.current.capture.audio.userName
                    )
                },
                onCancel: { showCountdown = false }
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                TextField("Search speakers…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: 280)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
            )

            Spacer()

            Button {
                runOrganize()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: organizing ? "wand.and.stars.inverse" : "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(organizing ? 360 : 0))
                        .animation(organizing
                            ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                            : .default, value: organizing)
                    Text("Organize with AI")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.blue.opacity(0.22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                )
            }
            .buttonStyle(.bouncyIcon)
            .disabled(unidentified.isEmpty)
            .opacity(unidentified.isEmpty ? 0.45 : 1)
        }
    }

    // MARK: - Mutators

    private func reload() {
        // loadSpeakers 同步 sqlite JOIN + GROUP BY,主线程跑会卡(切到这页就触发)。
        Task.detached(priority: .userInitiated) {
            let loaded = SpeakerLoader.loadAll()
            await MainActor.run { rows = loaded }
        }
    }

    /// Ask the LLM to propose names for every unidentified cluster, then
    /// apply each suggested label through the existing `rename` path
    /// (persistence is a no-op today — the speakers table is read-only
    /// from `TimelineDB` — but the names show up in the UI right away).
    private func runOrganize() {
        guard !organizing else { return }
        organizeError = nil
        let ids = unidentified.map { $0.id }
        guard !ids.isEmpty else { return }
        organizing = true
        Task {
            defer { organizing = false }
            do {
                let proposals = try await SpeakerOrganizer.run(unidentifiedIds: ids)
                for p in proposals where !p.label.isEmpty {
                    if let row = rows.first(where: { $0.id == p.speakerId }) {
                        rename(row, to: p.label)
                    }
                }
            } catch {
                organizeError = error.localizedDescription
            }
        }
    }
    private func rename(_ r: SpeakerRow, to newName: String) {
        let v = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, let i = rows.firstIndex(where: { $0.id == r.id }) else { return }
        rows[i].name = v
        guard let sid = Int64(r.id) else { return }
        Task.detached(priority: .userInitiated) {
            _ = TimelineDB().renameSpeaker(id: sid, to: v)
        }
    }
    private func markHallucination(_ r: SpeakerRow) {
        rows.removeAll { $0.id == r.id }
        guard let sid = Int64(r.id) else { return }
        Task.detached(priority: .userInitiated) {
            _ = TimelineDB().markSpeakerHallucination(id: sid)
        }
    }
    /// 把相似说话人 `similarId` 合并进 `keep`。
    private func merge(_ keep: SpeakerRow, with similarId: Int64) {
        guard let keepId = Int64(keep.id) else { return }
        Task {
            _ = await Task.detached(priority: .userInitiated) {
                TimelineDB().mergeSpeakers(keep: keepId, merge: similarId)
            }.value
            reload()
        }
    }
}

// MARK: - Header banners

private struct ProgressHeader: View {
    let identified: Int; let total: Int
    private var pct: Double {
        guard total > 0 else { return 0 }
        return Double(identified) / Double(total)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(identified) of \(total) speakers identified")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Identified speakers are searchable as \(token: "@speaker:<name>") in chat.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            ProgressView(value: pct)
                .tint(LinearGradient(
                    colors: [Color.purple, Color.blue],
                    startPoint: .leading, endPoint: .trailing))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        )
    }
}

private struct AttentionBanner: View {
    let count: Int
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18))
                .foregroundStyle(Color.orange.opacity(0.90))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) unidentified \(count == 1 ? "cluster" : "clusters")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Give each a name below, or click Organize with AI to group similar voices.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.45), lineWidth: 0.7))
        )
    }
}

private struct SectionLabel: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String) {
        self.title = title; self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.50))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Unidentified cluster card

private struct UnidentifiedCard: View {
    let row: SpeakerRow
    let onName: (String) -> Void
    let onHallucination: () -> Void
    @State private var draft: String = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(letter: "?", color: Color.orange, animating: true)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cluster \(row.id.prefix(8))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                HStack(spacing: 6) {
                    StatPill(icon: "waveform", text: "\(row.sampleCount) samples")
                    if let last = row.lastHeard {
                        StatPill(icon: "clock", text: relative(last))
                    }
                }
            }
            Spacer(minLength: 14)

            TextField("Name this speaker…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                )
                .frame(maxWidth: 200)
                .onSubmit { commit() }

            Button(action: commit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(
                                colors: [Color.purple.opacity(0.45), Color.blue.opacity(0.28)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.20), lineWidth: 0.7))
                    )
            }
            .buttonStyle(.bouncyIcon)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

            Menu {
                Button("Mark as hallucination", role: .destructive, action: onHallucination)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(hover ? 0.10 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.30), lineWidth: 0.7))
        )
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private func commit() {
        let v = draft.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        onName(v); draft = ""
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Identified row (compact)

private struct IdentifiedRow: View {
    let row: SpeakerRow
    let onRename: (String) -> Void
    let onDelete: () -> Void
    /// 把参数指定的相似说话人合并进本行说话人。
    let onMerge: (Int64) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @State private var showMerge = false
    @State private var similar: [SimilarSpeaker] = []
    @State private var loadingSimilar = false

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(letter: initial, color: avatarColor, animating: false)
                .frame(width: 32, height: 32)

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .frame(maxWidth: 220)
                    .onSubmit {
                        let v = draft.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty { onRename(v) }
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(row.name ?? "Unknown")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            }

            HStack(spacing: 4) {
                StatPill(icon: "waveform", text: "\(row.sampleCount)")
                if let last = row.lastHeard {
                    StatPill(icon: "clock", text: relative(last))
                }
            }

            Spacer()

            if hover, !editing {
                Button {
                    draft = row.name ?? ""; editing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.70))
                }
                .buttonStyle(.bouncyIcon)
                Button {
                    showMerge = true
                    loadSimilar()
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.70))
                }
                .buttonStyle(.bouncyIcon)
                .popover(isPresented: $showMerge, arrowEdge: .bottom) { mergePopover }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.70))
                }
                .buttonStyle(.bouncyIcon)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.05 : 0.025))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.7))
        )
        .onHover { hover = $0 }
    }

    @ViewBuilder private var mergePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sounds similar — same person?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if loadingSimilar {
                Text("Searching…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if similar.isEmpty {
                Text("No similar speakers found.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(similar) { s in
                    HStack(spacing: 8) {
                        Text(s.name ?? "Cluster \(s.id)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text("\(Int(s.similarity * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Merge") {
                            onMerge(s.id)
                            showMerge = false
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func loadSimilar() {
        guard let sid = Int64(row.id) else { return }
        loadingSimilar = true
        similar = []
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                TimelineDB().similarSpeakers(to: sid)
            }.value
            similar = result
            loadingSimilar = false
        }
    }

    private var initial: String {
        if let n = row.name, let first = n.first { return String(first).uppercased() }
        return "?"
    }
    private var avatarColor: Color {
        // Deterministic from name hash so each speaker gets a stable color.
        let palette: [Color] = [.purple, .blue, .pink, .green, .orange, .cyan, .mint, .indigo]
        guard let n = row.name else { return .gray }
        return palette[abs(n.hashValue) % palette.count]
    }
    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Bits

private struct SpeakerAvatar: View {
    let letter: String
    let color: Color
    let animating: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            if animating {
                Circle()
                    .fill(color.opacity(0.20))
                    .scaleEffect(pulse ? 1.25 : 1.0)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(LinearGradient(
                    colors: [color, color.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
            Text(letter)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        .onAppear { if animating { pulse = true } }
    }
}

private struct StatPill: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8.5))
            Text(text).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.60))
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Voice training

/// 声纹训练卡片。复刻 screenpipe 的格式：填名字 → Start training → 30s 倒计时
/// 期间正常说话 → 后台把那段时间窗的麦克风声纹簇命名成你。
private struct VoiceTrainingCard: View {
    let existingNames: [String]
    let onStart: () -> Void

    private var cfg: ConfigStore { ConfigStore.shared }
    private var trainer: VoiceTrainer { VoiceTrainer.shared }

    private var name: String { cfg.current.capture.audio.userName }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var audioOn: Bool { cfg.current.capture.audio.enabled }
    private var speakerOn: Bool { cfg.current.capture.audio.speakerIdEnabled }
    private var blocked: Bool { trimmedName.isEmpty || !audioOn || !speakerOn || trainer.isRunning }

    private var suggestions: [String] {
        let q = trimmedName.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(existingNames
            .filter { $0.lowercased().hasPrefix(q) && $0.lowercased() != q }
            .prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.purple.opacity(0.9))
                Text("Voice Training")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            Text("Read a short passage aloud for ~30 seconds so My Portrait can recognise your voice across recordings.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Your name")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.70))
                TextField("e.g. Louis", text: cfg.binding(\.capture.audio.userName))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .frame(maxWidth: 200)
            }

            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("existing:")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.40))
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { cfg.mutate { $0.capture.audio.userName = s } }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.blue.opacity(0.85))
                    }
                }
            }

            if !audioOn {
                warningRow("Turn on audio capture first.")
            } else if !speakerOn {
                warningRow("Turn on speaker identification first.")
            }

            HStack {
                statusLine
                Spacer()
                Button(action: onStart) {
                    Text("Start training")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(
                                    colors: [Color.purple.opacity(0.45), Color.blue.opacity(0.28)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        )
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .opacity(blocked ? 0.45 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        )
    }

    @ViewBuilder private var statusLine: some View {
        switch trainer.phase {
        case .idle:
            EmptyView()
        case .matching:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Matching your voice — may take a few minutes…")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.60))
            }
        case .success(let n):
            Text("✓ Trained as \(n)")
                .font(.system(size: 11)).foregroundStyle(Color.green.opacity(0.90))
        case .failure(let msg):
            Text(msg)
                .font(.system(size: 11)).foregroundStyle(Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warningRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(Color.orange.opacity(0.85))
    }
}

/// 30 秒倒计时对话框。期间用户照着 passage 朗读，常驻采集在录音。
private struct VoiceTrainingSheet: View {
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var secondsLeft = 30
    @State private var finished = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let passage = """
        The morning light moved slowly across the kitchen floor. \
        I poured a cup of coffee and watched the rain trace thin lines \
        down the window. Somewhere outside a dog barked twice, then the \
        street was quiet again. Days like this feel unhurried, as if the \
        clock had quietly agreed to wait for me.
        """

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("recording · \(30 - secondsLeft)s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Read this aloud")
                .font(.system(size: 15, weight: .semibold))

            Text(passage)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Text("\(secondsLeft)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()

            HStack(spacing: 10) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 380)
        .onReceive(timer) { _ in
            guard !finished else { return }
            if secondsLeft > 1 { secondsLeft -= 1 } else { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

// MARK: - Loader

private struct SpeakerRow: Identifiable, Hashable {
    let id: String
    var name: String?
    let sampleCount: Int
    let lastHeard: Date?
}

private enum SpeakerLoader {
    static func loadAll() -> [SpeakerRow] {
        TimelineDB().loadSpeakers().map { r in
            SpeakerRow(
                id: String(r.id),
                name: r.name,
                sampleCount: r.sampleCount,
                lastHeard: r.lastHeardMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
        }
    }
}

// Workaround for the inline string interpolation used in ProgressHeader
// (Swift String interpolation doesn't take labelled args directly).
private extension String.StringInterpolation {
    mutating func appendInterpolation(token v: String) {
        appendInterpolation("`\(v)`")
    }
}
