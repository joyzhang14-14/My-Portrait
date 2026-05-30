import SwiftUI

/// Audio Recording 设置子分区：麦克风 + 转录 + 说话人。
struct AudioCaptureSettingsView: View {
    @State private var config = ConfigStore.shared

    private var audioRec: Bool { config.current.capture.audio.enabled }
    private var engine: String { config.current.capture.audio.engine }

    /// 转录语言选项(code → 英文名)。给 Language 下拉用 —— 用户从列表选不手输。
    /// **按 engine 绑定**:不同转录引擎支持的语言不同;新增引擎在
    /// languageOptions(for:) 加一支即可。选中的 code 存进 capture.audio.languages。
    private struct TranscriptionLanguage: Identifiable, Hashable { let code, name: String; var id: String { code } }

    /// 当前引擎对应的语言选项。新增转录模型时在这里加 case。
    private static func languageOptions(for engine: String) -> [TranscriptionLanguage] {
        switch engine {
        case AudioEngine.deepgram.rawValue: return deepgramLanguages
        default:                            return whisperLanguages   // whisper / custom 默认用 Whisper 集
        }
    }

    /// Whisper(on-device)支持的语言。
    private static let whisperLanguages: [TranscriptionLanguage] = [
        ("af","Afrikaans"),("sq","Albanian"),("am","Amharic"),("ar","Arabic"),("hy","Armenian"),
        ("as","Assamese"),("az","Azerbaijani"),("ba","Bashkir"),("eu","Basque"),("be","Belarusian"),
        ("bn","Bengali"),("bs","Bosnian"),("br","Breton"),("bg","Bulgarian"),("my","Burmese"),
        ("ca","Catalan"),("zh","Chinese"),("hr","Croatian"),("cs","Czech"),("da","Danish"),
        ("nl","Dutch"),("en","English"),("et","Estonian"),("fo","Faroese"),("fi","Finnish"),
        ("fr","French"),("gl","Galician"),("ka","Georgian"),("de","German"),("el","Greek"),
        ("gu","Gujarati"),("ht","Haitian Creole"),("ha","Hausa"),("haw","Hawaiian"),("he","Hebrew"),
        ("hi","Hindi"),("hu","Hungarian"),("is","Icelandic"),("id","Indonesian"),("it","Italian"),
        ("ja","Japanese"),("jw","Javanese"),("kn","Kannada"),("kk","Kazakh"),("km","Khmer"),
        ("ko","Korean"),("lo","Lao"),("la","Latin"),("lv","Latvian"),("ln","Lingala"),
        ("lt","Lithuanian"),("lb","Luxembourgish"),("mk","Macedonian"),("mg","Malagasy"),("ms","Malay"),
        ("ml","Malayalam"),("mt","Maltese"),("mi","Maori"),("mr","Marathi"),("mn","Mongolian"),
        ("ne","Nepali"),("no","Norwegian"),("nn","Nynorsk"),("oc","Occitan"),("ps","Pashto"),
        ("fa","Persian"),("pl","Polish"),("pt","Portuguese"),("pa","Punjabi"),("ro","Romanian"),
        ("ru","Russian"),("sa","Sanskrit"),("sr","Serbian"),("sn","Shona"),("sd","Sindhi"),
        ("si","Sinhala"),("sk","Slovak"),("sl","Slovenian"),("so","Somali"),("es","Spanish"),
        ("su","Sundanese"),("sw","Swahili"),("sv","Swedish"),("tl","Tagalog"),("tg","Tajik"),
        ("ta","Tamil"),("tt","Tatar"),("te","Telugu"),("th","Thai"),("bo","Tibetan"),
        ("tr","Turkish"),("tk","Turkmen"),("uk","Ukrainian"),("ur","Urdu"),("uz","Uzbek"),
        ("vi","Vietnamese"),("cy","Welsh"),("yi","Yiddish"),("yo","Yoruba"),
    ].map { TranscriptionLanguage(code: $0.0, name: $0.1) }

