import Foundation

/// User's Obsidian vault settings. The app is not sandboxed, so a plain (non
/// security-scoped) bookmark is used — it survives the user moving/renaming the
/// vault folder, with the stored path as a fallback.
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
