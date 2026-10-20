import Foundation

/// Keeps personal follow-up status separate from the Obsidian index. The note
/// remains the source of truth for wording and ownership; this file stores only
/// the user's local complete/reopen choice so a vault refresh cannot erase it.
struct ProjectFollowUpStore {
    private(set) var overrides: [String: Bool]
    private let fileURL: URL
    private(set) var loadError: String?

    enum StoreError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let message): "Saved follow-up status could not be read. No changes were saved. \(message)"
            }
        }
    }

    init(fileURL: URL = AppPaths.appSupport.appendingPathComponent("project-follow-up-state.json")) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            overrides = [:]
            loadError = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            overrides = try JSONDecoder().decode([String: Bool].self, from: data)
            loadError = nil
        } catch {
            // Preserve the damaged file and refuse writes. Replacing it with an
            // empty dictionary would silently erase every saved completion.
            overrides = [:]
            loadError = error.localizedDescription
        }
    }

    func isCompleted(_ item: IndexedActionItem) -> Bool {
        overrides[item.id] ?? item.isCompleted
    }

    mutating func setCompleted(_ completed: Bool, for id: String) throws {
        if let loadError { throw StoreError.unreadable(loadError) }
        var updated = overrides
        updated[id] = completed
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        overrides = updated
    }
}
