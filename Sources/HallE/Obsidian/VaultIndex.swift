import Foundation
import CryptoKit
import GRDB

/// Rebuilds a disposable local index over the configured Hall-e vault folder.
/// The Markdown files remain authoritative; this actor only accelerates search,
/// task views, and explicit project exports.
actor VaultIndex {
    static let shared = VaultIndex()

    private(set) var lastIndexedAt: Date?

    func reindex() async {
        guard let root = await MainActor.run(body: { VaultAccess.currentVaultURL() }) else { return }
        let hallRoot = root.appendingPathComponent(ObsidianVaultConfig.load()?.subfolderName ?? "Hall-e",
                                                   isDirectory: true)
        let documents = scan(root: hallRoot)
        let actions = documents.flatMap(parseActions)
        do {
            try await AppDatabase.shared.dbQueue.write { db in
                try VaultDocument.deleteAll(db)
                for document in documents { try document.insert(db) }
                try IndexedActionItem.deleteAll(db)
                for action in actions { try action.insert(db) }
            }
            lastIndexedAt = Date()
            Log.obsidian.info("vault indexed: \(documents.count) notes, \(actions.count) action items")
            await MainActor.run {
                NotificationCenter.default.post(name: .halleProjectKnowledgeChanged, object: nil)
            }
        } catch {
            Log.obsidian.error("vault index failed: \(error, privacy: .public)")
        }
    }

    func search(_ query: String, project: String? = nil, limit: Int = 50, offset: Int = 0) async -> [VaultDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? await AppDatabase.shared.dbQueue.read { db in
            var request = VaultDocument.order(VaultDocument.Columns.modifiedAt.desc)
            if !trimmed.isEmpty {
                let escaped = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                request = request.filter(
                    sql: "title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'",
                    arguments: [pattern, pattern])
            }
            if let project, !project.isEmpty {
                request = request.filter(VaultDocument.Columns.project == project)
            }
            return try request.limit(max(1, min(limit, 200)), offset: max(0, offset)).fetchAll(db)
        }) ?? []
    }

    private func scan(root: URL) -> [VaultDocument] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }

        var result: [VaultDocument] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = { (key: String) in FrontmatterCodec.readValue(content, key: key) }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .flatMap { $0 } ?? Date.distantPast
            let title = content.components(separatedBy: "\n")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") })?
                .trimmingCharacters(in: .whitespaces)
                .dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines) ?? url.deletingPathExtension().lastPathComponent
            let hash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            result.append(VaultDocument(path: relative, title: String(title), type: values("type"),
                                        project: values("project"), eventId: values("hall_e_event_id"),
                                        contentHash: hash, modifiedAt: modified, body: content))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func parseActions(from document: VaultDocument) -> [IndexedActionItem] {
        let start = "<!-- hall-e:actions:start -->"
        let end = "<!-- hall-e:actions:end -->"
        var inside = false
        var result: [IndexedActionItem] = []
        for (index, line) in document.body.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == start { inside = true; continue }
            if trimmed == end { inside = false; continue }
            guard inside else { continue }
            let completed: Bool
            let prefix: String
            if trimmed.hasPrefix("- [ ] ") { completed = false; prefix = "- [ ] " }
            else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                completed = true; prefix = String(trimmed.prefix(6))
            } else { continue }
            let raw = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            var task = raw
            var owner: String?
            var due: String?
            if let range = task.range(of: "\\(@[^ )]+\\)", options: .regularExpression) {
                owner = String(task[range]).trimmingCharacters(in: CharacterSet(charactersIn: "(@)"))
                task.removeSubrange(range)
            }
            if let range = task.range(of: "— due .*$", options: .regularExpression) {
                due = String(task[range]).replacingOccurrences(of: "— due ", with: "")
                task.removeSubrange(range)
            }
            let identity = "\(document.path)|\(index)|\(raw)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            result.append(IndexedActionItem(id: String(id.prefix(32)), notePath: document.path,
                                            eventId: document.eventId, task: task.trimmingCharacters(in: .whitespaces),
                                            owner: owner, dueDate: due, project: document.project,
                                            isCompleted: completed, confidence: nil, updatedAt: document.modifiedAt))
        }
        return result
    }
}
