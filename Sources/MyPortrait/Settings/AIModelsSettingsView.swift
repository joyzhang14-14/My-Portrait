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

    var body: some View {
        SettingsPage("AI models",
                     subtitle: "On-device models that power your capture pipeline.",
                     onResetCurrentPage: { config.mutate { $0.aiModels = .init() } }) {

            SettingsCard(
                title: "Local capture models",
                footnote: "These power voice features. Some download automatically; others have a Download button. Each stays disabled until it shows Ready."
            ) {
                // Whisper 转录模型 —— 跟 Audio Capture 的 model picker 同一份目录。
                // 没装的这里点 Download 下载,装好后才能在 picker 里选。
                ForEach(Array(WhisperKitWrapper.allTranscriptionModels.enumerated()), id: \.offset) { _, m in
                    transcriptionModelRow(m)
                    SettingsDivider()
                }
                // Qwen3-ASR 模型 —— 走手动下载（不随 app 启动自动下）。下好后才能在
                // Audio Capture 里选 Qwen 引擎 + 对应 model。
                ForEach(Array(Qwen3ASRWrapper.allQwenModels.enumerated()), id: \.offset) { _, m in
                    qwenModelRow(m)
                    SettingsDivider()
                }
                // Speaker identification models — download here, choose which to use in Audio Capture.
                ForEach(Array(SpeakerModel.embeddingOptions.enumerated()), id: \.offset) { _, m in
                    speakerDownloadRow(m)
                    SettingsDivider()
                }
                localModelRow("Voice segmentation", detail: "pyannote segmentation-3.0 (~6 MB)",
                              ready: SpeakerModelStore.isOnDisk(.segmentation))
                SettingsDivider()
                localModelRow("Voice activity", detail: "Silero VAD (~2 MB)",
                              ready: SpeakerModelStore.isOnDisk(.vadSilero))
            }
            .id(localModelTick)   // 强制重渲染,反映新的 isOnDisk 结果
        }
    }

    // MARK: - Local model row

    private func localModelRow(_ title: String, detail: String, ready: Bool) -> some View {
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
            Text(ready ? "Ready" : "Downloading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ready
                                 ? Color.green.opacity(0.85)
                                 : Color.orange.opacity(0.85))
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
                Text("Ready").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.green.opacity(0.85))
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
                Text("Transcription")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text("\(m.label) (\(m.size))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
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
                Text("Transcription (Qwen)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                Text("\(m.label) (\(m.size))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            Spacer(minLength: 8)
            if ready {
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
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
