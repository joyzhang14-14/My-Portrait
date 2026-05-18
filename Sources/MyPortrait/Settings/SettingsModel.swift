import Foundation
import SwiftUI

/// One of the six tabs inside Settings. Drives both the sidebar list and the
/// main pane router.
enum SettingsSubsection: String, CaseIterable, Identifiable, Hashable {
    case general, display, recording, notifications, usage, privacy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .display:       return "Display"
        case .recording:     return "Recording"
        case .notifications: return "Notifications"
        case .usage:         return "Usage"
        case .privacy:       return "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .display:       return "display"
        case .recording:     return "record.circle"
        case .notifications: return "bell"
        case .usage:         return "chart.bar"
        case .privacy:       return "hand.raised"
        }
    }
}

// MARK: - AppStorage keys

/// Centralizes every AppStorage key so we don't drift typos across views.
enum SettingsKeys {
    // General
    static let launchAtLogin            = "Settings.launchAtLogin"
    static let updateCheckInterval      = "Settings.updateCheckInterval"     // String enum
    static let autoDownloadUpdates      = "Settings.autoDownloadUpdates"

    // Display
    static let theme                    = "Settings.theme"                    // system/light/dark
    static let chatAlwaysOnTop          = "Settings.chatAlwaysOnTop"
    static let translucentSidebar       = "Settings.translucentSidebar"
    static let hideModelReasoning       = "Settings.hideModelReasoning"
    static let smartBarEnabled          = "Settings.smartBarEnabled"
    static let smartBarOverlaySize      = "Settings.smartBarOverlaySize"      // double 0.5..1.5
    static let smartBarShowShortcuts    = "Settings.smartBarShowShortcuts"
    static let smartBarShowCapture      = "Settings.smartBarShowCapture"
    static let smartBarShowAudio        = "Settings.smartBarShowAudio"
    static let smartBarShowMeeting      = "Settings.smartBarShowMeeting"
    static let smartBarShowLyric        = "Settings.smartBarShowLyric"

    // Recording / audio
    static let audioEngine              = "Settings.audioEngine"              // whisper/deepgram
    static let deepgramAPIKey           = "Settings.deepgramAPIKey"
    static let audioLanguages           = "Settings.audioLanguages"           // [String]
    static let useCoreAudioCapture      = "Settings.useCoreAudioCapture"
    static let microphonesSelected      = "Settings.microphonesSelected"      // [String]
    static let captureSystemAudio       = "Settings.captureSystemAudio"

    // Recording / screen
    static let recordingQuality         = "Settings.recordingQuality"         // low/medium/high
    static let activeMonitor            = "Settings.activeMonitor"            // String identifier
    static let chineseMirror            = "Settings.chineseMirror"

    // Notifications
    static let notifyAppUpdates         = "Settings.notifyAppUpdates"
    static let notifyPipeSuggestions    = "Settings.notifyPipeSuggestions"
    static let notifyPipeAlerts         = "Settings.notifyPipeAlerts"
    static let notifyCaptureStalls      = "Settings.notifyCaptureStalls"
    static let mutedPipes               = "Settings.mutedPipes"               // [String]

    // Privacy
    static let ignoreIncognito          = "Settings.ignoreIncognito"
    static let captureClipboard         = "Settings.captureClipboard"
    static let recordAudioWhileLocked   = "Settings.recordAudioWhileLocked"
    static let piiRemoval               = "Settings.piiRemoval"
    static let ignoredApps              = "Settings.ignoredApps"              // [String]
    static let includedApps             = "Settings.includedApps"             // [String]
    static let ignoredURLs              = "Settings.ignoredURLs"              // [String]
}

// MARK: - Tiny enums backing string AppStorage values

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum UpdateInterval: String, CaseIterable, Identifiable {
    case hourly, daily, weekly, never
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AudioEngine: String, CaseIterable, Identifiable {
    case whisper, deepgram
    var id: String { rawValue }
    var label: String {
        switch self {
        case .whisper:  return "Whisper (on-device)"
        case .deepgram: return "Deepgram (cloud)"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
