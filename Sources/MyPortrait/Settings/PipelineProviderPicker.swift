import SwiftUI

/// 单个 pipeline 的 AI provider + main/light model 选择器(**不含外层卡片** ——
/// 由调用方套自己的容器:Memory 页用 `section()`,Typing Capture 页用 `SettingsCard`)。
///
/// - 可选 provider 直接读 Connections(连了就在列)。
/// - Ollama 的 model 读用户本地实际安装的(OllamaModelStore),其它走写死的。
/// - 没选有效 provider → 上方红字 "Please select a provider",model 行不显示。
/// - 配置存在各 pipeline 自己的 `SchedulerConfig`(providerId/model/modelLight)。
struct PipelineProviderPicker: View {
    /// 指向这条 pipeline 的 SchedulerConfig(如 `\.scheduler.event`)。
    let pipeline: WritableKeyPath<MyPortraitConfig, SchedulerConfig>

    @Environment(AppState.self) private var appState
    @State private var cfg = ConfigStore.shared
    @State private var ollamaStore = OllamaModelStore.shared

    var body: some View {
        let availableProviders = Provider.allCases.filter {
            appState.isConnected($0.integrationId)
        }
        // 选中的 provider 必须「已连接」;否则视为未选(空 / 已断开)。
        let selectedProvider: Provider? = {
            guard let p = Provider(rawValue: cfg.current[keyPath: pipeline].providerId),
                  availableProviders.contains(p) else { return nil }
            return p
        }()
        // get 把无效/未连接的值归一成 "";set 换 provider 时清旧 model。
        let providerBinding = Binding<String>(
            get: { selectedProvider?.rawValue ?? "" },
            set: { newId in
                cfg.mutate {
                    $0[keyPath: pipeline].providerId = newId
                    $0[keyPath: pipeline].model = ""
                    $0[keyPath: pipeline].modelLight = ""
                }
            }
        )
        let models: [String] = selectedProvider == .ollama
            ? ollamaStore.models
            : (selectedProvider?.availableModels ?? [])

        return VStack(alignment: .leading, spacing: 12) {
            if availableProviders.isEmpty {
                Text("No AI providers connected. Open Settings → Connections to add ChatGPT, Anthropic, Gemini, Ollama, etc.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if selectedProvider == nil {
                    Text("Please select a provider")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                row("Provider") {
                    Picker("", selection: providerBinding) {
                        ForEach(availableProviders, id: \.rawValue) { p in
                            Text(Self.providerDisplayName(p)).tag(p.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 没配置 model(="")时 picker 留空白(不放占位项);pipeline 侧
                // resolvedModel 把空串映射到 provider.defaultModel。
                if selectedProvider != nil {
                    row("Main model (heavy tasks)") {
                        Picker("", selection: cfg.binding(pipeline.appending(path: \.model))) {
                            ForEach(models, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    row("Light model (clustering / light tasks)") {
                        Picker("", selection: cfg.binding(pipeline.appending(path: \.modelLight))) {
                            ForEach(models, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // 选中 Ollama → 拉一次本地模型列表刷新下拉。
        .task(id: selectedProvider) {
            if selectedProvider == .ollama { await ollamaStore.refresh() }
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(_ label: String,
                                     @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: 280, alignment: .leading)
            trailing()
        }
    }

    static func providerDisplayName(_ p: Provider) -> String {
        switch p {
        case .chatgpt:     return "Codex (ChatGPT Pro / Plus OAuth)"
        case .openaiBYOK:  return "OpenAI (API key)"
        case .anthropic:   return "Anthropic (API key)"
        case .ollama:      return "Ollama (local)"
        case .gemini:      return "Gemini (API key)"
        case .perplexity:  return "Perplexity (API key)"
        case .deepseek:    return "DeepSeek (API key)"
        case .claudeCode:  return "Claude Code CLI (Pro / Max subscription)"
        }
    }
}
