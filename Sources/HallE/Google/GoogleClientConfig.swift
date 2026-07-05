import Foundation

/// Parsed Google Desktop OAuth client (the `installed` object from the JSON that
/// Google Cloud Console produces for a Desktop app). Non-secret enough to keep
/// in Application Support (0600); it identifies the app, not a user.
struct GoogleClientConfig: Codable, Equatable {
    var clientId: String
    var clientSecret: String
    var authURI: String
    var tokenURI: String

    /// Parse the raw downloaded JSON (either the `{ "installed": {...} }` wrapper
    /// or a bare object).
    static func parse(_ data: Data) throws -> GoogleClientConfig {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let installed = (obj["installed"] as? [String: Any])
            ?? (obj["web"] as? [String: Any])
            ?? obj
        guard let clientId = installed["client_id"] as? String, !clientId.isEmpty else {
            throw ConfigError.missing("client_id")
        }
        let clientSecret = installed["client_secret"] as? String ?? ""
        let authURI = installed["auth_uri"] as? String ?? "https://accounts.google.com/o/oauth2/v2/auth"
        let tokenURI = installed["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
        return GoogleClientConfig(clientId: clientId, clientSecret: clientSecret,
                                  authURI: authURI, tokenURI: tokenURI)
    }

    enum ConfigError: Error, LocalizedError {
        case missing(String)
        case notImported
        var errorDescription: String? {
            switch self {
            case .missing(let f): "OAuth client JSON is missing '\(f)'."
            case .notImported: "No Google OAuth client configured. Import your Desktop client JSON in Settings → Accounts."
            }
        }
    }

    // MARK: - Persistence (Application Support, 0600)

    static func load() -> GoogleClientConfig? {
        guard let data = try? Data(contentsOf: AppPaths.googleClientFile) else { return nil }
        return try? JSONDecoder().decode(GoogleClientConfig.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: AppPaths.googleClientFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: AppPaths.googleClientFile.path)
    }

    static func importFromJSON(_ data: Data) throws -> GoogleClientConfig {
        let config = try parse(data)
        try config.save()
        return config
    }
}
