import Foundation
import Testing
import GRDB
@testable import HallE

@Suite("Mac calendars")
struct MacCalendarTests {
    private func source(_ id: String, selected: Bool = false) -> CalendarSource {
        CalendarSource(accountEmail: MacCalendarProvider.accountID, calendarId: id,
                       summary: "Exchange · Work", isPrimary: false, accessRole: "reader", isSelected: selected)
    }

    @Test func refreshPreservesSelectionAndNewCalendarsStayOff() throws {
        let database = try AppDatabase(inMemory: true)
        try database.dbQueue.write { db in
            try MacCalendarCache.replaceSources([source("one")], in: db)
            var selected = source("one", selected: true)
            try selected.save(db)
            try MacCalendarCache.replaceSources([source("one"), source("two")], in: db)
            let calendars = try CalendarSource.fetchAll(db)
            #expect(calendars.first(where: { $0.calendarId == "one" })?.isSelected == true)
            #expect(calendars.first(where: { $0.calendarId == "two" })?.isSelected == false)
            try MacCalendarCache.replaceSources([source("two")], in: db)
            #expect(try CalendarSource.fetchCount(db) == 1)
        }
    }

    @Test func disconnectPreservesOtherAccountsAndCanRepeat() throws {
        let database = try AppDatabase(inMemory: true)
        try database.dbQueue.write { db in
            var google = ConnectedAccount(email: "test@example.com", colorHex: "#000000", addedAt: Date(), needsReauth: false)
            try google.save(db)
            try MacCalendarCache.replaceSources([source("one")], in: db)
            var imported = CalendarEvent(accountEmail: MacCalendarProvider.accountID, calendarId: "one", eventId: "meeting",
                                         title: "Meeting", startTs: Date(), endTs: Date().addingTimeInterval(60),
                                         isAllDay: false, status: "confirmed", fetchedAt: Date())
            try imported.save(db)
            var other = imported
            other.accountEmail = google.email
            try other.save(db)
            try MacCalendarCache.remove(in: db)
            try MacCalendarCache.remove(in: db)
            #expect(try CalendarEvent.fetchAll(db).map(\.accountEmail) == [google.email])
            #expect(try CalendarSource.fetchCount(db) == 0)
            #expect(try ConnectedAccount.fetchAll(db).map(\.email) == [google.email])
        }
    }

    @Test func recurringInstancesDoNotOverwriteEachOther() {
        let first = MacCalendarEventMapper.occurrenceID(identifier: "series", start: Date(timeIntervalSince1970: 100))
        let next = MacCalendarEventMapper.occurrenceID(identifier: "series", start: Date(timeIntervalSince1970: 200))
        #expect(first != next)
        #expect(first == MacCalendarEventMapper.occurrenceID(identifier: "series", start: Date(timeIntervalSince1970: 100)))
    }

    @Test func parsesTeamsLinksAndRejectsLookalikeDomains() {
        #expect(EventMapper.firstMeetingURL(in: "Join: https://teams.microsoft.com/l/meetup-join/123") == "https://teams.microsoft.com/l/meetup-join/123")
        #expect(EventMapper.firstMeetingURL(in: "<a href=\"https://teams.cloud.microsoft/meet/123?p=abc&amp;x=1\">Join</a>") == "https://teams.cloud.microsoft/meet/123?p=abc&x=1")
        #expect(EventMapper.firstMeetingURL(in: "https://teams.live.com/meet/123") != nil)
        #expect(EventMapper.firstMeetingURL(in: "https://company.zoom.us/j/123") != nil)
        #expect(EventMapper.firstMeetingURL(in: "https://evil.example/teams.microsoft.com/l/meetup") == nil)
        #expect(EventMapper.firstMeetingURL(in: "https://teams.microsoft.com.evil.example/join") == nil)
    }
}
