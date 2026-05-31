import Foundation
import SwiftUI

/// 一个 Settings 子分区。用嵌套枚举表达 group 归属:
/// 类型系统强制 `.capture(.screen)` 形态,switch 时模式匹配清楚。
///
/// 用法:
///   - 路由 switch:`case .capture(.screen): ...`
///   - 整组遍历:`SettingsSubsection.allCases.filter { $0.group == .capture }`
///   - 持久化(AppStorage)等用 `id`(形如 `"app.display"`)。
enum SettingsSubsection: Hashable, Identifiable, CaseIterable {

    case app(App)
    case capture(Capture)
    case memory(Memory)
    case data(DataPrivacy)

    enum App: String, Hashable, CaseIterable {
        case display, general, aiModels, connections, notifications, health
    }
    enum Capture: String, Hashable, CaseIterable {
        case screen, audio, typing
    }
    enum Memory: String, Hashable, CaseIterable {
        case parameter, scheduler, changelog
    }
    enum DataPrivacy: String, Hashable, CaseIterable {
        // privacy 子项已合并到 Screen Capture 页面尾部,这里不再列。
        // speakers 子项已折进 Audio Capture 页面尾部(2026-05-26)。
        case usage, storage, imports
    }

    var id: String {
        switch self {
        case .app(let s):     return "app.\(s.rawValue)"
        case .capture(let s): return "capture.\(s.rawValue)"
        case .memory(let s):  return "memory.\(s.rawValue)"
        case .data(let s):    return "data.\(s.rawValue)"
        }
    }

    static var allCases: [SettingsSubsection] {
        App.allCases.map(SettingsSubsection.app)
        + Capture.allCases.map(SettingsSubsection.capture)
        + Memory.allCases.map(SettingsSubsection.memory)
        + DataPrivacy.allCases.map(SettingsSubsection.data)
    }

    var label: String {
        switch self {
        case .app(.display):           return "Display"
        case .app(.general):           return "General"
        case .app(.aiModels):          return "AI models"
        case .app(.connections):       return "Connections"
        case .app(.notifications):     return "Notifications"
        case .app(.health):            return "Health"
        case .capture(.screen):        return "Screen Capture"
        case .capture(.audio):         return "Audio Capture"
        case .capture(.typing):        return "Typing Capture"
        case .memory(.parameter):      return "Parameter"
        case .memory(.scheduler):      return "Scheduler"
        case .memory(.changelog):      return "Changelog"
        case .data(.usage):            return "Usage"
        case .data(.storage):          return "Storage"
        case .data(.imports):          return "Import"
        }
    }

    var icon: String {
        switch self {
        case .app(.display):           return "display"
        case .app(.general):           return "gearshape"
        case .app(.aiModels):          return "brain"
        case .app(.connections):       return "powerplug"
        case .app(.notifications):     return "bell"
        case .app(.health):            return "stethoscope"
        case .capture(.screen):        return "display"
        case .capture(.audio):         return "mic"
        case .capture(.typing):        return "keyboard"
        case .memory(.parameter):      return "slider.horizontal.3"
        case .memory(.scheduler):      return "calendar.badge.clock"
        case .memory(.changelog):      return "list.bullet.rectangle"
        case .data(.usage):            return "chart.bar"
        case .data(.storage):          return "externaldrive"
        case .data(.imports):          return "tray.and.arrow.down"
        }
    }

    enum Group: String, Hashable, CaseIterable {
        case app         = "APP"
        case capture     = "CAPTURE"
        case memory      = "MEMORY"
        // case 名保留 dataPrivacy(改名要动一堆调用),只把展示文字改成 DATA。
        case dataPrivacy = "DATA"
    }

    var group: Group {
        switch self {
        case .app:     return .app
        case .capture: return .capture
        case .memory:  return .memory
        case .data:    return .dataPrivacy
        }
    }
}

// MARK: - Tiny enums backing string AppStorage values

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AudioEngine: String, CaseIterable, Identifiable {
    case disabled, whisper, qwen, deepgram, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .whisper:  return "Whisper (on-device)"
        case .qwen:     return "Qwen3-ASR (on-device)"
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

