import SwiftUI

/// AI Models — 由 Connections 里已连接的 AI 服务驱动的可见性面板。
///
/// 设计:
///   - 只显示 Connections 里已连接的 AI 服务(category .ai + .local 且
///     Provider.from(integrationId:) 不返回 nil)。
///   - 每个 provider 一行,toggle 控制是否在 chat picker 里出现。
///   - 展开后是 model 多选(checkboxes),没勾的 model chat picker 不显示。
///   - 关掉一个 provider 不会断开 Connections 里的连接,只是从 chat picker
///     里隐藏。
struct AIModelsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigStore.shared
    @State private var expanded: Set<String> = []
    /// 本地模型 ready 状态轮询(SpeakerModelStore.isOnDisk / WhisperKitWrapper.isOnDisk
    /// 都是同步 fs check,2s 轮一次)。view 可见时跑,disappear 后停。
    @State private var localModelTick: Int = 0
    /// 轮询重入 guard —— 7 行 onAppear + .id 重渲染会重复触发,没它会每 2s 增殖一批 Task。
    @State private var isPollingLocalModels = false
    /// 正在下载的转录模型 name(点 Download 触发)。
    @State private var downloading: Set<String> = []

    /// connections 里已连上的 AI provider(category .ai + .local 且能映射到
    /// 实际的 Provider)。disabled 状态不影响这个列表 —— 这里列的是"能用的",
    /// 用户在这页点 toggle 把"想用的"挑出来。
    private var connectedAIIntegrations: [Integration] {
        IntegrationRegistry.all.filter {
            ($0.category == .ai || $0.category == .local)
            && appState.isConnected($0.id)
            && Provider.from(integrationId: $0.id) != nil
        }
    }

    var body: some View {
        SettingsPage("AI models",
                     subtitle: "Pick which connected AI services + models show up in your chat picker",
                     onResetCurrentPage: { config.mutate { $0.aiModels = .init() } }) {

            SettingsCard(
                title: "Connected providers",
                footnote: "Connect services in Settings → Connections first. Toggle a provider off here to hide it from the chat input picker (the connection itself stays alive)."
            ) {
                if connectedAIIntegrations.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(connectedAIIntegrations.enumerated()), id: \.element.id) { idx, integ in
                        providerRow(integ)
                        if idx != connectedAIIntegrations.count - 1 { SettingsDivider() }
                    }
                }
            }

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
                localModelRow("Voice signature", detail: "wespeaker CAM++ (~30 MB)",
                              ready: SpeakerModelStore.isOnDisk(.embedding))
                SettingsDivider()
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No AI providers connected yet.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.65))
            Text("Open Settings → Connections to add ChatGPT, Anthropic, Gemini, Ollama, etc.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.45))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Provider row(toggle + 可展开的 model 多选)

    @ViewBuilder
    private func providerRow(_ integ: Integration) -> some View {
        let isEnabled = config.current.aiModels.isProviderEnabled(integ.id)
        let isExpanded = expanded.contains(integ.id)

        VStack(spacing: 0) {
            // 顶部:icon + name + 展开箭头 + 启用 toggle
            HStack(spacing: 12) {
                providerGlyph(integ)
                VStack(alignment: .leading, spacing: 2) {
                    Text(integ.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(isEnabled ? 0.95 : 0.45))
                    Text(modelsSummary(for: integ, enabled: isEnabled))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { toggleExpand(integ.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide models" : "Pick visible models")

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { setProviderEnabled(integ.id, $0) }
                ))
                .labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .opacity(isEnabled ? 1.0 : 0.7)

            // 展开:model 多选
            if isExpanded {
                modelChecklist(for: integ, enabled: isEnabled)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    /// 跟 Connections / Chat picker 同款 IntegrationIcon —— 优先真 app icon
    /// (Codex / Claude / Gemini …),fallback assetName(DeepSeek / Perplexity
    /// 等带的品牌 SVG),最后 letter 方块兜底。视觉跨页面统一。
    private func providerGlyph(_ integ: Integration) -> some View {
        IntegrationIcon(integration: integ, size: 26)
    }

    @ViewBuilder
    private func modelChecklist(for integ: Integration, enabled: Bool) -> some View {
        let provider = Provider.from(integrationId: integ.id)
        let all = provider?.availableModels ?? []
        VStack(alignment: .leading, spacing: 4) {
            ForEach(all, id: \.self) { model in
                let isChecked = isModelEnabled(integrationId: integ.id, model: model)
                Button {
                    toggleModel(integrationId: integ.id, model: model)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(isChecked
                                             ? Color.purple.opacity(0.85)
                                             : .white.opacity(0.5))
                        Text(model)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(isChecked ? 0.92 : 0.55))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(isChecked ? 0.04 : 0))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary line

    private func modelsSummary(for integ: Integration, enabled: Bool) -> String {
        let provider = Provider.from(integrationId: integ.id)
        let all = provider?.availableModels ?? []
        let visible = config.current.aiModels.visibleModels(forIntegrationId: integ.id, available: all)
        if !enabled { return "Hidden from chat picker" }
        if visible.count == all.count { return "All \(all.count) models visible" }
        return "\(visible.count) / \(all.count) models visible"
    }

    // MARK: - Mutations

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func setProviderEnabled(_ id: String, _ on: Bool) {
        config.mutate {
            var set = Set($0.aiModels.disabledProviderIds)
            if on { set.remove(id) } else { set.insert(id) }
            $0.aiModels.disabledProviderIds = Array(set).sorted()
        }
    }

    private func isModelEnabled(integrationId: String, model: String) -> Bool {
        // 没配置过 = 默认全勾。
        if let picked = config.current.aiModels.enabledModelsByProvider[integrationId] {
            return picked.contains(model)
        }
        return true
    }

    /// 切换 model 勾选。第一次切的时候,需要"物化"默认值(把当前所有 model 都
    /// 当 picked,然后再去掉/加上目标 model),否则用户取消勾一个 model 时,
    /// 因为 enabledModelsByProvider[id] = nil 默认"全勾",会出现"看上去都勾着
    /// 但点哪个都没反应"的状态。
    private func toggleModel(integrationId: String, model: String) {
        guard let provider = Provider.from(integrationId: integrationId) else { return }
        let all = provider.availableModels
        config.mutate {
            var picked = $0.aiModels.enabledModelsByProvider[integrationId] ?? all
            if picked.contains(model) {
                picked.removeAll { $0 == model }
            } else {
                picked.append(model)
            }
            // 全勾时存 nil 让默认"全可见"规则继续生效,空数组也存进去
            // (空 = 用户主动一个都不留)。
            if Set(picked) == Set(all) {
                $0.aiModels.enabledModelsByProvider[integrationId] = nil
            } else {
                $0.aiModels.enabledModelsByProvider[integrationId] = picked
            }
        }
    }
}
