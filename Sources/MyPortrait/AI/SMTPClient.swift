import Foundation
import Network

/// Minimal SMTP client with one job: send a single test email so we can verify
/// the user's SMTP credentials before saving them. Mirrors screenpipe's
/// `email.rs` `test()` — port 465 uses implicit TLS, 587/25 use STARTTLS.
///
/// No third-party dependency: implicit TLS (465) runs on `NWConnection`'s
/// built-in TLS; STARTTLS (587/25) runs on a raw POSIX socket upgraded in
/// place with Secure Transport (`SSLContext`), because `NWConnection`'s TLS is
/// fixed at creation time and can't be turned on mid-stream.
enum SMTPClient {

    struct SMTPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Send the fixed "My Portrait SMTP test" email. Throws `SMTPError` with a
    /// human-readable message on any failure.
    static func sendTestEmail(host: String,
                              port: Int,
                              username: String,
                              password: String,
                              from: String,
                              to: String) async throws {
        let session: SMTPSession = (port == 465)
            ? try await NWImplicitTLSSession(host: host, port: port)
            : try await STARTTLSSession(host: host, port: port)
        defer { session.close() }

        try await runConversation(session: session,
                                   host: host,
                                   port: port,
                                   username: username,
                                   password: password,
                                   from: from,
                                   to: to)
    }

    // MARK: - SMTP conversation

    private static func runConversation(session: SMTPSession,
                                        host: String,
                                        port: Int,
                                        username: String,
                                        password: String,
                                        from: String,
                                        to: String) async throws {
        // The implicit-TLS transport hands us a fresh stream, so we read the
        // 220 greeting here. The STARTTLS transport already consumed the
        // greeting (and the pre-TLS EHLO/STARTTLS) during its own setup, so it
        // sets `expectsGreeting == false`.
        if session.expectsGreeting {
            try await expect(session, code: 220, step: "server greeting")
        }

        // By here the channel is always encrypted. EHLO, then authenticate.
        try await command(session, "EHLO \(ehloName(host))", expect: 250, step: "EHLO")

        // AUTH LOGIN: 334 -> base64(user) -> 334 -> base64(pass) -> 235.
        try await command(session, "AUTH LOGIN", expect: 334, step: "AUTH LOGIN")
        try await command(session, base64(username), expect: 334, step: "username")
        try await command(session, base64(password), expect: 235, step: "password")

        try await command(session, "MAIL FROM:<\(from)>", expect: 250, step: "MAIL FROM")
        try await command(session, "RCPT TO:<\(to)>", expect: 250, step: "RCPT TO")
        try await command(session, "DATA", expect: 354, step: "DATA")

        try await session.send(messageBody(from: from, to: to))
        try await expect(session, code: 250, step: "message accept")

        // Best-effort QUIT — don't fail the test if the server hangs up early.
        try? await session.send("QUIT\r\n")
    }

    /// Send a command line (`\r\n` appended) and require the given reply code.
    private static func command(_ session: SMTPSession,
                                _ line: String,
                                expect code: Int,
                                step: String) async throws {
        try await session.send(line + "\r\n")
        try await expect(session, code: code, step: step)
    }

    /// Read one full SMTP reply (handling `250-` multi-line continuations) and
    /// require its 3-digit code to match.
    private static func expect(_ session: SMTPSession, code: Int, step: String) async throws {
        let reply = try await readReply(session)
        guard reply.code == code else {
            throw SMTPError(message: "SMTP \(step) failed: \(reply.text.isEmpty ? "code \(reply.code)" : reply.text)")
        }
    }

    private struct Reply { let code: Int; let text: String }

    /// Reads lines until a final line is seen — final lines have a space after
    /// the code (`250 OK`), continuation lines a hyphen (`250-...`).
    private static func readReply(_ session: SMTPSession) async throws -> Reply {
        var buffer = ""
        while true {
            buffer += try await session.receiveLine()
            // Process complete lines accumulated so far.
            let lines = buffer.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            if let last = lines.last, last.count >= 4 {
                let sep = last[last.index(last.startIndex, offsetBy: 3)]
                if sep == " " {
                    let code = Int(last.prefix(3)) ?? 0
                    let text = lines.map { String($0.dropFirst(4)) }.joined(separator: " ")
                    return Reply(code: code, text: text)
                }
            }
            // else: keep reading more continuation lines.
        }
    }

    // MARK: - Helpers

    private static func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// EHLO argument: a bare hostname/domain. Fall back to "localhost".
    private static func ehloName(_ host: String) -> String {
        host.isEmpty ? "localhost" : host
    }

