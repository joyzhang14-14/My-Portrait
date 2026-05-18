import SwiftUI

/// Mirrors Orphies' Recording section. User-vetoed fields are intentionally
/// absent: Use all monitors, Auto-detect audio devices, Auto-detect meeting.
struct RecordingSettingsView: View {
    @AppStorage(SettingsKeys.audioRecordingEnabled)  private var audioRec = true
    @AppStorage(SettingsKeys.userName)               private var userName = ""
    @AppStorage(SettingsKeys.audioEngine)            private var engine = AudioEngine.whisper.rawValue
    @AppStorage(SettingsKeys.deepgramAPIKey)         private var deepgramKey = ""
    @AppStorage(SettingsKeys.useCoreAudioCapture)    private var coreAudio = true
    @AppStorage(SettingsKeys.captureSystemAudio)     private var systemAudio = true
    @AppStorage(SettingsKeys.speakerIdEnabled)       private var speakerId = true
    @AppStorage(SettingsKeys.filterMusic)            private var filterMusic = false
    @AppStorage(SettingsKeys.batchTranscription)     private var batchTranscription = true
    @AppStorage(SettingsKeys.autoSelectAudioDevices) private var autoSelectAudio = true

    @AppStorage(SettingsKeys.screenRecordingEnabled) private var screenRec = true
    @AppStorage(SettingsKeys.ocrEngine)              private var ocrEngine = OCREngine.tesseract.rawValue
    @AppStorage(SettingsKeys.videoFps)               private var fps: Int = 1
    @AppStorage(SettingsKeys.recordingQuality)       private var quality = RecordingQuality.medium.rawValue
    @AppStorage(SettingsKeys.videoFormat)            private var format = VideoFormat.h264.rawValue
    @AppStorage(SettingsKeys.frameIntervalMs)        private var frameIntervalMs: Int = 1000
    @AppStorage(SettingsKeys.chineseMirror)          private var chineseMirror = false

    @AppStorage(SettingsKeys.powerMode)              private var powerMode = PowerMode.auto.rawValue

    @State private var languages:  [String] = StringArrayStorage(key: SettingsKeys.audioLanguages).get()
    @State private var microphones:[String] = StringArrayStorage(key: SettingsKeys.microphonesSelected).get()
    @State private var vocabulary: [String] = StringArrayStorage(key: SettingsKeys.customVocabulary).get()

    var body: some View {
        SettingsPage("Recording", subtitle: "Audio + screen capture") {

            powerModeCard
            audioSection
            screenSection
            systemSection
        }
    }

    // MARK: - Power mode

