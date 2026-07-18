import SwiftUI
import SQLite3

/// Speakers — voices captured from your microphone + system audio.
/// Progress header, attention banner for unidentified clusters, a dense
/// identified roster with avatar + sample count + last heard + hover
/// actions, search + "Merge duplicates" button.
///
/// Reads `speakers JOIN audio_transcriptions` live from timeline DB.
///
/// **2026-05-26**: 之前是独立的 Settings 分页(`SettingsPage("Speakers", ...)`)。
/// 现在被嵌进 Audio Capture 页 —— 训练 + 簇管理跟麦克风/转录配置放一起,
/// 不再单独走 sidebar。view 自己不再包 SettingsPage,由 caller 控制版式。
struct SpeakersSettingsView: View {
    @State private var rows: [SpeakerRow] = []
    @State private var search = ""
    @State private var organizing = false
    @State private var config = ConfigStore.shared
    @State private var reidentify = SpeakerReidentifyCoordinator.shared

    private var filtered: [SpeakerRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { ($0.name ?? "").lowercased().contains(q) }
    }
    /// 三段切分(trained_at_ms / name 两条正交轴):
    ///   - trainedVoices:你真跑过 voice training 的声纹(资产,要保护、删要确认)。
    ///   - namedClusters:diarization 自动建后被命名、但没训练过的簇(可随意管理)。
    ///   - unidentified:真匿名簇(name == "")。
    /// trained 一定有名字(训练强制先输名),所以从"有名"里按 trainedAt 再切一刀。
    private var trainedVoices: [SpeakerRow] { filtered.filter { $0.trainedAt != nil } }
    private var namedClusters: [SpeakerRow] { filtered.filter { ($0.name ?? "").isEmpty == false && $0.trainedAt == nil } }
    private var unidentified:  [SpeakerRow] { filtered.filter { ($0.name ?? "").isEmpty } }
    /// 真·语音训练过的数量 —— 只数 trained_at_ms 非空(用户真跑过 voice training)。
    /// 绝对数,不受 search 影响。loadSpeakers 已过滤 hallucination=0,被软删的训练
    /// 声纹不计入(它已不参与匹配)。
    private var voiceTrainedCount: Int { rows.filter { $0.trainedAt != nil }.count }
    /// 被命名(具名)的说话人数 —— name 非空(含训练过的 + 仅命名的)。
    private var namedCount: Int { rows.filter { !($0.name ?? "").isEmpty }.count }
    /// 当前选用的声纹模型显示名。
    private var currentModelLabel: String {
        let id = config.current.capture.audio.speakerEmbeddingModel
        return SpeakerModel.embeddingOptions.first { $0.id == id }?.label ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressHeader(trainedCount: voiceTrainedCount, namedCount: namedCount, modelLabel: currentModelLabel)

            if reidentify.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Re-identifying today's audio with the named speakers…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.65))
                    Spacer()
                    Button("Stop") { reidentify.cancel() }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
                .padding(.horizontal, 4)
            } else if let msg = reidentify.lastResultMessage {
                // 重扫跑完的一次性反馈(绿勾)。用户离开本页(.onDisappear)即清掉,下次进来不再显示。
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.65))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // 重扫期间整块编辑禁用(直到跑完 / Stop)。Stop 按钮在上面指示条里,不受影响。
            Group {
            VoiceTrainingCard(
                existingNames: rows.compactMap { $0.name }.filter { !$0.isEmpty },
                onTrained: { reload() }
            )

            // ① 你训练的声纹 —— 资产,置顶。删除走二次确认(IdentifiedRow.trained)。
            if !trainedVoices.isEmpty {
                SectionLabel("YOUR TRAINED VOICES",
                             subtitle: "Voice recordings used to recognize you in transcripts. You'll be asked before any is removed.")
                VStack(spacing: 6) {
                    ForEach(trainedVoices) { r in
                        IdentifiedRow(row: r, trained: true,
                                      onRename: { newName in rename(r, to: newName) },
                                      onDelete: { markHallucination(r) },
                                      onMerge: { similarId in merge(r, with: similarId) })
                    }
                }
            }

            toolbar

            // ② diarization 自动识别 + 你命名、但没训练过的簇 —— 可随意管理。
            SectionLabel("DETECTED SPEAKERS",
                         subtitle: namedClusters.isEmpty
                            ? "Auto-detected voices you've named will show up here."
                            : "\(namedClusters.count) named cluster\(namedClusters.count == 1 ? "" : "s") from auto-detection.")
            if !namedClusters.isEmpty {
                VStack(spacing: 6) {
                    ForEach(namedClusters) { r in
                        IdentifiedRow(row: r, trained: false,
                                      onRename: { newName in rename(r, to: newName) },
                                      onDelete: { markHallucination(r) },
                                      onMerge: { similarId in merge(r, with: similarId) })
                    }
                }
            }

            // ③ 真匿名簇 —— 给名字或标为误判。
            if !unidentified.isEmpty {
                AttentionBanner(count: unidentified.count)
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
            }
            .disabled(reidentify.isRunning)   // 重扫时禁用编辑(Stop 不受影响,在指示条里)
        }
        .task { reload() }
        // 换说话人模型 → 重新加载列表(声纹按模型隔离,列表只显示当前模型的人)。
        .onChange(of: config.current.capture.audio.speakerEmbeddingModel) { _, _ in reload() }
        // 重扫跑完(isRunning true→false)→ 重新加载列表,反映归拢结果。
        .onChange(of: reidentify.isRunning) { _, running in if !running { reload() } }
        // 离开 Speakers 页 → 清掉完成反馈(一次性:用户看到后,下次进来不再显示)。
        .onDisappear { reidentify.clearResult() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
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
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .medium))
                    Text("Merge duplicates")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
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
            .disabled(!canOrganize)
            .opacity(canOrganize ? 1 : 0.45)
        }
    }

    // MARK: - Mutators

    private func reload() {
        // loadSpeakers 同步 sqlite JOIN + GROUP BY,主线程跑会卡(切到这页就触发)。
        // 只列当前选用模型绑定的说话人(声纹按模型隔离)。
        let model = config.current.capture.audio.speakerEmbeddingModel
        Task.detached(priority: .userInitiated) {
            let loaded = SpeakerLoader.loadAll(forModel: model)
            await MainActor.run { rows = loaded }
        }
    }

    /// 合并重复的同名声音簇 —— 同名 + 样本相似(best-of-N cosine ≥ 阈值)才合,挡住
    /// "名同声不同"。纯本地向量计算,不用 AI;优先保留训练过的 voiceprint。
    private func runOrganize() {
        guard !organizing else { return }
        guard canOrganize else { return }
        organizing = true
        Task {
            defer { organizing = false }
            let samples = await Task.detached(priority: .userInitiated) {
                TimelineDB().speakerSampleEmbeddings()
            }.value
            let plan = mergePlan(samples: samples)
            if !plan.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    for (keepId, mergeIds) in plan {
                        for mid in mergeIds { _ = TimelineDB().mergeSpeakers(keep: keepId, merge: mid) }
                    }
                }.value
                reload()
            }
        }
    }

    /// 同名簇合并计划:`[(keepId, [mergeId...])]`。把 name 相同(忽略大小写/首尾空白)
    /// 的多个簇并成一个;keep 优先选训练过的 voiceprint,否则选样本最多的。
    ///
    /// **声纹护栏(best-of-N)**:同名还不够 —— 只合并跟 keep「最接近的一条样本」
    /// cosine ≥ `simThreshold` 的簇。**不用质心**:质心是平均值,在被拆散的簇上极不
    /// 可靠(实测同一人两簇质心 cosine 可低至 −0.06,比跨人还低),用它当护栏会把真·
    /// 同人挡在外面(就是 "Merge duplicates 点了没用" 的原因)。改比样本对齐 matchSpeaker。
    /// 仍挡住"名同声不同":真·不同人没有任何一对样本够像,best-of-N 过不了阈值。
    /// 缺样本的簇保守跳过(不合)。
    private func mergePlan(samples: [Int64: [[Float]]]) -> [(Int64, [Int64])] {
        let simThreshold: Float = 0.45   // 对齐 PortraitDBImpl.matchSpeaker
        let named = rows.filter { !($0.name ?? "").isEmpty }
        let groups = Dictionary(grouping: named) {
            ($0.name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        var out: [(Int64, [Int64])] = []
        for (_, group) in groups where group.count > 1 {
            let keep = group.first(where: { $0.trainedAt != nil })
                ?? group.max(by: { $0.sampleCount < $1.sampleCount })
                ?? group[0]
            guard let keepId = Int64(keep.id), let ks = samples[keepId], !ks.isEmpty else { continue }
            let mergeIds: [Int64] = group.compactMap { r in
                guard r.id != keep.id, let rid = Int64(r.id), let rs = samples[rid], !rs.isEmpty else { return nil }
                return bestOfN(rs, ks) >= simThreshold ? rid : nil
            }
            if !mergeIds.isEmpty { out.append((keepId, mergeIds)) }
        }
        return out
    }

    /// 两簇样本间「最接近的一对」cosine(best-of-N)。维度不一致的样本对(不同
    /// embedding 引擎)跳过 —— cosineSimilarity 的 precondition 维度不等会崩 app。
    private func bestOfN(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var best: Float = -2
        for x in a {
            for y in b where y.count == x.count {
                let s = VectorMath.cosineSimilarity(x, y)
                if s > best { best = s }
            }
        }
        return best
    }

    /// 有同名的多个簇时为 true(忽略大小写/首尾空白)。
    private var hasDuplicateNames: Bool {
        let names = rows.filter { !($0.name ?? "").isEmpty }
            .map { ($0.name ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        return names.count != Set(names).count
    }

    /// "Merge duplicates" 按钮可用:有同名重复簇可合并。
    private var canOrganize: Bool { hasDuplicateNames }
    private func rename(_ r: SpeakerRow, to newName: String) {
        let v = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, let i = rows.firstIndex(where: { $0.id == r.id }) else { return }
        rows[i].name = v   // 乐观显示新名字
        guard let sid = Int64(r.id) else { return }
        // 改名落库由 coordinator 在 debounce 结束、重扫**开始前**执行 ——
        // 重扫的同名归拢(sameName rival 豁免)要在 DB 里看到新名字才生效。
        reidentify.schedule(commit: { _ = TimelineDB().renameSpeaker(id: sid, to: v) })
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
            reidentify.schedule()   // 合并后也重扫今天
        }
    }
}

// MARK: - Header banners

private struct ProgressHeader: View {
    /// 用户真训练过的 speaker 数(只数 trained_at_ms 非空的)。
    let trainedCount: Int
    /// 被命名的 speaker 数(name 非空)。
    let namedCount: Int
    /// 当前选用的声纹模型名(声纹按模型隔离 → 计数也按模型)。
    let modelLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((trainedCount == 1
                          ? "1 speaker trained"
                          : "\(trainedCount) speakers trained") + " for \(modelLabel)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    Text(namedCount == 1 ? "1 speaker named" : "\(namedCount) speakers named")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.75))
                    Text("Trained speakers are searchable as \(token: "@speaker:<name>") in chat.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
                Spacer()
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text("Give each a name below so they're linked across recordings.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.60))
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
                .foregroundStyle(Theme.textPrimary.opacity(0.50))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.45))
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Unidentified cluster card

/// 试听按钮 —— 圆形渐变 play/pause + 播放时外扩脉冲环。Identified /
/// Unidentified 行共用,避免两边各改各的漂移(本次 bug 就是只给 IdentifiedRow
/// 修了播放、漏了 UnidentifiedCard)。
private struct SpeakerPlayButton: View {
    let speakerId: Int64
    var helpText: String = "Play a recent clip"
    @State private var audioPlayer = SpeakerAudioPlayer.shared
    /// 播放中向外扩散并淡出的脉冲环动画开关。
    @State private var playPulse = false

    var body: some View {
        let isPlaying = audioPlayer.playingId == speakerId
        Button {
            SpeakerAudioPlayer.shared.toggle(speakerId: speakerId)
        } label: {
            ZStack {
                // 播放中:向外扩散并淡出的脉冲环。
                if isPlaying {
                    Circle()
                        .stroke(Color.purple.opacity(0.55), lineWidth: 2)
                        .scaleEffect(playPulse ? 1.65 : 0.9)
                        .opacity(playPulse ? 0 : 0.7)
                }
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.85), Color.blue.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.7))
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    // play 三角形视觉重心偏左,微调居中(pause 不偏)。
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                playPulse = false
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    playPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { playPulse = false }
            }
        }
    }
}

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
                // Unidentified 区只放 name == "" 的真匿名簇,
                // 显示 "Cluster <id>" 占位。
                Text("Cluster \(row.id.prefix(8))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                HStack(spacing: 6) {
                    StatPill(icon: "waveform", text: "\(row.sampleCount) samples")
                    if let last = row.lastHeard {
                        StatPill(icon: "clock", text: relative(last))
                    }
                }
            }
            Spacer(minLength: 14)

            SpeakerPlayButton(speakerId: Int64(row.id) ?? -1,
                              helpText: "Play a recent clip of this cluster")

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
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.65))
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
    /// 这行是不是用户真训练过的声纹(trained_at_ms 非空)。true → 加 Trained 徽标 +
    /// 删除要二次确认,防误删训练资产。
    var trained: Bool = false
    let onRename: (String) -> Void
    let onDelete: () -> Void
    /// 把参数指定的相似说话人合并进本行说话人。
    let onMerge: (Int64) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @State private var confirmingDelete = false
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
                HStack(spacing: 6) {
                    Text(row.name ?? "Unknown")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    if trained {
                        Text("Trained")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.green.opacity(0.95))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15))
                                .overlay(Capsule().stroke(Color.green.opacity(0.40), lineWidth: 0.6)))
                    }
                }
            }

            HStack(spacing: 4) {
                StatPill(icon: "waveform", text: "\(row.sampleCount)")
                SpeakerPlayButton(speakerId: Int64(row.id) ?? -1,
                                  helpText: "Play a recent clip of this speaker")
                if let last = row.lastHeard {
                    StatPill(icon: "clock", text: relative(last))
                }
            }

            Spacer()

            // **hover 或 popover 打开都显示 actions**。之前只看 hover,
            // 用户鼠标从 person.2 滑到 popover 的瞬间 hover 变 false →
            // actions 直接消失 → popover 跟着 dismiss,merge 永远点不到。
            // 把 popover 状态也算进可见条件,popover 关之前 actions 不收。
            if (hover || showMerge), !editing {
                Button {
                    draft = row.name ?? ""; editing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.70))
                }
                .buttonStyle(.bouncyIcon)
                Button {
                    showMerge = true
                    loadSimilar()
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.70))
                }
                .buttonStyle(.bouncyIcon)
                .popover(isPresented: $showMerge, arrowEdge: .bottom) { mergePopover }
                Button(role: .destructive) {
                    // 训练声纹:先确认,防误删资产。普通簇:沿用原行为直接软删。
                    if trained { confirmingDelete = true } else { onDelete() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.70))
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
        .confirmationDialog(
            "Remove trained voiceprint?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Remove voiceprint", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(row.name ?? "This voice")” will stop being used to recognise you in transcripts, and your trained count drops by one. The recording stays on disk — re-run Voice Training to set it up again.")
        }
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
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
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
        .foregroundStyle(Theme.textPrimary.opacity(0.60))
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Voice training

