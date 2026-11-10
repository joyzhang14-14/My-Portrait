import Foundation
import Observation

/// EventSession 运行要的东西(下发清单 manifest.json 列出),装在 ~/.portrait/runtime/eventsession/:
/// python(独立 CPython)→ engine(管线代码 + 题面 + requirements.lock,依赖按锁定版本装进 python)→
/// rime(librime 桥 + 词库,只在用户的输入法对得上时才装)→ models(EventSession 模型,只有本机模型要)。
/// 每样装好在目录里留 `.installed`(记下包的 sha256),再点 Set up 时装好的跳过。
/// 下载边下边存 downloads/<名>.part,Stop 或 app 中途退出后再点 Resume,用 HTTP Range 从已下的字节接着下。
/// 解包用系统 tar,不按名字结束任何进程。
@MainActor @Observable
final class EventSessionInstaller {
    static let shared = EventSessionInstaller()

    enum Phase: Equatable {
        case idle
        case working
        case paused
        case ready
        case failed(String)
    }

    /// 设置页那一排步骤。
    static let steps = ["Python", "Packages", "Engine", "Dictionary", "Model"]

    private(set) var phase: Phase = .idle
    /// 正在做哪一步(`steps` 的下标)和这一步在干什么。
    private(set) var stepIndex = 0
    private(set) var stepText = ""
    /// 当前这个下载的字节进度;不在下载时 expected = 0。
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0
    /// 按这次下载的平均速度估的剩余秒数。
    private(set) var remaining: TimeInterval?

    private var job: Task<Void, Never>?
    private var download: RangeDownload?