    private var powerModeCard: some View {
        SettingsCard(
            title: "Power mode",
            footnote: "Switches capture FPS, transcription cadence, and OCR aggressiveness based on the profile you pick."
        ) {
            ForEach(PowerMode.allCases) { mode in
                PowerModeRow(mode: mode, isActive: powerMode == mode.rawValue) {
                    powerMode = mode.rawValue
                }
                if mode != PowerMode.allCases.last { SettingsDivider() }
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Group {
            SettingsCard(title: "Audio recording") {
                SettingsRow("Audio recording",
                            description: "Capture from your microphone(s).",
                            icon: "mic") {
                    Toggle("", isOn: $audioRec).labelsHidden().toggleStyle(.switch)
                }
                if audioRec {
                    SettingsDivider()
                    SettingsRow("Your name",
                                description: "Used so the assistant knows when you're the speaker.",
                                icon: "person.text.rectangle") {
                        TextField("e.g. Louis", text: $userName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1))
                            )
                            .frame(width: 180)
                    }
                }
            }

            if audioRec {
                SettingsCard(title: "Microphones") {
                    SettingsRow("Auto-select audio devices",
                                description: "Records all default devices. Turn off to exclude Bluetooth headphones or pick specific devices below.",
                                icon: "speaker.wave.3") {
                        Toggle("", isOn: $autoSelectAudio).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Microphones",
                                description: "Devices to capture from. Used when auto-select is off.",
                                icon: "mic.fill") { EmptyView() }
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
                    SettingsRow("CoreAudio system audio capture",
                                description: "Lower-overhead path. Requires macOS 14+.",
                                icon: "rectangle.connected.to.line.below") {
                        Toggle("", isOn: $coreAudio).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsCard(
                    title: "Transcription",
                    footnote: engine == AudioEngine.deepgram.rawValue
                        ? "Deepgram sends audio to the cloud. Audio leaves this Mac."
                        : (engine == AudioEngine.whisper.rawValue
                            ? "Whisper runs entirely on-device. Audio stays on this Mac."
                            : "Pick an engine to enable speech-to-text.")
                ) {
                    SettingsRow("Transcription engine", icon: "waveform.path") {
                        Picker("", selection: $engine) {
                            ForEach(AudioEngine.allCases) { e in Text(e.label).tag(e.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 200)
                    }
                    if engine == AudioEngine.deepgram.rawValue {
                        SettingsDivider()
                        SettingsRow("Deepgram API key",
                                    description: "Required for cloud transcription.",
                                    icon: "key") {
                            SecureField("paste key…", text: $deepgramKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1))
                                )
                                .frame(width: 220)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Languages",
                                description: "Models to load for transcription.",
                                icon: "character.bubble") { EmptyView() }
                    VStack { TagListEditor(tags: $languages, placeholder: "e.g. en, zh, ja") }
                        .padding(.horizontal, 48).padding(.bottom, 12)
                        .onChange(of: languages) {
                            StringArrayStorage(key: SettingsKeys.audioLanguages).set(languages)
                        }
                    if engine != AudioEngine.disabled.rawValue {
                        SettingsDivider()
                        SettingsRow("Filter music",
                                    description: "Detect and skip music-dominant audio (Spotify, YouTube, etc.) so transcription doesn't get poisoned by lyrics.",
                                    icon: "music.note.list") {
                            Toggle("", isOn: $filterMusic).labelsHidden().toggleStyle(.switch)
                        }
                        SettingsDivider()
                        SettingsRow("Batch transcription",
                                    description: "Process audio chunks together for higher throughput. Slight latency cost.",
                                    icon: "tray.full") {
                            Toggle("", isOn: $batchTranscription).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                SettingsCard(
                    title: "Custom vocabulary",
                    footnote: "Boost recognition of names, jargon, and brand terms."
                ) {
                    VStack(alignment: .leading) {
                        TagListEditor(tags: $vocabulary, placeholder: "term · optional replacement")
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .onChange(of: vocabulary) {
                        StringArrayStorage(key: SettingsKeys.customVocabulary).set(vocabulary)
                    }
                }

                SettingsCard(title: "Speakers (Voice ID)") {
                    SettingsRow("Enable speaker identification",
                                description: "Detect and cluster distinct voices.",
                                icon: "person.wave.2") {
                        Toggle("", isOn: $speakerId).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: - Screen

    private var screenSection: some View {
        Group {
            SettingsCard(title: "Screen recording") {
                SettingsRow("Screen recording",
                            description: "Capture periodic snapshots of your screen.",
                            icon: "display") {
                    Toggle("", isOn: $screenRec).labelsHidden().toggleStyle(.switch)
                }
                if screenRec {
                    SettingsDivider()
                    SettingsRow("Recording quality",
                                description: "Higher quality means larger snapshots.",
                                icon: "rectangle.stack") {
                        Picker("", selection: $quality) {
                            ForEach(RecordingQuality.allCases) { q in Text(q.label).tag(q.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 110)
                    }
                    SettingsDivider()
                    SettingsRow("Output video format", icon: "rectangle.compress.vertical") {
                        Picker("", selection: $format) {
                            ForEach(VideoFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 110)
                    }
                    SettingsDivider()
                    SettingsRow("Video FPS",
                                description: "Frames per second to capture into the video chunks.",
                                icon: "speedometer") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { Double(fps) },
                                set: { fps = Int($0) }
                            ), in: 1...30, step: 1).frame(width: 140)
                            Text("\(fps) fps")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Frame interval",
                                description: "Milliseconds between standalone snapshots.",
                                icon: "timer") {
                        HStack(spacing: 4) {
                            TextField("", value: $frameIntervalMs, formatter: NumberFormatter())
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1))
                                )
                                .frame(width: 70)
                            Text("ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    SettingsDivider()
                    SettingsRow("OCR engine",
                                description: "Convert captured frames into searchable text.",
                                icon: "doc.text.viewfinder") {
                        Picker("", selection: $ocrEngine) {
                            ForEach(OCREngine.allCases) { o in Text(o.label).tag(o.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 160)
                    }
                }
            }
        }
    }

    // MARK: - System

    private var systemSection: some View {
        SettingsCard(title: "System") {
            SettingsRow("Chinese mirror",
                        description: "Use a CN-region mirror for model downloads.",
                        icon: "globe.asia.australia") {
                Toggle("", isOn: $chineseMirror).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Power mode row (one per mode)

private struct PowerModeRow: View {
    let mode: PowerMode
    let isActive: Bool
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Color.purple.opacity(0.45), Color.blue.opacity(0.30)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.white.opacity(0.06)))
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? .white.opacity(0.95) : .white.opacity(0.75))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.purple.opacity(0.90))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                Color.white.opacity(isActive ? 0.04 : (hover ? 0.03 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
