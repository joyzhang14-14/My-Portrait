import SwiftUI

/// Memories → Personal Info 卡片。用户自填的基础画像,**全部可选**。
///
/// 填好的字段会被 `MemoryPrompts.aboutUserBlock(_:)` 拼成
/// "About the user:" 段落,塞到 memory pipeline(event / portrait /
/// personality)所有 LLM prompt 的最顶部 —— 帮助 LLM 在事件聚类、
/// 画像蒸馏、人格刷新时基于「这个人是谁」做判断。
///
/// 没填的字段直接跳过,不进 prompt。
struct PersonalInfoView: View {
    @State private var config = ConfigStore.shared

    /// 添加新语言的临时输入框文本。
    @State private var newLanguage: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                SettingsCard(
                    title: "Name",
                    footnote: "Used as-is in prompts to the memory pipeline. Empty fields are skipped."
                ) {
                    SettingsRow("First name",
                                description: "Given name (or chosen first name).",
                                icon: "person") {
                        textField(\.personalInfo.firstName, placeholder: "")
                    }
                    SettingsDivider()
                    SettingsRow("Middle name",
                                description: "Optional.",
                                icon: "person") {
                        textField(\.personalInfo.middleName, placeholder: "")
                    }
                    SettingsDivider()
                    SettingsRow("Last name",
                                description: "Family name.",
                                icon: "person") {
                        textField(\.personalInfo.lastName, placeholder: "")
                    }
                    SettingsDivider()
                    SettingsRow("Also goes by",
                                description: "Alias, nickname, English name — whatever you'd like the AI to call you.",
                                icon: "person.crop.circle.badge.questionmark") {
                        textField(\.personalInfo.alias, placeholder: "")
                    }
                }

                SettingsCard(
                    title: "Identity",
                    footnote: "Helps the AI choose the right pronouns and contextualize cultural references in your events."
                ) {
                    SettingsRow("Pronouns",
                                description: "How the AI refers to you in summaries.",
                                icon: "text.bubble") {
                        Picker("", selection: config.binding(\.personalInfo.gender)) {
                            ForEach(PersonalInfoGender.allCases, id: \.self) { g in
                                Text(g.displayName).tag(g)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 90)
                    }
                    SettingsDivider()
                    SettingsRow("Nationality",
                                description: "Free text. E.g. \"Chinese\", \"American\", \"German\".",
                                icon: "flag") {
                        textField(\.personalInfo.nationality, placeholder: "")
                    }
                    SettingsDivider()
                    SettingsRow("Ethnicity",
                                description: "Free text. Optional.",
                                icon: "globe") {
                        textField(\.personalInfo.ethnicity, placeholder: "")
                    }
                    SettingsDivider()
                    SettingsRow("Date of birth",
                                description: "YYYY-MM-DD. Used as-is.",
                                icon: "calendar") {
                        textField(\.personalInfo.birthDate, placeholder: "1990-01-31")
                            .frame(width: 130)
                    }
                }

                SettingsCard(
                    title: "Languages",
                    footnote: "Add the languages you speak. The AI uses this to interpret what it sees in your captured screen + typing."
                ) {
                    languagesEditor
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal info")
                .font(.system(size: 26, weight: .semibold))
            Text("Fill what you want — every empty field is simply skipped. Filled fields are passed to the memory pipeline (event clustering, portrait distillation, personality refresh) as extra context. Saved to `~/.portrait/config.toml`.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Languages

    @ViewBuilder
    private var languagesEditor: some View {
        let langs = config.current.personalInfo.languages
        VStack(alignment: .leading, spacing: 8) {
            if langs.isEmpty {
                Text("No languages added.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                // 每条一行 + 删除按钮 —— 不限数量。
                ForEach(Array(langs.enumerated()), id: \.offset) { idx, lang in
                    HStack(spacing: 10) {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.50))
                            .frame(width: 18)
                        Text(lang)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            removeLanguage(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(lang)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    if idx != langs.count - 1 { SettingsDivider() }
                }
            }

            SettingsDivider()
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.50))
                    .frame(width: 18)
                TextField("Add a language (e.g. English, 中文)", text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(addLanguage)
                Button("Add") { addLanguage() }
                    .font(.system(size: 12, weight: .medium))
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func addLanguage() {
        let v = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        config.mutate { c in
            // 去重(case-insensitive),已存在就跳过。
            if !c.personalInfo.languages.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                c.personalInfo.languages.append(v)
            }
        }
        newLanguage = ""
    }

    private func removeLanguage(at idx: Int) {
        config.mutate { c in
            guard idx < c.personalInfo.languages.count else { return }
            c.personalInfo.languages.remove(at: idx)
        }
    }

    // MARK: - Text field helper

    @ViewBuilder
    private func textField(_ kp: WritableKeyPath<MyPortraitConfig, String>,
                           placeholder: String) -> some View {
        TextField(placeholder, text: config.binding(kp))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
            .frame(width: 200)
    }
}
