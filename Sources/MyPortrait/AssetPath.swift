import Foundation

/// Single resolver for every on-disk file path that came out of the DB.
///
/// All `snapshot_path` / `video_chunks.file_path` / `audio_chunks.file_path`
/// columns are stored **relative to `Storage.rootURL`** (i.e. `~/.portrait`)
/// so the data tree is relocatable. The DB layer (`PortraitDBImpl`) wraps
/// every external-facing path field through this function so callers always
/// receive either:
///
///   - an **absolute path that exists on disk**, or
///   - `nil` (file missing or input was empty)
///
/// Callers must never load raw strings off the DB without going through here.
enum AssetPath {
    /// Resolve a DB-stored file path.
    /// - Returns: absolute path if file exists, `nil` otherwise.
    static func resolve(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let abs: String = (raw as NSString).isAbsolutePath
            ? raw
            : (Storage.rootURL.path as NSString).appendingPathComponent(raw)
        return FileManager.default.fileExists(atPath: abs) ? abs : nil
    }

    /// Inverse of `resolve`. Strip the `Storage.rootURL` prefix from an
    /// absolute path so it can be stored relative. Used by writers
    /// (PortraitDBImpl insertVideoChunk / insertAudioChunk / insertFrame)
    /// so the on-disk DB stays portable regardless of what the caller
    /// hands in.
    static func normalize(_ raw: String) -> String {
        let root = Storage.rootURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        if raw == root { return "" }
        return raw    // already relative, or outside the tree (caller's choice)
    }
}
