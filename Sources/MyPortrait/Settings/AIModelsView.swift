import SwiftUI

/// AI Models — list saved presets, create/edit, set default. Mirrors
/// Orphies' `ai-presets.tsx` minus the in-house quota / share-to-team bits
/// (those need a backend we don't have).
struct AIModelsSettingsView: View {
    @State private var config = ConfigStore.shared
    @State private var editing: AIPresetSpec? = nil

    var body: some View {
        SettingsPage("AI models",
                     subtitle: "Presets that map a provider + model to a name you can pick from chat") {

            SettingsCard(title: "Presets",
                         footnote: "Default preset is the one the chat input picker resolves to when no provider is explicitly chosen.") {
                if config.current.aiModels.presets.isEmpty {
                    Text("No presets yet — click New preset below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(config.current.aiModels.presets) { p in
                        SettingsRow(
                            p.name,
                            description: "\(providerLabel(p.provider)) · \(p.model)\(p.maxTokens > 0 ? "  ·  \(p.maxTokens) tok" : "")",
                            icon: iconForProvider(p.provider)
                        ) {
                            HStack(spacing: 4) {
                                if p.isDefault {
                                    Text("DEFAULT")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .tracking(0.6)
                                        .foregroundStyle(Color.purple.opacity(0.85))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().stroke(Color.purple.opacity(0.45), lineWidth: 0.8))
                                } else {
                                    Button("Set default") { setDefault(p) }
                                        .font(.system(size: 11))
                                }
                                Menu {
                                    Button("Edit",      action: { editing = p })
                                    Button("Duplicate", action: { duplicate(p) })
                                    Divider()
                                    Button("Delete", role: .destructive, action: { delete(p) })
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .frame(width: 22, height: 22)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                        if p.id != config.current.aiModels.presets.last?.id { SettingsDivider() }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    editing = AIPresetSpec()
                } label: {
                    Label("New preset", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
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
        .sheet(item: $editing) { preset in
            AIPresetEditor(initial: preset) { saved in
                if config.current.aiModels.presets.contains(where: { $0.id == saved.id }) {
                    config.mutate {
                        if let i = $0.aiModels.presets.firstIndex(where: { $0.id == saved.id }) {
                            $0.aiModels.presets[i] = saved
                        }
                    }
                } else {
                    config.mutate { $0.aiModels.presets.append(saved) }
                }
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    
    private func setDefault(_ p: AIPresetSpec) {
        config.mutate {
            for i in $0.aiModels.presets.indices {
                $0.aiModels.presets[i].isDefault = ($0.aiModels.presets[i].id == p.id)
            }
        }
    }
    private func duplicate(_ p: AIPresetSpec) {
        var copy = p; copy.id = UUID(); copy.name = p.name + " copy"; copy.isDefault = false
        config.mutate { $0.aiModels.presets.append(copy) }
    }
    private func delete(_ p: AIPresetSpec) {
        config.mutate { $0.aiModels.presets.removeAll { $0.id == p.id } }
    }

    // MARK: - View helpers
// MARK: - View helpers

    private func providerLabel(_ p: String) -> String {
        Provider(rawValue: p).map { $0.label } ?? p
    }
    private func iconForProvider(_ p: String) -> String {
        switch Provider(rawValue: p) {
        case .chatgpt:        return "circle.dotted"
        case .anthropic:      return "a.circle"
        case .openaiBYOK:     return "key.horizontal"
        case .ollama:         return "cpu"
        case .gemini:         return "diamond"
        default:              return "wand.and.stars"
        }
    }
}

private extension Provider {
    var label: String {
        switch self {
        case .chatgpt:    return "ChatGPT (OAuth)"
        case .anthropic:  return "Anthropic"
        case .openaiBYOK: return "OpenAI BYOK"
        case .ollama:     return "Ollama (local)"
        case .gemini:     return "Gemini"
        }
    }
}

// MARK: - Editor sheet

private struct AIPresetEditor: View {
    @State var initial: AIPresetSpec
    let onSave: (AIPresetSpec) -> Void
    let onCancel: () -> Void
    @State private var revealKey = false
    /// Plaintext entered in the API key field. Loaded from SecretStore via
    /// `initial.apiKeyRef` on appear; on Save we write back to SecretStore
    /// (auto-assigning a ref if `initial.apiKeyRef` was empty) — the TOML
    /// only ever stores the ref string.
    @State private var apiKeyText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI preset").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save")   { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(initial.name.isEmpty || initial.model.isEmpty)
            }

            HStack(spacing: 8) {
                TextField("name", text: $initial.name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $initial.provider) {
                    ForEach(Provider.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                .onChange(of: initial.provider) { _, new in
                    // Default the model to the new provider's first option
                    // if the user hasn't typed something custom yet.
                    if let p = Provider(rawValue: new), !p.availableModels.contains(initial.model) {
                        initial.model = p.defaultModel
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("model id", text: $initial.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if let p = Provider(rawValue: initial.provider) {
                    Text("suggestions: " + p.availableModels.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API key (optional)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack {
                    if revealKey {
                        TextField("key", text: $apiKeyText).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("key", text: $apiKeyText).textFieldStyle(.roundedBorder)
                    }
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye").font(.system(size: 11))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL (optional, for custom endpoints)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("https://…", text: $initial.baseUrl).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max tokens").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("", value: $initial.maxTokens, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max context").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("", value: $initial.maxContext, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("System prompt").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { initial.systemPrompt = "" }.font(.system(size: 11))
                }
                TextEditor(text: $initial.systemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if !initial.apiKeyRef.isEmpty,
               let data = SecretStore.shared.get(initial.apiKeyRef),
               let s = String(data: data, encoding: .utf8) {
                apiKeyText = s
            }
        }
    }

    /// Persist the secret value to SecretStore + update the TOML-side ref
    /// before handing the spec back to the parent's onSave.
    private func commit() {
        var spec = initial
        let trimmed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !spec.apiKeyRef.isEmpty { SecretStore.shared.delete(spec.apiKeyRef) }
            spec.apiKeyRef = ""
        } else {
            let ref = spec.apiKeyRef.isEmpty
                ? "apikey:preset:\(spec.id.uuidString)"
                : spec.apiKeyRef
            try? SecretStore.shared.set(ref, value: Data(trimmed.utf8))
            spec.apiKeyRef = ref
        }
        onSave(spec)
    }
}

