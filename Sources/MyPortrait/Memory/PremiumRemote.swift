import CryptoKit
import Foundation
import IOKit
import os.log

private let remoteLog = Logger(subsystem: "com.myportrait.memory", category: "premium-remote")

/// Premium 收件服务的客户端 + 本机上传台账。
///
/// 服务地址在 config `[premium] server_url`(空 = `defaultServer`:打包时从 Info.plist 的
/// `PremiumServerURL` 来,值写在不进 git 的 `Support/Premium.local.xcconfig`;开源构建里是空的),密钥在
/// SecretStore `premium.key`。接口:`GET /v1/health`、`GET /v1/me`、
/// `PUT /v1/bundles/<id>`(tar.gz + `X-Content-SHA256`)、`GET /v1/bundles/<id>`、
/// `GET /v1/bundles/<id>/result`、`POST /v1/bundles/<id>/ack`,鉴权 `Authorization: Bearer <密钥>`,
/// 外加 `X-MP-Names`(Personal Info 的名字)和 `X-MP-Device`(`deviceId`):服务器要求其中一个名字
/// 等于密钥登记的名字,并把密钥绑在第一次连上的那台 Mac 上。
///
/// 台账 `<数据根>/.staging/premium_remote.json`:每个上传过、还没导入完的包一条
/// (`pending_upload` → 服务端的 queued / running / done / failed / superseded / cancelled),
/// 每次检查按服务端刷新;导入并确认后删掉那一条。包文件在 `.staging/premium_upload/`,
/// 下载的结果在 `.staging/premium_download/`。
enum PremiumRemote {

