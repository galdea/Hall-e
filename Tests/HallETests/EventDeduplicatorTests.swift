import Testing
import Foundation
@testable import HallE

@Suite("EventDeduplicator")
struct EventDeduplicatorTests {
    private func makeEvent(account: String, cal: String, id: String, uid: String?,
                           title: String, start: Date, end: Date,
                           response: String? = "accepted", status: String = "confirmed",
                           url: String? = nil, originalStart: Date? = nil) -> CalendarEvent {
        CalendarEvent(accountEmail: account, calendarId: cal, eventId: id, iCalUID: uid,
                      title: title, startTs: start, endTs: end, isAllDay: false, status: status,
                      myResponseStatus: response, organizerEmail: "org@x.com", attendeesJSON: nil,
                      meetingURL: url, location: nil, descriptionText: nil, htmlLink: nil,
                      originalStartTs: originalStart, etag: nil, updatedAt: nil, fetchedAt: Date())
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let end = Date(timeIntervalSince1970: 1_800_003_600)

    @Test func sameMeetingAcrossTwoAccountsMergesToOneWithTwoSources() {
        let a = makeEvent(account: "a@x.com", cal: "a@x.com", id: "id_a", uid: "UID-123",
                          title: "Sync", start: start, end: end)
        let b = makeEvent(account: "b@y.com", cal: "b@y.com", id: "id_b", uid: "UID-123",
                          title: "Sync", start: start, end: end)
        let unified = EventDeduplicator.deduplicate([a, b], primaryEmail: nil) { _, _ in "#111111" }
        #expect(unified.count == 1)
        #expect(unified.first?.sources.count == 2)
    }

    @Test func recurringInstancesShareUIDButStayDistinctByInstanceStart() {
        let s2 = end  // a later instance
        let e2 = Date(timeIntervalSince1970: 1_800_007_200)
        let inst1 = makeEvent(account: "a@x.com", cal: "c", id: "r_1", uid: "REC-1",
                              title: "Standup", start: start, end: end, originalStart: start)
        let inst2 = makeEvent(account: "a@x.com", cal: "c", id: "r_2", uid: "REC-1",
                              title: "Standup", start: s2, end: e2, originalStart: s2)
        let unified = EventDeduplicator.deduplicate([inst1, inst2], primaryEmail: nil) { _, _ in nil }
        #expect(unified.count == 2)
    }

    @Test func declinedOnOneAcceptedOnOtherIsEffectivelyAccepted() {
        let a = makeEvent(account: "a@x.com", cal: "a", id: "1", uid: "U", title: "M",
                          start: start, end: end, response: "declined")
        let b = makeEvent(account: "b@y.com", cal: "b", id: "2", uid: "U", title: "M",
                          start: start, end: end, response: "accepted")
        let unified = EventDeduplicator.deduplicate([a, b], primaryEmail: nil) { _, _ in nil }
        #expect(unified.count == 1)
        #expect(unified.first?.effectiveResponse == "accepted")
        #expect(unified.first?.winnerAccountEmail == "b@y.com")  // best response wins
    }

    @Test func cancelledWithoutConfirmedCopyShowsCancelled() {
        let a = makeEvent(account: "a@x.com", cal: "a", id: "1", uid: "U", title: "M",
                          start: start, end: end, status: "cancelled")
        let unified = EventDeduplicator.deduplicate([a], primaryEmail: nil) { _, _ in nil }
        #expect(unified.first?.status == "cancelled")
    }

    @Test func noICalUIDFallsBackToFuzzyKeyAndStillMergesIdentical() {
        let a = makeEvent(account: "a@x.com", cal: "a", id: "1", uid: nil, title: "Lunch",
                          start: start, end: end, url: "https://meet.google.com/abc")
        let b = makeEvent(account: "b@y.com", cal: "b", id: "2", uid: nil, title: "Lunch",
                          start: start, end: end, url: "https://meet.google.com/abc")
        let unified = EventDeduplicator.deduplicate([a, b], primaryEmail: nil) { _, _ in nil }
        #expect(unified.count == 1)
    }

    @Test func primaryAccountPreferenceBreaksTies() {
        let a = makeEvent(account: "a@x.com", cal: "a", id: "1", uid: "U", title: "M",
                          start: start, end: end, response: "accepted")
        let b = makeEvent(account: "b@y.com", cal: "b", id: "2", uid: "U", title: "M",
                          start: start, end: end, response: "accepted")
        let unified = EventDeduplicator.deduplicate([a, b], primaryEmail: "b@y.com") { _, _ in nil }
        #expect(unified.first?.winnerAccountEmail == "b@y.com")
    }
}
