import SwiftUI

/// AI Models — 本地采集模型的下载/状态面板(语音转录 / 声纹 / VAD)。
/// 原 Connected providers 段(chat picker 可见性 + 单 model 勾选)已删 ——
/// chat picker / Memory Parameter / Onboarding 现在直接读 Connections,
/// 连了的 provider 一律列出,所有 model 都可选。schema 里 disabledProviderIds /
/// enabledModelsByProvider 已一并下线。
struct AIModelsSettingsView: View {
    @State private var config = ConfigStore.shared
    /// 本地模型 ready 状态轮询(SpeakerModelStore.isOnDisk / WhisperKitWrapper.isOnDisk
    /// 都是同步 fs check,2s 轮一次)。view 可见时跑,disappear 后停。
    @State private var localModelTick: Int = 0
    /// 轮询重入 guard —— 7 行 onAppear + .id 重渲染会重复触发,没它会每 2s 增殖一批 Task。
    @State private var isPollingLocalModels = false
    /// 正在下载的转录模型 name(点 Download 触发)。
    @State private var downloading: Set<String> = []
    /// 待确认卸载的模型 —— 点 Uninstall 先弹确认框,确认了才真删。
    @State private var pendingUninstall: PendingUninstall? = nil
    /// 已展开的分区标题。默认全收起,只看蓝色 Installed n/m。
    @State private var expanded: Set<String> = []

    /// 一次待确认的卸载:显示名 + 真正执行删除的闭包。
    private struct PendingUninstall: Identifiable {
        let id = UUID()
        let label: String
        let perform: () -> Void
    }

