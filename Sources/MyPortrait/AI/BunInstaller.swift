import Foundation

/// Downloads & installs the Bun runtime to `~/.portrait/bun/bin/bun`.
/// Pi (`@mariozechner/pi-coding-agent`) requires Bun (or Node) to run; we ship Bun
/// because Orphies does and the package is small (~50 MB) and self-contained.
enum BunInstaller {

    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case unzipFailed(String)
        case binaryMissing
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "Bun download failed: \(m)"
            case .unzipFailed(let m):    return "Bun unzip failed: \(m)"
            case .binaryMissing:         return "Bun binary missing after install."
            }
        }
    }

    /// True if a usable bun binary is already on disk.
    static var isInstalled: Bool {
        let p = AIPaths.bunBinary.path
        return FileManager.default.isExecutableFile(atPath: p)
    }

    /// Install Bun. Idempotent — returns immediately if already installed.
    /// `progress` is called on the main actor with values in 0...1 during download.
    static func install(progress: @MainActor @escaping (Double) -> Void = { _ in }) async throws {
        if isInstalled { return }
        try AIPaths.ensureExists()

        let fm = FileManager.default
        try fm.createDirectory(at: AIPaths.bunDir.appendingPathComponent("bin"),
                               withIntermediateDirectories: true)

        let arch = currentArch()
        let url = URL(string: "https://github.com/oven-sh/bun/releases/latest/download/bun-darwin-\(arch).zip")!

        let zipURL = AIPaths.bunDir.appendingPathComponent("bun.zip")
        try await download(url, to: zipURL, progress: progress)

        // Unzip with system /usr/bin/unzip.
        try unzip(zipURL, into: AIPaths.bunDir)
        try? fm.removeItem(at: zipURL)

        // The zip extracts to `bun-darwin-<arch>/bun`. Move into bin/.
        let extractedDir = AIPaths.bunDir.appendingPathComponent("bun-darwin-\(arch)")
        let extractedBun = extractedDir.appendingPathComponent("bun")
        let target = AIPaths.bunBinary
        try? fm.removeItem(at: target)
        try fm.moveItem(at: extractedBun, to: target)
        try? fm.removeItem(at: extractedDir)

        // Make executable.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)

        guard isInstalled else { throw InstallError.binaryMissing }
    }

    // MARK: - helpers

    private static func currentArch() -> String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x64"
        #endif
    }

    private static func download(_ url: URL, to dest: URL,
                                 progress: @MainActor @escaping (Double) -> Void) async throws {
        // URLSession.download(for:) does the right thing and reports via delegate.
        // For simplicity, we just await the data — bun release zip is ~30 MB.
        let session = URLSession(configuration: .ephemeral)
        let (tmpURL, resp) = try await session.download(from: url, delegate: ProgressDelegate(onProgress: progress))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.downloadFailed("status \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.launchPath = "/usr/bin/unzip"
        p.arguments = ["-oq", zip.path, "-d", dir.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.unzipFailed(err)
        }
    }
}

/// URLSessionDownloadDelegate that forwards progress to a main-actor closure.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @MainActor (Double) -> Void
    init(onProgress: @escaping @MainActor (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let cb = onProgress
        Task { @MainActor in cb(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // No-op — the async download(_:delegate:) entry point returns the temp URL itself.
    }
}
