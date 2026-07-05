import Testing
import Foundation
@testable import HallE

@Suite("TimelineBuilder")
struct TimelineBuilderTests {
    private func makeUnified(title: String, start: Date, end: Date,
                             allDay: Bool = false, status: String = "confirmed") -> UnifiedEvent {
        UnifiedEvent(dedupKey: "k-\(title)-\(start.timeIntervalSince1970)", title: title,
                     startTs: start, endTs: end, isAllDay: allDay, status: status,
                     effectiveResponse: "accepted", meetingURL: nil, location: nil,
                     descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                     iCalUID: nil, winnerAccountEmail: "a@x.com", projectId: nil,
                     projectConfidence: nil, sourcesJSON: "[]")
    }

    // Fixed "now": 2026-07-03 10:30 local.
    private var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 3; c.hour = 10; c.minute = 30
        return Calendar.current.date(from: c)!
    }
    private func at(_ h: Int, _ m: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 3; c.hour = h; c.minute = m
        return Calendar.current.date(from: c)!
    }

    @Test func separatesAllDayFromTimed() {
        let events = [
            makeUnified(title: "Holiday", start: at(0, 0), end: at(23, 59), allDay: true),
            makeUnified(title: "Standup", start: at(9, 0), end: at(9, 30)),
        ]
        let t = TimelineBuilder.build(events: events, now: now)
        #expect(t.allDay.count == 1)
        #expect(t.hourGroups.flatMap(\.events).count == 1)
    }

    @Test func identifiesInProgressAndNext() {
        let events = [
            makeUnified(title: "Now Mtg", start: at(10, 0), end: at(11, 0)),   // in progress at 10:30
            makeUnified(title: "Later", start: at(14, 0), end: at(15, 0)),
        ]
        let t = TimelineBuilder.build(events: events, now: now)
        #expect(t.inProgress.map(\.title) == ["Now Mtg"])
        #expect(t.next?.title == "Later")
    }

    @Test func nextIsSoonestUpcomingOnly() {
        let events = [
            makeUnified(title: "Past", start: at(8, 0), end: at(8, 30)),
            makeUnified(title: "Soon", start: at(11, 0), end: at(11, 30)),
            makeUnified(title: "Evening", start: at(18, 0), end: at(19, 0)),
        ]
        let t = TimelineBuilder.build(events: events, now: now)
        #expect(t.next?.title == "Soon")
    }

    @Test func excludesCancelledByDefault() {
        let events = [makeUnified(title: "Cancelled", start: at(12, 0), end: at(13, 0), status: "cancelled")]
        let t = TimelineBuilder.build(events: events, now: now)
        #expect(t.isEmpty)
    }

    @Test func groupsByHour() {
        let events = [
            makeUnified(title: "A", start: at(9, 0), end: at(9, 30)),
            makeUnified(title: "B", start: at(9, 45), end: at(10, 0)),
            makeUnified(title: "C", start: at(14, 0), end: at(14, 30)),
        ]
        let t = TimelineBuilder.build(events: events, now: now)
        #expect(t.hourGroups.count == 2)          // 9am group (A,B) and 2pm group (C)
        #expect(t.hourGroups.first?.events.count == 2)
    }

    @Test func emptyDayIsEmpty() {
        let t = TimelineBuilder.build(events: [], now: now)
        #expect(t.isEmpty)
    }

    @Test func buildForArbitraryDayFiltersToThatDay() {
        let today = makeUnified(title: "Today", start: at(9, 0), end: at(9, 30))
        let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1, to: at(9, 0))!
        let tomorrow = makeUnified(title: "Tomorrow", start: tomorrowStart,
                                   end: tomorrowStart.addingTimeInterval(1800))
        let t = TimelineBuilder.build(events: [today, tomorrow], day: tomorrowStart, now: now)
        #expect(t.hourGroups.flatMap(\.events).map(\.title) == ["Tomorrow"])
    }

    @Test func daySummariesCountPerDay() {
        let interval = TimelineBuilder.periodInterval(scope: .week, anchor: now)
        let events = [makeUnified(title: "A", start: at(9, 0), end: at(9, 30)),
                      makeUnified(title: "B", start: at(11, 0), end: at(11, 30))]
        let sums = TimelineBuilder.daySummaries(in: interval, events: events)
        #expect(sums.count == 7)
        let todaySummary = sums.first { Calendar.current.isDate($0.day, inSameDayAs: now) }
        #expect(todaySummary?.count == 2)
    }

    @Test func periodIntervalSpansWeekAndMonth() {
        let week = TimelineBuilder.periodInterval(scope: .week, anchor: now)
        #expect(Calendar.current.dateComponents([.day], from: week.start, to: week.end).day == 7)
        let month = TimelineBuilder.periodInterval(scope: .month, anchor: now)  // July → 31 days
        #expect(Calendar.current.dateComponents([.day], from: month.start, to: month.end).day == 31)
    }
}
