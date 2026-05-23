import Foundation
import AppKit
import UniformTypeIdentifiers

/// A file or image the user has attached to the input bar. Persisted to
/// `~/.portrait/attachments/<uuid>.<ext>` so the
/// path stays stable after the user pastes ephemeral clipboard data.
struct Attachment: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let kind: Kind
    let displayName: String

    enum Kind { case image, file }

    /// Path that goes into the prompt prefix — absolute so Pi's bash/read
    /// tools can pick it up regardless of where Pi's cwd is.
    var promptPath: String { url.path }
}

enum AttachmentStore {
    static var dir: URL {
        let d = AIPaths.supportDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Save an arbitrary file (image, PDF, txt…) into the attachments dir
    /// under a fresh UUID name; returns the resulting Attachment.
    static func save(data: Data, suggestedName: String?, isImage: Bool) -> Attachment? {
        let ext = (suggestedName as NSString?)?.pathExtension.lowercased()
                ?? (isImage ? "png" : "bin")
        let id = UUID()
        let url = dir.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return Attachment(
            id: id, url: url,
            kind: isImage ? .image : .file,
            displayName: suggestedName ?? "\(id.uuidString.prefix(6)).\(ext)"
        )
    }

    /// Reference an existing file by URL — used when the user drops or
    /// pastes a file URL. We don't COPY into the attachments dir for these;
    /// just keep a pointer so Pi reads the original.
    static func wrap(fileURL: URL) -> Attachment {
        let ext = fileURL.pathExtension.lowercased()
        let isImage = ["png","jpg","jpeg","heic","gif","webp","tiff","bmp"].contains(ext)
        return Attachment(
            id: UUID(), url: fileURL,
            kind: isImage ? .image : .file,
            displayName: fileURL.lastPathComponent
        )
    }
}
