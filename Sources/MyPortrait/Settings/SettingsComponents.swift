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
/// title + an arbitrary VStack of cards.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageTitle(title: title, subtitle: subtitle)
                    .padding(.bottom, 4)
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
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !tags.isEmpty {
                HStack(spacing: 6) {
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
                            .buttonStyle(.plain)
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
