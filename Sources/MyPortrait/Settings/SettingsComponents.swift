import SwiftUI

/// Group of related settings rendered as one glass card with an optional
/// section header above. Pattern matches macOS System Settings.
struct SettingsCard<Content: View>: View {
    let title: String?
    let footnote: String?
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, footnote: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 14)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row inside a `SettingsCard`. Label + optional description on the
/// left, control on the right. Rows separate with a hairline divider.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let description: String?
    let icon: String?
    var indent: CGFloat = 0
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, description: String? = nil, icon: String? = nil,
         indent: CGFloat = 0,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.description = description; self.icon = icon
        self.indent = indent; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.leading, 14 + indent)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }
}

/// Convenience overload: row that does nothing on the right (e.g. a button
/// row where the button IS the row's body).
struct SettingsActionRow: View {
    let title: String
    let description: String?
    let buttonLabel: String
    let buttonIcon: String?
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, description: String? = nil,
         buttonLabel: String, buttonIcon: String? = nil,
         role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.description = description
        self.buttonLabel = buttonLabel; self.buttonIcon = buttonIcon
        self.role = role; self.action = action
    }

    var body: some View {
        SettingsRow(title, description: description) {
            Button(role: role, action: action) {
                HStack(spacing: 4) {
                    if let buttonIcon {
                        Image(systemName: buttonIcon).font(.system(size: 11))
                    }
                    Text(buttonLabel).font(.system(size: 12, weight: .medium))
                }
            }
        }
    }
}

/// Thin separator that fits the card visual.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 48)
    }
}

/// Sticky-feeling section title used at the top of each main pane.
struct SettingsPageTitle: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// Standard scrollable container for a settings section. Holds the page
/// title + an arbitrary VStack of cards. Surfaces config-file errors
/// (parse failures) inline so the user knows when ~/.portrait/config.toml
/// got rejected and the app fell back to defaults.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content
    @State private var config = ConfigStore.shared

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    SettingsPageTitle(title: title, subtitle: subtitle)
                    Spacer()
                    ConfigToolbar(config: config)
                }
                .padding(.bottom, 4)

                if let err = config.loadError {
                    ConfigErrorBanner(message: err) {
                        config.reload()
                    }
                }

                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }
}

/// "Reveal config.toml" + "Reset to defaults" buttons in the page header.
/// Lives on every Settings tab — fast escape hatch when the UI gets in the
/// way and the user wants to edit by hand or wipe the slate.
private struct ConfigToolbar: View {
    let config: ConfigStore
    @State private var confirmingReset = false
    var body: some View {
        HStack(spacing: 6) {
            Button {
                config.revealInFinder()
            } label: {
                Label("config.toml", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
            }
            .help("Open ~/.portrait/config.toml in Finder")

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .help("Restore every setting to its baked-in default")
        }
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $confirmingReset
        ) {
            Button("Reset", role: .destructive) { config.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes ~/.portrait/config.toml and restores every Settings value to its built-in default. Your conversations / pipes / templates are not touched.")
        }
    }
}

/// Inline orange banner for TOML parse errors. Click "Reload" to re-read
/// after fixing the file in vim.
private struct ConfigErrorBanner: View {
    let message: String
    let onReload: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange.opacity(0.90))
            VStack(alignment: .leading, spacing: 2) {
                Text("config.toml problem")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onReload) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.45), lineWidth: 0.7))
        )
    }
}

// MARK: - String-array editor (used by Privacy "Ignored Apps" / "Ignored URLs")

/// Compact tag-style editor for list values. Each entry rendered as a pill;
/// click × to remove; press Enter in the field to add. Persisted by the
/// caller — this view just reads + writes the binding.
struct TagListEditor: View {
    @Binding var tags: [String]
    var placeholder: String = "type to add…"
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white.opacity(0.85))
                        .background(
                            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.bouncyIcon)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.bouncyIcon)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func add() {
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !tags.contains(v) else { return }
        tags.append(v)
        draft = ""
    }
}

/// 自动换行的横向布局：一行放不下就折到下一行。SwiftUI 的 HStack 不会换行，
/// chip 多了会被挤压；用这个让 chip 流式排布、容器高度自适应。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Ignored-apps picker. Mirrors screenpipe's `MultiSelect` with two dropdowns:
///   - "Select app to ignore" — app names seen in captured frames
///   - "System / privacy"     — curated system-level entries that never show
///     up as a focused app (wallpaper, Dock, Control Center, …)
/// Either dropdown toggles membership; selected entries render as removable
/// chips. Every entry can be unchecked at any time.
struct IgnoredAppPicker: View {
    @Binding var apps: [String]
    var discovered: [String] = []

