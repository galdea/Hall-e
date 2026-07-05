import Foundation
import GRDB

/// A calendar belonging to a connected account (from calendarList.list).
/// `isSelected` drives which calendars are synced/shown.
struct CalendarSource: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var accountEmail: String
    var calendarId: String
    var summary: String
    var colorHex: String?
    var isPrimary: Bool
    var accessRole: String
    var isSelected: Bool

    /// Composite identity for SwiftUI lists.
    var id: String { "\(accountEmail)\u{1F}\(calendarId)" }

    static let databaseTableName = "calendar_source"

    enum Columns {
        static let accountEmail = Column(CodingKeys.accountEmail)
        static let calendarId = Column(CodingKeys.calendarId)
        static let isSelected = Column(CodingKeys.isSelected)
    }
}