    static var defaultServer: String {
        ((Bundle.main.object(forInfoDictionaryKey: "PremiumServerURL") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let keyRef = "premium.key"

    /// 这台 Mac 的设备 id:硬件 UUID 加前缀后的 sha256(不发原值)。重装 app、清数据都不变。
    static let deviceId: String = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(svc) }
        let uuid = IORegistryEntryCreateCFProperty(svc, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
        guard !uuid.isEmpty else { return "" }
        return SHA256.hash(data: Data("my-portrait-premium:\(uuid)".utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    static let statusPendingUpload = "pending_upload"
    static let statusImportFailed = "import_failed"
    /// 在路上的包:发出了(或在等上传)、结果还没导入。merged = 并进同一个用户较新的那个包处理,跟着它的结果一起导入。
    static let outstandingStatuses: Set<String> = [statusPendingUpload, "queued", "running", "done", "merged"]

    // MARK: - 配置

    /// nil = 没有地址(config 没填、包里也没带)或不是 http(s) 地址。
    static func serverURL(_ cfg: PremiumConfig) -> URL? {
        let raw = cfg.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: raw.isEmpty ? defaultServer : raw), ["https", "http"].contains(u.scheme) else { return nil }
        return u
    }

    static func key() -> String? {
        SecretStore.shared.get(keyRef).flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 测试注入的假服务;nil = 真的 HTTP。
    nonisolated(unsafe) static var transportOverride: (any Transport)?

    /// nil = 没填密钥或地址不对。
    static func transport(_ cfg: PremiumConfig) -> (any Transport)? {
        if let t = transportOverride { return t }
        guard let base = serverURL(cfg), let key = key() else { return nil }
        return HTTPTransport(base: base, key: key, names: ConfigStore.snapshot.personalNames, device: deviceId)
    }

    // MARK: - 服务端

    struct BundleStatus: Codable, Sendable, Equatable {
        var bundleId: String
        var status: String
        var ahead: Int?
        var stage: String?
        var summary: String?
        var resultSha256: String?
        var mergedInto: String?

        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case status, ahead, stage, summary
            case resultSha256 = "result_sha256"
            case mergedInto = "merged_into"
        }
    }

    struct Me: Codable, Sendable {
        var user: String
        var bundles: [BundleStatus]
    }

    struct RemoteError: LocalizedError, Sendable {
        let message: String
        /// HTTP 状态码;nil = 没连上。
        var code: Int?
        var errorDescription: String? { message }
    }

    protocol Transport: Sendable {
        func health() async throws
        func me() async throws -> Me
        func upload(bundleId: String, file: URL, sha256: String) async throws -> BundleStatus
        func status(bundleId: String) async throws -> BundleStatus
        /// 存到 `to`,返回响应头 `X-Content-SHA256`。
        func download(bundleId: String, to: URL) async throws -> String
        func ack(bundleId: String) async throws
    }

    struct HTTPTransport: Transport {
        let base: URL
        let key: String
        let names: [String]
        let device: String

        private static let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 900
            return URLSession(configuration: c)
        }()

        private func request(_ method: String, _ path: String, auth: Bool = true) -> URLRequest {
            var r = URLRequest(url: base.appendingPathComponent(path))
            r.httpMethod = method
            if auth {
                r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                // 名字可能是中文,头里放 JSON 数组的 base64。
                let json = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
                r.setValue(json.base64EncodedString(), forHTTPHeaderField: "X-MP-Names")
                r.setValue(device, forHTTPHeaderField: "X-MP-Device")
            }
            return r
        }

        private static func check(_ data: Data, _ resp: URLResponse) throws {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw RemoteError(message: msg ?? "HTTP \(code)", code: code)
            }
        }

        private static func send(_ r: URLRequest, body: URL? = nil) async throws -> Data {
            do {
                let (data, resp): (Data, URLResponse)
                if let body { (data, resp) = try await session.upload(for: r, fromFile: body) } else {
                    (data, resp) = try await session.data(for: r)
                }
                try check(data, resp)
                return data
            } catch let e as URLError {
                throw RemoteError(message: e.localizedDescription)
            }
        }

        func health() async throws { _ = try await Self.send(request("GET", "v1/health", auth: false)) }

        func me() async throws -> Me {
            try JSONDecoder().decode(Me.self, from: try await Self.send(request("GET", "v1/me")))
        }

        func upload(bundleId: String, file: URL, sha256: String) async throws -> BundleStatus {
            var r = request("PUT", "v1/bundles/\(bundleId)")
            r.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
            r.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            return try JSONDecoder().decode(BundleStatus.self, from: try await Self.send(r, body: file))
        }

        func status(bundleId: String) async throws -> BundleStatus {
            try JSONDecoder().decode(BundleStatus.self,
                                     from: try await Self.send(request("GET", "v1/bundles/\(bundleId)")))
        }

        func download(bundleId: String, to: URL) async throws -> String {
            let r = request("GET", "v1/bundles/\(bundleId)/result")
            let tmp: URL, resp: URLResponse
            do { (tmp, resp) = try await Self.session.download(for: r) } catch let e as URLError {
                throw RemoteError(message: e.localizedDescription)
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                try? FileManager.default.removeItem(at: tmp)
                throw RemoteError(message: "result download HTTP \(code)", code: code)
            }
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: to)
            return (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Content-SHA256") ?? ""
        }

        func ack(bundleId: String) async throws {
            _ = try await Self.send(request("POST", "v1/bundles/\(bundleId)/ack"))
        }
    }

    /// 发不发得出去:nil = 能(地址通、密钥有效),否则是原因。
    static func unreachableReason(_ cfg: PremiumConfig) async -> String? {
        guard let t = transport(cfg) else { return serverURL(cfg) == nil ? "no Premium server address" : "no Premium key" }
        do { _ = try await t.me(); return nil } catch { return error.localizedDescription }
    }

    // MARK: - 本机台账

    struct Upload: Codable, Sendable, Equatable {
        var bundleId: String
        var trigger: String
        var chains: [String]
        var createdAt: String
        var status: String
        var ahead: Int?
        var stage: String?
        var summary: String?
        var resultSha256: String?
        /// 包里的区间 id(在路上时不再发)。
        var intervals: [String]?
        /// status = merged 时:并进了哪个包(跟着它的结果一起导入、一起删)。
        var mergedInto: String?

        init(bundleId: String, trigger: String, chains: [String], createdAt: String, status: String,
             intervals: [String]? = nil) {
            self.bundleId = bundleId; self.trigger = trigger; self.chains = chains
            self.createdAt = createdAt; self.status = status; self.intervals = intervals
        }

        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case trigger, chains, status, ahead, stage, summary, intervals
            case createdAt = "created_at"
            case resultSha256 = "result_sha256"
            case mergedInto = "merged_into"
        }
    }

    struct Event: Codable, Sendable, Equatable {
        var bundleId: String
        var at: String
        var outcome: String
        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case at, outcome
        }
    }

