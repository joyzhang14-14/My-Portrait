import Foundation
import SwiftUI

/// One of the nine subsections inside Settings. Drives both the sidebar
/// list and the main pane router.
enum SettingsSubsection: String, CaseIterable, Identifiable, Hashable {
    case display, general, aiModels, recording, notifications
    case usage, privacy, storage, speakers
    var id: String { rawValue }

    var label: String {
        switch self {
        case .display:       return "Display"
        case .general:       return "General"
        case .aiModels:      return "AI models"
        case .recording:     return "Recording"
        case .notifications: return "Notifications"
        case .usage:         return "Usage"
        case .privacy:       return "Privacy"
        case .storage:       return "Storage"
        case .speakers:      return "Speakers"
        }
    }

    var icon: String {
        switch self {
        case .display:       return "display"
        case .general:       return "gearshape"
        case .aiModels:      return "brain"
        case .recording:     return "record.circle"
        case .notifications: return "bell"
        case .usage:         return "chart.bar"
        case .privacy:       return "hand.raised"
        case .storage:       return "externaldrive"
        case .speakers:      return "person.wave.2"
        }
    }

    enum Group: String, Hashable { case app = "APP", dataPrivacy = "DATA & PRIVACY" }

    var group: Group {
        switch self {
        case .display, .general, .aiModels, .recording, .notifications: return .app
        case .usage, .privacy, .storage, .speakers:                     return .dataPrivacy
        }
    }
}

// MARK: - AppStorage keys

/// Centralizes every AppStorage key so we don't drift typos across views.
enum SettingsKeys {
    // General
    static let launchAtLogin            = "Settings.launchAtLogin"
    static let updateCheckInterval      = "Settings.updateCheckInterval"      // String enum (legacy)
    static let updateCheckMinutes       = "Settings.updateCheckMinutes"       // Int (Orphies parity)
    static let autoDownloadUpdates      = "Settings.autoDownloadUpdates"

    // Display
    static let theme                    = "Settings.theme"                    // system/light/dark
    static let chatAlwaysOnTop          = "Settings.chatAlwaysOnTop"
    static let translucentSidebar       = "Settings.translucentSidebar"
    static let hideModelReasoning       = "Settings.hideModelReasoning"
    static let showOverlayInRecording   = "Settings.showOverlayInRecording"

    // Recording / audio
    static let audioRecordingEnabled    = "Settings.audioRecordingEnabled"
    static let userName                 = "Settings.userName"
    static let audioEngine              = "Settings.audioEngine"              // whisper/deepgram/disabled
    static let deepgramAPIKey           = "Settings.deepgramAPIKey"
    static let audioLanguages           = "Settings.audioLanguages"           // [String]
    static let useCoreAudioCapture      = "Settings.useCoreAudioCapture"
    static let microphonesSelected      = "Settings.microphonesSelected"      // [String]
    static let captureSystemAudio       = "Settings.captureSystemAudio"
    static let customVocabulary         = "Settings.customVocabulary"         // [String]
    static let speakerIdEnabled         = "Settings.speakerIdEnabled"

    // Recording / screen
    static let screenRecordingEnabled   = "Settings.screenRecordingEnabled"
    static let ocrEngine                = "Settings.ocrEngine"                // disabled/tesseract/cloud
    static let videoFps                 = "Settings.videoFps"                 // Int 1..30
    static let recordingQuality         = "Settings.recordingQuality"         // low/medium/high
    static let videoFormat              = "Settings.videoFormat"              // h264/h265/prores
    static let frameIntervalMs          = "Settings.frameIntervalMs"          // Int
    static let activeMonitor            = "Settings.activeMonitor"            // String identifier

    // Recording / system
    static let chineseMirror            = "Settings.chineseMirror"

    // Notifications
    static let notifyAppUpdates         = "Settings.notifyAppUpdates"
    static let notifyPipeSuggestions    = "Settings.notifyPipeSuggestions"
    static let pipeSuggestionInterval   = "Settings.pipeSuggestionInterval"   // SuggestionInterval rawValue
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

    // Storage
    static let dataDirectory            = "Settings.dataDirectory"            // String path

    // Usage
    static let usageRange               = "Settings.usageRange"               // UsageRange rawValue
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
    case disabled, whisper, deepgram, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .whisper:  return "Whisper (on-device)"
        case .deepgram: return "Deepgram (cloud)"
        case .custom:   return "Custom endpoint"
        }
    }
}

enum OCREngine: String, CaseIterable, Identifiable {
    case disabled, tesseract, cloud
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disabled:  return "Disabled"
        case .tesseract: return "Tesseract (on-device)"
        case .cloud:     return "Cloud"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case h264, h265, prores
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264:   return "H.264"
        case .h265:   return "H.265"
        case .prores: return "ProRes"
        }
    }
}

enum SuggestionInterval: String, CaseIterable, Identifiable {
    case h1, h2, h3, h6, h12, daily, weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h1: return "every 1h";   case .h2: return "every 2h"
        case .h3: return "every 3h";   case .h6: return "every 6h"
        case .h12: return "every 12h"; case .daily: return "daily"; case .weekly: return "weekly"
        }
    }
}

enum UsageRange: String, CaseIterable, Identifiable {
    case last24h, last7d, last30d, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .last24h: return "24h"; case .last7d: return "7d"
        case .last30d: return "30d"; case .all: return "all"
        }
    }
}
