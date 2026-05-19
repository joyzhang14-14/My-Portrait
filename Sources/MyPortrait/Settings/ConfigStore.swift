import Foundation
import SwiftUI
import AppKit
import Observation
import TOMLKit

/// Single source of truth for everything in `~/.myportrait/config.toml`.
/// Replaces every Settings `@AppStorage` — UI binds through here.
///
/// Lifecycle:
///   1. On launch: read TOML → decode `MyPortraitConfig`. Missing keys take
///      defaults from the struct. Parse failure → keep defaults, surface
///      `loadError` for the UI banner.
///   2. One-shot migration: if no TOML existed AND we find legacy
///      AppStorage values, seed those in and write the file once.
///   3. Every UI mutation funnels through `mutate { … }` → debounced write.
///   4. `DispatchSource` watches the file. External edits (vim, sync) hot-
///      reload — the UI animates the change in.
@MainActor
@Observable
final class ConfigStore {
    static let shared = ConfigStore()

    /// Current config. Mutate via `mutate { $0.section.field = ... }` so the
    /// debounced writer gets a kick and `Equatable` change-detection works.
    private(set) var current: MyPortraitConfig = .init()

    /// Non-nil when the last load hit a TOML parse error — shown as a
    /// dismissable banner so the user knows what happened. `current` falls
    /// back to defaults in that case so the app keeps working.
    private(set) var loadError: String?

    /// True once the very first save has landed. Used by the migration step
    /// to avoid clobbering a file we just wrote.
    private(set) var didCompleteInitialSeed = false

