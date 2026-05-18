import SwiftUI

struct RecordingSettingsView: View {
    @AppStorage(SettingsKeys.audioEngine)         private var engine = AudioEngine.whisper.rawValue
    @AppStorage(SettingsKeys.deepgramAPIKey)      private var deepgramKey = ""
    @AppStorage(SettingsKeys.useCoreAudioCapture) private var coreAudio = true
    @AppStorage(SettingsKeys.captureSystemAudio)  private var systemAudio = true
    @AppStorage(SettingsKeys.recordingQuality)    private var quality = RecordingQuality.medium.rawValue
    @AppStorage(SettingsKeys.activeMonitor)       private var activeMonitor = ""
    @AppStorage(SettingsKeys.chineseMirror)       private var chineseMirror = false

    @State private var languages: [String]   = StringArrayStorage(key: SettingsKeys.audioLanguages).get()
    @State private var microphones: [String] = StringArrayStorage(key: SettingsKeys.microphonesSelected).get()

    var body: some View {
        SettingsPage("Recording",
                     subtitle: "What gets captured from your screen and microphone") {

            SettingsCard(
                title: "Audio engine",
                footnote: engine == AudioEngine.deepgram.rawValue
                    ? "Deepgram sends audio to the cloud. Audio leaves this Mac."
                    : "Whisper runs entirely on-device. Audio stays on this Mac."
            ) {
                SettingsRow("Engine",
                            description: "Transcription backend.",
                            icon: "waveform") {
                    Picker("", selection: $engine) {
                        ForEach(AudioEngine.allCases) { e in Text(e.label).tag(e.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if engine == AudioEngine.deepgram.rawValue {
                    SettingsDivider()
                    SettingsRow("Deepgram API key", description: "Required for cloud transcription.",
                                icon: "key") {
                        SecureField("paste key…", text: $deepgramKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            )
                            .frame(width: 220)
                    }
                }
                SettingsDivider()
                SettingsRow("Languages",
                            description: "Models to load for transcription.",
                            icon: "character.bubble") {
                    EmptyView()
                }
                VStack { TagListEditor(tags: $languages, placeholder: "e.g. en, zh, ja") }
                    .padding(.horizontal, 48).padding(.bottom, 12)
                    .onChange(of: languages) {
                        StringArrayStorage(key: SettingsKeys.audioLanguages).set(languages)
                    }
            }

            SettingsCard(title: "Microphones") {
                SettingsRow("Selected microphones",
                            description: "What you say. Leave empty to use the system default.",
                            icon: "mic") { EmptyView() }
                VStack { TagListEditor(tags: $microphones, placeholder: "device name…") }
                    .padding(.horizontal, 48).padding(.bottom, 12)
                    .onChange(of: microphones) {
                        StringArrayStorage(key: SettingsKeys.microphonesSelected).set(microphones)
                    }
            }

            SettingsCard(title: "System audio") {
                SettingsRow("Capture system audio",
                            description: "What you hear (loopback).",
                            icon: "speaker.wave.2") {
                    Toggle("", isOn: $systemAudio).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("CoreAudio capture",
                            description: "Lower-overhead system-audio path. Requires macOS 14+.",
                            icon: "rectangle.connected.to.line.below") {
                    Toggle("", isOn: $coreAudio).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Screen recording") {
                SettingsRow("Recording quality",
                            description: "Higher quality means larger snapshots.",
                            icon: "rectangle.stack") {
                    Picker("", selection: $quality) {
                        ForEach(RecordingQuality.allCases) { q in Text(q.label).tag(q.rawValue) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Monitor",
                            description: "Which display to record. Multi-monitor recording is disabled.",
                            icon: "display") {
                    TextField("primary", text: $activeMonitor)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.04))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                        )
                        .frame(width: 160)
                }
            }

            SettingsCard(title: "Network") {
                SettingsRow("Chinese mirror",
                            description: "Use a CN-region mirror for model downloads.",
                            icon: "globe.asia.australia") {
                    Toggle("", isOn: $chineseMirror).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