    private static func messageBody(from: String, to: String) -> String {
        let date = smtpDate()
        return [
            "From: \(from)",
            "To: \(to)",
            "Subject: My Portrait SMTP test",
            "Date: \(date)",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "My Portrait email connection verified.",
            "",
            ".",
            ""
        ].joined(separator: "\r\n")
    }

    private static func smtpDate() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return fmt.string(from: Date())
    }
}

// MARK: - Session abstraction

/// A duplex text channel to the SMTP server. Both transports (NWConnection
/// implicit-TLS and POSIX-socket STARTTLS) conform to this.
protocol SMTPSession {
    /// True when the conversation should begin by reading a 220 greeting.
    /// Implicit-TLS sessions need it; STARTTLS sessions already consumed it.
    var expectsGreeting: Bool { get }
    func send(_ text: String) async throws
    /// Receive at least one chunk of bytes, decoded as UTF-8 text. May return
    /// a partial reply — `readReply` loops until a final line arrives.
    func receiveLine() async throws -> String
    func close()
}

/// One-shot latch ensuring a `CheckedContinuation` is resumed exactly once,
/// even though `NWConnection`'s state handler may fire multiple times.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time it's called, false thereafter.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Implicit TLS (port 465) via NWConnection

/// Implicit-TLS transport: the whole connection is TLS from byte zero, which
/// is exactly what `NWConnection` with `NWProtocolTLS` gives us.
private final class NWImplicitTLSSession: SMTPSession {
    let expectsGreeting = true
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "smtp.nw")
    /// 连接 / 读 / 写统一超时（秒）
    private static let timeout: TimeInterval = 15

    init(host: String, port: Int) async throws {
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 465
        )
        connection = NWConnection(to: endpoint, using: params)
        // `resumed` lives in a reference box so the @Sendable state handler can
        // mutate it without tripping Swift 6 strict-concurrency checks. Access
        // is serialized onto `queue`, which is where NWConnection calls back.
        let resumed = ResumeGuard()
        let conn = connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { cont.resume() }
                case .waiting(let err):
                    // 连接被拒 / 不可达时 NWConnection 进 .waiting 无限重试，永远不会
                    // 转 .failed —— 必须在这里视为失败，否则 continuation 永不 resume，
                    // UI 永久卡在 connecting
                    if resumed.claim() {
                        conn.cancel()
                        cont.resume(throwing: SMTPClient.SMTPError(message: "Connect failed: \(err.localizedDescription)"))
                    }
                case .failed(let err):
                    if resumed.claim() {
                        cont.resume(throwing: SMTPClient.SMTPError(message: "TLS connect failed: \(err.localizedDescription)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        cont.resume(throwing: SMTPClient.SMTPError(message: "Connection cancelled"))
                    }
                default:
                    break
                }
            }
            // 连接超时兜底：15s 内既没 ready 也没 failed 就主动 cancel 并抛错
            queue.asyncAfter(deadline: .now() + Self.timeout) {
                if resumed.claim() {
                    conn.cancel()
                    cont.resume(throwing: SMTPClient.SMTPError(message: "Connect to \(host):\(port) timed out"))
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        let resumed = ResumeGuard()
        let conn = connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 写超时：15s 没完成就 cancel 抛错，防止永久挂起
            queue.asyncAfter(deadline: .now() + Self.timeout) {
                if resumed.claim() {
                    conn.cancel()
                    cont.resume(throwing: SMTPClient.SMTPError(message: "send timed out"))
                }
            }
            conn.send(content: Data(text.utf8), completion: .contentProcessed { err in
                guard resumed.claim() else { return }
                if let err {
                    cont.resume(throwing: SMTPClient.SMTPError(message: "send failed: \(err.localizedDescription)"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    func receiveLine() async throws -> String {
        let resumed = ResumeGuard()
        let conn = connection
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // 读超时：15s 没收到任何字节就 cancel 抛错（服务器不发 greeting 等场景）
            queue.asyncAfter(deadline: .now() + Self.timeout) {
                if resumed.claim() {
                    conn.cancel()
                    cont.resume(throwing: SMTPClient.SMTPError(message: "receive timed out"))
                }
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                guard resumed.claim() else { return }
                if let err {
                    cont.resume(throwing: SMTPClient.SMTPError(message: "receive failed: \(err.localizedDescription)"))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else if isComplete {
                    cont.resume(throwing: SMTPClient.SMTPError(message: "server closed connection"))
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    func close() { connection.cancel() }
}

// MARK: - STARTTLS (port 587/25) via POSIX socket + Secure Transport

/// STARTTLS transport. Opens a plaintext POSIX socket, does the initial
/// greeting + EHLO + `STARTTLS` handshake in the clear, then upgrades the same
/// file descriptor to TLS with Secure Transport (`SSLContext`). After `init`
/// returns, every `send`/`receiveLine` goes through the encrypted channel.
///
/// We need a raw socket here because `NWConnection`'s TLS is decided at
/// creation and cannot be enabled mid-stream — so an in-place STARTTLS upgrade
/// isn't expressible with `NWConnection`.
/// `@unchecked Sendable`: the fd and SSLContext are mutated only from `init`
/// and from the serialized `send`/`receiveLine` calls, which `runConversation`
/// always awaits one at a time — there is never concurrent access.
private final class STARTTLSSession: SMTPSession, @unchecked Sendable {
    let expectsGreeting = false   // greeting consumed during the pre-TLS phase
    private var fd: Int32 = -1
    private var sslContext: SSLContext?
    private let host: String

    init(host: String, port: Int) async throws {
        self.host = host
        try await Task.detached(priority: .userInitiated) { [self] in
            try connectPlain(host: host, port: port)
            try plainHandshakeAndUpgrade(host: host)
        }.value
    }

    // --- plaintext phase ---

    private func connectPlain(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let info = result else {
            throw SMTPClient.SMTPError(message: "DNS lookup failed for \(host)")
        }
        defer { freeaddrinfo(info) }

        var sock: Int32 = -1
        var cur: UnsafeMutablePointer<addrinfo>? = info
        while let node = cur {
            sock = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if sock >= 0 {
                // 超时设置：读写 15s（SO_RCVTIMEO/SO_SNDTIMEO，超时后 read/write 返回
                // -1 + EAGAIN）；connect 15s（Darwin 的 TCP_CONNECTIONTIMEOUT，不设则
                // 系统默认约 75s）。防止服务器不可达 / 不回包时永久阻塞。
                var tv = timeval(tv_sec: 15, tv_usec: 0)
                _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var connTimeout: Int32 = 15
                _ = setsockopt(sock, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &connTimeout, socklen_t(MemoryLayout<Int32>.size))
                if connect(sock, node.pointee.ai_addr, node.pointee.ai_addrlen) == 0 { break }
                Darwin.close(sock)
                sock = -1
            }
            cur = node.pointee.ai_next
        }
        guard sock >= 0 else {
            throw SMTPClient.SMTPError(message: "TCP connect to \(host):\(port) failed")
        }
        fd = sock
    }

    /// Greeting -> EHLO -> STARTTLS -> 220, then wrap the fd in TLS and EHLO
    /// again over the encrypted channel.
    private func plainHandshakeAndUpgrade(host: String) throws {
        try requireCode(220, rawReadReply(), step: "server greeting")
        try rawWrite("EHLO \(host.isEmpty ? "localhost" : host)\r\n")
        try requireCode(250, rawReadReply(), step: "EHLO")
        try rawWrite("STARTTLS\r\n")
        try requireCode(220, rawReadReply(), step: "STARTTLS")
        try startTLS(host: host)
        // The post-TLS EHLO is issued by runConversation as its first command
        // (expectsGreeting == false means it skips the 220 read).
    }

    // --- TLS upgrade ---

    private func startTLS(host: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw SMTPClient.SMTPError(message: "could not create TLS context")
        }
        sslContext = ctx
        SSLSetIOFuncs(ctx, STARTTLSSession.tlsRead, STARTTLSSession.tlsWrite)
        let connRef = UnsafeMutableRawPointer(bitPattern: Int(fd))
        SSLSetConnection(ctx, connRef)
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, host.utf8.count) }

        var status: OSStatus = errSSLWouldBlock
        while status == errSSLWouldBlock {
            status = SSLHandshake(ctx)
        }
        guard status == errSecSuccess else {
            throw SMTPClient.SMTPError(message: "TLS handshake failed (status \(status))")
        }
    }

    // Secure Transport I/O callbacks — read/write the raw fd. `connection` is
    // the fd packed into the pointer.
    private static let tlsRead: SSLReadFunc = { conn, data, dataLength in
        let fd = Int32(Int(bitPattern: conn))
        var requested = dataLength.pointee
        var total = 0
        while total < requested {
            let n = Darwin.read(fd, data.advanced(by: total), requested - total)
            if n > 0 { total += n }
            else if n == 0 { dataLength.pointee = total; return errSSLClosedGraceful }
            else {
                dataLength.pointee = total
                // socket 是阻塞模式，EAGAIN 只会因 SO_RCVTIMEO 超时出现；若映射成
                // errSSLWouldBlock 上层 SSLHandshake/SSLRead 会无限重试，直接视为失败
                return errSSLClosedAbort
            }
        }
        dataLength.pointee = total
        _ = requested
        return errSecSuccess
    }

    private static let tlsWrite: SSLWriteFunc = { conn, data, dataLength in
        let fd = Int32(Int(bitPattern: conn))
        let requested = dataLength.pointee
        var total = 0
        while total < requested {
            let n = Darwin.write(fd, data.advanced(by: total), requested - total)
            if n > 0 { total += n }
            else {
                dataLength.pointee = total
                // 同 tlsRead：阻塞 socket 的 EAGAIN = SO_SNDTIMEO 超时，视为失败
                return errSSLClosedAbort
            }
        }
        dataLength.pointee = total
        return errSecSuccess
    }

    // --- raw plaintext read/write (pre-TLS only) ---

    private func rawWrite(_ text: String) throws {
        let bytes = Array(text.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: off), bytes.count - off) }
            guard n > 0 else { throw SMTPClient.SMTPError(message: "socket write failed") }
            off += n
        }
    }

    private func rawReadReply() throws -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        var acc = ""
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                // SO_RCVTIMEO 超时时 read 返回 -1 + EAGAIN（服务器不发 greeting 等）
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw SMTPClient.SMTPError(message: "socket read timed out")
                }
                throw SMTPClient.SMTPError(message: "socket closed")
            }
            acc += String(decoding: buf[0..<n], as: UTF8.self)
            if isFinalReply(acc) { return acc }
        }
    }

    private func isFinalReply(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let last = lines.last, last.count >= 4 else { return false }
        return last[last.index(last.startIndex, offsetBy: 3)] == " "
    }

    private func requireCode(_ code: Int, _ reply: String, step: String) throws {
        let lines = reply.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let got = Int(lines.last?.prefix(3) ?? "") ?? 0
        guard got == code else {
            throw SMTPClient.SMTPError(message: "SMTP \(step) failed: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // --- SMTPSession (post-TLS) ---

    func send(_ text: String) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let ctx = sslContext else { throw SMTPClient.SMTPError(message: "TLS not active") }
            let bytes = Array(text.utf8)
            var off = 0
            try bytes.withUnsafeBytes { raw in
                while off < bytes.count {
                    var processed = 0
                    let status = SSLWrite(ctx, raw.baseAddress!.advanced(by: off), bytes.count - off, &processed)
                    off += processed
                    if status == errSSLWouldBlock { continue }
                    guard status == errSecSuccess else {
                        throw SMTPClient.SMTPError(message: "TLS write failed (status \(status))")
                    }
                }
            }
        }.value
    }

    func receiveLine() async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let ctx = sslContext else { throw SMTPClient.SMTPError(message: "TLS not active") }
            var buf = [UInt8](repeating: 0, count: 8192)
            let capacity = buf.count
            var processed = 0
            var status: OSStatus = errSSLWouldBlock
            while status == errSSLWouldBlock && processed == 0 {
                status = buf.withUnsafeMutableBytes {
                    SSLRead(ctx, $0.baseAddress!, capacity, &processed)
                }
            }
            if processed > 0 {
                return String(decoding: buf[0..<processed], as: UTF8.self)
            }
            if status == errSSLClosedGraceful {
                throw SMTPClient.SMTPError(message: "server closed connection")
            }
            if status == errSSLClosedAbort {
                // tlsRead 把 SO_RCVTIMEO 超时也映射成 abort，这里两种都可能
                throw SMTPClient.SMTPError(message: "connection aborted or read timed out")
            }
            guard status == errSecSuccess else {
                throw SMTPClient.SMTPError(message: "TLS read failed (status \(status))")
            }
            return ""
        }.value
    }

    func close() {
        if let ctx = sslContext { SSLClose(ctx); sslContext = nil }
        if fd >= 0 { Darwin.close(fd); fd = -1 }   // 置 -1 → 幂等,deinit + defer 重复调不会 double-close
    }

    // init() 在 TCP 连上后抛错(凭证/STARTTLS/TLS 失败)时,没有 defer 兜底会泄漏
    // fd。deinit 保证被 drop 也释放;close() 幂等使「成功路径 defer close + deinit」
    // 不会重复关 fd。
    deinit { close() }
}
