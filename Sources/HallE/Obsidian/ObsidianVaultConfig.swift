import Foundation

/// User's notes-folder settings. App Store builds require a selected-folder
/// security-scoped bookmark; direct builds retain their path fallback.
struct ObsidianVaultConfig: Codable, Equatable {
    var vaultPath: String
    var bookmarkData: Data?
    var subfolderName: String = "Hall-e"
    var resolvedVaultName: String?

    static func load() -> ObsidianVaultConfig? {
        AppPreferences.codable(ObsidianVaultConfig.self, forKey: AppPreferences.obsidianVaultConfigKey)
    }

    func save() {
        AppPreferences.setCodable(self, forKey: AppPreferences.obsidianVaultConfigKey)
    }

    /// The Hall-e root inside the vault (…/AgentBrain/Hall-e).
    var rootURL: URL {
        URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(subfolderName, isDirectory: true)
    }
}
