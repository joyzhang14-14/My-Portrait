import SwiftUI

/// AI Models — list saved presets, create/edit, set default. Mirrors
/// Orphies' `ai-presets.tsx` minus the in-house quota / share-to-team bits
/// (those need a backend we don't have).
struct AIModelsSettingsView: View {
    @State private var presets: [AIPreset] = AIPresetStore.shared.all
    @State private var editing: AIPreset? = nil

    var body: some View {
        SettingsPage("AI models",
                     subtitle: "Presets that map a provider + model to a name you can pick from chat") {

            SettingsCard(title: "Presets",
                         footnote: "Default preset is the one the chat input picker resolves to when no provider is explicitly chosen.") {
                if presets.isEmpty {
                    Text("No presets yet — click New preset below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(presets) { p in
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
                        if p.id != presets.last?.id { SettingsDivider() }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    editing = AIPreset.blank()
                } label: {
                    Label("New preset", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .sheet(item: $editing) { preset in
            AIPresetEditor(initial: preset) { saved in
                if presets.contains(where: { $0.id == saved.id }) {
                    AIPresetStore.shared.update(saved)
                } else {
                    AIPresetStore.shared.add(saved)
                }
                presets = AIPresetStore.shared.all
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    // MARK: - Actions

    private func setDefault(_ p: AIPreset) {
        AIPresetStore.shared.setDefault(p.id)
        presets = AIPresetStore.shared.all
    }
    private func duplicate(_ p: AIPreset) {
        var copy = p; copy.id = UUID(); copy.name = p.name + " copy"; copy.isDefault = false
        AIPresetStore.shared.add(copy)
        presets = AIPresetStore.shared.all
    }
    private func delete(_ p: AIPreset) {
        AIPresetStore.shared.delete(p.id)
        presets = AIPresetStore.shared.all
    }

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
    @State var initial: AIPreset
    let onSave: (AIPreset) -> Void
    let onCancel: () -> Void
    @State private var revealKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI preset").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save")   { onSave(initial) }
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
                        TextField("key", text: $initial.apiKey).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("key", text: $initial.apiKey).textFieldStyle(.roundedBorder)
                    }
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye").font(.system(size: 11))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL (optional, for custom endpoints)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("https://…", text: $initial.baseURL).textFieldStyle(.roundedBorder)
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
    }
}

// MARK: - Store + model

struct AIPreset: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var provider: String       // Provider.rawValue
    var model: String
    var apiKey: String
    var baseURL: String
    var maxTokens: Int
    var maxContext: Int
    var systemPrompt: String
    var isDefault: Bool

    static func blank() -> AIPreset {
        AIPreset(
            id: UUID(), name: "New preset",
            provider: Provider.chatgpt.rawValue,
            model: Provider.chatgpt.defaultModel,
            apiKey: "", baseURL: "",
            maxTokens: 4096, maxContext: 16384,
            systemPrompt: "", isDefault: false
        )
    }
}

@MainActor
final class AIPresetStore {
    static let shared = AIPresetStore()
    private let key = "Settings.aiPresets.v1"

    private(set) var all: [AIPreset] = []

    private init() { load() }

    func add(_ p: AIPreset) { all.append(p); save() }
    func update(_ p: AIPreset) {
        guard let i = all.firstIndex(where: { $0.id == p.id }) else { return }
        all[i] = p; save()
    }
    func delete(_ id: UUID) { all.removeAll { $0.id == id }; save() }
    func setDefault(_ id: UUID) {
        for i in all.indices { all[i].isDefault = (all[i].id == id) }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AIPreset].self, from: data) else { return }
        all = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
