import SwiftUI

struct PrivacySettingsView: View {
    @State private var config = ConfigStore.shared
    /// App names seen in captured frames — powers the ignored-apps dropdown.
    @State private var discoveredApps: [String] = []

    var body: some View {
        SettingsPage("Privacy",
                     subtitle: "What's allowed to be captured and what's filtered out") {

            SettingsCard(title: "Capture rules") {
                SettingsRow("Ignore incognito windows",
                            description: "Skip private browsing sessions automatically.",
                            icon: "eye.slash") {
                    Toggle("", isOn: config.binding(\.privacy.ignoreIncognito)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Capture clipboard",
                            description: "Include text you copy in the activity log.",
                            icon: "doc.on.clipboard") {
                    Toggle("", isOn: config.binding(\.privacy.captureClipboard)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Record audio while screen is locked",
                            description: "Keep listening even when your Mac is locked.",
                            icon: "lock.shield") {
                    Toggle("", isOn: config.binding(\.privacy.recordAudioWhileLocked)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Mask ignored windows",
                            description: "Exclude windows matching the ignore lists below from the screenshot — the frame is still captured, those windows just go transparent.",
                            icon: "rectangle.dashed") {
                    Toggle("", isOn: config.binding(\.privacy.maskIgnoredApps)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Data protection",
                footnote: "Applied to OCR text before it's pasted into chat prompts. Matches emails, phone numbers, credit cards, SSNs, JWTs, and common API keys."
            ) {
                SettingsRow("PII removal",
                            description: "Redact personally-identifying info before sending to AI.",
                            icon: "shield.lefthalf.filled") {
                    Toggle("", isOn: config.binding(\.privacy.piiRemoval)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Ignored apps",
                footnote: "Windows from these apps are masked out of the screenshot (transparent). The frame itself is still captured. Case-insensitive substring match against the window's app name or title."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pick from apps you've captured, or type a custom name…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    IgnoredAppPicker(apps: config.binding(\.privacy.ignoredApps), discovered: discoveredApps)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                                        }
            }

            SettingsCard(
                title: "Included apps (allowlist)",
                footnote: "If non-empty, ONLY frames from these apps are captured. Leave empty to capture everything except the ignored list."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Only capture these apps (optional)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    TagListEditor(tags: config.binding(\.privacy.includedApps), placeholder: "app name")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                                        }
            }

            SettingsCard(
                title: "Ignored URLs",
                footnote: "Substring match. e.g. \"chase.com\" filters every page on chase.com."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Hostnames or substrings…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    TagListEditor(tags: config.binding(\.privacy.ignoredUrls), placeholder: "e.g. wellsfargo.com, mail.")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                                        }
            }

            SettingsCard(
                title: "Ignored window titles",
                footnote: "Case-insensitive substring match against each window's title. e.g. \"Incognito\" masks every private-browsing window out of the screenshot."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Window title substrings…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    TagListEditor(tags: config.binding(\.privacy.ignoredWindowTitles), placeholder: "e.g. Incognito, Private")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                                        }
            }
        }
        .task {
            discoveredApps = await Self.loadDiscoveredApps()
        }
    }

    /// Off-main scan of `frames.app_name` for the ignored-apps dropdown.
    private static func loadDiscoveredApps() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            TimelineDB().distinctAppNames()
        }.value
    }
}
