import AppKit
import CryptoKit
import Foundation
import Network

/// Only runs after an explicit authorization action. No client login files are used.
struct QueryOAuthClient: Sendable {
    let provider: UsageProvider
    var session: URLSession = .shared

    static let claudeRedirect = "https://platform.claude.com/oauth/code/callback"

    func authorizationURL(redirect: String, state: String, verifier: String) throws -> URL {
        guard provider != .codex else { throw QueryAccountError.format }
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var url = URLComponents(string: provider == .claude
            ? "https://claude.com/cai/oauth/authorize" : "https://accounts.google.com/o/oauth2/v2/auth")!
        var fields = [
            "response_type": "code", "client_id": clientID, "redirect_uri": redirect,
            "state": state, "code_challenge": challenge, "code_challenge_method": "S256"
        ]
        if provider == .claude {
            // Query-only authorization does not request API key creation, uploads or session management.
            fields["scope"] = "user:profile"
            fields["code"] = "true"
        } else {
            fields["scope"] = "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
            fields["access_type"] = "offline"
            fields["prompt"] = "consent select_account"
        }
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    private var clientID: String {
        switch provider {
        case .codex: return "app_EMoamEEZ73f0CkXaXp7hrann"
        case .claude: return ClaudeTokenRefresher.clientID
        case .antigravity: return AntigravityQuotaClient.clientID
        }
    }

    func exchange(code: String, redirect: String, state: String, verifier: String) async throws -> QueryCredential {
        try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "state": state, "code_verifier": verifier
        ])
    }

    func refresh(_ credential: QueryCredential) async throws -> QueryCredential {
        guard let refresh = credential.refreshToken, !refresh.isEmpty else { throw QueryAccountError.authorization }
        let result = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
        return QueryCredential(accessToken: result.accessToken, refreshToken: result.refreshToken ?? refresh,
                               expiresAt: result.expiresAt, isGCPToS: credential.isGCPToS,
                               idToken: result.idToken ?? credential.idToken, oauthClientKey: credential.oauthClientKey)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> QueryCredential {
        var values = fields
        values["client_id"] = clientID
        let endpoint = provider == .claude ? ClaudeTokenRefresher.endpoint
            : URL(string: provider == .codex ? "https://auth.openai.com/oauth/token" : "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        if provider == .claude {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: values)
        } else {
            if provider == .antigravity { values["client_secret"] = AntigravityQuotaClient.clientSecret }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(ClaudeTokenRefresher.formBody(values.map { ($0.key, $0.value) }).utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QueryAccountError.unavailable }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if object["error"] as? String == "invalid_grant" { throw QueryAccountError.authorization }
        guard http.statusCode == 200, let access = object["access_token"] as? String, !access.isEmpty else {
            throw QueryAccountError.unavailable
        }
        return QueryCredential(accessToken: access, refreshToken: object["refresh_token"] as? String,
            expiresAt: (object["expires_in"] as? Double).map { Date().addingTimeInterval($0) }, isGCPToS: false,
            idToken: object["id_token"] as? String)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class QueryOAuthFlow {
    let id = UUID()
    let provider: UsageProvider
    let state = UUID().uuidString + UUID().uuidString
    let verifier = UUID().uuidString + UUID().uuidString
    private(set) var redirect = QueryOAuthClient.claudeRedirect
    private let expiresAt = Date().addingTimeInterval(600)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var completed = false
    var onCode: ((String) -> Void)?

    init(provider: UsageProvider) { self.provider = provider }

    func startURL() async throws -> URL {
        if provider == .claude { return try url() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection, buffer: Data()) }
        }
        server.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    self.redirect = "http://127.0.0.1:\(port.rawValue)/oauth/callback"
                    let continuation = self.ready
                    self.ready = nil
                    do { continuation?.resume(returning: try self.url()) }
                    catch { continuation?.resume(throwing: error) }
                case .failed:
                    self.cancel()
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            server.start(queue: .main)
        }
    }

    private func url() throws -> URL {
        try QueryOAuthClient(provider: provider).authorizationURL(redirect: redirect, state: state, verifier: verifier)
    }

    static func callbackCode(target: String, expectedState: String) -> String? {
        guard let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/oauth/callback" else { return nil }
        let fields = components.queryItems ?? []
        guard fields.filter({ $0.name == "state" }).count == 1,
              fields.first(where: { $0.name == "state" })?.value == expectedState,
              fields.filter({ $0.name == "code" }).count == 1,
              let code = fields.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty {
            connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: .main)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.completed, self.expiresAt > Date() else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
                let request = String(decoding: bytes, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: bytes) }
                    return
                }
                let line = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                let code = line.count == 3 && line[0] == "GET"
                    ? Self.callbackCode(target: String(line[1]), expectedState: self.state) : nil
                let status = code == nil ? "400 Bad Request" : "200 OK"
                let message = code == nil ? "Invalid authorization callback." : "Return to QuotaLens."
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(message)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code {
                    self.completed = true
                    self.listener?.cancel()
                    self.onCode?(code)
                }
            }
        }
    }

    func exchange(_ rawCode: String) async throws -> QueryCredential {
        guard expiresAt > Date() else { throw QueryAccountError.authorization }
        let pieces = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", omittingEmptySubsequences: false)
        guard let code = pieces.first, !code.isEmpty,
              pieces.count <= 2, pieces.count == 1 || pieces[1] == state else { throw QueryAccountError.authorization }
        return try await QueryOAuthClient(provider: provider).exchange(code: String(code), redirect: redirect, state: state, verifier: verifier)
    }

    func cancel() {
        completed = true
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        ready?.resume(throwing: CancellationError())
        ready = nil
        onCode = nil
    }
}
