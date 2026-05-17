import Foundation
import CryptoKit
import AppKit
import Darwin

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
        let listener = try CallbackListener.start(preferredPort: callbackPort)
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

// MARK: - Local HTTP listener for OAuth callback (BSD sockets)
//
// Network.framework's NWListener returned EINVAL fallbacks in our test runs.
// A POSIX socket is what Orphies' Rust implementation uses and is the most
// predictable thing on macOS — bind, listen, accept, read one request,
// respond, close. No frameworks in the way.

private final class CallbackListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    private init(fd: Int32, port: UInt16) {
        self.fd = fd
        self.port = port
    }

    deinit { close(fd) }

    static func start(preferredPort: UInt16) throws -> CallbackListener {
        if let l = try? bind(port: preferredPort) { return l }
        return try bind(port: 0)
    }

    private static func bind(port: UInt16) throws -> CallbackListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthError.listenerFailed("socket(): \(String(cString: strerror(errno)))")
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian          // host → network byte order
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw OAuthError.listenerFailed("bind \(port): \(err)")
        }
        guard listen(fd, 1) == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw OAuthError.listenerFailed("listen: \(err)")
        }

        // Read back the assigned port (matters when port = 0 → ephemeral).
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        let assigned = UInt16(bigEndian: bound.sin_port)
        return CallbackListener(fd: fd, port: assigned)
    }

    /// Accept one connection, parse the GET ?code=…, write 200 OK, return the code.
    func waitForCode() async throws -> String {
        try await Task.detached(priority: .userInitiated) { [fd] in
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            guard client >= 0 else {
                throw OAuthError.listenerFailed("accept: \(String(cString: strerror(errno)))")
            }
            defer { close(client) }

            // Read up to 4 KB — the OAuth redirect is far smaller.
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(client, &buf, buf.count)
            guard n > 0 else {
                throw OAuthError.listenerFailed("read: empty request")
            }
            let request = String(decoding: buf[0..<n], as: UTF8.self)
            // Request line: "GET /auth/callback?code=…&state=… HTTP/1.1"
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  let comps = URLComponents(string: "http://localhost" + parts[1]),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
            else {
                Self.respond(client: client, status: "404 Not Found", body: "")
                throw OAuthError.listenerFailed("no code in callback")
            }

            let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px">
            <h2>Login successful!</h2>
            <p>You can close this tab and return to My Portrait.</p>
            <script>window.close()</script>
            </body></html>
            """
            Self.respond(client: client, status: "200 OK", body: html, contentType: "text/html")
            return code
        }.value
    }

    private static func respond(client: Int32, status: String, body: String, contentType: String = "text/plain") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var packet = header.data(using: .utf8) ?? Data()
        packet.append(bodyData)
        _ = packet.withUnsafeBytes { ptr in
            write(client, ptr.baseAddress, packet.count)
        }
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

