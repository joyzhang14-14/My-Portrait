import Foundation
import CryptoKit
import Network
import AppKit

/// OAuth PKCE flow for ChatGPT (OpenAI Codex / ChatGPT subscriber login).
///
/// Mirrors the Rust implementation in My-Orphies' `chatgpt_oauth.rs`:
///   1. Generate PKCE verifier + S256 challenge
///   2. Bind local TCP listener on 127.0.0.1:1455 (fallback ports if busy)
///   3. Open the system browser to /oauth/authorize
///   4. Listener accepts the redirect, extracts `?code=...`
///   5. POST authorization_code → access_token + refresh_token
///   6. Persist tokens in `SecretStore` under key `oauth:chatgpt`
///
/// Tokens are auto-refreshed on demand via `validToken()`.
enum ChatGPTOAuth {

    // MARK: - Constants (copied from Orphies chatgpt_oauth.rs)

    private static let clientId   = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer     = "https://auth.openai.com"
    private static let tokenURL   = URL(string: "https://auth.openai.com/oauth/token")!
    private static let authURL    = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let callbackPort: UInt16 = 1455
    private static let scope      = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    private static let secretKey  = "oauth:chatgpt"

    // MARK: - Token model

    struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        /// Unix epoch seconds when access_token expires.
        let expiresAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date().timeIntervalSince1970 >= expiresAt - 60
        }
    }

    // MARK: - Public API

    static func isLoggedIn() -> Bool {
        SecretStore.shared.getJSON(secretKey, as: Tokens.self) != nil
    }

    /// Return a valid access token, refreshing if needed. Throws if not logged in.
    static func validToken() async throws -> String {
        guard let tokens = SecretStore.shared.getJSON(secretKey, as: Tokens.self) else {
            throw OAuthError.notLoggedIn
        }
        if tokens.isExpired {
            let refreshed = try await refresh(tokens.refreshToken)
            return refreshed.accessToken
        }
        return tokens.accessToken
    }

    static func logout() {
        SecretStore.shared.delete(secretKey)
    }

    /// Run the interactive login flow: opens browser, awaits callback, exchanges code, saves tokens.
    static func login() async throws -> Tokens {
        let (verifier, challenge) = generatePKCE()

        // Bind listener (try port 1455 first; fall back to ephemeral).
        let listener = try await CallbackListener.start(preferredPort: callbackPort)
        let actualPort = listener.port
        let redirectURI = "http://localhost:\(actualPort)/auth/callback"
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        guard let openURL = comps.url else { throw OAuthError.badRequest("auth url build failed") }

        await MainActor.run { _ = NSWorkspace.shared.open(openURL) }

        // Wait up to 120s for the redirect to land.
        let code = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await listener.waitForCode() }
            group.addTask {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                throw OAuthError.timeout
            }
            let v = try await group.next()!
            group.cancelAll()
            return v
        }

        // Exchange code → tokens
        let tokens = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        try SecretStore.shared.setJSON(secretKey, tokens)
        return tokens
    }

    // MARK: - Internals

    private static func refresh(_ refreshToken: String) async throws -> Tokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
            "scope": scope
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data, label: "refresh")
        let new = try parseTokenResponse(data, fallbackRefresh: refreshToken)
        try SecretStore.shared.setJSON(secretKey, new)
        return new
    }

    private static func exchange(code: String, verifier: String, redirectURI: String) async throws -> Tokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body = [
            "grant_type=authorization_code",
            "code=\(percent(code))",
            "redirect_uri=\(percent(redirectURI))",
            "client_id=\(percent(clientId))",
            "code_verifier=\(percent(verifier))"
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data, label: "token exchange")
        return try parseTokenResponse(data, fallbackRefresh: nil)
    }

    private static func parseTokenResponse(_ data: Data, fallbackRefresh: String?) throws -> Tokens {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let access = obj["access_token"] as? String else {
            throw OAuthError.badResponse("missing access_token")
        }
        let refresh = (obj["refresh_token"] as? String) ?? fallbackRefresh
        guard let refresh else { throw OAuthError.badResponse("missing refresh_token") }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return Tokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().timeIntervalSince1970 + expiresIn
        )
    }

    private static func ensure2xx(_ resp: URLResponse, data: Data, label: String) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw OAuthError.badResponse("\(label): no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.badResponse("\(label) \(http.statusCode): \(body)")
        }
    }

    // MARK: - PKCE

    private static func generatePKCE() -> (verifier: String, challenge: String) {
        // Same shape as Rust: two UUIDs concatenated, no hyphens.
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "")
              + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let lower = v.lowercased()
        let digest = SHA256.hash(data: Data(lower.utf8))
        let challenge = Data(digest).base64URLNoPad()
        return (lower, challenge)
    }

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