/// 声纹训练卡片。复刻 screenpipe 的格式：填名字 → Start training → 30s 倒计时
/// 期间正常说话 → 后台把那段时间窗的麦克风声纹簇命名成你。
/// 自洽的声纹训练 card —— 跟 onboarding 里 SpeakerTrainingStep 完全同款流程:
/// 不依赖 audio.enabled / speakerIdEnabled 这两个 toggle 提前开;训练期间
/// 临时关主采集 + 训练完(success/failure/cancel)恢复原值由 VoiceTrainer
/// 自己管(跟 phase 同生命周期,view 销毁/崩溃也不丢)。
///
/// 只要求:mic 权限给了 + 名字填了。
///
/// 自带 PermissionMonitor + 自带训练倒计时 sheet,SpeakersView 把它当
/// 普通 view 放进去就行。
struct VoiceTrainingCard: View {
    let existingNames: [String]
    /// 训练成功(新声纹已落库)后回调一次,让父视图重新加载列表。
    var onTrained: () -> Void = {}

    @State private var cfg = ConfigStore.shared
    @StateObject private var monitor = PermissionMonitor()
    @State private var trainer = VoiceTrainer.shared
    @State private var showCountdown = false
    /// 训练用的 speaker 名字 —— 跟持久化的 userName(「本人」身份,diarizer 用它自动
    /// 起名)解耦,这样训练别人不会覆盖你自己的名字。onAppear 默认填 userName。
    @State private var trainingName: String = ""

