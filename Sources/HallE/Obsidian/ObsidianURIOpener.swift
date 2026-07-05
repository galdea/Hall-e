import Foundation
import AppKit

/// Opens notes in Obsidian via the `obsidian://` URL scheme, resolving the vault
/// display name from Obsidian's own config.
enum ObsidianURIOpener {
    /// Strict percent-encoding for URI query values: RFC 3986 unreserved only.
    /// (`.urlQueryAllowed` leaves `&` and `+` raw, which breaks the query.)
    private static let unreserved: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    /// Vault display name = folder basename, matched against obsidian.json.
    static func vaultName(forPath path: String) -> String? {
        let obsidianJSON = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: obsidianJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any] else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        for (_, v) in vaults {
            if let vd = v as? [String: Any], let p = vd["path"] as? String,
               URL(fileURLWithPath: p).standardizedFileURL.path == target {
                return URL(fileURLWithPath: p).lastPathComponent
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Build obsidian://open?vault=…&file=… for a vault-relative note path.
    static func openURL(vaultName: String, relativeFilePath: String) -> URL? {
        let fileNoExt = relativeFilePath.hasSuffix(".md")
            ? String(relativeFilePath.dropLast(3)) : relativeFilePath
        let encFile = fileNoExt.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
        let encVault = vaultName.addingPercentEncoding(withAllowedCharacters: unreserved) ?? vaultName
        return URL(string: "obsidian://open?vault=\(encVault)&file=\(encFile)")
    }

    /// `vaultRelativePath` already includes the Hall-e subfolder prefix
    /// (as produced by VaultPathBuilder), e.g. "Hall-e/Meetings/2026/…".
    @MainActor
    static func open(vaultRelativePath: String) {
        guard let config = ObsidianVaultConfig.load() else { return }
        let name = config.resolvedVaultName ?? vaultName(forPath: config.vaultPath) ?? "vault"
        if let url = openURL(vaultName: name, relativeFilePath: vaultRelativePath) {
            NSWorkspace.shared.open(url)
        }
    }
}
