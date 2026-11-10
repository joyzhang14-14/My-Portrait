import Foundation
import GRDB
import Observation
import os.log

/// EventSession 运行(workflow 第 1 层):每分钟查一次闸,能跑就拉起引擎子进程(Python,`engine.py`),
/// 一批最多 `chunkSessions` 个会话就让它退出、下一批重拉(本机 MLX 长跑会触发显卡驱动 panic)。
/// 本机模型的闸:开关开着、东西装齐;插电,且按运行时间档(charging / charging_idle,内存 < 20 GB 的机器只有后者);
/// 内存压力正常、可回收内存 ≥ `needBytes`;温度没到 serious、不在低电量模式;延后 OCR 不在跑(一次只跑一个重活)。
/// 云端 provider:引擎每要调一次模型就发 `llm` 请求,这里用 Connections 里连好的服务调(`EventSessionCloud`),
/// 把回复交回引擎;运行时间档多一个 packed(一天过完、电脑醒着就跑,不看电源),不看内存。
/// provider 选 Premium:本机不跑,交给 Premium 的打包上传(`PremiumConfig.eventSession` 跟着开)。
/// 没有过完、还没做的天就不起引擎;引擎回 idle(那天 OCR 还没补完)后 15 分钟内不再起。
/// 结果写 `~/.portrait/eventsession/session.sqlite` 的 event_sessions。引擎卡住 `watchdog` 秒没出声就结束它(按 Process 句柄,不按名字)。
actor EventSessionWorker {
    static let shared = EventSessionWorker()

    private let log = Logger(subsystem: "com.myportrait.eventsession", category: "worker")
    private let chunkSessions = 10
    private let needBytes: UInt64 = 10 * 1024 * 1024 * 1024
    private let watchdog: TimeInterval = 1800
    private var pool: DatabasePool?
    private var loop: Task<Void, Never>?
    private var awake = false
    private var idleUntil = Date.distantPast

    func start() {
        guard loop == nil else { return }
        do {
            pool = try DBPools.openPool(path: Storage.eventSessionDBPath, kind: .eventSession)
        } catch {
            log.error("eventsession db open failed: \(error.localizedDescription, privacy: .public)")
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func tick() async {
        guard let reason = await gate() else {
            let since = await MainActor.run { ConfigStore.shared.current.eventSession.sinceMs }
            guard Date() >= idleUntil, Self.hasPendingDay(sinceMs: since) else {
                await setStatus(running: false, waiting: "Up to date")
                return
            }
            await setStatus(running: true, waiting: nil)
            await holdAwake(true)
            await runChunk()
            await holdAwake(false)
            MemoryTrim.ifHidden()
            await setStatus(running: false, waiting: nil)
            return
        }
        await setStatus(running: false, waiting: reason)
    }

    /// 能跑回 nil,不能跑回原因(给设置页看)。
    private func gate() async -> String? {
        let es = await MainActor.run { ConfigStore.shared.current.eventSession }
        guard es.enabled else { return "Off" }
        if es.source == Provider.premium.rawValue { return "Handled by My Portrait Premium" }
        let elig = EventSessionEligibility.current
        if es.isLocal, elig == .notEligible { return "This Mac doesn't support the local model" }
        guard EventSessionInstaller.isReady(local: es.isLocal) else { return "Waiting for setup" }
        let mode = es.isLocal && elig == .idleOnly ? .chargingIdle : es.powerMode
        if mode != .packed {
            guard PowerMonitor.isOnAC else { return "Waiting for the charger" }
            if mode == .chargingIdle, !PowerMonitor.isIdle { return "Waiting until the screen isn't in use" }
        }
        let snap = PowerMonitor.snapshot()
        if es.isLocal, snap.isLowPowerMode { return "Low Power Mode is on" }
        if snap.thermalState == .serious || snap.thermalState == .critical { return "The Mac is too hot" }
        if es.isLocal {
            if let level = SystemMemory.pressureLevel(), level > 1 { return "Memory pressure is high" }
            guard let avail = SystemMemory.availableBytes(), avail >= needBytes else { return "Not enough free memory" }
        }
        if await MainActor.run(body: { DeferredOCRStatus.shared.running }) { return "Waiting for screen text recognition" }
        return nil
    }

    /// 一批:拉起引擎 → run → 收结果,直到 chunk_done / idle / stopped / error 或看门狗到点。
    private func runChunk() async {
        let es = await MainActor.run { ConfigStore.shared.current.eventSession }
        let cloud = es.isLocal ? nil : Provider(rawValue: es.source)
        let model = EventSessionInstaller.modelDir
        guard cloud != nil || model != nil else { return }
        let cloudModel = cloud.map { es.model.isEmpty ? $0.defaultModel : es.model } ?? ""
        let p = Process()
        p.executableURL = Self.launcher()
        p.arguments = [EventSessionInstaller.engineDir.appendingPathComponent("engine.py").path]
        let work = Storage.pipelineDir.appendingPathComponent("eventsession", isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["MP_ES_WORK"] = work.path
        env["PORTRAIT_ROOT"] = Storage.rootURL.path
        env["PORTRAIT_KEYS_OUT"] = work.appendingPathComponent("keys").path
        env["PORTRAIT_DB_DIR"] = EventSessionInstaller.root.appendingPathComponent("engine").path
        env["MP_FRAME_EXTRACTOR"] = Bundle.main.executablePath ?? ""
        env["PYTHONNOUSERSITE"] = "1"
        if FileManager.default.fileExists(atPath: EventSessionInstaller.rimeDir.path) {
            env["PORTRAIT_RIME_DIR"] = EventSessionInstaller.rimeDir.path
        }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch {
            log.error("engine launch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var cfg: [String: Any] = ["since_ms": es.sinceMs, "budget": es.frameBudget,
                                  "dial_max": es.dialMax, "dial_min": EventSessionConfig.dialMin]
        if let cloud { cfg["cloud"] = "\(cloud.rawValue)/\(cloudModel)" } else if let model { cfg["model"] = model.path }
        let cmd: [String: Any] = ["cmd": "run", "cfg": cfg, "max_sessions": chunkSessions]
        if let data = try? JSONSerialization.data(withJSONObject: cmd) {
            inPipe.fileHandleForWriting.write(data + Data("\n".utf8))
        }
        let modelName = cloud.map { "\($0.rawValue)/\(cloudModel)" }
            ?? (model.flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0.appendingPathComponent("eventsession.json"))) }
                as? [String: Any])?["name"] as? String ?? model?.lastPathComponent ?? ""
        var last = Date()
        let dog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Date().timeIntervalSince(last) > watchdog, p.isRunning { p.terminate() }
            }
        }
        for await line in Self.lines(outPipe.fileHandleForReading) {
            last = Date()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ev = obj["event"] as? String else { continue }
            switch ev {
            case "session":
                if let rec = obj["record"] as? [String: Any] { store(rec, model: modelName) }
            case "plan", "day_plan":
                await setPlan(obj)
            case "llm":
                guard let cloud, let id = obj["id"] as? Int else { break }
                var reply: [String: Any] = ["cmd": "llm_result", "id": id]
                do {
                    reply["text"] = try await EventSessionCloud.ask(provider: cloud, model: cloudModel, text: obj["text"] as? String ?? "")
                } catch {
                    reply["error"] = error.localizedDescription
                    log.error("cloud call failed: \(error.localizedDescription, privacy: .public)")
                }
                if let data = try? JSONSerialization.data(withJSONObject: reply) {
                    inPipe.fileHandleForWriting.write(data + Data("\n".utf8))
                }
            case "idle":
                idleUntil = Date().addingTimeInterval(15 * 60)
                inPipe.fileHandleForWriting.closeFile()
            case "chunk_done", "stopped":
                inPipe.fileHandleForWriting.closeFile()
            case "error":
                log.error("engine error: \(String(describing: obj["message"]), privacy: .public)")
                inPipe.fileHandleForWriting.closeFile()
            default:
                break
            }
            if await gate() != nil, ["progress"].contains(ev) {
                inPipe.fileHandleForWriting.write(Data("{\"cmd\": \"stop\"}\n".utf8))   // 用户回来了:手上这个会话做完就停
            }
        }
        dog.cancel()
        p.waitUntilExit()
    }

    private func store(_ rec: [String: Any], model: String) {
        guard let pool, let data = try? JSONSerialization.data(withJSONObject: rec),
              let day = rec["day"] as? String else { return }
        let key = (rec["key"] as? Int) ?? (rec["start_ms"] as? Int) ?? 0
        let kind = rec["kind"] as? String ?? "summary"
        let segs = rec["segments"] as? [[Int]]
        let start = (rec["start_ms"] as? Int) ?? segs?.first?.first ?? 0
        let end = (rec["end_ms"] as? Int) ?? segs?.last?.last ?? start
        try? pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO event_sessions (day, session_key, kind, app, start_ms, end_ms, activity, record, model, created_at_ms)
                VALUES (:day, :key, :kind, :app, :start, :end, :activity, :record, :model, :now)
                """, arguments: ["day": day, "key": Int64(key), "kind": kind, "app": rec["app"] as? String,
                                 "start": Int64(start), "end": Int64(end), "activity": rec["activity"] as? String,
                                 "record": String(decoding: data, as: UTF8.self), "model": model,
                                 "now": Int64(Date().timeIntervalSince1970 * 1000)])
        }
    }

    /// 有没有已经过完、还没做的本地日(开启那天起到昨天,对照引擎记的 days_done)。没有就不起引擎。
    private static func hasPendingDay(sinceMs: Int64) -> Bool {
        guard sinceMs > 0 else { return false }
        let cal = Calendar.current
        let first = cal.startOfDay(for: Date(timeIntervalSince1970: Double(sinceMs) / 1000))
        let today = cal.startOfDay(for: Date())
        guard first < today else { return false }
        let state = Storage.pipelineDir.appendingPathComponent("eventsession/engine_state.json")
        let done = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: state))) as? [String: Any])?["days_done"] as? [String] ?? [])
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var d = first
        while d < today {
            if !done.contains(fmt.string(from: d)) { return true }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today
        }
        return false
    }

    /// 起引擎用的解释器:python3 复制成「MyPortrait EventSession」,活动监视器里显示这个名字而不是 python。
    private static func launcher() -> URL {
        let py = EventSessionInstaller.python
        let named = py.deletingLastPathComponent().appendingPathComponent("MyPortrait EventSession")
        let fm = FileManager.default
        if !fm.fileExists(atPath: named.path) {
            try? fm.copyItem(at: py.resolvingSymlinksInPath(), to: named)
        }
        return fm.isExecutableFile(atPath: named.path) ? named : py
    }

    private static func lines(_ h: FileHandle) -> AsyncStream<String> {
        AsyncStream { cont in
            Task.detached {
                do {
                    for try await line in h.bytes.lines { cont.yield(line) }
                } catch {}
                cont.finish()
            }
        }
    }

    private func holdAwake(_ on: Bool) async {
        guard on || awake else { return }
        awake = on
        await MainActor.run {
            let ac = PowerMonitor.isOnAC
            KeepAwakeAssertion.shared.set(on && ac, owner: "eventsession")
            SleepHelperClient.shared.setKeepAwake(on && ac && PowerMonitor.isLidClosed, owner: "eventsession")
        }
    }

    private func setStatus(running: Bool, waiting: String?) async {
        await MainActor.run {
            EventSessionStatus.shared.running = running
            EventSessionStatus.shared.waitingReason = waiting
        }
    }

    /// plan = 待处理的天;day_plan = 正在做的这天的减负方案(待看帧数 / 扔掉的会话 / 挑帧比例)。
    private func setPlan(_ obj: [String: Any]) async {
        let days = (obj["days"] as? [String])?.count
        let dayPlan = obj["event"] as? String == "day_plan"
        let frames = obj["frames"] as? Int ?? 0, shed = obj["shed"] as? Int ?? 0, dial = obj["dial"] as? Double ?? 0.5
        await MainActor.run {
            let st = EventSessionStatus.shared
            if let days { st.pendingDays = days }
            if dayPlan {
                st.pendingFrames = frames
                st.shedSessions = shed
                st.dial = dial
            }
        }
    }
}

/// EventSession 的运行状态,给设置页读。
@MainActor @Observable
final class EventSessionStatus {
    static let shared = EventSessionStatus()
    var running = false
    var waitingReason: String?
    var pendingDays = 0
    var pendingFrames = 0
    var shedSessions = 0
    var dial = 0.5
}

/// Timeline 的 Event session 卡读结果:和 [start, end] 重叠、最早开始的那条(总结优先,其次减负记录)。
enum EventSessionStore {
    static func text(start: Date, end: Date) -> String? {
        let path = Storage.eventSessionDBPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var cfg = Configuration()
        cfg.readonly = true
        guard let q = try? DatabaseQueue(path: path, configuration: cfg) else { return nil }
        let a = Int64(start.timeIntervalSince1970 * 1000), z = Int64(end.timeIntervalSince1970 * 1000)
        return try? q.read { db -> String? in
            guard try db.tableExists("event_sessions") else { return nil }
            let row = try Row.fetchOne(db, sql: """
                SELECT kind, activity, record FROM event_sessions
                WHERE kind IN ('summary', 'shed') AND start_ms <= :z AND end_ms >= :a
                ORDER BY kind = 'summary' DESC, start_ms LIMIT 1
                """, arguments: ["a": a, "z": z])
            guard let row else { return nil }
            if (row["kind"] as String?) == "summary" { return row["activity"] }
            let rec = (try? JSONSerialization.jsonObject(with: Data((row["record"] as String? ?? "").utf8))) as? [String: Any]
            let title = (rec?["window"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (rec?["url"] as? String) ?? ""
            return "Skipped — too much was waiting." + (title.isEmpty ? "" : " \(title)")
        }
    }
}

/// 云端 provider 回引擎的一次模型调用:一次一个 agent(同 memory 流水线的 oneshot 用法),收齐回复返回。
/// 题面里已写好截图路径,模型用自己的读文件工具去看图。
enum EventSessionCloud {
    static let timeout: TimeInterval = 900

    static func ask(provider: Provider, model: String, text: String) async throws -> String {
        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        try await agent.start()
        defer { agent.stop() }
        let reply = Reply()
        let consumer = Task { [events = agent.events] in
            for await e in events { await reply.handle(e) }
        }
        defer { consumer.cancel() }
        try agent.sendPrompt(text, id: UUID().uuidString)
        let out = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { await reply.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CloudError.timeout
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
        if let err = await reply.error, out.isEmpty { throw CloudError.failed(err) }
        return out
    }

    enum CloudError: LocalizedError {
        case timeout, failed(String)
        var errorDescription: String? {
            switch self {
            case .timeout: return "The cloud model didn't answer in time."
            case .failed(let m): return m
            }
        }
    }

    private actor Reply {
        private var buffer = ""
        private var waiter: CheckedContinuation<String, Never>?
        private var finished = false
        private(set) var error: String?

        func wait() async -> String {
            if finished { return buffer }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.finish() }
            }
        }

        func handle(_ e: PiAgent.Event) {
            switch e {
            case .textDelta(let d): buffer.append(d)
            case .assistantFinalText(let t): if buffer.isEmpty { buffer = t }
            case .agentEnd: finish()
            case .error(let m): error = m; finish()
            default: break
            }
        }

        func finish() {
            finished = true
            waiter?.resume(returning: buffer)
            waiter = nil
        }
    }
}

extension EventSessionConfig {
    /// EventSession 交给 Premium 时,按运行时间档决定这会儿能不能打包上传(packed 不看电源)。没交给 Premium 不拦。
    var premiumMayPack: Bool {
        guard enabled, source == Provider.premium.rawValue, powerMode != .packed else { return true }
        guard PowerMonitor.isOnAC else { return false }
        return powerMode == .charging || PowerMonitor.isIdle
    }
}
