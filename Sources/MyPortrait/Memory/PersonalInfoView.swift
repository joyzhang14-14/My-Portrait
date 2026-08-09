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

                // 灰字说明全部收走:字段的提示进输入框 placeholder(不占版面,
                // 填了就自动消失),整卡 / 需要展开讲的进 ⓘ。
                SettingsCard(
                    title: "Name",
                    info: "Used as-is in prompts to the memory pipeline. Empty fields are skipped."
                ) {
                    SettingsRow("First name", icon: "person") {
                        textField(\.personalInfo.firstName, placeholder: "Given name")
                    }
                    SettingsDivider()
                    SettingsRow("Middle name", icon: "person") {
                        textField(\.personalInfo.middleName, placeholder: "Optional")
                    }
                    SettingsDivider()
                    SettingsRow("Last name", icon: "person") {
                        textField(\.personalInfo.lastName, placeholder: "Family name")
                    }
                    SettingsDivider()
                    SettingsRow("Also goes by",
                                info: "Alias, nickname, English name — whatever you'd like the AI to call you.",
                                icon: "person.crop.circle.badge.questionmark") {
                        textField(\.personalInfo.alias, placeholder: "Optional")
                    }
                }

                SettingsCard(
                    title: "Identity",
                    info: "Helps the AI choose the right pronouns and contextualize cultural references in your events."
                ) {
                    SettingsRow("Pronouns",
                                info: "How the AI refers to you in summaries.",
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
                    SettingsRow("Nationality", icon: "flag") {
                        textField(\.personalInfo.nationality, placeholder: "e.g. Chinese")
                    }
                    SettingsDivider()
                    SettingsRow("Ethnicity", icon: "globe") {
                        textField(\.personalInfo.ethnicity, placeholder: "Optional")
                    }
                    SettingsDivider()
                    SettingsRow("Date of birth", icon: "calendar") {
                        textField(\.personalInfo.birthDate, placeholder: "YYYY-MM-DD")
                    }
                }

                SettingsCard(
                    title: "Languages",
                    info: "Add the languages you speak. The AI uses this to interpret what it sees in your captured screen + typing."
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
        Text("Personal info")
            .font(.system(size: 26, weight: .semibold))
    }

    // MARK: - Languages

    @ViewBuilder
    private var languagesEditor: some View {
        let langs = config.current.personalInfo.languages
        // spacing **必须是 0** —— SettingsCard 的内容槽本身是 VStack(spacing: 0),
        // Name / Identity 那两张卡的行和分隔线因此是贴死的。这里原来写了 8,
        // 等于每行之间多塞 8pt,分隔线悬在空档中间而不是紧贴上下行,
        // 整张 Languages 卡的行距就跟别的卡对不上。
        VStack(alignment: .leading, spacing: 0) {
            if langs.isEmpty {
                Text("No languages added.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                // 直接复用 SettingsRow,跟上面 First name / Nationality 等字段
                // 用同一套排版,SwiftUI Text 对齐细节由组件负责,不再自己拼
                // HStack(避免 SF Symbol 字形重心 + 单行 vs 双行的视觉错位)。
                // icon 用 character.book.closed.fill —— 之前 character.bubble.fill
                // 有向下小尾巴,bounding box 比文字高、视觉重心偏上,HStack
                // center 之后整行内容跑到上半,下半留空看着不平衡。book 这个
                // 图标 bounds 矩形对称无尾巴,跟文字 center 对齐严丝合缝。
                ForEach(Array(langs.enumerated()), id: \.offset) { idx, lang in
                    SettingsRow(lang, icon: "character.book.closed.fill") {
                        Button {
                            removeLanguage(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(lang)")
                    }
                    if idx != langs.count - 1 { SettingsDivider() }
                }
            }

            SettingsDivider()
            // Add 行不能复用 SettingsRow(它假设 title-on-left + control-on-right);
            // 这里 TextField 要紧跟 icon 占据主区域。手写 HStack,padding 跟
            // SettingsRow 完全一致(leading 14 / trailing 14 / vertical 10),
            // 视觉跟上面 language 行对齐。
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary.opacity(0.75))
                    .frame(width: 22)
                TextField("Add a language (e.g. English, 中文)", text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addLanguage)
                Button("Add") { addLanguage() }
                    .font(.system(size: 13, weight: .medium))
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
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
            // 尺寸跟设置页其他输入框对齐:内边距 10/6、宽 220
            //(CaptureView 的 Endpoint / API key、SettingsView 的搜索框都是这套)。
            // 字体不跟 —— 那几处是 monospaced,因为填的是 URL / key;
            // 这里填的是人名,等宽反而怪。
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
            .frame(width: 220)
    }
}
