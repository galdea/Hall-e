import Foundation
import AppKit

/// Hand-rolled Google OAuth 2.0 for native/desktop apps: PKCE + loopback
/// redirect. No Google SDK. Scope is calendar.readonly only.
struct GoogleOAuthClient {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    let config: GoogleClientConfig

    enum OAuthError: Error, LocalizedError {
        case stateMismatch
        case denied(String)
        case tokenExchangeFailed(String)
        case invalidGrant
        case network(String)

        var errorDescription: String? {
            switch self {
            case .stateMismatch: "Authorization state mismatch (possible tampering); try again."
            case .denied(let e): "Authorization was denied: \(e)."
            case .tokenExchangeFailed(let m): "Token exchange failed: \(m)."
            case .invalidGrant: "This account's authorization expired. Reconnect it."
            case .network(let m): "Network error: \(m)."
            }
        }
    }

    func buildAuthURL(pkce: PKCE, redirectURI: String) -> URL {
        var comps = URLComponents(string: config.authURI)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        return comps.url!
    }

    /// Runs the full interactive add-account flow: open browser, await redirect,
    /// exchange the code. Returns the token response (with a refresh token).
    @MainActor
    func authorize() async throws -> TokenResponse {
        let pkce = PKCE()
        let server = LoopbackServer()
        defer { server.stop() }

        let port = try server.start()
        let redirectURI = LoopbackServer.redirectURI(port: port)

        // Bridge the one-shot callback to async/await, with a 3-minute timeout.
        let result: LoopbackServer.CallbackResult = try await withCheckedThrowingContinuation { cont in
            let resumed = ResumeGuard()
            server.onCallback = { res in
                if resumed.tryResume() { cont.resume(returning: res) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                if resumed.tryResume() {
                    cont.resume(throwing: OAuthError.denied("timed_out"))
                }
            }
            NSWorkspace.shared.open(buildAuthURL(pkce: pkce, redirectURI: redirectURI))
        }

        if let err = result.error { throw OAuthError.denied(err) }
        guard result.state == pkce.state else { throw OAuthError.stateMismatch }
        guard let code = result.code else { throw OAuthError.denied("no_code") }

        return try await exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)
    }

    func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        try await postToken([
            "code": code,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
    }

    func refresh(refreshToken: String) async throws -> TokenResponse {
        try await postToken([
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: config.tokenURI)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OAuthError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if let http, http.statusCode == 200 {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        }
        if let oe = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
            if oe.error == "invalid_grant" { throw OAuthError.invalidGrant }
            throw OAuthError.tokenExchangeFailed(oe.errorDescription ?? oe.error)
        }
        throw OAuthError.tokenExchangeFailed("HTTP \(http?.statusCode ?? -1)")
    }
}

extension CharacterSet {
    /// Allowed chars for an application/x-www-form-urlencoded value.
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
}

/// Ensures a checked continuation is resumed exactly once across the redirect
/// callback and the timeout task.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
