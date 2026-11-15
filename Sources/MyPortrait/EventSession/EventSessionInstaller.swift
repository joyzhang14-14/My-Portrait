import Foundation
import Observation

/// EventSession 运行要的东西(下发清单 manifest.json 列出),装在 ~/.portrait/runtime/eventsession/:
/// python(独立 CPython)→ engine(管线代码 + 题面 + requirements.lock,依赖按锁定版本装进 python)→
/// rime(librime 桥 + 词库,只在用户的输入法对得上时才装);EventSession 模型(只有本机模型要)和其他本机模型一样
/// 放 ~/.portrait/models/<模型名>/。每样装好在自己的目录里留 `.installed`(记下包的 sha256),再点 Set up 时装好的跳过。
/// 一次只有一轮安装在跑:Resume 先等上一轮(哪怕正在后台算校验和、解包)彻底结束,Stop 之后旧的那轮不再动文件。
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

    /// 模型更新(11-15 update):查到的新版、后台下载进度。和上面 Set up 的那套状态分开,装好之后才用得到。
    enum ModelUpdate: Equatable {
        case unknown
        case checking
        case upToDate
        case available(name: String, size: Int64)
        case downloading(name: String)
        case paused(name: String)
        /// 下好、校验过,等 EventSession 空下来换上。
        case downloaded(name: String)
        case failed(String)
    }
    private(set) var modelUpdate: ModelUpdate = .unknown
    private(set) var updateReceived: Int64 = 0
    private(set) var updateExpected: Int64 = 0
    private var updateJob: Task<Void, Never>?
    private var updateDownload: RangeDownload?

    private var job: Task<Void, Never>?
    /// 每次 start / stop 加一;旧的一轮看到对不上就停手,不再改文件和状态。
    private var generation = 0
    private var download: RangeDownload?

    nonisolated static var root: URL { Storage.rootURL.appendingPathComponent("runtime/eventsession", isDirectory: true) }
    nonisolated static var python: URL { root.appendingPathComponent("python/bin/python3") }
    nonisolated static var engineDir: URL { root.appendingPathComponent("engine/event-local-lab/pipeline", isDirectory: true) }
    nonisolated static var rimeDir: URL { root.appendingPathComponent("rime/rime", isDirectory: true) }
    nonisolated static var modelsDir: URL { Storage.modelsDir }
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
            /// 包里最外层的目录名(模型):只替换这一个目录,不清空共用的 models/。
            let name: String?
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
        generation += 1
        let gen = generation, prev = job
        job = Task {
            await prev?.value                                  // 上一轮可能还在后台校验 / 解包,等它停手
            await self.install(local: local, gen: gen)
        }
    }

    /// 这一轮还算数吗:被 Stop / 新一轮取代就抛出,别再动文件。
    private func alive(_ gen: Int) throws {
        if gen != generation || Task.isCancelled { throw CancellationError() }
    }

    /// Stop:停掉当前下载(已下的字节留在 .part 里),Resume 时接着下。
    func stop() {
        guard phase == .working else { return }
        generation += 1
        job?.cancel()
        download?.cancel()
        phase = .paused
        remaining = nil
    }

    /// 删掉整套运行环境和模型(Downloads 页的 Uninstall)。
    func uninstall() {
        stop()
        stopModelUpdate()
        try? FileManager.default.removeItem(at: Self.root)
        if let m = Self.modelDir { try? FileManager.default.removeItem(at: m) }
        phase = .idle
        received = 0
        expected = 0
    }

    /// 已装好时的更新检查(worker 定时调):运行环境(python / 引擎 / 词库)有新版就就地换上;模型已经在就不动,不在才下。
    /// 连不上下载点就保持现状。
    func update(local: Bool) async {
        guard phase != .working, Self.isReady(local: local) else { return }
        phase = .working
        generation += 1
        await install(local: local, gen: generation, keepModel: true)
        if Self.isReady(local: local) { phase = .ready }
    }

    // MARK: - 模型更新

    /// 下好待换的新模型:包在 downloads/model-update.part,说明在 model-update.json。
    nonisolated private static var updatePart: URL { partsDir.appendingPathComponent("model-update.part") }
    nonisolated private static var updateInfo: URL { partsDir.appendingPathComponent("model-update.json") }
    private struct UpdateInfo: Codable { let sha: String; let size: Int64; let name: String; let strip: Int?; var verified: Bool }

    /// 已装模型的包指纹(模型目录里的 .installed)。
    nonisolated private static var installedModelSha: String? {
        modelDir.flatMap { try? String(contentsOf: $0.appendingPathComponent(".installed"), encoding: .utf8) }
    }

    private func readManifest() async throws -> Manifest {
        let base = ConfigStore.shared.current.eventSession.downloadBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let murl = URL(string: base.hasSuffix("/") ? base + "manifest.json" : base + "/manifest.json") else {
            throw Failure("The download location isn't set up yet.")
        }
        let (mdata, _) = try await URLSession.shared.data(for: URLRequest(url: murl, cachePolicy: .reloadIgnoringLocalCacheData))
        return try JSONDecoder().decode(Manifest.self, from: mdata)
    }

    /// 查下发清单里的模型和已装的是不是同一份;不同就记成有新版,`download` 时接着在后台下(不等它下完就返回)。
    /// 已经下好待换、或正在下的那一份就是清单里的,不重查。没装模型(还没 Set up)时不查。
    func checkModelUpdate(download: Bool) async {
        guard Self.modelDir != nil, phase != .working else { return }
        if case .downloading = modelUpdate { return }
        let before = modelUpdate
        modelUpdate = .checking
        do {
            let m = try await readManifest()
            guard let c = m.components["model"], let sha = c.sha256 else { modelUpdate = .upToDate; return }
            if sha == Self.installedModelSha {
                modelUpdate = .upToDate
                Self.dropUpdatePart()
                return
            }
            let name = c.name ?? "EventSession"
            if let info = Self.pendingUpdate(), info.sha == sha, info.verified {
                modelUpdate = .downloaded(name: name)
                return
            }
            modelUpdate = .available(name: name, size: c.size ?? 0)
            if download { downloadModelUpdate(c, sha: sha, name: name) }
        } catch {
            modelUpdate = before == .unknown || before == .checking ? .failed("Couldn't check for updates") : before
        }
    }

    /// 点 Download(或自动下载):后台下到 model-update.part,能接着上次的下;下完校验 sha。
    func downloadModelUpdate() {
        Task {
            guard let m = try? await readManifest(), let c = m.components["model"], let sha = c.sha256 else { return }
            downloadModelUpdate(c, sha: sha, name: c.name ?? "EventSession")
        }
    }

    private func downloadModelUpdate(_ c: Manifest.Component, sha: String, name: String) {
        guard updateJob == nil, let url = URL(string: c.url) else { return }
        modelUpdate = .downloading(name: name)
        updateJob = Task {
            defer { updateJob = nil; updateDownload = nil }
            do {
                try FileManager.default.createDirectory(at: Self.partsDir, withIntermediateDirectories: true)
                if Self.pendingUpdate()?.sha != sha { try? FileManager.default.removeItem(at: Self.updatePart) }   // 清单换了版本,旧的半截不能接
                var info = UpdateInfo(sha: sha, size: c.size ?? 0, name: name, strip: c.strip, verified: false)
                try JSONEncoder().encode(info).write(to: Self.updateInfo)
                let dl = RangeDownload(url: url, to: Self.updatePart, expected: c.size ?? 0)
                updateDownload = dl
                updateReceived = dl.existing
                updateExpected = c.size ?? 0
                try await dl.run { [weak self] got, total in
                    Task { @MainActor in
                        guard let self, case .downloading = self.modelUpdate else { return }
                        self.updateReceived = got
                        if total > 0 { self.updateExpected = total }
                    }
                }
                let got = try await off({ try Self.sha256(Self.updatePart) })
                guard got == sha else {
                    try? FileManager.default.removeItem(at: Self.updatePart)
                    modelUpdate = .failed("The update download is damaged. Try again.")
                    return
                }
                info.verified = true
                try JSONEncoder().encode(info).write(to: Self.updateInfo)
                modelUpdate = .downloaded(name: name)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    modelUpdate = .paused(name: name)
                } else {
                    modelUpdate = .failed("Couldn't download the update")
                }
            }
        }
    }

    /// Stop:停下后台下载,已下的字节留着,下次 Download / 自动下载接着下。
    func stopModelUpdate() {
        updateDownload?.cancel()
        updateJob?.cancel()
    }

    /// 下好、校验过的新模型换上(worker 在开跑前调,这时引擎没在跑):解进 models/,装好后删掉旧模型目录。回是否换了。
    func applyModelUpdate() async -> Bool {
        guard phase != .working, updateJob == nil, let info = Self.pendingUpdate(), info.verified else { return false }
        let unit = Self.modelsDir.appendingPathComponent(info.name, isDirectory: true)
        let old = Self.modelDir
        do {
            try? FileManager.default.removeItem(at: unit)
            var args = ["-xf", Self.updatePart.path, "-C", Self.modelsDir.path]
            if let s = info.strip, s > 0 { args.append("--strip-components=\(s)") }
            let tarArgs = args
            try await off { try Self.run("/usr/bin/tar", tarArgs) }
            try info.sha.write(to: unit.appendingPathComponent(".installed"), atomically: true, encoding: .utf8)
            if let old, old.standardizedFileURL != unit.standardizedFileURL { try? FileManager.default.removeItem(at: old) }
            Self.dropUpdatePart()
            modelUpdate = .upToDate
            return true
        } catch {
            modelUpdate = .failed("Couldn't install the update")
            return false
        }
    }

    nonisolated private static func pendingUpdate() -> UpdateInfo? {
        try? JSONDecoder().decode(UpdateInfo.self, from: Data(contentsOf: updateInfo))
    }

    nonisolated private static func dropUpdatePart() {
        try? FileManager.default.removeItem(at: updatePart)
        try? FileManager.default.removeItem(at: updateInfo)
    }

    private func install(local: Bool, gen: Int, keepModel: Bool = false) async {
        let base = ConfigStore.shared.current.eventSession.downloadBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let murl = URL(string: base.hasSuffix("/") ? base + "manifest.json" : base + "/manifest.json") else {
            phase = .failed("The download location isn't set up yet.")
            return
        }
        do {
            set(0, "Reading the download list")
            // 清单不走缓存:同一个地址,内容随新版变
            let (mdata, _) = try await URLSession.shared.data(for: URLRequest(url: murl, cachePolicy: .reloadIgnoringLocalCacheData))
            let m = try JSONDecoder().decode(Manifest.self, from: mdata)
            try FileManager.default.createDirectory(at: Self.partsDir, withIntermediateDirectories: true)

            guard let py = m.components["python"], let engine = m.components["engine"] else {
                throw Failure("The download list is incomplete.")
            }
            try alive(gen)
            try await component("python", py, step: 0, label: "Python", gen: gen)
            let engineChanged = try await component("engine", engine, step: 2, label: "the engine", gen: gen)
            let pipMark = Self.root.appendingPathComponent("engine/.pip-installed")
            if engineChanged || !FileManager.default.fileExists(atPath: pipMark.path) {
                set(1, "Installing packages")
                let lock = Self.root.appendingPathComponent("engine/requirements.lock").path
                try await off { try Self.run(Self.python.path, ["-m", "pip", "install", "--disable-pip-version-check", "--no-deps", "-r", lock]) }
                try alive(gen)
                FileManager.default.createFile(atPath: pipMark.path, contents: Data())
            }
            try alive(gen)
            if let c = m.components["rime"], try await off({ try Self.needsRime() }) {
                try await component("rime", c, step: 3, label: "the input-method dictionary", gen: gen)
            }
            if local, !(keepModel && Self.modelDir != nil) {
                guard let c = m.components["model"] else { throw Failure("The download list has no model.") }
                try await component("model", c, step: 4, label: "the model", gen: gen)
            }
            try alive(gen)
            expected = 0
            phase = Self.isReady(local: local) ? .ready : .failed("Setup finished, but something is missing.")
        } catch {
            guard gen == generation else { return }            // 被 Stop / 新一轮取代:状态归新的那轮管
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = .paused
                return
            }
            phase = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    private func set(_ step: Int, _ text: String) {
        stepIndex = step
        stepText = text
    }

    /// 一个包:装过同一份(.installed 里的 sha 对得上)就跳过,回 false;否则下载 → 校验 → 解包,回 true。
    @discardableResult
    private func component(_ name: String, _ c: Manifest.Component, step: Int, label: String, gen: Int) async throws -> Bool {
        // 解到哪:模型解进共用的 models/,其余解进 runtime 下各自的目录;unit = 这个包自己的目录(装前只删它)
        let dest = name == "model" ? Self.modelsDir : Self.root.appendingPathComponent(c.dest, isDirectory: true)
        let unit = c.name.map { dest.appendingPathComponent($0, isDirectory: true) } ?? dest
        let mark = unit.appendingPathComponent(".installed")
        let want = c.sha256 ?? c.url
        if (try? String(contentsOf: mark, encoding: .utf8)) == want { return false }
        // 早先装的没有 .installed:Python / 词库 / 模型已经能用就认下,不重下(引擎每版都换,照常更新)
        if !FileManager.default.fileExists(atPath: mark.path), FileManager.default.fileExists(atPath: unit.path), Self.looksInstalled(name) {
            try want.write(to: mark, atomically: true, encoding: .utf8)
            return false
        }
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
        try alive(gen)

        if let sha = c.sha256 {
            set(step, "Checking \(label)")
            let got = try await off({ try Self.sha256(part) })
            try alive(gen)
            guard got == sha else {
                try? FileManager.default.removeItem(at: part)
                throw Failure("The \(name) download is damaged. Try again.")
            }
        }
        set(step, "Unpacking \(label)")
        try? FileManager.default.removeItem(at: unit)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var args = ["-xf", part.path, "-C", dest.path]
        if let s = c.strip, s > 0 { args.append("--strip-components=\(s)") }
        let tarArgs = args
        try await off { try Self.run("/usr/bin/tar", tarArgs) }
        try alive(gen)
        try want.write(to: mark, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: Self.partsDir.appendingPathComponent("\(name).json"))
        return true
    }

    private struct PartInfo: Codable { let sha: String; let size: Int64 }

    nonisolated private static func looksInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        switch name {
        case "python": return fm.isExecutableFile(atPath: python.path)
        case "rime": return fm.isExecutableFile(atPath: rimeDir.appendingPathComponent("cands").path)
        case "model": return modelDir != nil
        default: return false
        }
    }

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
