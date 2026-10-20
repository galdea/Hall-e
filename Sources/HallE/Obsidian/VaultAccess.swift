import Foundation
import AppKit

/// Vault folder selection, bookmark persistence, and reachability checks.
@MainActor
enum VaultAccess {
    #if MAC_APP_STORE
    private static var scopedURL: URL?
    private static var scopedBookmark: Data?
    private(set) static var needsReselection = false
    #else
    static let needsReselection = false
    #endif

    /// Prompt the user to choose a vault folder; persists path + bookmark.
    static func chooseVault() -> ObsidianVaultConfig? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Notes Folder"
        panel.message = "Select a folder for Hall-e notes. No separate notes app is required."
        if let existing = ObsidianVaultConfig.load(), !DistributionCapabilities.usesSecurityScopedVaultAccess {
            panel.directoryURL = URL(fileURLWithPath: existing.vaultPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var config = ObsidianVaultConfig(vaultPath: url.path)
        #if MAC_APP_STORE
        config.bookmarkData = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        config.bookmarkData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        #if MAC_APP_STORE
        guard config.bookmarkData != nil else { return nil }
        #endif
        config.resolvedVaultName = url.lastPathComponent
        stopAccessingVault()
        config.save()
        _ = currentVaultURL() // Start the newly saved security scope before the panel's grant ends.
        return config
    }

    /// Resolve the current vault URL (via bookmark if the folder moved).
    static func currentVaultURL() -> URL? {
        guard let config = ObsidianVaultConfig.load() else { return nil }
        #if MAC_APP_STORE
        // A direct-release path has no sandbox grant. Require reselection rather than
        // falling back to a path that only happened to be readable before sandboxing.
        guard let data = config.bookmarkData else { needsReselection = true; return nil }
        if let scopedURL, scopedBookmark == data { return scopedURL }
        stopAccessingVault()
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { needsReselection = true; return nil }
        scopedURL = url
        scopedBookmark = data
        needsReselection = false
        if stale {
            var renewed = config
            renewed.vaultPath = url.path
            renewed.bookmarkData = try? url.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil, relativeTo: nil)
            renewed.resolvedVaultName = url.lastPathComponent
            renewed.save()
            scopedBookmark = renewed.bookmarkData
        }
        return url
        #else
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
        #endif
    }

    /// Stop the app-scoped grant when the selected vault changes or the app exits.
    static func stopAccessingVault() {
        #if MAC_APP_STORE
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        scopedBookmark = nil
        #endif
    }

    /// Is the vault present and writable right now?
    static func isReachable() -> Bool {
        guard let url = currentVaultURL() else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }
}
