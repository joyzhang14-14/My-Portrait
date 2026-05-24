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
                     subtitle: "Pick which connected AI services + models show up in your chat picker") {

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
                title: "Semantic search index",
                footnote: "Off by default. When on, captured text is embedded into vectors (bge-m3) so search can match by meaning, not just keywords — at the cost of ~1.15 GB resident memory while indexing. Keyword search works either way. Indexing runs only while plugged in."
            ) {
                SettingsRow("Enable semantic indexing",
                            description: "Build a vector index for meaning-based search.",
                            icon: "magnifyingglass") {
                    Toggle("", isOn: config.binding(\.aiModels.semanticIndexEnabled))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No AI providers connected yet.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
            Text("Open Settings → Connections to add ChatGPT, Anthropic, Gemini, Ollama, etc.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
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
                        .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.45))
                    Text(modelsSummary(for: integ, enabled: isEnabled))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { toggleExpand(integ.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
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

    private func providerGlyph(_ integ: Integration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(integ.accent.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(integ.accent.opacity(0.55), lineWidth: 0.6)
                )
            Text(integ.letter)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 26, height: 26)
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
                            .foregroundStyle(.white.opacity(isChecked ? 0.92 : 0.55))
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
