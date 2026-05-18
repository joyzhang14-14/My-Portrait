import SwiftUI

struct PrivacySettingsView: View {
    @AppStorage(SettingsKeys.ignoreIncognito)        private var ignoreIncognito = true
    @AppStorage(SettingsKeys.captureClipboard)       private var captureClipboard = false
    @AppStorage(SettingsKeys.recordAudioWhileLocked) private var audioWhileLocked = false
    @AppStorage(SettingsKeys.piiRemoval)             private var piiRemoval = true

    @State private var ignoredApps:  [String] = StringArrayStorage(key: SettingsKeys.ignoredApps).get()
    @State private var includedApps: [String] = StringArrayStorage(key: SettingsKeys.includedApps).get()
    @State private var ignoredURLs:  [String] = StringArrayStorage(key: SettingsKeys.ignoredURLs).get()

    var body: some View {
        SettingsPage("Privacy",
                     subtitle: "What's allowed to be captured and what's filtered out") {

            SettingsCard(title: "Capture rules") {
                SettingsRow("Ignore incognito windows",
                            description: "Skip private browsing sessions automatically.",
                            icon: "eye.slash") {
                    Toggle("", isOn: $ignoreIncognito).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Capture clipboard",
                            description: "Include text you copy in the activity log.",
                            icon: "doc.on.clipboard") {
                    Toggle("", isOn: $captureClipboard).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Record audio while screen is locked",
                            description: "Keep listening even when your Mac is locked.",
                            icon: "lock.shield") {
                    Toggle("", isOn: $audioWhileLocked).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Data protection",
                footnote: "Applied to OCR text before it's pasted into chat prompts. Matches emails, phone numbers, credit cards, SSNs, JWTs, and common API keys."
            ) {
                SettingsRow("PII removal",
                            description: "Redact personally-identifying info before sending to AI.",
                            icon: "shield.lefthalf.filled") {
                    Toggle("", isOn: $piiRemoval).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Ignored apps",
                footnote: "Frames captured while these apps are foreground are dropped entirely."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Select apps to ignore…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    TagListEditor(tags: $ignoredApps, placeholder: "e.g. 1Password, Banking")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                        .onChange(of: ignoredApps) {
                            StringArrayStorage(key: SettingsKeys.ignoredApps).set(ignoredApps)
                        }
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
                    TagListEditor(tags: $includedApps, placeholder: "app name")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                        .onChange(of: includedApps) {
                            StringArrayStorage(key: SettingsKeys.includedApps).set(includedApps)
                        }
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
                    TagListEditor(tags: $ignoredURLs, placeholder: "e.g. wellsfargo.com, mail.")
                        .padding(.horizontal, 14).padding(.bottom, 12)
                        .onChange(of: ignoredURLs) {
                            StringArrayStorage(key: SettingsKeys.ignoredURLs).set(ignoredURLs)
                        }
                }
            }
        }
    }
}