    nonisolated static var root: URL { Storage.rootURL.appendingPathComponent("runtime/eventsession", isDirectory: true) }
    nonisolated static var python: URL { root.appendingPathComponent("python/bin/python3") }
    nonisolated static var engineDir: URL { root.appendingPathComponent("engine/event-local-lab/pipeline", isDirectory: true) }
    nonisolated static var rimeDir: URL { root.appendingPathComponent("rime/rime", isDirectory: true) }
    nonisolated static var modelsDir: URL { root.appendingPathComponent("models", isDirectory: true) }
    nonisolated static var partsDir: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// 已装好的模型目录(有 eventsession.json 的第一个)。
    nonisolated static var modelDir: URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.first { fm.fileExists(atPath: $0.appendingPathComponent("eventsession.json").path) }
    }

    /// 运行环境(python + 依赖 + 引擎)装好了没有;云端 provider 只要这些。
    nonisolated static var runtimeReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: engineDir.appendingPathComponent("engine.py").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("engine/.pip-installed").path)
    }

    nonisolated static func isReady(local: Bool) -> Bool { runtimeReady && (!local || modelDir != nil) }

    /// 已下了一部分的包(Stop / 中途退出留下的),设置页显示成 Paused。
    nonisolated static var hasPartial: Bool {
        let parts = (try? FileManager.default.contentsOfDirectory(atPath: partsDir.path)) ?? []
        return parts.contains { $0.hasSuffix(".part") }
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

    /// 打开设置页 / Downloads 页时按磁盘状态归位(正在装就不动)。
    func refresh(local: Bool) {
        if phase == .working { return }
        if Self.isReady(local: local) {
            phase = .ready
        } else if Self.hasPartial {
            phase = .paused
            if let (got, total) = Self.partialProgress() { received = got; expected = total }
        } else if case .failed = phase {
        } else {
            phase = .idle
        }
    }

    func start(local: Bool) {
        guard phase != .working else { return }
        phase = .working
        remaining = nil
        job = Task { await self.install(local: local) }
    }

    /// Stop:停掉当前下载(已下的字节留在 .part 里),Resume 时接着下。
    func stop() {
        guard phase == .working else { return }
        job?.cancel()
        download?.cancel()
        phase = .paused
        remaining = nil
    }

    /// 删掉整套运行环境和模型(Downloads 页的 Uninstall)。
    func uninstall() {
        stop()
        try? FileManager.default.removeItem(at: Self.root)
        phase = .idle
        received = 0
        expected = 0
    }

    private func install(local: Bool) async {
        let base = ConfigStore.shared.current.eventSession.downloadBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let murl = URL(string: base.hasSuffix("/") ? base + "manifest.json" : base + "/manifest.json") else {
            phase = .failed("The download location isn't set up yet.")
            return
        }
        do {
            set(0, "Reading the download list")
            let (mdata, _) = try await URLSession.shared.data(from: murl)
            let m = try JSONDecoder().decode(Manifest.self, from: mdata)
            try FileManager.default.createDirectory(at: Self.partsDir, withIntermediateDirectories: true)

            guard let py = m.components["python"], let engine = m.components["engine"] else {
                throw Failure("The download list is incomplete.")
            }
            try await component("python", py, step: 0, label: "Python")
            let engineChanged = try await component("engine", engine, step: 2, label: "the engine")
            let pipMark = Self.root.appendingPathComponent("engine/.pip-installed")
            if engineChanged || !FileManager.default.fileExists(atPath: pipMark.path) {
                set(1, "Installing packages")
                let lock = Self.root.appendingPathComponent("engine/requirements.lock").path
                try await off { try Self.run(Self.python.path, ["-m", "pip", "install", "--disable-pip-version-check", "--no-deps", "-r", lock]) }
                FileManager.default.createFile(atPath: pipMark.path, contents: Data())
            }
            try Task.checkCancellation()
            if let c = m.components["rime"], try await off({ try Self.needsRime() }) {
                try await component("rime", c, step: 3, label: "the input-method dictionary")
            }
            if local {
                guard let c = m.components["model"] else { throw Failure("The download list has no model.") }
                try await component("model", c, step: 4, label: "the model")
            }
            expected = 0
            phase = Self.isReady(local: local) ? .ready : .failed("Setup finished, but something is missing.")
        } catch is CancellationError {
            phase = .paused
        } catch let e as URLError where e.code == .cancelled {
            phase = .paused
        } catch {
            if phase == .paused { return }                     // Stop 之后下载报的错不算失败
            phase = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    private func set(_ step: Int, _ text: String) {
        stepIndex = step
        stepText = text
    }

    /// 一个包:装过同一份(.installed 里的 sha 对得上)就跳过,回 false;否则下载 → 校验 → 解包,回 true。
    @discardableResult
    private func component(_ name: String, _ c: Manifest.Component, step: Int, label: String) async throws -> Bool {
        let dest = Self.root.appendingPathComponent(c.dest, isDirectory: true)
        let mark = dest.appendingPathComponent(".installed")
        let want = c.sha256 ?? c.url
        if (try? String(contentsOf: mark, encoding: .utf8)) == want { return false }
        guard let url = URL(string: c.url) else { throw Failure("Bad download address for \(name).") }

        set(step, "Downloading \(label)")
        let part = Self.partsDir.appendingPathComponent("\(name).part")
        let info = Self.partsDir.appendingPathComponent("\(name).json")
        if let old = try? JSONDecoder().decode(PartInfo.self, from: Data(contentsOf: info)), old.sha != want {
            try? FileManager.default.removeItem(at: part)       // 包换了版本,旧的半截不能接
        }
        try? JSONEncoder().encode(PartInfo(sha: want, size: c.size ?? 0)).write(to: info)
        let dl = RangeDownload(url: url, to: part, expected: c.size ?? 0)
        download = dl
        let started = Date()
        let startBytes = dl.existing
        received = startBytes
        expected = c.size ?? 0
        try await dl.run { [weak self] got, total in
            Task { @MainActor in
                guard let self, self.phase == .working else { return }
                self.received = got
                if total > 0 { self.expected = total }
                let rate = Double(got - startBytes) / max(Date().timeIntervalSince(started), 0.5)
                self.remaining = rate > 0 && self.expected > got ? Double(self.expected - got) / rate : nil
            }
        }
        download = nil
        remaining = nil

        if let sha = c.sha256 {
            set(step, "Checking \(label)")
            guard try await off({ try Self.sha256(part) }) == sha else {
                try? FileManager.default.removeItem(at: part)
                throw Failure("The \(name) download is damaged. Try again.")
            }
        }
        set(step, "Unpacking \(label)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var args = ["-xf", part.path, "-C", dest.path]
        if let s = c.strip, s > 0 { args.append("--strip-components=\(s)") }
        let tarArgs = args
        try await off { try Self.run("/usr/bin/tar", tarArgs) }
        try want.write(to: mark, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: Self.partsDir.appendingPathComponent("\(name).json"))
        return true
    }

    private struct PartInfo: Codable { let sha: String; let size: Int64 }

    /// 留下的半截:已下字节 / 总大小(取最大的那个,一般就是模型)。
    nonisolated private static func partialProgress() -> (Int64, Int64)? {
        let fm = FileManager.default
        let parts = ((try? fm.contentsOfDirectory(atPath: partsDir.path)) ?? []).filter { $0.hasSuffix(".part") }
        let best = parts.compactMap { name -> (Int64, Int64)? in
            let got = ((try? fm.attributesOfItem(atPath: partsDir.appendingPathComponent(name).path))?[.size] as? Int64) ?? 0
            let info = try? JSONDecoder().decode(PartInfo.self, from: Data(contentsOf: partsDir.appendingPathComponent(
                name.replacingOccurrences(of: ".part", with: ".json"))))
            return (got, info?.size ?? 0)
        }.max { $0.1 < $1.1 }
        return best
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

/// 能接着下的下载:目标文件已有 N 字节就带 `Range: bytes=N-`;服务器回 206 接在后面写,回 200 从头写。
/// 进度按收到的数据块回调(已下字节,总字节)。`cancel()` 停下,已写的留着。
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let file: URL
    private var total: Int64
    private var got: Int64 = 0
    private var handle: FileHandle?
    private var session: URLSession?
    private var cont: CheckedContinuation<Void, Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var lastReport = Date.distantPast
    private let lock = NSLock()

    init(url: URL, to file: URL, expected: Int64) {
        self.url = url
        self.file = file
        self.total = expected
    }

    /// 目标文件里已经有的字节数。
    var existing: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0
    }

    func run(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        onProgress = progress
        got = existing
        if total > 0, got == total { return }                  // 上次已经下完,只差校验
        if total > 0, got > total {
            try? FileManager.default.removeItem(at: file)
            got = 0
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        var req = URLRequest(url: url)
        if got > 0 { req.setValue("bytes=\(got)-", forHTTPHeaderField: "Range") }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); cont = c; lock.unlock()
                s.dataTask(with: req).resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            finish(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        handle = try? FileHandle(forWritingTo: file)
        if code == 200 {                                       // 服务器不认 Range:从头写
            try? handle?.truncate(atOffset: 0)
            got = 0
            if response.expectedContentLength > 0 { total = response.expectedContentLength }
        } else {
            _ = try? handle?.seekToEnd()
        }
        completionHandler(handle == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        got += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            onProgress?(got, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        onProgress?(got, total)
        session.finishTasksAndInvalidate()
        finish(error)
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