    private var name: String { trainingName }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var micGranted: Bool { monitor.microphone == .granted }
    private var blocked: Bool {
        trimmedName.isEmpty || !micGranted || trainer.isRunning
    }

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
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
            }
            Text("Read a short passage aloud for ~30 seconds. My Portrait will briefly turn on your microphone for the training session and turn it back off when it's done.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Speaker name")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.70))
                TextField("", text: $trainingName)
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
                        .foregroundStyle(Theme.textPrimary.opacity(0.40))
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { trainingName = s }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.blue.opacity(0.85))
                    }
                }
            }

            if !micGranted {
                warningRow("Microphone permission needed — grant it in System Settings → Privacy.")
            }

            HStack {
                statusLine
                Spacer()
                Button(action: startTraining) {
                    Text(trainer.isRunning ? "Training…" : "Start training")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
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
        .onAppear {
            monitor.start()
            // 清掉上次训练残留的 failure/success —— VoiceTrainer 是全局单例,上次在
            // 别处(Settings / 之前的 onboarding)失败的 "got 0s" 报错会一直挂在
            // trainer.phase 上;加上 trainingName 是新的空 @State → Start disabled,
            // 用户打开就看到旧红报错 + 灰按钮,以为这次卡住了。训练中不打断。
            if !trainer.isRunning { trainer.reset() }
            // 不预填名字 —— 没训练的说话人就保持 "Cluster <id>" 显示;
            // 训练时用户自己输名字。不注入 firstName。
        }
        .onDisappear {
            monitor.stop()
            // 兜底:倒计时(录音中)直接关 Settings 窗口时 sheet 被 dismiss 但
            // onCancel 不会触发 —— 录音 engine 会一直跑、audio.enabled 留在
            // false。录音中 sheet 是 window-modal,view 消失只可能是关窗,
            // 直接取消训练(cancel 内部还原 audio toggle)。processing 阶段
            // 不取消 —— assign 在 trainer(单例)里继续跑,终态自己还原。
            if case .recording = trainer.phase { trainer.cancel() }
        }
        // 换说话人模型 → 清掉上一次训练(在别的模型下)留下的 "✓ Trained as …"
        // 成功/失败提示 —— 它属于旧模型,对新模型不适用。训练进行中不打断。
        .onChange(of: cfg.current.capture.audio.speakerEmbeddingModel) { _, _ in
            if !trainer.isRunning { trainer.reset() }
        }
        // audio toggle 的还原由 VoiceTrainer 在 phase 终态自己做,view 只管回调。
        .onChange(of: phaseKey(trainer.phase)) { _, newKey in
            // 训练成功 = 新声纹已写进 speakers 表,通知父视图 reload。
            if newKey == "success" { onTrained() }
        }
        // 倒计时 sheet 自己持有,SpeakersView 不再管它。
        .sheet(isPresented: $showCountdown) {
            VoiceTrainingSheet(
                onFinish: {
                    showCountdown = false
                    // assign 内部会 stop engine + run embedding + 存 DB
                    trainer.assign(name: trimmedName)
                },
                onCancel: {
                    showCountdown = false
                    // 用户取消 → 关 engine,清 buffer,回 idle(audio toggle
                    // 由 trainer 在回 idle 时还原)。
                    trainer.cancel()
                }
            )
        }
    }

    // MARK: - Audio toggle 临时拉起 / 还原

    private func startTraining() {
        guard !blocked else { return }
        // 上次训练失败(故意的 "got 0s" 太短保护等)后 phase 停在 .failure,
        // VoiceTrainer.start() 的 `guard case .idle` 会拒绝重新起来 → 卡住。
        // 每次点 Start 先 reset 回 idle,让用户能直接重试。
        trainer.reset()
        // 训练期间临时关主 mic capture + 完成后还原都在 VoiceTrainer 里做
        // (跟 phase 同生命周期,view 销毁也不丢;原值记 UserDefaults 崩溃安全)。
        guard trainer.start() else {
            // 没起来就别弹 sheet,phase 自带错误描述给 statusLine 用。
            return
        }
        showCountdown = true
    }

    /// VoiceTrainer.Phase 不是 Equatable-keyed-by-case,onChange 要个稳定 key。
    private func phaseKey(_ p: VoiceTrainer.Phase) -> String {
        switch p {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .success: return "success"
        case .failure: return "failure"
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch trainer.phase {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("Recording your voice…")
                    .font(.system(size: 11)).foregroundStyle(Theme.textPrimary.opacity(0.60))
            }
        case .processing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Extracting voice signature…")
                    .font(.system(size: 11)).foregroundStyle(Theme.textPrimary.opacity(0.60))
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
struct VoiceTrainingSheet: View {
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
    /// 用户真跑过 voice training 的标记。nil = 仅 diarization / 仅 rename。
    /// SpeakersView "identified" 计数只数 trainedAt != nil 的。
    let trainedAt: Date?
}

private enum SpeakerLoader {
    static func loadAll(forModel model: String) -> [SpeakerRow] {
        TimelineDB().loadSpeakers(forModel: model).map { r in
            SpeakerRow(
                id: String(r.id),
                name: r.name,
                sampleCount: r.sampleCount,
                lastHeard: r.lastHeardMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                trainedAt: r.trainedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
        }
    }
}

/// "重扫今天"的协调器(命名 / 合并触发)。状态 + 任务放**单例**上 —— 视图切走再回来
/// 被重建也不丢指示、任务也不中断(之前放视图 @State,切界面就没了)。
@MainActor
@Observable
final class SpeakerReidentifyCoordinator {
    static let shared = SpeakerReidentifyCoordinator()
    private(set) var isRunning = false
    /// 重扫**正常跑完**的一次性反馈(绿勾)。用户离开 Speakers 页再进来即清空。
    private(set) var lastResultMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 待提交的"改名落库"动作 —— debounce 结束、重扫**开始前**落库
    /// (重扫要在 DB 里看到新名字,同名归拢才生效)。
    @ObservationIgnored private var pendingCommit: (@Sendable () -> Void)?

    /// 防抖 1.2s 触发重扫。`commit` 是改名落库动作,debounce 结束后、重扫开始前执行。
    func schedule(commit: (@Sendable () -> Void)? = nil) {
        // 连续改名:上一个待提交的先落库,别丢。
        if let prev = pendingCommit { Task.detached { prev() } }
        task?.cancel()
        pendingCommit = commit
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            self.isRunning = true
            self.lastResultMessage = nil
            // 改名**先落库**再重扫:reidentifyToday 的同名归拢(sameName rival
            // 豁免)要在 DB 里看到新名字才生效。原先 commit 推迟到重扫后,重扫
            // 期间 DB 还是旧名字,刚命名的簇与同名旧簇互为 rival → margin 判定
            // 永不通过,改名触发的重扫等于 no-op。
            if let c = self.pendingCommit { await Task.detached { c() }.value; self.pendingCommit = nil }
            let outcome = await SpeakerReidentifier.shared.reidentifyToday()
            if Task.isCancelled { return }   // Stop:不给完成反馈
            self.isRunning = false
            // 0 改动是改名常态,不打扰;只有真归拢了段才给绿勾。
            self.lastResultMessage = outcome.updated > 0
                ? "Re-identified today's audio — \(outcome.updated) clip\(outcome.updated == 1 ? "" : "s") re-grouped."
                : nil
        }
    }

    /// Stop:取消重扫(写库前退出 = 段全不变)。重扫开始前改名已落库,**不回滚**;
    /// 仅当还在 debounce 窗口内时丢弃待提交的改名。不给完成反馈。
    func cancel() {
        task?.cancel()
        task = nil
        pendingCommit = nil
        isRunning = false
        lastResultMessage = nil
    }

    /// 用户离开 Speakers 页时清掉反馈 —— 下次进来不再显示(一次性)。
    func clearResult() { lastResultMessage = nil }
}

// Workaround for the inline string interpolation used in ProgressHeader
// (Swift String interpolation doesn't take labelled args directly).
private extension String.StringInterpolation {
    mutating func appendInterpolation(token v: String) {
        appendInterpolation("`\(v)`")
    }
}
