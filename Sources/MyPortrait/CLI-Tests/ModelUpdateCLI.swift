import Foundation

/// EventSession 本机模型更新的自检(`EventSessionInstaller` 的 checkModelUpdate / downloadModelUpdate /
/// applyModelUpdate)。只在临时数据根上跑:必须设 `CFFIXED_USER_HOME` 指到一个空的临时目录,否则拒绝执行。
/// 下发清单和模型包由本机起的一个临时 HTTP 服务提供(系统 python3 的 http.server,跑完按句柄结束)。
/// 覆盖:已装的和清单是同一份 → 已是最新;清单换了模型 → 查到新版、下载、校验、换上并删掉旧模型目录、
/// 删掉下载的包;包的指纹对不上 → 报下载损坏、不动已装的模型。
///
///   CFFIXED_USER_HOME=$(mktemp -d .build/muhome.XXXX) .build/debug/MyPortrait --model-update-selftest
@MainActor
enum ModelUpdateSelfTest {

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    static func run() {
        Task { @MainActor in
            var server: Process?
            do {
                server = try await runImpl()
                print(failures == 0 ? "[model-update-selftest] ALL PASS" : "[model-update-selftest] \(failures) FAILURE(S)")
            } catch {
                fputs("[model-update-selftest] ERROR: \(error.localizedDescription)\n", stderr)
                failures += 1
            }
            server?.terminate()
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// 数据根必须在 CFFIXED_USER_HOME 下,且不是本机用户真实的 ~/.portrait。
    private static func tempRootOK() -> Bool {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else { return false }
        let root = Storage.rootURL.standardizedFileURL.path
        let fixed = URL(fileURLWithPath: home).standardizedFileURL.path
        guard root.hasPrefix(fixed + "/") else { return false }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let real = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent(".portrait").standardizedFileURL.path
            if root == real { return false }
        }
        return true
    }

    @discardableResult
    private static func sh(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\(exe) failed") }
        return String(decoding: data, as: UTF8.self)
    }

    /// 模型包:<名>/eventsession.json + 一个占位权重文件,打成 tar.gz;回 (包, sha256, 字节数)。
    private static func makeModel(_ name: String, in dir: URL) throws -> (URL, String, Int64) {
        let build = dir.appendingPathComponent("build-\(name)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("{\"name\": \"\(name)\"}".utf8).write(to: build.appendingPathComponent("eventsession.json"))
        try Data(repeating: 7, count: 300_000).write(to: build.appendingPathComponent("weights.bin"))
        let tgz = dir.appendingPathComponent("\(name).tar.gz")
        try sh("/usr/bin/tar", ["-czf", tgz.path, "-C", build.deletingLastPathComponent().path, name])
        let sha = try sh("/usr/bin/shasum", ["-a", "256", tgz.path]).split(separator: " ").first.map(String.init) ?? ""
        let size = (try FileManager.default.attributesOfItem(atPath: tgz.path)[.size] as? Int64) ?? 0
        return (tgz, sha, size)
    }

    private static func writeManifest(_ dir: URL, url: String, sha: String, size: Int64, name: String) throws {
        let m: [String: Any] = ["components": ["model": ["url": url, "sha256": sha, "size": size, "dest": "models", "name": name]]]
        try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("manifest.json"))
    }

    private static func waitFor(_ cond: () -> Bool) async {
        for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    private static func runImpl() async throws -> Process {
        guard tempRootOK() else { throw Failure("set CFFIXED_USER_HOME to an empty temp directory") }
        let fm = FileManager.default
        let srv = Storage.rootURL.deletingLastPathComponent().appendingPathComponent("srv", isDirectory: true)
        try fm.createDirectory(at: srv, withIntermediateDirectories: true)
        let port = Int.random(in: 20_000..<40_000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", srv.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        try await Task.sleep(nanoseconds: 800_000_000)
        let base = "http://127.0.0.1:\(port)"
        ConfigStore.shared.mutate { $0.eventSession.downloadBase = base }

        // 已装的旧模型(和 Set up 装出来的一样:models/<名>/ + .installed 记包指纹)
        let (oldPkg, oldSha, oldSize) = try makeModel("EventSession-old", in: srv)
        try fm.createDirectory(at: Storage.modelsDir, withIntermediateDirectories: true)
        try sh("/usr/bin/tar", ["-xzf", oldPkg.path, "-C", Storage.modelsDir.path])
        let oldDir = Storage.modelsDir.appendingPathComponent("EventSession-old")
        try oldSha.write(to: oldDir.appendingPathComponent(".installed"), atomically: true, encoding: .utf8)
        let inst = EventSessionInstaller.shared

        print("1. 清单和已装的是同一份")
        try writeManifest(srv, url: "\(base)/EventSession-old.tar.gz", sha: oldSha, size: oldSize, name: "EventSession-old")
        await inst.checkModelUpdate(download: false)
        check(inst.modelUpdate == .upToDate, "已是最新")

        print("2. 清单换了模型:查到 → 下载 → 换上")
        let (_, newSha, newSize) = try makeModel("EventSession-new", in: srv)
        try writeManifest(srv, url: "\(base)/EventSession-new.tar.gz", sha: newSha, size: newSize, name: "EventSession-new")
        await inst.checkModelUpdate(download: false)
        check(inst.modelUpdate == .available(name: "EventSession-new", size: newSize), "查到新版,不自动下(Auto-check)")
        check(fm.fileExists(atPath: oldDir.path) && EventSessionInstaller.modelDir?.lastPathComponent == "EventSession-old",
              "只查不下时旧模型照常在用")
        inst.downloadModelUpdate()
        await waitFor { if case .downloaded = inst.modelUpdate { return true }; return false }
        check(inst.modelUpdate == .downloaded(name: "EventSession-new"), "后台下好、校验过")
        check(EventSessionInstaller.modelDir?.lastPathComponent == "EventSession-old", "下好后、换上前仍用旧模型")
        let swapped = await inst.applyModelUpdate()
        let newDir = Storage.modelsDir.appendingPathComponent("EventSession-new")
        check(swapped && EventSessionInstaller.modelDir?.standardizedFileURL == newDir.standardizedFileURL, "换上新模型")
        check(!fm.fileExists(atPath: oldDir.path), "旧模型目录删掉")
        check((try? String(contentsOf: newDir.appendingPathComponent(".installed"), encoding: .utf8)) == newSha, "新模型记下包指纹")
        check(!fm.fileExists(atPath: EventSessionInstaller.partsDir.appendingPathComponent("model-update.part").path), "下载的包删掉")
        check(inst.modelUpdate == .upToDate, "状态回到已是最新")
        await inst.checkModelUpdate(download: true)
        check(inst.modelUpdate == .upToDate, "再查:已是最新,不重下")

        print("3. 包的指纹对不上")
        let (_, nextSha, nextSize) = try makeModel("EventSession-next", in: srv)
        try writeManifest(srv, url: "\(base)/EventSession-next.tar.gz", sha: String(nextSha.reversed()), size: nextSize, name: "EventSession-next")
        await inst.checkModelUpdate(download: true)        // 自动下载档:查到就下
        await waitFor { if case .failed = inst.modelUpdate { return true }; return false }
        check(inst.modelUpdate == .failed("The update download is damaged. Try again."), "报下载损坏")
        let applied = await inst.applyModelUpdate()
        check(!applied && EventSessionInstaller.modelDir?.lastPathComponent == "EventSession-new", "已装的模型不动")
        return server
    }
}