    var body: some View {
        SettingsPage("Downloads",
                     subtitle: "Local models that keep your data safe.",
                     onResetCurrentPage: { config.mutate { $0.aiModels = .init() } }) {

            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    "Audio capture models",
                    info: "These power voice features. Some download automatically; others have a Download button. Each stays disabled until it shows Ready."
                )

                // Whisper / Qwen3-ASR 转录模型 —— 跟 Audio Capture 的 model
                // picker 同一份目录。没装的这里点 Download 下载,装好后才能在
                // picker 里选。Qwen 一律手动下(不随 app 启动自动下)。
                modelSection("Transcription",
                             installed: transcriptionInstalled, total: transcriptionTotal) {
                    ForEach(Array(WhisperKitWrapper.allTranscriptionModels.enumerated()), id: \.offset) { _, m in
                        transcriptionModelRow(m)
                        SettingsDivider()
                    }
                    ForEach(Array(Qwen3ASRWrapper.allQwenModels.enumerated()), id: \.offset) { idx, m in
                        qwenModelRow(m)
                        if idx < Qwen3ASRWrapper.allQwenModels.count - 1 { SettingsDivider() }
                    }
                }

                // 声纹模型 —— 这里只管下载,选用哪个在 Audio Capture。
                modelSection("Speaker recognition",
                             installed: speakerInstalled, total: SpeakerModel.embeddingOptions.count) {
                    ForEach(Array(SpeakerModel.embeddingOptions.enumerated()), id: \.offset) { idx, m in
                        speakerDownloadRow(m)
                        if idx < SpeakerModel.embeddingOptions.count - 1 { SettingsDivider() }
                    }
                }

                modelSection("Voice segmentation",
                             installed: SpeakerModelStore.isOnDisk(.segmentation) ? 1 : 0, total: 1) {
                    localModelRow("pyannote segmentation-3.0", detail: "~6 MB",
                                  ready: SpeakerModelStore.isOnDisk(.segmentation), model: .segmentation)
                }

                modelSection("Voice activity detection",
                             installed: SpeakerModelStore.isOnDisk(.vadSilero) ? 1 : 0, total: 1) {
                    localModelRow("Silero VAD", detail: "~2 MB",
                                  ready: SpeakerModelStore.isOnDisk(.vadSilero), model: .vadSilero)
                }
            }
            .id(localModelTick)   // 强制重渲染,反映新的 isOnDisk 结果
            // 分区默认收起时一行 row 都不渲染,原来挂在 row 上的 onAppear
            // 起不来 —— 轮询改挂在容器上,收起状态下 Installed n/m 也会刷新。
            .onAppear { startLocalModelPolling() }
        }
        .confirmationDialog(
            pendingUninstall.map { "Uninstall \($0.label)?" } ?? "",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let p = pendingUninstall {
                Button("Uninstall", role: .destructive) {
                    p.perform()
                    pendingUninstall = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: {
            Text("This deletes the model from disk. You can download it again later.")
        }
    }

    // MARK: - 可折叠分区(标题行 + 蓝色 Installed n/m,点标题展开)

    /// 一个模型分区。收起时只留标题行,展开才渲染卡片。
    @ViewBuilder
    private func modelSection<Content: View>(_ title: String,
                                             installed: Int, total: Int,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        let open = expanded.contains(title)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
                Text("Installed \(installed)/\(total)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if open { expanded.remove(title) } else { expanded.insert(title) }
                }
            }
            if open {
                SettingsCard { content() }
            }
        }
    }

    /// 已装的转录模型数(Whisper + Qwen 合起来算一个分区)。
    private var transcriptionInstalled: Int {
        WhisperKitWrapper.allTranscriptionModels.filter { WhisperKitWrapper.isOnDisk(modelName: $0.name) }.count
            + Qwen3ASRWrapper.allQwenModels.filter { Qwen3ASRWrapper.isOnDisk(modelId: $0.name) }.count
    }

    private var transcriptionTotal: Int {
        WhisperKitWrapper.allTranscriptionModels.count + Qwen3ASRWrapper.allQwenModels.count
    }

    private var speakerInstalled: Int {
        SpeakerModel.embeddingOptions.filter { SpeakerModelStore.isOnDisk($0.model) }.count
    }

    // MARK: - Uninstall(点 Uninstall → 弹确认框 → 确认才真删)

    private func uninstallWhisperModel(_ name: String) {
        let label = WhisperKitWrapper.allTranscriptionModels.first { $0.name == name }?.label ?? name
        pendingUninstall = PendingUninstall(label: label) {
            WhisperKitWrapper.deleteFromDisk(modelName: name)
            localModelTick &+= 1
        }
    }

    private func uninstallQwenModel(_ name: String) {
        let label = Qwen3ASRWrapper.allQwenModels.first { $0.name == name }?.label ?? name
        pendingUninstall = PendingUninstall(label: label) {
            Qwen3ASRWrapper.deleteFromDisk(modelId: name)
            localModelTick &+= 1
        }
    }

    private func uninstallSpeakerModel(_ model: SpeakerModel) {
        pendingUninstall = PendingUninstall(label: speakerModelLabel(model)) {
            Task { @MainActor in
                await SpeakerModelStore.shared.deleteFromDisk(model)
                localModelTick &+= 1
            }
        }
    }

    /// 说话人 / VAD / segmentation 模型的显示名(确认框标题用)。
    private func speakerModelLabel(_ model: SpeakerModel) -> String {
        if model == .segmentation { return "Voice segmentation" }
        if model == .vadSilero { return "Voice activity" }
        return SpeakerModel.embeddingOptions.first { $0.model == model }?.label ?? "speaker model"
    }

    // MARK: - Ready + Uninstall

    /// Ready 绿字 + 右边一个 Uninstall 按钮(点了删磁盘,轮询会把状态转回可下载)。
    private func readyWithUninstall(_ onUninstall: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text("Ready")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.green.opacity(0.85))
            Button("Uninstall", action: onUninstall)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.red.opacity(0.85))
        }
    }

    // MARK: - Local model row

    private func localModelRow(_ title: String, detail: String,
                               ready: Bool, model: SpeakerModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                readyWithUninstall { uninstallSpeakerModel(model) }
            } else {
                Text("Downloading…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { startLocalModelPolling() }
    }

    // MARK: - 说话人识别声纹模型(下载行 —— 选用在 Audio Capture)

    private func speakerDownloadRow(_ m: SpeakerModel.EmbeddingOption) -> some View {
        let ready = SpeakerModelStore.isOnDisk(m.model)
        let isDownloading = downloading.contains(m.id)
        return HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text(m.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                readyWithUninstall { uninstallSpeakerModel(m.model) }
            } else if isDownloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange.opacity(0.85))
                }
            } else {
                Button("Download") { downloadSpeakerModel(m) }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { startLocalModelPolling() }
    }

    private func downloadSpeakerModel(_ m: SpeakerModel.EmbeddingOption) {
        guard !downloading.contains(m.id), !SpeakerModelStore.isOnDisk(m.model) else { return }
        downloading.insert(m.id)
        Task { @MainActor in
            _ = try? await SpeakerModelStore.shared.path(for: m.model)
            downloading.remove(m.id)
            localModelTick &+= 1
        }
    }

    /// Whisper 转录模型行 —— 没装显示 Download 按钮,下载中显示进度,装好显示 Ready。
    private func transcriptionModelRow(_ m: (name: String, label: String, size: String)) -> some View {
        let ready = WhisperKitWrapper.isOnDisk(modelName: m.name)
        let isDownloading = downloading.contains(m.name)
        return HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text(m.size)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                readyWithUninstall { uninstallWhisperModel(m.name) }
            } else if isDownloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.85))
                }
            } else {
                Button("Download") { downloadModel(m.name) }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { startLocalModelPolling() }
    }

    /// 点 Download:后台拉模型,完成后刷新让状态变 Ready。
    private func downloadModel(_ name: String) {
        guard !downloading.contains(name), !WhisperKitWrapper.isOnDisk(modelName: name) else { return }
        downloading.insert(name)
        Task { @MainActor in
            await WhisperKitWrapper.downloadModel(name)
            downloading.remove(name)
            localModelTick &+= 1
        }
    }

    /// Qwen3-ASR 模型行 —— 结构同 transcriptionModelRow，用 Qwen3ASRWrapper。
    private func qwenModelRow(_ m: (name: String, label: String, size: String)) -> some View {
        let ready = Qwen3ASRWrapper.isOnDisk(modelId: m.name)
        let isDownloading = downloading.contains(m.name)
        return HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text(m.size)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                readyWithUninstall { uninstallQwenModel(m.name) }
            } else if isDownloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.85))
                }
            } else {
                Button("Download") { downloadQwenModel(m.name) }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { startLocalModelPolling() }
    }

    /// 点 Download:后台拉 Qwen 模型(~2.3 GB),完成后刷新让状态变 Ready。
    private func downloadQwenModel(_ name: String) {
        guard !downloading.contains(name), !Qwen3ASRWrapper.isOnDisk(modelId: name) else { return }
        downloading.insert(name)
        Task { @MainActor in
            await Qwen3ASRWrapper.downloadModel(modelId: name)
            downloading.remove(name)
            localModelTick &+= 1
        }
    }

    /// 2s 轮一次 isOnDisk,把状态打到 localModelTick 强制重渲染。view 不可见
    /// 时 Timer 不再被 SwiftUI 持有自然停。
    private func startLocalModelPolling() {
        // 简单实现:每次 onAppear 启动一个 Task 短轮询(只在所有模型都还没
        // ready 时才反复轮,全 ready 之后停)。guard 保证全程只有一个轮询 Task,
        // 否则 7 行 onAppear + .id 重渲染会每 2s 成倍 spawn。
        guard !isPollingLocalModels else { return }
        isPollingLocalModels = true
        Task { @MainActor in
            defer { isPollingLocalModels = false }
            while !allLocalModelsReady {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                localModelTick &+= 1
            }
        }
    }

    /// 轮询停止条件:只看「采集必需」的 —— 当前选中的 Whisper 模型 + 三个说话人
    /// 模型 ready 即可。其它可选 Whisper 模型按需下载,不阻塞轮询停止。
    private var allLocalModelsReady: Bool {
        WhisperKitWrapper.isOnDisk(modelName: config.current.capture.audio.whisperModel)
            && SpeakerModelStore.isOnDisk(.embedding)
            && SpeakerModelStore.isOnDisk(.segmentation)
            && SpeakerModelStore.isOnDisk(.vadSilero)
    }

}