    /// Curated system / privacy entries. These are never the "focused app"
    /// so they'd never appear in `discovered` — surfaced here so the user
    /// can one-click toggle them. Mirrors screenpipe's default ignore list.
    static let systemEntries: [String] = [
        "Wallpaper", "Dock", "Control Center", "Settings",
        "Trash", "VPN", "Private", "Incognito", ".env",
        "Item-0", "App Icon Window", "Battery", "WiFi", "Clock",
    ]

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                dropdown(title: "Select app to ignore", icon: "plus.circle.fill",
                         options: discovered, emptyHint: "No captured apps yet")
                dropdown(title: "System / privacy", icon: "macwindow",
                         options: Self.systemEntries, emptyHint: "")
            }
            if !apps.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(apps, id: \.self) { app in
                        HStack(spacing: 4) {
                            Text(app)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                            Button {
                                apps.removeAll { $0 == app }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.bouncyIcon)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func dropdown(title: String, icon: String,
                          options: [String], emptyHint: String) -> some View {
        Menu {
            if options.isEmpty {
                Text(emptyHint)
            } else {
                ForEach(options, id: \.self) { app in
                    Button { toggle(app) } label: {
                        if apps.contains(app) {
                            Label(app, systemImage: "checkmark")
                        } else {
                            Text(app)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(boxBackground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func toggle(_ app: String) {
        if let i = apps.firstIndex(of: app) { apps.remove(at: i) } else { apps.append(app) }
    }
}

/// Typing 设置用的 app 选择器 —— 黑名单 / 回车发送列表共用。
/// 跟 `IgnoredAppPicker` 同形（下拉 + 可移除 chips），但条目是 **bundle id**：
/// 存 bundle id，显示友好名（bundle id 末段）。
struct TypingAppPicker: View {
    @Binding var apps: [String]            // bundle id
    var discovered: [String] = []          // 用户打过字的 app（bundle id）
    /// 永远生效、不可移除的条目（如硬编码黑名单）—— 灰显、带锁、无 × 。
    var locked: [String] = []

    /// bundle id → 友好名（com.tencent.xinWeChat → xinWeChat）。
    static func label(_ bundleId: String) -> String {
        let last = bundleId.split(separator: ".").last.map(String.init)
        return (last?.isEmpty == false ? last : nil) ?? bundleId
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dropdown(title: "Select app", icon: "plus.circle.fill",
                     options: discovered, emptyHint: "No typed-in apps yet")
            if !locked.isEmpty || !apps.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(locked, id: \.self) { lockedChip($0) }
                    ForEach(apps, id: \.self) { editableChip($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 用户加的条目 —— 可移除。
    @ViewBuilder
    private func editableChip(_ app: String) -> some View {
        HStack(spacing: 4) {
            Text(Self.label(app))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Button {
                apps.removeAll { $0 == app }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.bouncyIcon)
        }
        .padding(.horizontal, 7).padding(.vertical, 3.5)
        .help(app)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
        )
    }

    /// 硬编码、永远生效的条目 —— 灰显、带锁、不可移除。
    @ViewBuilder
    private func lockedChip(_ app: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
            Text(Self.label(app))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 7).padding(.vertical, 3.5)
        .help("\(app) — always excluded")
        .background(
            Capsule()
                .fill(Color.white.opacity(0.03))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7))
        )
    }

    @ViewBuilder
    private func dropdown(title: String, icon: String,
                          options rawOptions: [String], emptyHint: String) -> some View {
        let options = rawOptions.filter { !locked.contains($0) }
        Menu {
            if options.isEmpty {
                Text(emptyHint)
            } else {
                ForEach(options, id: \.self) { app in
                    Button { toggle(app) } label: {
                        if apps.contains(app) {
                            Label(Self.label(app), systemImage: "checkmark")
                        } else {
                            Text(Self.label(app))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(boxBackground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func toggle(_ app: String) {
        if let i = apps.firstIndex(of: app) { apps.remove(at: i) } else { apps.append(app) }
    }
}

/// `[String]` AppStorage bridge — UserDefaults stores arrays natively but
/// `@AppStorage` doesn't directly support them, so we round-trip via JSON.
struct StringArrayStorage {
    let key: String
    func get() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }
    func set(_ value: [String]) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
