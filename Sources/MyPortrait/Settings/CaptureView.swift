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
        case AudioEngine.qwen.rawValue:     return qwenLanguages
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

    /// Qwen3-ASR(on-device)支持的语言(常用子集；用 ISO 码，同 Whisper 格式）。
    /// 跟 whisper 分开维护 —— 选中的存进 `qwenLanguages`，不混 `languages`。
    private static let qwenLanguages: [TranscriptionLanguage] = [
        ("zh","Chinese"),("en","English"),("ja","Japanese"),("ko","Korean"),("es","Spanish"),
        ("fr","French"),("de","German"),("ru","Russian"),("pt","Portuguese"),("it","Italian"),
        ("ar","Arabic"),("hi","Hindi"),("nl","Dutch"),("tr","Turkish"),("pl","Polish"),
        ("vi","Vietnamese"),("th","Thai"),("id","Indonesian"),("uk","Ukrainian"),("cs","Czech"),
        ("sv","Swedish"),("da","Danish"),("fi","Finnish"),("no","Norwegian"),("el","Greek"),
        ("he","Hebrew"),("ro","Romanian"),("hu","Hungarian"),("ms","Malay"),("ca","Catalan"),
    ].map { TranscriptionLanguage(code: $0.0, name: $0.1) }

    /// 当前 whisperModel code → 显示标签(Menu 闭合态用)。找不到回退 code 本身。
    private static func whisperModelLabel(_ code: String) -> String {
        WhisperKitWrapper.allTranscriptionModels.first { $0.name == code }?.label ?? code
    }

    /// 当前 qwenModel code → 显示标签。找不到回退 code 本身。
    private static func qwenModelLabel(_ code: String) -> String {
        Qwen3ASRWrapper.allQwenModels.first { $0.name == code }?.label ?? code
    }

    /// code → 显示名(在 whisper/deepgram/qwen 表里找,找不到回退大写 code)。
    private static func displayName(for code: String) -> String {
        whisperLanguages.first { $0.code == code }?.name
            ?? deepgramLanguages.first { $0.code == code }?.name
            ?? qwenLanguages.first { $0.code == code }?.name
            ?? code.uppercased()
    }

    /// 当前引擎选中的语言列表。**每个 engine 独立存** —— 切 engine 不会
    /// 把别的引擎的选择带过来。whisper 沿用历史字段名 `languages`。
    private var selectedLangs: [String] {
        let a = config.current.capture.audio
        switch a.engine {
        case AudioEngine.qwen.rawValue:     return a.qwenLanguages
        case AudioEngine.deepgram.rawValue: return a.deepgramLanguages
        case AudioEngine.custom.rawValue:   return a.customLanguages
        default:                            return a.languages
        }
    }

    /// 勾选/取消某语言。按当前引擎写进对应字段。
    private func toggleLanguage(_ code: String, _ on: Bool) {
        config.mutate {
            switch $0.capture.audio.engine {
            case AudioEngine.qwen.rawValue:
                var ls = $0.capture.audio.qwenLanguages
                if on { if !ls.contains(code) { ls.append(code) } } else { ls.removeAll { $0 == code } }
                $0.capture.audio.qwenLanguages = ls
            case AudioEngine.deepgram.rawValue:
                var ls = $0.capture.audio.deepgramLanguages
                if on { if !ls.contains(code) { ls.append(code) } } else { ls.removeAll { $0 == code } }
                $0.capture.audio.deepgramLanguages = ls
            case AudioEngine.custom.rawValue:
                var ls = $0.capture.audio.customLanguages
                if on { if !ls.contains(code) { ls.append(code) } } else { ls.removeAll { $0 == code } }
                $0.capture.audio.customLanguages = ls
            default:
                var ls = $0.capture.audio.languages
                if on { if !ls.contains(code) { ls.append(code) } } else { ls.removeAll { $0 == code } }
                $0.capture.audio.languages = ls
            }
        }
    }

    /// 选中语言的 chips(下方显示,点 × 移除)。
    private var selectedLanguageChips: some View {
        HStack(spacing: 6) {
            ForEach(selectedLangs, id: \.self) { code in
                HStack(spacing: 4) {
                    Text(Self.displayName(for: code)).font(.system(size: 11))
                    Button { toggleLanguage(code, false) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textPrimary.opacity(0.5))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48).padding(.bottom, 12)
    }

    // MARK: - 转录实时状态(队列 + 内存)

    /// 待转录队列长度(audio_chunks 里 status 非 done/failed)。~1Hz 刷。
    @State private var statusPending = 0
    /// app 当前 resident memory（GB）。转录(尤其 Qwen/MLX)时会明显抬高。
    @State private var statusMemGB = 0.0
    /// 后台刷新循环句柄,行可见时跑、消失时取消。
    @State private var statusRefresh: Task<Void, Never>?

    /// 当前进程的 physical footprint（GB）—— 跟 Activity Monitor 的 Memory 列一致。
    /// 用 phys_footprint 而非 resident_size:后者会漏报 mmap 进来的模型权重(Qwen
    /// /MLX 的 ~2GB 大头),导致显示远低于实际。nonisolated,给后台刷新循环直接调。
    private nonisolated static func appMemoryGB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024 / 1024
    }

    /// 转录实时状态行。暂停态直接读 @Observable 单例(自动响应);
    /// 队列长度 + 内存走 ~1Hz 后台轮询。
    private var transcriptionStatusRow: some View {
        let paused = IntentionalPauseState.shared.audioTranscriptionPaused
        let active = !paused && statusPending > 0
        let stateText = paused ? "Paused on battery"
                      : active ? "Transcribing…"
                      :          "Up to date"
        let stateColor: Color = paused ? .orange : active ? .green : Theme.textPrimary.opacity(0.5)
        let detail = (statusPending > 0
                        ? "\(statusPending) clip\(statusPending == 1 ? "" : "s") in queue"
                        : "Queue empty")
                   + String(format: " · %.1f GB memory", statusMemGB)
        return SettingsRow("Status", description: detail, icon: "waveform.badge.magnifyingglass") {
            HStack(spacing: 6) {
                if active {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                } else {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                }
                Text(stateText).font(.system(size: 12)).foregroundStyle(stateColor)
            }
        }
        .onAppear { startStatusRefresh() }
        .onDisappear { statusRefresh?.cancel(); statusRefresh = nil }
    }

    /// 队列长度 + 内存的 ~1Hz 刷新循环。DB 读走 detached(避免占主线程),
    /// 回主线程写 @State。
    private func startStatusRefresh() {
        statusRefresh?.cancel()
        statusRefresh = Task.detached {
            while !Task.isCancelled {
                let pending = TimelineDB().pendingAudioCount()
                let mem = Self.appMemoryGB()
                await MainActor.run { statusPending = pending; statusMemGB = mem }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

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
                SettingsDivider()
                // 锁屏录音是采集行为(决定要不要继续抓音频),不是转译选项。
                SettingsRow("Record audio while screen is locked",
                            description: "Keep listening even when your Mac is locked.",
                            icon: "lock.shield") {
                    Toggle("", isOn: config.binding(\.privacy.recordAudioWhileLocked)).labelsHidden().toggleStyle(.switch)
                }
            }

            if audioRec {
                inputDeviceCard
            }   // 关闭 if audioRec —— Mic / System audio 仅采集开启时显示

            // 转译配置常驻显示 —— 关着采集也能预先配好引擎/模型/语言/批量。
                SettingsCard(title: "Transcription") {
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
                        transcriptionStatusRow
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
                                    description: "Download models in AI models. Uninstalled models can't be selected here.",
                                    icon: "cpu") {
                            Menu {
                                ForEach(WhisperKitWrapper.allTranscriptionModels, id: \.name) { m in
                                    let installed = WhisperKitWrapper.isOnDisk(modelName: m.name)
                                    Button {
                                        config.mutate { $0.capture.audio.whisperModel = m.name }
                                    } label: {
                                        Text(installed ? "\(m.label) (\(m.size))"
                                                       : "\(m.label) — uninstalled")
                                    }
                                    .disabled(!installed)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(Self.whisperModelLabel(config.current.capture.audio.whisperModel))
                                        .font(.system(size: 12))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                                }
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    if engine == AudioEngine.qwen.rawValue {
                        SettingsDivider()
                        SettingsRow("Qwen model",
                                    description: "Download models in AI models. Uninstalled models can't be selected here.",
                                    icon: "cpu") {
                            Menu {
                                ForEach(Qwen3ASRWrapper.allQwenModels, id: \.name) { m in
                                    let installed = Qwen3ASRWrapper.isOnDisk(modelId: m.name)
                                    Button {
                                        config.mutate { $0.capture.audio.qwenModel = m.name }
                                    } label: {
                                        Text(installed ? "\(m.label) (\(m.size))"
                                                       : "\(m.label) — uninstalled")
                                    }
                                    .disabled(!installed)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(Self.qwenModelLabel(config.current.capture.audio.qwenModel))
                                        .font(.system(size: 12))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                                }
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
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
                    SettingsRow("Languages",
                                description: "Pick the languages you speak. One is used as a hint; pick several or none to auto-detect.",
                                icon: "character.bubble") {
                        Menu {
                            ForEach(Self.languageOptions(for: engine)) { lang in
                                Toggle(lang.name, isOn: Binding(
                                    get: { selectedLangs.contains(lang.code) },
                                    set: { on in toggleLanguage(lang.code, on) }
                                ))
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedLangs.isEmpty
                                     ? "Auto-detect"
                                     : "\(selectedLangs.count) selected")
                                    .font(.system(size: 12))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                            }
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    // 选中的语言 chips 显示在下方,点 × 移除。
                    if !selectedLangs.isEmpty {
                        selectedLanguageChips
                    }
                        SettingsDivider()
                        SettingsRow("Only transcribe while plugged in",
                                    description: "Audio still records on battery, but transcribing waits until you're plugged in.",
                                    icon: "powerplug") {
                            Toggle("", isOn: config.binding(\.capture.audio.transcribeOnACOnly)).labelsHidden().toggleStyle(.switch)
                        }
                        SettingsDivider()
                        SettingsRow("Keep Mac awake while transcribing",
                                    description: "While plugged in, it keeps the Mac awake until the transcription backlog finishes instead of letting it sleep. Closing the lid still puts it to sleep.",
                                    icon: "zzz") {
                            Toggle("", isOn: config.binding(\.capture.audio.keepAwakeWhileTranscribing)).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

            // 「Filtering & pausing」常显示 —— 不 gate audioRec(跟 Speakers 一样,
            // 采集关着也能先配好过滤 / 暂停规则,等开采集即生效)。
            SettingsCard(title: "Filtering & pausing") {
                SettingsRow("Filter music",
                            description: "Skips audio that's mostly music, so song lyrics don't end up in your transcripts.",
                            icon: "music.note.list") {
                    Toggle("", isOn: config.binding(\.capture.audio.filterMusic)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Pause capture for these apps / categories",
                            description: "Stops recording whenever an app on this list is playing audio. It's more thorough than filtering music and takes priority. Pick specific apps or categories, or leave it empty to never pause.",
                            icon: "pause.circle") { EmptyView() }
                VStack(alignment: .leading) {
                    PauseAudioListPicker(
                        apps: config.binding(\.capture.audio.pauseAudioApps),
                        categories: config.binding(\.capture.audio.pauseAudioCategories))
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }

            // Custom vocabulary 是转译器的 hint(prompt 给 Whisper/Qwen/
             // Deepgram 让它认对专有名词),逻辑上属 Transcription。只在转译
             // 开着时才有意义显示。
            if engine != AudioEngine.disabled.rawValue {
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

    // MARK: - Input device card (Issue #10)

    @State private var devicesMonitor = AudioDevicesMonitor.shared
    /// 跟 ProgressView 的脉动 —— 真在录时绿点 pulse,没在录就 hide。
    @State private var pulseOn: Bool = false

    /// 输入源 card。Mic picker + 实时 active device + 并行 system audio loopback。
    /// 用户视角:这些都是"声音从哪进来" → 都归 Input。
    @ViewBuilder private var inputDeviceCard: some View {
        let preferred = config.current.capture.audio.preferredInputDeviceUID
        let devices = devicesMonitor.devices
        let activeUID = devicesMonitor.activeUID
        let activeDevice = devices.first { $0.id == activeUID }
        // 用户锁了一个设备,但当前 devices 列表里没有 → 设备被拔了。
        let preferredDisconnected = !preferred.isEmpty
            && !devices.contains(where: { $0.id == preferred })

        SettingsCard(
            title: "Input",
            footnote: preferred.isEmpty
                ? "Follow system default — macOS will switch the mic when you plug in headphones, AirPods, etc. System audio is a parallel loopback track."
                : "Locked to your chosen device. Headphone/AirPods plug-in won't change the mic. Disconnect → temporary fallback to system default until the device returns. System audio is a parallel loopback track."
        ) {
            SettingsRow("Microphone",
                        description: "Pick which mic My Portrait records from.",
                        icon: "mic.circle") {
                // 用原生 Picker —— macOS Menu 不认 Image.opacity,所以
                // 之前自己画 checkmark 会导致每个选项都显示打勾(Issue #11)。
                // Picker 让系统自己给选中项画 ✓,避免这个坑。
                Picker("", selection: config.binding(\.capture.audio.preferredInputDeviceUID)) {
                    Text("Follow system default").tag("")
                    Divider()
                    ForEach(devices) { d in
                        Label(d.name, systemImage: d.transport.icon).tag(d.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(maxWidth: 240, alignment: .trailing)
            }

            // 实时状态行 —— 真在录显示绿点 pulse + device 名,没录灰显示。
            SettingsDivider()
            SettingsRow("Currently recording from",
                        description: activeDevice?.transport == .bluetooth
                            ? "Bluetooth — slightly higher latency (~200ms jitter); we buffer to compensate."
                            : nil,
                        icon: activeDevice?.transport.icon ?? "waveform") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(activeUID.isEmpty ? Color.gray.opacity(0.3) : Color.green)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulseOn ? 1.3 : 1.0)
                        .opacity(pulseOn ? 0.55 : 1.0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: pulseOn)
                    Text(activeUID.isEmpty
                         ? "Not capturing"
                         : (activeDevice?.name ?? activeUID))
                        .font(.system(size: 12))
                        .foregroundStyle(activeUID.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 240, alignment: .trailing)
                .onAppear { pulseOn = !activeUID.isEmpty }
                .onChange(of: activeUID) { _, new in pulseOn = !new.isEmpty }
            }

            // System audio 是并行 loopback 路 —— 跟 mic 同时存在,不互斥。
            // 跟 mic 放一张卡里:用户视角"都是声音从哪进来"。
            SettingsDivider()
            SettingsRow("Also capture system audio",
                        description: "What you hear (loopback) — meeting partner's voice, video, music.",
                        icon: "speaker.wave.2") {
                Toggle("", isOn: config.binding(\.capture.audio.captureSystemAudio))
                    .labelsHidden().toggleStyle(.switch)
            }

            // 锁定设备掉线 → 橙色警告 banner。
            if preferredDisconnected {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Selected device disconnected — recording from system default. Will rebind when it returns.")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
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
            SettingsRow("Mask ignored windows",
                        description: "Windows on the lists below are hidden from the screenshot. The screenshot is still taken; those windows just go transparent.",
                        icon: "rectangle.dashed") {
                Toggle("", isOn: config.binding(\.privacy.maskIgnoredApps)).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsCard(
            title: "Ignored apps",
            footnote: "Windows from these apps are blanked out of the screenshot, but the screenshot itself is still taken. Matching ignores case and checks the app name or window title."
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
            title: "Pause capture for protected video",
            footnote: "When a listed app or site is active, screen capture stops completely instead of just masking. This keeps DRM playback like Netflix or Disney+ from going black in your screenshots. Apps match by name and sites by URL, both ignoring case. Common services are filled in already, and you can edit the list."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Apps — pick from installed apps…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                PauseCaptureAppPicker(apps: config.binding(\.privacy.pauseCaptureApps))
                    .padding(.horizontal, 14).padding(.bottom, 10)
                SettingsDivider()
                Text("Sites — hostnames or substrings…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                TagListEditor(tags: config.binding(\.privacy.pauseCaptureUrls), placeholder: "e.g. netflix.com, hbomax.com")
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
            footnote: "Trades screen-capture detail for battery life based on the profile you pick."
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
            footnote: "Password managers and terminals are always excluded. Pick an app to block all of it, or a URL to block only pages under that address."
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
                        description: "Reads what you finish typing into input fields to learn your writing style. Everything stays on this Mac and is never uploaded, and password fields are never read.",
                        icon: "keyboard") {
                Toggle("", isOn: config.binding(\.capture.typingCaptureEnabled)).labelsHidden().toggleStyle(.switch)
            }
            if config.current.capture.typingCaptureEnabled {
                SettingsDivider()
                SettingsRow("Keyboard correlation window",
                            description: "Only text that changes within this time after a keystroke counts as your typing, which filters out things like terminal output and incoming messages.",
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
                            description: "Edits made within this window are merged into one step. A higher value records fewer, coarser steps.",
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
                            description: "When you stop typing for this long, what you wrote is saved. Keep typing and it stays a single entry.",
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
                            description: "After you press Return, the box must clear within this time to count as a sent message rather than a deletion.",
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
                            description: "Clipboard text shorter than this is ignored when detecting pastes, so short typing isn't mistaken for a paste.",
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
                            description: "When it's on, text you paste is kept and marked as pasted. When it's off, pasted text is left out of what's saved.",
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