    struct State: Codable, Sendable {
        var uploads: [Upload] = []
        var lastExport: Event?
        var lastImport: Event?
        /// 最近一次打包时区间台账的截止点(`event_intervals` 的 MAX(end_ms));之后又封了区间才再发包。
        var lastExportCutMs: Int64?

        enum CodingKeys: String, CodingKey {
            case uploads
            case lastExport = "last_export"
            case lastImport = "last_import"
            case lastExportCutMs = "last_export_cut_ms"
        }

        /// 在路上的包里的区间(不再发)。
        var sentIntervals: Set<String> {
            Set(uploads.filter { PremiumRemote.outstandingStatuses.contains($0.status) }.flatMap { $0.intervals ?? [] })
        }

        /// 导入了 `id` 的结果(或它在服务端失败了):删掉它和并进它的包。
        mutating func drop(_ id: String) {
            uploads.removeAll { $0.bundleId == id || $0.mergedInto == id }
        }
    }

    static func stagingDir(_ root: URL) -> URL { root.appendingPathComponent(".staging", isDirectory: true) }
    static func stateURL(_ root: URL) -> URL { stagingDir(root).appendingPathComponent("premium_remote.json") }
    static func uploadDir(_ root: URL) -> URL { stagingDir(root).appendingPathComponent("premium_upload", isDirectory: true) }
    static func downloadDir(_ root: URL) -> URL { stagingDir(root).appendingPathComponent("premium_download", isDirectory: true) }
    static func archiveURL(_ root: URL, _ id: String) -> URL { uploadDir(root).appendingPathComponent("\(id).tar.gz") }

    private static let stateLock = NSLock()

    static func readState(_ root: URL) -> State {
        guard let d = try? Data(contentsOf: stateURL(root)),
              let s = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return s
    }

    /// 读改写(进程内串行;跨进程由调用方持交换锁或只改自己那一条)。
    @discardableResult
    static func updateState(_ root: URL, _ block: (inout State) -> Void) -> State {
        stateLock.lock(); defer { stateLock.unlock() }
        var s = readState(root)
        block(&s)
        do { try PremiumExchange.writeAtomic(try PremiumExchange.encoder().encode(s), to: stateURL(root)) } catch {
            remoteLog.error("state write failed: \(error.localizedDescription, privacy: .public)")
        }
        return s
    }

    // MARK: - 打包 / 解包(/usr/bin/tar)

