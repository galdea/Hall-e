import Foundation
import GRDB

/// Local index entry for one Markdown file in the configured Hall-e vault area.
/// Obsidian remains the source of truth; this record is disposable search/cache data.
struct VaultDocument: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var path: String
    var title: String
    var type: String?
    var project: String?
    var eventId: String?
    var contentHash: String
    var modifiedAt: Date
    var body: String

    var id: String { path }
    static let databaseTableName = "vault_document"

    enum Columns {
        static let path = Column(CodingKeys.path)
        static let title = Column(CodingKeys.title)
        static let project = Column(CodingKeys.project)
        static let eventId = Column(CodingKeys.eventId)
        static let modifiedAt = Column(CodingKeys.modifiedAt)
    }
}

struct IndexedActionItem: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var notePath: String
    var eventId: String?
    var task: String
    var owner: String?
    var dueDate: String?
    var project: String?
    var isCompleted: Bool
    var confidence: Double?
    var updatedAt: Date

    static let databaseTableName = "indexed_action_item"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let notePath = Column(CodingKeys.notePath)
        static let project = Column(CodingKeys.project)
        static let isCompleted = Column(CodingKeys.isCompleted)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
