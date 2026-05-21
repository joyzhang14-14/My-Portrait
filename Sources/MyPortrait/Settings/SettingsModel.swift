import Foundation
import SwiftUI

/// One of the nine subsections inside Settings. Drives both the sidebar
/// list and the main pane router.
enum SettingsSubsection: String, CaseIterable, Identifiable, Hashable {
    case display, general, aiModels, connections, recording, notifications
    case memoryParameter, memoryScheduler, memoryChangelog
    case usage, privacy, storage, speakers
    var id: String { rawValue }

    var label: String {
        switch self {
        case .display:          return "Display"
        case .general:          return "General"
        case .aiModels:         return "AI models"
        case .connections:      return "Connections"
        case .recording:        return "Recording"
        case .notifications:    return "Notifications"
        case .memoryParameter:  return "Parameter"
        case .memoryScheduler:  return "Scheduler"
        case .memoryChangelog:  return "Changelog"
        case .usage:            return "Usage"
        case .privacy:          return "Privacy"
        case .storage:          return "Storage"
        case .speakers:         return "Speakers"
        }
    }

    var icon: String {
        switch self {
        case .display:          return "display"
        case .general:          return "gearshape"
        case .aiModels:         return "brain"
        case .connections:      return "powerplug"
        case .recording:        return "record.circle"
        case .notifications:    return "bell"
        case .memoryParameter:  return "slider.horizontal.3"
        case .memoryScheduler:  return "calendar.badge.clock"
        case .memoryChangelog:  return "list.bullet.rectangle"
        case .usage:            return "chart.bar"
        case .privacy:          return "hand.raised"
        case .storage:          return "externaldrive"
        case .speakers:         return "person.wave.2"
        }
    }

    enum Group: String, Hashable {
        case app         = "APP"
        case memory      = "MEMORY"
        case dataPrivacy = "DATA & PRIVACY"
    }

    var group: Group {
        switch self {
        case .display, .general, .aiModels, .connections, .recording, .notifications: return .app
        case .memoryParameter, .memoryScheduler, .memoryChangelog:       return .memory
        case .usage, .privacy, .storage, .speakers:                     return .dataPrivacy
        }
    }
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

enum PowerMode: String, CaseIterable, Identifiable {
    case auto, performance, batterySaver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:         return "Auto"
        case .performance:  return "Performance"
        case .batterySaver: return "Battery saver"
        }
    }
    var subtitle: String {
        switch self {
        case .auto:         return "Adjusts based on battery state"
        case .performance:  return "Full quality, ignore battery"
        case .batterySaver: return "Maximum power saving"
        }
    }
    var icon: String {
        switch self {
        case .auto:         return "wand.and.stars"
        case .performance:  return "bolt.fill"
        case .batterySaver: return "leaf.fill"
        }
    }
}

enum RetentionDays: String, CaseIterable, Identifiable {
    case d7, d14, d30, d60, d90, forever
    var id: String { rawValue }
    var label: String {
        switch self {
        case .d7: return "7 days"; case .d14: return "14 days"
        case .d30: return "30 days"; case .d60: return "60 days"
        case .d90: return "90 days"; case .forever: return "Keep forever"
        }
    }
    /// nil → never auto-delete (Keep forever).
    var days: Int? {
        switch self {
        case .d7: return 7; case .d14: return 14
        case .d30: return 30; case .d60: return 60
        case .d90: return 90; case .forever: return nil
        }
    }
}

enum AutoDeleteMode: String, CaseIterable, Identifiable {
    case off, mediaOnly, everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:        return "Off"
        case .mediaOnly:  return "Video + audio only"
        case .everything: return "Everything (including OCR text + DB)"
        }
    }
    var subtitle: String {
        switch self {
        case .off:        return "Nothing gets deleted automatically."
        case .mediaOnly:  return "Recommended. Drops the heavy MP4s + audio chunks; keeps OCR text + transcripts so the timeline stays searchable."
        case .everything: return "Aggressive. Wipes everything older than the retention window."
        }
    }
    var icon: String {
        switch self {
        case .off:        return "pause.circle"
        case .mediaOnly:  return "film"
        case .everything: return "trash"
        }
    }
}

enum AccentColor: String, CaseIterable, Identifiable {
    case purple, blue, pink, green, orange, indigo, mint
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .purple: return Color(red: 0.65, green: 0.30, blue: 1.0)
        case .blue:   return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .pink:   return Color(red: 0.95, green: 0.35, blue: 0.65)
        case .green:  return Color(red: 0.30, green: 0.78, blue: 0.55)
        case .orange: return Color(red: 1.00, green: 0.55, blue: 0.25)
        case .indigo: return Color(red: 0.40, green: 0.35, blue: 0.95)
        case .mint:   return Color(red: 0.40, green: 0.85, blue: 0.75)
        }
    }
}

enum AppIconVariant: String, CaseIterable, Identifiable {
    case `default`, dark, monochrome, gradient
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default:    return "Default"
        case .dark:       return "Dark"
        case .monochrome: return "Monochrome"
        case .gradient:   return "Gradient"
        }
    }
}
