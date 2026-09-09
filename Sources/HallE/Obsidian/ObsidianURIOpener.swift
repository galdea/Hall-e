import Foundation
import AppKit

/// Opens the existing Markdown notes with macOS TextEdit, independently of
/// third-party notes apps or their URL registrations.
enum LocalNoteOpener {
    static func noteURL(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        // Resolve each existing parent even when the final note is missing.
        let note = relativePath.split(separator: "/").reduce(base) { parent, part in
            parent.appendingPathComponent(String(part)).standardizedFileURL.resolvingSymlinksInPath()
        }.standardizedFileURL
        guard note.path.hasPrefix(base.path + "/") else { return nil }
        return note
    }

    @MainActor
    static func open(vaultRelativePath: String) {
        guard let root = VaultAccess.currentVaultURL(),
              let note = noteURL(root: root, relativePath: vaultRelativePath),
              FileManager.default.fileExists(atPath: note.path) else {
            showError("The notes folder or note is unavailable. Check Settings → Notes Folder.")
            return
        }
        let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([note], withApplicationAt: editor,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in showError(error.localizedDescription) }
            }
        }
    }

    @MainActor
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open note"
        alert.informativeText = message
        alert.runModal()
    }
}
