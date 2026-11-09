import Foundation
import Observation

/// EventSession 本机运行要的东西(下发清单 manifest.json 列出),装在 ~/.portrait/runtime/eventsession/:
/// python(独立 CPython)→ engine(管线代码 + 学生题面 + requirements.lock,依赖按锁定版本装进 python)→
/// rime(librime 桥 + 词库,只在用户的输入法对得上时才装)→ models(EventSession 模型)。
/// 顺序同设置页:资格通过后先装运行环境,再下模型。下载用 URLSession,解包用系统 tar,不按名字结束任何进程。
@MainActor @Observable
final class EventSessionInstaller {
    static let shared = EventSessionInstaller()

    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    nonisolated static var root: URL { Storage.rootURL.appendingPathComponent("runtime/eventsession", isDirectory: true) }
    nonisolated static var python: URL { root.appendingPathComponent("python/bin/python3") }
    nonisolated static var engineDir: URL { root.appendingPathComponent("engine/event-local-lab/pipeline", isDirectory: true) }
    nonisolated static var rimeDir: URL { root.appendingPathComponent("rime/rime", isDirectory: true) }
    nonisolated static var modelsDir: URL { root.appendingPathComponent("models", isDirectory: true) }

    /// 已装好的模型目录(有 eventsession.json 的第一个)。
    nonisolated static var modelDir: URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.first { fm.fileExists(atPath: $0.appendingPathComponent("eventsession.json").path) }
    }

    nonisolated static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: engineDir.appendingPathComponent("engine.py").path)
            && modelDir != nil
    }

    private struct Manifest: Decodable {
        struct Component: Decodable {
            let url: String
            let sha256: String?
            let size: Int64?
            let dest: String
            let strip: Int?
        }
        let components: [String: Component]
    }

    func refresh() {
        if case .working = phase { return }
        phase = Self.isReady ? .ready : .idle
    }

    func install() async {
        if case .working = phase { return }
        let base = ConfigStore.shared.current.eventSession.downloadBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let murl = URL(string: base.hasSuffix("/") ? base + "manifest.json" : base + "/manifest.json") else {
            phase = .failed("The download location isn't set up yet.")
            return
        }
        do {
            phase = .working("Reading the download list…")
            let (mdata, _) = try await URLSession.shared.data(from: murl)
            let m = try JSONDecoder().decode(Manifest.self, from: mdata)
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            for name in ["python", "engine"] {
                guard let c = m.components[name] else { throw Failure("The download list has no \(name).") }
                try await fetch(name, c)
            }
            phase = .working("Installing Python packages…")
            let lock = Self.root.appendingPathComponent("engine/requirements.lock").path
            try await off { try Self.run(Self.python.path, ["-m", "pip", "install", "--disable-pip-version-check", "--no-deps", "-r", lock]) }
            if try await off({ try Self.needsRime() }), let c = m.components["rime"] {
                try await fetch("rime", c)
            }
            guard let c = m.components["model"] else { throw Failure("The download list has no model.") }
            try await fetch("model", c)
            phase = Self.isReady ? .ready : .failed("Setup finished, but something is missing.")
        } catch {
            phase = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    /// 下载 → 校验 sha256 → 解进 root/<dest>(strip = 去掉包里最外层几级目录)。
    private func fetch(_ name: String, _ c: Manifest.Component) async throws {
        guard let url = URL(string: c.url) else { throw Failure("Bad download address for \(name).") }
        let size = c.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        phase = .working("Downloading \(name) \(size)…")
        let (tmp, _) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let want = c.sha256 {
            phase = .working("Checking \(name)…")
            guard try await off({ try Self.sha256(tmp) }) == want else { throw Failure("The \(name) download is damaged. Try again.") }
        }
        phase = .working("Unpacking \(name)…")
        let dest = Self.root.appendingPathComponent(c.dest, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var args = ["-xf", tmp.path, "-C", dest.path]
        if let s = c.strip, s > 0 { args.append("--strip-components=\(s)") }
        let tarArgs = args
        try await off { try Self.run("/usr/bin/tar", tarArgs) }
    }

    /// 外部命令放后台线程跑,别卡住界面。
    private func off<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(operation: f).value
    }

    /// 用户的输入法里有 librime 方案对得上的 → 要装 rime(问引擎,同一份判据)。
    nonisolated private static func needsRime() throws -> Bool {
        let out = try run(Self.python.path, ["-c",
            "import sys; sys.path.insert(0, sys.argv[1]); import keyfeed, source; print(keyfeed.needs_rime(source.portrait_db.connect()))",
            Self.engineDir.path])
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
    }

    @discardableResult
    nonisolated private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["PORTRAIT_ROOT": Storage.rootURL.path, "PYTHONNOUSERSITE": "1"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure(String(text.suffix(300))) }
        return text
    }

    nonisolated private static func sha256(_ url: URL) throws -> String {
        try run("/usr/bin/shasum", ["-a", "256", url.path]).split(separator: " ").first.map(String.init) ?? ""
    }

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }
}
