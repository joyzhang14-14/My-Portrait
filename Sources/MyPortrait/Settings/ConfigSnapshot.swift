import Foundation

/// Thread-safe snapshot of the few config fields that non-MainActor code
/// needs to read (e.g. `TimelineDB.init` deciding which DB to open).
/// Keep small — anything UI-bound stays inside the @MainActor ConfigStore.
struct ConfigSnapshot: Sendable {
    var dataDirectory: String = ""
}