    static func runTar(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RemoteError(message: "tar \(args.first ?? "") failed: \(msg.prefix(300))")
        }
    }

    /// 包目录的内容(根目录即包本身)打成 tar.gz。
    static func pack(_ dir: URL, to archive: URL) throws {
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: archive)
        try runTar(["-czf", archive.path, "--no-mac-metadata", "--no-xattrs", "-C", dir.path, "."])
    }

    static func unpack(_ archive: URL, into dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runTar(["-xzf", archive.path, "-C", dir.path])
    }

    // MARK: - 上传

    /// 把台账里 `pending_upload` 的包传上去(不持锁:网络慢不挡别的活)。失败留着,下一次检查再传。
    static func flushUploads(root: URL, cfg: PremiumConfig) async {
        let pending = readState(root).uploads.filter { $0.status == statusPendingUpload }
        guard !pending.isEmpty else { return }
        guard let t = transport(cfg) else {
            remoteLog.notice("upload skipped: no Premium key")
            return
        }
        for u in pending {
            let file = archiveURL(root, u.bundleId)
            guard let sha = PremiumExchange.fileSHA(file) else {
                remoteLog.error("upload \(u.bundleId, privacy: .public): archive missing — dropped")
                updateState(root) { s in s.uploads.removeAll { $0.bundleId == u.bundleId } }
                continue
            }
            do {
                let r = try await t.upload(bundleId: u.bundleId, file: file, sha256: sha)
                try? FileManager.default.removeItem(at: file)
                updateState(root) { s in
                    if let i = s.uploads.firstIndex(where: { $0.bundleId == u.bundleId }) {
                        s.uploads[i].status = r.status
                        s.uploads[i].ahead = r.ahead
                    }
                }
                remoteLog.notice("uploaded \(u.bundleId, privacy: .public): \(r.status, privacy: .public)")
            } catch let e as RemoteError where e.code.map({ (400..<500).contains($0) && $0 != 429 }) == true {
                // 服务端明确不收(格式、大小、id 冲突):留着也传不上去,删掉,下一次检查按台账重新导出。
                remoteLog.error("upload \(u.bundleId, privacy: .public) rejected: \(e.message, privacy: .public)")
                try? FileManager.default.removeItem(at: file)
                updateState(root) { s in
                    s.uploads.removeAll { $0.bundleId == u.bundleId }
                    s.lastExport = Event(bundleId: u.bundleId, at: PremiumExchange.isoNow(), outcome: "rejected: \(e.message)")
                }
            } catch {
                remoteLog.notice("upload \(u.bundleId, privacy: .public) failed, retry next check: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 按服务端刷新台账里已上传的包的状态;服务端没有了(404)的删掉。网络不通就不动。
    static func refresh(root: URL, cfg: PremiumConfig) async {
        let ids = readState(root).uploads.filter { ["queued", "running", "done"].contains($0.status) }.map(\.bundleId)
        guard !ids.isEmpty, let t = transport(cfg) else { return }
        for id in ids {
            do {
                let r = try await t.status(bundleId: id)
                updateState(root) { s in
                    guard let i = s.uploads.firstIndex(where: { $0.bundleId == id }) else { return }
                    s.uploads[i].status = r.status
                    s.uploads[i].ahead = r.ahead
                    s.uploads[i].stage = r.stage
                    s.uploads[i].summary = r.summary
                    s.uploads[i].resultSha256 = r.resultSha256
                    s.uploads[i].mergedInto = r.mergedInto
                    if ["superseded", "cancelled"].contains(r.status) { s.uploads.remove(at: i) }
                }
            } catch let e as RemoteError where e.code == 404 {
                remoteLog.notice("\(id, privacy: .public) unknown to Premium — dropped")
                updateState(root) { s in s.uploads.removeAll { $0.bundleId == id } }
            } catch {
                remoteLog.info("status \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    // MARK: - Connections 卡片 / Detect

    struct Status: Sendable {
        var server: String
        var hasKey: Bool
        /// nil = 地址通、密钥有效;否则是原因。
        var problem: String?
        var user: String?
        var state: State

        var healthy: Bool { problem == nil }
    }

    static func probe(_ cfg: PremiumConfig, root: URL = Storage.rootURL) async -> Status {
        let server = serverURL(cfg)?.absoluteString ?? cfg.serverURL
        var st = Status(server: server, hasKey: key() != nil, problem: nil, user: nil, state: readState(root))
        guard let t = transport(cfg) else {
            st.problem = serverURL(cfg) == nil ? "no server address" : "no key"
            return st
        }
        do {
            try await t.health()
            st.user = try await t.me().user
        } catch {
            st.problem = error.localizedDescription
        }
        return st
    }
}