    // File path / write debounce / fs watcher
    private let path: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".myportrait/config.toml")
    }()
    private var writeTask: Task<Void, Never>?
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var suppressNextWatchEvent = false       // ignore our own writes

    private init() {
        loadFromDisk()
        migrateIfNeeded()
        startWatching()
    }

    // MARK: - Public mutation hook

    /// Mutate the config and schedule a debounced write. Use this from views:
    ///     ConfigStore.shared.mutate { $0.display.theme = "dark" }
    func mutate(_ block: (inout MyPortraitConfig) -> Void) {
        var next = current
        block(&next)
        guard next != current else { return }
        current = next
        refreshSnapshot()
        scheduleWrite()
    }

    // MARK: - Section passthroughs (so @Bindable works)
    //
    // @Bindable needs stored-property-shaped access, but our underlying truth
    // is a single `current: MyPortraitConfig`. These computed get/set
    // properties bridge the two: SwiftUI sees them as tracked properties
    // (because `current` is @Observable-tracked), and write-through funnels
    // back into mutate() for debounced persistence.
    var display:       DisplayConfig       { get { current.display }       set { mutate { $0.display = newValue } } }
    var general:       GeneralConfig       { get { current.general }       set { mutate { $0.general = newValue } } }
    var aiModels:      AIModelsConfig      { get { current.aiModels }      set { mutate { $0.aiModels = newValue } } }
    var recording:     RecordingConfig     { get { current.recording }     set { mutate { $0.recording = newValue } } }
    var notifications: NotificationsConfig { get { current.notifications } set { mutate { $0.notifications = newValue } } }
    var memory:        MemoryConfig        { get { current.memory }        set { mutate { $0.memory = newValue } } }
    var usage:         UsageConfig         { get { current.usage }         set { mutate { $0.usage = newValue } } }
    var privacy:       PrivacyConfig       { get { current.privacy }       set { mutate { $0.privacy = newValue } } }
    var storage:       StorageConfig       { get { current.storage }       set { mutate { $0.storage = newValue } } }
    var chat:          ChatConfig          { get { current.chat }          set { mutate { $0.chat = newValue } } }

    /// Force-flush any pending debounced write immediately (caller awaits it).
    func saveNow() {
        Task { await writeNow() }
    }

    /// Cross-actor read for non-MainActor callers (TimelineDB, background
     /// scanners). Updated by `refreshSnapshot()` on every mutate / load.
     /// Keep small — only fields needed off the main actor go here.
     nonisolated static var snapshot: ConfigSnapshot { Self.snapshotLock.withLock { Self.snapshotValue } }
     nonisolated private static let snapshotLock = NSLock()
     nonisolated(unsafe) private static var snapshotValue = ConfigSnapshot()

     /// Mirror current values into the cross-actor snapshot. Called from
     /// load + every mutate.
     func refreshSnapshot() {
         let next = ConfigSnapshot(
             dataDirectory: current.storage.dataDirectory,
             retentionDays: current.storage.retentionDays,
             autoDeleteMode: current.storage.autoDeleteMode
         )
         Self.snapshotLock.withLock { Self.snapshotValue = next }
     }

    /// Static for callers that want the on-disk URL without going through
    /// `.shared` first (e.g. footer of the Memory page).
    static var path: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".myportrait/config.toml")
    }

    /// Convenience two-way Binding for any value in the config tree.
    /// Usage:  Toggle("", isOn: ConfigStore.shared.binding(\.display.chatAlwaysOnTop))
    func binding<V>(_ kp: WritableKeyPath<MyPortraitConfig, V>) -> Binding<V> {
        Binding(
            get: { self.current[keyPath: kp] },
            set: { new in self.mutate { $0[keyPath: kp] = new } }
        )
    }

    /// Binding for an API-key / token slot: the TOML only stores a string
    /// REFERENCE; the actual secret lives in SecretStore. Setting empty
    /// clears both; setting a value writes through to SecretStore and
    /// auto-assigns a ref if one wasn't there yet.
    func secretBinding(refKeyPath: WritableKeyPath<MyPortraitConfig, String>,
                       defaultRef: String) -> Binding<String> {
        Binding(
            get: {
                let ref = self.current[keyPath: refKeyPath]
                guard !ref.isEmpty,
                      let data = SecretStore.shared.get(ref),
                      let s = String(data: data, encoding: .utf8)
                else { return "" }
                return s
            },
            set: { newValue in
                let trimmed = newValue
                let ref = self.current[keyPath: refKeyPath]
                if trimmed.isEmpty {
                    if !ref.isEmpty { SecretStore.shared.delete(ref) }
                    self.mutate { $0[keyPath: refKeyPath] = "" }
                } else {
                    let useRef = ref.isEmpty ? defaultRef : ref
                    try? SecretStore.shared.set(useRef, value: Data(trimmed.utf8))
                    if ref.isEmpty {
                        self.mutate { $0[keyPath: refKeyPath] = useRef }
                    }
                }
            }
        )
    }

    /// Convenience: open `config.toml` in Finder (selected) so the user can
    /// hand-edit it. Creates the file first if it doesn't exist yet.
    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: path.path) {
            Task { await writeNow() }
        }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    /// Read-only accessor used by tests / utilities.
    var fileURL: URL { path }

    /// Delete the on-disk file and revert to baked-in defaults.
    func resetToDefaults() {
        try? FileManager.default.removeItem(at: path)
        current = .init()
        loadError = nil
    }

    /// Force a re-read from disk. Hot-reload calls this too.
    func reload() {
        loadFromDisk()
    }

    // MARK: - Load (fail-soft)

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: path.path) else {
            // No file yet — keep defaults; the migration step will seed one.
            loadError = nil
            refreshSnapshot()
            return
        }
        do {
            let raw = try String(contentsOf: path, encoding: .utf8)
            let decoded = try TOMLDecoder().decode(MyPortraitConfig.self, from: raw)
            current = applySchemaMigration(decoded)
            loadError = nil
        } catch {
            loadError = "Couldn't read config.toml: \(error.localizedDescription) — using defaults."
            // Keep `current` as whatever it was (defaults on fresh launch).
        }
        refreshSnapshot()
    }

    /// Hook for future schema bumps. Today this is identity; once schema
    /// changes shape we transform `decoded` in here based on its version.
    private func applySchemaMigration(_ decoded: MyPortraitConfig) -> MyPortraitConfig {
        var c = decoded
        // Future: if c.schemaVersion < MyPortraitConfig.currentSchemaVersion { … }
        c.schemaVersion = MyPortraitConfig.currentSchemaVersion
        return c
    }

    // MARK: - Save (debounced)

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    private func writeNow() async {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try TOMLEncoder().encode(current)
            let blob = headerComment + encoded
            suppressNextWatchEvent = true
            try blob.write(to: path, atomically: true, encoding: .utf8)
            didCompleteInitialSeed = true
        } catch {
            loadError = "Couldn't write config.toml: \(error.localizedDescription)"
        }
    }

    private var headerComment: String {
        """
        # My Portrait configuration. Hand-editable — saved on every change.
        # Reset to defaults by deleting this file.

        """
    }

    // MARK: - One-shot AppStorage → TOML migration

    /// On the very first launch after this build ships, copy values from the
    /// legacy UserDefaults keys into the config + write it out so nothing
    /// the user previously set goes missing. Subsequent launches skip this.
    private func migrateIfNeeded() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }

        let ud = UserDefaults.standard
        var c = current

        // — Display
        if let v = ud.string(forKey: "Settings.theme")                  { c.display.theme = v }
        c.display.chatAlwaysOnTop         = bool(ud, "Settings.chatAlwaysOnTop",       default: c.display.chatAlwaysOnTop)
        c.display.translucentSidebar      = bool(ud, "Settings.translucentSidebar",    default: c.display.translucentSidebar)
        c.display.hideModelReasoning      = bool(ud, "Settings.hideModelReasoning",    default: c.display.hideModelReasoning)
        c.display.showOverlayInRecording  = bool(ud, "Settings.showOverlayInRecording",default: c.display.showOverlayInRecording)
        if let v = ud.string(forKey: "Settings.appName")                { c.display.appName = v }
        if let v = ud.string(forKey: "Settings.customDockIcon")         { c.display.customDockIcon = v }
        if let v = ud.string(forKey: "Settings.customTrayIcon")         { c.display.customTrayIcon = v }
        c.display.showInMenuBar           = bool(ud, "Settings.showInMenuBar",         default: c.display.showInMenuBar)

        // — General
        c.general.launchAtLogin           = bool(ud, "Settings.launchAtLogin",         default: c.general.launchAtLogin)
        c.general.autoDownloadUpdates     = bool(ud, "Settings.autoDownloadUpdates",   default: c.general.autoDownloadUpdates)
        let mins = ud.integer(forKey: "Settings.updateCheckMinutes")
        if mins > 0 { c.general.updateCheckMinutes = mins }

        // — Recording / audio
        c.recording.audio.enabled                = bool(ud, "Settings.audioRecordingEnabled",  default: c.recording.audio.enabled)
        if let v = ud.string(forKey: "Settings.userName")              { c.recording.audio.userName = v }
        if let v = ud.string(forKey: "Settings.audioEngine")           { c.recording.audio.engine = v }
        c.recording.audio.languages              = stringArray(ud, "Settings.audioLanguages")
        c.recording.audio.microphonesSelected    = stringArray(ud, "Settings.microphonesSelected")
        c.recording.audio.captureSystemAudio     = bool(ud, "Settings.captureSystemAudio",     default: c.recording.audio.captureSystemAudio)
        c.recording.audio.useCoreAudioCapture    = bool(ud, "Settings.useCoreAudioCapture",    default: c.recording.audio.useCoreAudioCapture)
        c.recording.audio.speakerIdEnabled       = bool(ud, "Settings.speakerIdEnabled",       default: c.recording.audio.speakerIdEnabled)
        c.recording.audio.filterMusic            = bool(ud, "Settings.filterMusic",            default: c.recording.audio.filterMusic)
        c.recording.audio.batchTranscription     = bool(ud, "Settings.batchTranscription",     default: c.recording.audio.batchTranscription)
        c.recording.audio.autoSelectAudioDevices = bool(ud, "Settings.autoSelectAudioDevices", default: c.recording.audio.autoSelectAudioDevices)
        c.recording.audio.customVocabulary       = stringArray(ud, "Settings.customVocabulary")

        // — Recording / screen
        c.recording.screen.enabled               = bool(ud, "Settings.screenRecordingEnabled", default: c.recording.screen.enabled)
        if let v = ud.string(forKey: "Settings.ocrEngine")             { c.recording.screen.ocrEngine = v }
        let fps = ud.integer(forKey: "Settings.videoFps")
        if fps > 0 { c.recording.screen.videoFps = fps }
        if let v = ud.string(forKey: "Settings.recordingQuality")      { c.recording.screen.quality = v }
        if let v = ud.string(forKey: "Settings.videoFormat")           { c.recording.screen.videoFormat = v }
        let fim = ud.integer(forKey: "Settings.frameIntervalMs")
        if fim > 0 { c.recording.screen.frameIntervalMs = fim }

        // — Recording / system
        c.recording.system.chineseMirror = bool(ud, "Settings.chineseMirror", default: c.recording.system.chineseMirror)
        if let v = ud.string(forKey: "Settings.powerMode") { c.recording.system.powerMode = v }

        // — Notifications
        c.notifications.appUpdates       = bool(ud, "Settings.notifyAppUpdates",      default: c.notifications.appUpdates)
        c.notifications.pipeAlerts       = bool(ud, "Settings.notifyPipeAlerts",      default: c.notifications.pipeAlerts)
        c.notifications.captureStalls    = bool(ud, "Settings.notifyCaptureStalls",   default: c.notifications.captureStalls)
        c.notifications.mutedPipes       = stringArray(ud, "Settings.mutedPipes")

        // — Usage
        if let v = ud.string(forKey: "Settings.usageRange") { c.usage.range = v }

        // — Privacy
        c.privacy.ignoreIncognito        = bool(ud, "Settings.ignoreIncognito",        default: c.privacy.ignoreIncognito)
        c.privacy.captureClipboard       = bool(ud, "Settings.captureClipboard",       default: c.privacy.captureClipboard)
        c.privacy.recordAudioWhileLocked = bool(ud, "Settings.recordAudioWhileLocked", default: c.privacy.recordAudioWhileLocked)
        c.privacy.piiRemoval             = bool(ud, "Settings.piiRemoval",             default: c.privacy.piiRemoval)
        c.privacy.ignoredApps            = stringArray(ud, "Settings.ignoredApps")
        c.privacy.includedApps           = stringArray(ud, "Settings.includedApps")
        c.privacy.ignoredUrls            = stringArray(ud, "Settings.ignoredURLs")

        // — Storage
        if let v = ud.string(forKey: "Settings.dataDirectory")  { c.storage.dataDirectory = v }
        if let v = ud.string(forKey: "Settings.retentionDays")  { c.storage.retentionDays = v }
        if let v = ud.string(forKey: "Settings.autoDeleteMode") { c.storage.autoDeleteMode = v }

        // — Chat (HomeView shield)
        c.chat.redactPii = bool(ud, "MyPortrait.redactPII", default: c.chat.redactPii)

        // — AI presets (was JSON in UserDefaults under "Settings.aiPresets.v1")
        if let blob = ud.data(forKey: "Settings.aiPresets.v1"),
           let decoded = try? JSONDecoder().decode([LegacyPreset].self, from: blob) {
            c.aiModels.presets = decoded.map {
                AIPresetSpec(
                    id: $0.id, name: $0.name, provider: $0.provider, model: $0.model,
                    apiKeyRef: $0.apiKey.isEmpty ? "" : "apikey:preset:\($0.id.uuidString)",
                    baseUrl: $0.baseURL, maxTokens: $0.maxTokens, maxContext: $0.maxContext,
                    systemPrompt: $0.systemPrompt, isDefault: $0.isDefault
                )
            }
            // Move every preset's actual key into SecretStore.
            for old in decoded where !old.apiKey.isEmpty {
                let ref = "apikey:preset:\(old.id.uuidString)"
                try? SecretStore.shared.set(ref, value: Data(old.apiKey.utf8))
            }
        }

        current = c
        scheduleWrite()
    }

    private func bool(_ ud: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        // UserDefaults.bool returns false for missing keys; distinguish via object(forKey:)
        ud.object(forKey: key) == nil ? fallback : ud.bool(forKey: key)
    }
    private func stringArray(_ ud: UserDefaults, _ key: String) -> [String] {
        if let arr = ud.stringArray(forKey: key) { return arr }
        if let data = ud.data(forKey: key),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        return []
    }

    /// Shape of the JSON the old AIPresetStore wrote into UserDefaults.
    private struct LegacyPreset: Codable {
        let id: UUID
        let name: String
        let provider: String
        let model: String
        let apiKey: String
        let baseURL: String
        let maxTokens: Int
        let maxContext: Int
        let systemPrompt: String
        let isDefault: Bool
    }

    // MARK: - File system watcher

    private func startWatching() {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) {
            // Touch the file so DispatchSource has something to watch.
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }

        let fd = open(path.path, O_EVTONLY)
        guard fd != -1 else { return }
        watchFD = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleFileChange() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        watchSource = src
    }

    private func handleFileChange() {
        if suppressNextWatchEvent {
            suppressNextWatchEvent = false
            return
        }
        // The file might have been atomically replaced — re-arm the watcher.
        watchSource?.cancel()
        watchSource = nil
        startWatching()
        loadFromDisk()
    }

    // Singleton — no deinit cleanup needed (process death closes the fd).
}
