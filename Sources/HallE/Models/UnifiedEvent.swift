import Foundation
import GRDB

/// A deduplicated event shown in the agenda. Built from one or more
/// `CalendarEvent` rows that represent the same meeting across accounts.
struct UnifiedEvent: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var dedupKey: String
    var title: String
    var startTs: Date
    var endTs: Date
    var isAllDay: Bool
    var status: String              // display status (worst-case wins)
    var effectiveResponse: String?  // best response across sources
    var meetingURL: String?
    var location: String?
    var descriptionText: String?
    var htmlLink: String?
    var organizerEmail: String?
    var attendeesJSON: String?
    var iCalUID: String?
    var winnerAccountEmail: String
    var projectId: String?          // classification result (nil = unclassified)
    var projectConfidence: Double?
    var sourcesJSON: String         // [EventSource]

    var id: String { dedupKey }

    static let databaseTableName = "unified_event"

    enum Columns {
        static let dedupKey = Column(CodingKeys.dedupKey)
        static let startTs = Column(CodingKeys.startTs)
        static let endTs = Column(CodingKeys.endTs)
        static let status = Column(CodingKeys.status)
    }

    var sources: [EventSource] {
        (try? JSONDecoder().decode([EventSource].self, from: Data(sourcesJSON.utf8))) ?? []
    }

    var attendees: [EventAttendee] {
        guard let json = attendeesJSON else { return [] }
        return (try? JSONDecoder().decode([EventAttendee].self, from: Data(json.utf8))) ?? []
    }
}

/// A contributing (account, calendar) source for a unified event.
struct EventSource: Codable, Hashable {
    var accountEmail: String
    var calendarId: String
    var eventId: String
    var responseStatus: String?
    var colorHex: String?
}
