import Foundation
import GRDB

/// A raw calendar event as fetched from one account/calendar (pre-dedup).
/// Times are stored as absolute instants (UTC); all-day events use local
/// midnight materialized at fetch time.
struct CalendarEvent: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var accountEmail: String
    var calendarId: String
    var eventId: String
    var iCalUID: String?
    var title: String?
    var startTs: Date
    var endTs: Date
    var isAllDay: Bool
    var status: String            // confirmed | tentative | cancelled
    var myResponseStatus: String? // accepted | tentative | needsAction | declined
    var organizerEmail: String?
    var attendeesJSON: String?    // [{name,email,responseStatus,isSelf}]
    var meetingURL: String?
    var location: String?
    var descriptionText: String?
    var htmlLink: String?
    var originalStartTs: Date?
    var etag: String?
    var updatedAt: Date?
    var fetchedAt: Date

    var id: String { "\(accountEmail)\u{1F}\(calendarId)\u{1F}\(eventId)" }

    static let databaseTableName = "calendar_event"

    enum Columns {
        static let accountEmail = Column(CodingKeys.accountEmail)
        static let calendarId = Column(CodingKeys.calendarId)
        static let eventId = Column(CodingKeys.eventId)
        static let startTs = Column(CodingKeys.startTs)
        static let endTs = Column(CodingKeys.endTs)
        static let status = Column(CodingKeys.status)
    }
}

/// One attendee, encoded into `CalendarEvent.attendeesJSON`.
struct EventAttendee: Codable, Hashable {
    var name: String?
    var email: String?
    var responseStatus: String?
    var isSelf: Bool
    var isOrganizer: Bool
}