    /// Deepgram(cloud)支持的语言(常用子集,按需补)。
    private static let deepgramLanguages: [TranscriptionLanguage] = [
        ("en","English"),("zh","Chinese"),("es","Spanish"),("fr","French"),("de","German"),
        ("hi","Hindi"),("ja","Japanese"),("ko","Korean"),("pt","Portuguese"),("ru","Russian"),
        ("it","Italian"),("nl","Dutch"),("tr","Turkish"),("pl","Polish"),("sv","Swedish"),
        ("da","Danish"),("no","Norwegian"),("fi","Finnish"),("id","Indonesian"),("uk","Ukrainian"),
        ("vi","Vietnamese"),("th","Thai"),("cs","Czech"),("el","Greek"),("hu","Hungarian"),
        ("ro","Romanian"),("ms","Malay"),("ta","Tamil"),("bg","Bulgarian"),("ca","Catalan"),
    ].map { TranscriptionLanguage(code: $0.0, name: $0.1) }

    var body: some View {
        SettingsPage("Audio Capture", subtitle: "Microphone + transcription",
                     onResetCurrentPage: { config.mutate { $0.capture.audio = .init() } }) {
            audioSection
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Group {
            SettingsCard(title: "Audio Capture") {
                SettingsRow("Audio Capture",
                            description: "Capture from your microphone(s).",
                            icon: "mic") {
                    Toggle("", isOn: config.binding(\.capture.audio.enabled)).labelsHidden().toggleStyle(.switch)
                }
                if audioRec {
                    SettingsDivider()
                    SettingsRow("Your name",
                                description: "Used so the assistant knows when you're the speaker.",
                                icon: "person.text.rectangle") {
                        TextField("e.g. Louis", text: config.binding(\.capture.audio.userName))
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
                        Toggle("", isOn: config.binding(\.capture.audio.autoSelectAudioDevices)).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Microphones",
                                description: "Devices to capture from. Used when auto-select is off.",
                                icon: "mic.fill") { EmptyView() }
                    VStack { TagListEditor(tags: config.binding(\.capture.audio.microphonesSelected), placeholder: "device name…") }
                        .padding(.horizontal, 48).padding(.bottom, 12)
                                        }

                SettingsCard(title: "System audio") {
                    SettingsRow("Capture system audio",
                                description: "What you hear (loopback).",
                                icon: "speaker.wave.2") {
                        Toggle("", isOn: config.binding(\.capture.audio.captureSystemAudio)).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("CoreAudio system audio capture",
                                description: "Lower-overhead path. Requires macOS 14+.",
                                icon: "rectangle.connected.to.line.below") {
                        Toggle("", isOn: config.binding(\.capture.audio.useCoreAudioCapture)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }   // 关闭 if audioRec —— Mic / System audio 仅采集开启时显示

            // 转译配置常驻显示 —— 关着采集也能预先配好引擎/模型/语言/批量。
                SettingsCard(
                    title: "Transcription",
                    footnote: engine == AudioEngine.deepgram.rawValue
                        ? "Deepgram sends audio to the cloud. Audio leaves this Mac."
                        : (engine == AudioEngine.whisper.rawValue
                            ? "Whisper runs entirely on-device. Audio stays on this Mac."
                            : "Pick an engine to enable speech-to-text.")
                ) {
                    // 转译总开关 —— 关掉就把 engine 设成 disabled,下面引擎/模型/语言全隐藏。
                    SettingsRow("Transcription",
                                description: "Turn speech-to-text on or off.",
                                icon: "waveform") {
                        Toggle("", isOn: Binding(
                            get: { engine != AudioEngine.disabled.rawValue },
                            set: { on in config.mutate {
                                $0.capture.audio.engine = on ? AudioEngine.whisper.rawValue : AudioEngine.disabled.rawValue
                            } }
                        )).labelsHidden().toggleStyle(.switch)
                    }
                    if engine != AudioEngine.disabled.rawValue {
                        SettingsDivider()
                        SettingsRow("Transcription engine", icon: "waveform.path") {
                            Picker("", selection: config.binding(\.capture.audio.engine)) {
                                ForEach(AudioEngine.allCases.filter { $0 != .disabled }) { e in Text(e.label).tag(e.rawValue) }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 200)
                        }
                    if engine == AudioEngine.whisper.rawValue {
                        SettingsDivider()
                        SettingsRow("Whisper model",
                                    description: "Larger models are more accurate but slower and bigger to download.",
                                    icon: "cpu") {
                            Picker("", selection: config.binding(\.capture.audio.whisperModel)) {
                                Text("Small (~500 MB)").tag("openai_whisper-small")
                                Text("Large v3 Turbo (~1.5 GB)").tag("openai_whisper-large-v3-v20240930")
                                Text("Large v3 (~3 GB, downloads on first use)").tag("openai_whisper-large-v3")
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 200)
                        }
                    }
                    if engine == AudioEngine.deepgram.rawValue {
                        SettingsDivider()
                        SettingsRow("Deepgram API key",
                                    description: "Required for cloud transcription.",
                                    icon: "key") {
                            SecureField("paste key…", text: config.secretBinding(refKeyPath: \.capture.audio.deepgramApiKeyRef, defaultRef: "deepgram_key"))
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
                    if engine == AudioEngine.custom.rawValue {
                        SettingsDivider()
                        SettingsRow("Endpoint",
                                    description: "OpenAI-compatible transcription server (mlx-audio, llama.cpp, vLLM…). Audio leaves this Mac.",
                                    icon: "network") {
                            TextField("http://127.0.0.1:8080", text: config.binding(\.capture.audio.customEndpoint))
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
                        SettingsDivider()
                        SettingsRow("Model", description: "Model ID sent to the endpoint.", icon: "cpu") {
                            TextField("whisper-1", text: config.binding(\.capture.audio.customModel))
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
                        SettingsDivider()
                        SettingsRow("API key", description: "Optional — leave blank for local servers.", icon: "key") {
                            SecureField("paste key…", text: config.secretBinding(refKeyPath: \.capture.audio.customApiKeyRef, defaultRef: "custom_transcribe_key"))
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
                    SettingsRow("Language",
                                description: "Whisper language hint. Auto-detect handles multilingual / mixed speech.",
                                icon: "character.bubble") {
                        Picker("", selection: Binding(
                            get: { config.current.capture.audio.languages.first ?? "" },
                            set: { code in config.mutate {
                                $0.capture.audio.languages = code.isEmpty ? [] : [code]
                            } }
                        )) {
                            Text("Auto-detect").tag("")
                            ForEach(Self.languageOptions(for: engine)) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 200)
                    }
                        SettingsDivider()
                        SettingsRow("Batch transcription",
                                    description: "Process audio chunks together for higher throughput. Slight latency cost.",
                                    icon: "tray.full") {
                            Toggle("", isOn: config.binding(\.capture.audio.batchTranscription)).labelsHidden().toggleStyle(.switch)
                        }
                        SettingsDivider()
                        SettingsRow("Only transcribe while plugged in",
                                    description: "Saves battery — audio still records on battery and transcribes once you're back on AC power. Off = transcribe regardless of power.",
                                    icon: "powerplug") {
                            Toggle("", isOn: config.binding(\.capture.audio.transcribeOnACOnly)).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

            if audioRec {
                // 录音行为相关 —— 只在采集开启时显示。
                SettingsCard(title: "Music handling") {
                    SettingsRow("Filter music",
                                description: "Detect and skip music-dominant audio (Spotify, YouTube, etc.) so transcription doesn't get poisoned by lyrics.",
                                icon: "music.note.list") {
                        Toggle("", isOn: config.binding(\.capture.audio.filterMusic)).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Pause when a music app is playing",
                                description: "Stop recording entirely while a music app is playing audio — solves it at the source. Detected via the app's category; call apps (Zoom, etc.) aren't affected. Takes priority over Filter music.",
                                icon: "pause.circle") {
                        Toggle("", isOn: config.binding(\.capture.audio.pauseOnMusicApp)).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsCard(
                    title: "Custom vocabulary",
                    footnote: "Boost recognition of names, jargon, and brand terms."
                ) {
                    VStack(alignment: .leading) {
                        TagListEditor(tags: config.binding(\.capture.audio.customVocabulary), placeholder: "term · optional replacement")
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                                    }

            }

            // Speakers 部分(toggle + 训练 + 簇管理)。**故意放在 audioRec
            // 判断外面 —— audio capture 关着也能看到、能开始训练。**
            // VoiceTrainingCard.startTraining 自己会临时强开
            // audio.enabled + speakerIdEnabled,训练完(success/failure/
            // cancel)还原回原值,跟之前的设计一致。
            SettingsCard(title: "Speakers (Voice ID)") {
                SettingsRow("Enable speaker identification",
                            description: "Detect and cluster distinct voices.",
                            icon: "person.wave.2") {
                    Toggle("", isOn: config.binding(\.capture.audio.speakerIdEnabled)).labelsHidden().toggleStyle(.switch)
                }
            }

            // 原来独立的 Speakers 分页(训练 + 簇管理 + Organize w/ AI)。
            // **不再 gate** —— 训练入口要随时可达;speakerId 关 / DB 空
            // 时下面列表自然就是 "0 of 0 identified",VoiceTrainingCard
            // 仍可点。SpeakersSettingsView 自带懒加载 + task 触发。
            SpeakersSettingsView()
        }
    }

}

// MARK: - Screen Recording

/// Screen Recording 设置子分区:Power mode + 屏幕采集(截图 + OCR)+
/// privacy 子项(原 Privacy 子分区,合并到这里页面尾部 —— 跟 capture 配置
/// 是同一条思路,放一起省一次跳转)。
struct ScreenCaptureSettingsView: View {
    @State private var config = ConfigStore.shared
    /// 用 frames.app_name 装填 ignored apps 下拉,page task 触发加载。
    @State private var discoveredApps: [String] = []

    private var screenRec: Bool { config.current.capture.screen.enabled }

    var body: some View {
        SettingsPage("Screen Capture", subtitle: "Screenshots + OCR + Privacy",
                     onResetCurrentPage: {
                         config.mutate {
                             $0.capture.screen = .init()
                             $0.capture.system = .init()
                         }
                     }) {
            powerModeCard
            screenSection
            privacySection
        }
        .task {
            discoveredApps = await Self.loadDiscoveredApps()
        }
    }

    /// 原 PrivacyView 整组 cards 搬来。Screen Capture 同一物理通道,
    /// 用户体感"屏幕能看到的内容怎么过滤"也属于 capture 配置范畴。
    @ViewBuilder private var privacySection: some View {
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
                Text("Pick from captured apps or the system / privacy list…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                TagListEditor(tags: config.binding(\.privacy.ignoredWindowTitles), placeholder: "e.g. Incognito, Private")
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    /// Off-main scan of `frames.app_name` for the ignored-apps dropdown.
    private static func loadDiscoveredApps() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            TimelineDB().distinctAppNames()
        }.value
    }

    private var powerModeCard: some View {
        SettingsCard(
            title: "Power mode",
            footnote: "Switches capture FPS, transcription cadence, and OCR aggressiveness based on the profile you pick."
        ) {
            ForEach(PowerMode.allCases) { mode in
                PowerModeRow(mode: mode,
                             isActive: config.current.capture.system.powerMode == mode.rawValue) {
                    config.mutate { $0.capture.system.powerMode = mode.rawValue }
                }
                if mode != PowerMode.allCases.last { SettingsDivider() }
            }
        }
    }

    private var screenSection: some View {
        Group {
            SettingsCard(title: "Screen Capture") {
                SettingsRow("Screen Capture",
                            description: "Capture periodic snapshots of your screen.",
                            icon: "display") {
                    Toggle("", isOn: config.binding(\.capture.screen.enabled)).labelsHidden().toggleStyle(.switch)
                }
                if screenRec {
                    SettingsDivider()
                    SettingsRow("Recording quality",
                                description: "Higher quality means larger snapshots.",
                                icon: "rectangle.stack") {
                        Picker("", selection: config.binding(\.capture.screen.quality)) {
                            ForEach(RecordingQuality.allCases) { q in Text(q.label).tag(q.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 110)
                    }
                    SettingsDivider()
                    SettingsRow("Output video format", icon: "rectangle.compress.vertical") {
                        Picker("", selection: config.binding(\.capture.screen.videoFormat)) {
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
                                get: { Double(config.current.capture.screen.videoFps) },
                                set: { v in config.mutate { $0.capture.screen.videoFps = Int(v) } }
                            ), in: 1...30, step: 1).frame(width: 140)
                            Text("\(config.current.capture.screen.videoFps) fps")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary.opacity(0.55))
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Frame interval",
                                description: "Milliseconds between standalone snapshots.",
                                icon: "timer") {
                        HStack(spacing: 4) {
                            TextField("", value: config.binding(\.capture.screen.frameIntervalMs), formatter: NumberFormatter())
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
                                .foregroundStyle(Theme.textPrimary.opacity(0.55))
                        }
                    }
                    SettingsDivider()
                    SettingsRow("OCR engine",
                                description: "Convert captured frames into searchable text.",
                                icon: "doc.text.viewfinder") {
                        Picker("", selection: config.binding(\.capture.screen.ocrEngine)) {
                            ForEach(OCREngine.allCases) { o in Text(o.label).tag(o.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 160)
                    }
                }
            }
        }
    }

}

// MARK: - Typing Capture

/// Typing Capture 设置子分区。
struct TypingCaptureSettingsView: View {
    @State private var config = ConfigStore.shared
    @Environment(\.services) private var services
    /// 用户打过字的 app（bundle id）—— 给两个 app 选择器的下拉用。
    @State private var discovered: [String] = []
    /// 发现到的 (bundle_id, url) 对子,给 URL-prefix picker 列候选用。
    @State private var discoveredSummaries: [(bundleId: String, url: String)] = []

    var body: some View {
        SettingsPage("Typing Capture", subtitle: "Learn your writing style",
                     onResetCurrentPage: {
                         config.mutate {
                             let def = RecordingConfig()
                             $0.capture.typingKeyCorrelationWindowMs = def.typingKeyCorrelationWindowMs
                             $0.capture.typingCaptureEnabled         = def.typingCaptureEnabled
                             $0.capture.typingDebounceMs             = def.typingDebounceMs
                             $0.capture.typingFlushIdleSec           = def.typingFlushIdleSec
                             $0.capture.typingSubmitWindowMs         = def.typingSubmitWindowMs
                             $0.capture.typingPasteMinChars          = def.typingPasteMinChars
                             $0.capture.typingRecordPasteEvents      = def.typingRecordPasteEvents
                         }
                     }) {
            typingSection
            blacklistSection
        }
        .task {
            discovered = await Self.loadDiscovered(services?.typingStore)
            discoveredSummaries = await Self.loadDiscoveredSummaries(services?.typingStore)
        }
    }

    /// 后台扫 typing_events 的 (bundle_id, url) 对子。
    private static func loadDiscoveredSummaries(_ store: TypingEventStore?)
        async -> [(bundleId: String, url: String)]
    {
        guard let store else { return [] }
        return await Task.detached {
            (try? store.appSummaries())?.map { (bundleId: $0.bundleId, url: $0.url) } ?? []
        }.value
    }

    /// 黑名单 entries —— 整 app 或 (app, urlPrefix) 屏蔽打字。
    private var blacklistSection: some View {
        SettingsCard(
            title: "Typing blacklist",
            footnote: "Password managers and terminals are always excluded. Pick an app to block the whole app, or pick a specific URL inside a browser to block only pages with that URL prefix."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pick an app (and optionally a URL prefix)…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                TypingBlacklistEntryPicker(
                    entries: config.binding(\.privacy.typingBlacklistEntries),
                    summaries: discoveredSummaries,
                    locked: TypingPrivacyFilter.defaultBlacklist
                )
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

/// 后台扫 typing_events 的 distinct bundle id(去重 —— appSummaries 按
    /// (bundle_id, url) 分组,每个浏览器 URL 一行,bundle_id 会重复)。
    private static func loadDiscovered(_ store: TypingEventStore?) async -> [String] {
        guard let store else { return [] }
        return await Task.detached {
            var seen = Set<String>()
            return (try? store.appSummaries())?
                .map(\.bundleId)
                .filter { seen.insert($0).inserted } ?? []
        }.value
    }

    private var typingSection: some View {
        SettingsCard(title: "Typing Capture") {
            SettingsRow("Typing Capture",
                        description: "Reads the text you finish typing into input fields, used to learn your writing style. All data stays on this Mac and is never uploaded. Password fields and secure inputs are never read.",
                        icon: "keyboard") {
                Toggle("", isOn: config.binding(\.capture.typingCaptureEnabled)).labelsHidden().toggleStyle(.switch)
            }
            if config.current.capture.typingCaptureEnabled {
                SettingsDivider()
                SettingsRow("Keyboard correlation window",
                            description: "Only text changes that happen within this long after a keystroke count as your typing (filters out terminal output, incoming messages, etc.).",
                            icon: "timer") {
                    Stepper(value: config.binding(\.capture.typingKeyCorrelationWindowMs),
                            in: 50...500, step: 50) {
                        Text("\(config.current.capture.typingKeyCorrelationWindowMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Edit-log debounce",
                            description: "Edits that settle within this long collapse into one edit-log step. Higher = coarser log; also collapses IME (pinyin) intermediate states.",
                            icon: "hourglass") {
                    Stepper(value: config.binding(\.capture.typingDebounceMs),
                            in: 100...1000, step: 50) {
                        Text("\(config.current.capture.typingDebounceMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Session flush idle",
                            description: "After this long without typing, the current input is saved as a record. Continuous edits keep merging into the same record.",
                            icon: "tray.and.arrow.down") {
                    Stepper(value: config.binding(\.capture.typingFlushIdleSec),
                            in: 2...30, step: 1) {
                        Text("\(config.current.capture.typingFlushIdleSec) s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Enter-to-send window",
                            description: "After pressing Return, the input box must clear within this long to count as a sent message rather than a deletion.",
                            icon: "paperplane") {
                    Stepper(value: config.binding(\.capture.typingSubmitWindowMs),
                            in: 200...3000, step: 100) {
                        Text("\(config.current.capture.typingSubmitWindowMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Paste match minimum",
                            description: "Clipboard content shorter than this isn't used to detect pastes — avoids flagging short typed text that happens to equal the clipboard.",
                            icon: "doc.on.clipboard") {
                    Stepper(value: config.binding(\.capture.typingPasteMinChars),
                            in: 2...50, step: 1) {
                        Text("\(config.current.capture.typingPasteMinChars) chars")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Record paste events",
                            description: "On: pastes (⌘V / clipboard match / burst) are recorded as 'paste' entries in edit log — LLM decides what counts as user input. Off: pastes are stripped from the record.",
                            icon: "doc.on.doc") {
                    Toggle("", isOn: config.binding(\.capture.typingRecordPasteEvents))
                        .labelsHidden().toggleStyle(.switch)
                }
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
                              : AnyShapeStyle(Color.primary.opacity(0.06)))
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .medium))
                        // active 时背景是彩色 gradient,白色图标在 light/dark 都看得清;
                        // 非 active 时背景透明,用 textPrimary 跟 colorScheme 切。
                        .foregroundStyle(isActive ? Color.white.opacity(0.95) : Theme.textPrimary.opacity(0.75))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
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
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}