/// One-shot atomic flag — `setOnce()` returns true exactly once.
/// Used to guard a single `cont.resume(...)` across concurrent state callbacks.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

enum OAuthError: LocalizedError {
    case notLoggedIn
    case badRequest(String)
    case badResponse(String)
    case timeout
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:           return "Not signed in to ChatGPT."
        case .badRequest(let m):     return "OAuth request error: \(m)"
        case .badResponse(let m):    return "OAuth response error: \(m)"
        case .timeout:               return "Login timed out (120s)."
        case .listenerFailed(let m): return "Local callback server failed: \(m)"
        }
    }
}

// MARK: - Local HTTP listener for OAuth callback

/// Minimal one-shot HTTP listener bound to localhost. Accepts the first
/// connection whose request line includes `?code=...`, responds with a
/// success page, and yields the code.
private final class CallbackListener: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
    }

    static func start(preferredPort: UInt16) async throws -> CallbackListener {
        // Try preferred port first; on any failure (port busy, EADDRINUSE, etc.)
        // fall back to an OS-assigned ephemeral port.
        if let l = try? await makeListener(port: preferredPort) { return l }
        return try await makeListener(port: 0)
    }

    private static func makeListener(port: UInt16) async throws -> CallbackListener {
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: nwPort)

        // Await `.ready` via stateUpdateHandler — polling `listener.state`
        // races the underlying nw_listener and can miss the transition.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = AtomicFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() { cont.resume() }
                case .failed(let err):
                    if resumed.setOnce() {
                        listener.cancel()
                        cont.resume(throwing: OAuthError.listenerFailed(err.localizedDescription))
                    }
                case .waiting(let err):
                    if resumed.setOnce() {
                        listener.cancel()
                        cont.resume(throwing: OAuthError.listenerFailed(err.localizedDescription))
                    }
                case .cancelled:
                    if resumed.setOnce() {
                        cont.resume(throwing: OAuthError.listenerFailed("listener cancelled"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        guard let actual = listener.port?.rawValue else {
            listener.cancel()
            throw OAuthError.listenerFailed("no port assigned")
        }
        return CallbackListener(listener: listener, port: actual)
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            self.continuation = cont
            lock.unlock()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        listener.cancel()
        switch result {
        case .success(let s): cont?.resume(returning: s)
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            guard let data, let req = String(data: data, encoding: .utf8) else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            // First line: "GET /auth/callback?code=xxx&state=yyy HTTP/1.1"
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            let path = String(parts[1])
            let urlString = "http://localhost" + path
            guard let comps = URLComponents(string: urlString),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px">
            <h2>Login successful!</h2>
            <p>You can close this tab and return to My Portrait.</p>
            <script>window.close()</script>
            </body></html>
            """
            self.respond(conn, status: "200 OK", body: html, contentType: "text/html")
            self.finish(.success(code))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String, contentType: String = "text/plain") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var packet = header.data(using: .utf8) ?? Data()
        packet.append(bodyData)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - tiny helpers

private extension Data {
    func base64URLNoPad() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

