import Foundation
import AppKit

/// Vault folder selection, bookmark persistence, and reachability checks.
@MainActor
enum VaultAccess {
    /// Prompt the user to choose a vault folder; persists path + bookmark.
    static func chooseVault() -> ObsidianVaultConfig? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.message = "Select your Obsidian vault folder"
        if let existing = ObsidianVaultConfig.load() {
            panel.directoryURL = URL(fileURLWithPath: existing.vaultPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var config = ObsidianVaultConfig(vaultPath: url.path)
        config.bookmarkData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        config.resolvedVaultName = ObsidianURIOpener.vaultName(forPath: url.path) ?? url.lastPathComponent
        config.save()
        return config
    }

    /// Resolve the current vault URL (via bookmark if the folder moved).
    static func currentVaultURL() -> URL? {
        guard let config = ObsidianVaultConfig.load() else { return nil }
        if let data = config.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                if stale {
                    var updated = config
                    updated.vaultPath = url.path
                    updated.bookmarkData = try? url.bookmarkData()
                    updated.save()
                }
                return url
            }
        }
        return URL(fileURLWithPath: config.vaultPath)
    }

    /// Is the vault present and writable right now?
    static func isReachable() -> Bool {
        guard let url = currentVaultURL() else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }
}
