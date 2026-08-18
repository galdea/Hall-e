import Foundation
import GRDB

struct EventProjectAssignment: Codable, FetchableRecord, PersistableRecord {
    var dedupKey: String
    var projectId: String?
    var updatedAt: Date

    static let databaseTableName = "event_project_assignment"
    enum Columns { static let dedupKey = Column(CodingKeys.dedupKey) }
}
