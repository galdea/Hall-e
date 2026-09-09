import EventKit
import Foundation
import GRDB

/// Reads only calendars that the user selects. Account authentication belongs to macOS.
@MainActor
final class MacCalendarProvider {
    static let shared = MacCalendarProvider()
    nonisolated static let accountID = "macos-calendars"
    private let store = EKEventStore()
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "macCalendarsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "macCalendarsEnabled") }
    }
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func connect() async throws {
        guard try await store.requestFullAccessToEvents() else {
            throw CalendarAccessError.denied
        }
        Self.enabled = true
        try await refreshSources()
        await SyncCoordinator.shared.syncAll()
    }

    func disconnect() async throws {
        Self.enabled = false
        try await removeCache()
        await SyncCoordinator.shared.rebuildAfterSourceChange()
    }

    func refreshSources() async throws {
        guard Self.enabled && Self.authorized else {
            try await removeCache()
            return
        }
        let sources = store.calendars(for: .event).map { calendar in
            CalendarSource(accountEmail: Self.accountID, calendarId: calendar.calendarIdentifier,
                           summary: "\(calendar.source.title) · \(calendar.title)", colorHex: nil,
                           isPrimary: false, accessRole: "reader", isSelected: false)
        }
        try await AppDatabase.shared.dbQueue.write { db in
            try MacCalendarCache.replaceSources(sources, in: db)
        }
    }

    func events(calendarID: String, from: Date, to: Date, fetchedAt: Date) throws -> [CalendarEvent] {
        guard Self.enabled && Self.authorized else { throw CalendarAccessError.denied }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarAccessError.missingCalendar }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).compactMap { MacCalendarEventMapper.map($0, fetchedAt: fetchedAt) }
    }

    private func removeCache() async throws {
        try await AppDatabase.shared.dbQueue.write { db in
            try MacCalendarCache.remove(in: db)
        }
    }

    enum CalendarAccessError: LocalizedError {
        case denied, missingCalendar
        var errorDescription: String? {
            switch self {
            case .denied: "Allow full Calendar access in System Settings → Privacy & Security → Calendars, then reconnect. Hall-e only reads calendars you select."
            case .missingCalendar: "This calendar is no longer available. Refresh your calendars."
            }
        }
    }
}

enum MacCalendarEventMapper {
    static func map(_ event: EKEvent, fetchedAt: Date) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate, end > start,
              let calendarID = event.calendar?.calendarIdentifier,
              let identifier = event.eventIdentifier else { return nil }
        let attendees = (event.attendees ?? []).map {
            EventAttendee(name: $0.name, email: email($0.url), responseStatus: response($0.participantStatus),
                          isSelf: $0.isCurrentUser, isOrganizer: $0.url == event.organizer?.url)
        }
        let meetingURL = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.compactMap { EventMapper.firstMeetingURL(in: $0) }.first
        return CalendarEvent(accountEmail: MacCalendarProvider.accountID, calendarId: calendarID,
                             eventId: occurrenceID(identifier: identifier, start: event.occurrenceDate ?? start),
                             iCalUID: event.calendarItemExternalIdentifier, title: event.title,
                             startTs: start, endTs: end, isAllDay: event.isAllDay,
                             status: event.status == .canceled ? "cancelled" : (event.status == .tentative ? "tentative" : "confirmed"),
                             myResponseStatus: attendees.first(where: \.isSelf)?.responseStatus,
                             organizerEmail: event.organizer.flatMap { email($0.url) },
                             attendeesJSON: (try? JSONEncoder().encode(attendees)).map { String(decoding: $0, as: UTF8.self) },
                             meetingURL: meetingURL, location: event.location, descriptionText: event.notes,
                             htmlLink: nil, originalStartTs: event.occurrenceDate, etag: nil,
                             updatedAt: event.lastModifiedDate, fetchedAt: fetchedAt)
    }
    static func occurrenceID(identifier: String, start: Date) -> String {
        "\(identifier)#\(start.timeIntervalSince1970)"
    }
    private static func email(_ url: URL) -> String? {
        url.scheme?.lowercased() == "mailto" ? String(url.absoluteString.dropFirst(7)).removingPercentEncoding : nil
    }
    private static func response(_ status: EKParticipantStatus) -> String? {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "needsAction"
        default: nil
        }
    }
}

/// Pure database operations, shared by refresh and disconnect. Never touches provider data.
enum MacCalendarCache {
    static func replaceSources(_ sources: [CalendarSource], in db: Database) throws {
            var account = try ConnectedAccount.fetchOne(db, key: MacCalendarProvider.accountID)
                ?? ConnectedAccount(email: MacCalendarProvider.accountID, displayName: "Calendars on this Mac",
                                    colorHex: "#14B8A6", addedAt: Date(), needsReauth: false,
                                    lastSyncAt: nil, lastSyncError: nil)
            account.needsReauth = false
            try account.save(db)
            let previous = try CalendarSource.filter(CalendarSource.Columns.accountEmail == MacCalendarProvider.accountID).fetchAll(db)
            let ids = Set(sources.map(\.calendarId))
            for old in previous where !ids.contains(old.calendarId) {
                try old.delete(db)
                try CalendarEvent.filter(CalendarEvent.Columns.accountEmail == MacCalendarProvider.accountID && CalendarEvent.Columns.calendarId == old.calendarId).deleteAll(db)
                // Invalidate derived caches, including previously browsed ranges.
                try UnifiedEvent.deleteAll(db)
            }
            for var source in sources {
                source.isSelected = previous.first(where: { $0.calendarId == source.calendarId })?.isSelected ?? false
                try source.save(db)
            }
    }
    static func remove(in db: Database) throws {
            guard try ConnectedAccount.fetchOne(db, key: MacCalendarProvider.accountID) != nil else { return }
            try CalendarEvent.filter(CalendarEvent.Columns.accountEmail == MacCalendarProvider.accountID).deleteAll(db)
            try ConnectedAccount.deleteOne(db, key: MacCalendarProvider.accountID)
            try UnifiedEvent.deleteAll(db)
    }
}
