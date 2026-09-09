import Foundation
import GRDB

/// A manual project choice that applies from one occurrence forward within a
/// recurring calendar series. Exact per-occurrence assignments still take
/// precedence over these rules.
struct RecurringProjectAssignment: Codable, FetchableRecord, PersistableRecord, Equatable {
    var seriesId: String
    var effectiveFrom: Date
    var projectId: String?
    var updatedAt: Date

    static let databaseTableName = "recurring_project_assignment"

    enum Columns {
        static let seriesId = Column(CodingKeys.seriesId)
        static let effectiveFrom = Column(CodingKeys.effectiveFrom)
    }
}
