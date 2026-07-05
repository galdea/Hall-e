import Foundation

/// Caches short-lived access tokens in memory (per account) and refreshes them
/// on demand using the Keychain-stored refresh token. Single-flight per account.
actor TokenStore {
    static let shared = TokenStore()

    private struct Entry {
        var accessToken: String
        var expiresAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    /// Returns a valid access token for `email`, refreshing if needed.
    func accessToken(for email: String) async throws -> String {
        if let e = cache[email], e.expiresAt.timeIntervalSinceNow > 60 {
            return e.accessToken
        }
        if let task = inFlight[email] {
            return try await task.value
        }
        let task = Task<String, Error> { try await refreshToken(for: email) }
        inFlight[email] = task
        defer { inFlight[email] = nil }
        return try await task.value
    }

    /// Seed a freshly obtained access token (e.g. right after authorization) so
    /// the first API calls don't trigger an immediate refresh.
    func seed(email: String, accessToken: String, expiresIn: Int?) {
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600))
        cache[email] = Entry(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// Forget a cached access token (e.g. after a 401) to force a refresh.
    func invalidate(_ email: String) {
        cache[email] = nil
    }

    private func refreshToken(for email: String) async throws -> String {
        guard let config = GoogleClientConfig.load() else {
            throw GoogleClientConfig.ConfigError.notImported
        }
        guard let refresh = KeychainStore.get(account: KeychainStore.googleRefreshAccount(email: email)) else {
            throw GoogleOAuthClient.OAuthError.invalidGrant
        }
        let client = GoogleOAuthClient(config: config)
        let resp = try await client.refresh(refreshToken: refresh)
        // Google may issue a rotated refresh token; persist if present.
        if let newRefresh = resp.refreshToken {
            try? KeychainStore.set(newRefresh, account: KeychainStore.googleRefreshAccount(email: email))
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(resp.expiresIn ?? 3600))
        cache[email] = Entry(accessToken: resp.accessToken, expiresAt: expiresAt)
        return resp.accessToken
    }
}
