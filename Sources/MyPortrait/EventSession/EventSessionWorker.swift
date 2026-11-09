import Foundation
import GRDB
import Observation
import os.log

/// EventSession 本机运行(workflow 第 1 层):每分钟查一次闸,能跑就拉起引擎子进程(Python,`engine.py`),
/// 一批最多 `chunkSessions` 个会话就让它退出、下一批重拉(本机 MLX 长跑会触发显卡驱动 panic)。
/// 闸:开关开着、模型来源是本机、东西装齐;插电,且按运行时间档(charging / charging_idle,内存 < 20 GB 的机器只有后者);
/// 内存压力正常、可回收内存 ≥ `needBytes`;温度没到 serious、不在低电量模式;延后 OCR 不在跑(一次只跑一个重活)。
/// 结果写 workflow.sqlite 的 event_sessions。引擎卡住 `watchdog` 秒没出声就结束它(按 Process 句柄,不按名字)。
actor EventSessionWorker {
    static let shared = EventSessionWorker()

    private let log = Logger(subsystem: "com.myportrait.eventsession", category: "worker")
    private let chunkSessions = 10
    private let needBytes: UInt64 = 10 * 1024 * 1024 * 1024
    private let watchdog: TimeInterval = 1800
    private var pool: DatabasePool?
    private var loop: Task<Void, Never>?
    private var awake = false

    func start(workflow: DatabasePool) {
        pool = workflow
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func tick() async {
        guard let reason = await gate() else {
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
        guard es.enabled, es.source == "local" else { return "Off" }
        let elig = EventSessionEligibility.current
        guard elig != .notEligible else { return "Not eligible on this Mac" }
        guard EventSessionInstaller.isReady else { return "Waiting for setup" }
        guard PowerMonitor.isOnAC else { return "Waiting for the charger" }
        if es.powerMode == .chargingIdle || elig == .idleOnly, !PowerMonitor.isIdle {
            return "Waiting until the screen isn't in use"
        }
        let snap = PowerMonitor.snapshot()
        if snap.isLowPowerMode { return "Low Power Mode is on" }
        if snap.thermalState == .serious || snap.thermalState == .critical { return "The Mac is too hot" }
        if let level = SystemMemory.pressureLevel(), level > 1 { return "Memory pressure is high" }
        guard let avail = SystemMemory.availableBytes(), avail >= needBytes else { return "Not enough free memory" }
        if await MainActor.run(body: { DeferredOCRStatus.shared.running }) { return "Waiting for screen text recognition" }
        return nil
    }

    /// 一批:拉起引擎 → run → 收结果,直到 chunk_done / idle / stopped / error 或看门狗到点。
    private func runChunk() async {
        guard let model = EventSessionInstaller.modelDir else { return }
        let es = await MainActor.run { ConfigStore.shared.current.eventSession }
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
        let cfg: [String: Any] = ["model": model.path, "since_ms": es.sinceMs, "budget": es.frameBudget,
                                  "dial_max": es.dialMax, "dial_min": EventSessionConfig.dialMin]
        let cmd: [String: Any] = ["cmd": "run", "cfg": cfg, "max_sessions": chunkSessions]
        if let data = try? JSONSerialization.data(withJSONObject: cmd) {
            inPipe.fileHandleForWriting.write(data + Data("\n".utf8))
        }
        let modelName = (try? JSONSerialization.jsonObject(with: Data(contentsOf: model.appendingPathComponent("eventsession.json")))
                         as? [String: Any])?["name"] as? String ?? model.lastPathComponent
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
            case "plan":
                await setPlan(obj)
            case "chunk_done", "idle", "stopped":
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

    private func setPlan(_ obj: [String: Any]) async {
        let frames = obj["frames"] as? Int ?? 0, shed = obj["shed"] as? Int ?? 0, dial = obj["dial"] as? Double ?? 0.5
        let days = (obj["days"] as? [String])?.count ?? 0
        await MainActor.run {
            EventSessionStatus.shared.pendingDays = days
            EventSessionStatus.shared.pendingFrames = frames
            EventSessionStatus.shared.shedSessions = shed
            EventSessionStatus.shared.dial = dial
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
        let path = Storage.workflowDBPath
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
