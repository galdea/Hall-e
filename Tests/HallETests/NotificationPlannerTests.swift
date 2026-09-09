import Testing
import Foundation
@testable import HallE

@Suite("NotificationPlanner")
struct NotificationPlannerTests {
    private func event(_ key: String, start: Date, allDay: Bool = false,
                       status: String = "confirmed", response: String? = "accepted") -> UnifiedEvent {
        UnifiedEvent(dedupKey: key, title: "Mtg \(key)", startTs: start,
                     endTs: start.addingTimeInterval(1800), isAllDay: allDay, status: status,
                     effectiveResponse: response, meetingURL: "https://meet.google.com/x", location: nil,
                     descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                     iCalUID: nil, winnerAccountEmail: "a@x.com", projectId: nil,
                     projectConfidence: nil, sourcesJSON: "[]")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func desiredExcludesAllDayCancelledDeclinedAndPast() {
        let events = [
            event("future", start: now.addingTimeInterval(3600)),
            event("allday", start: now.addingTimeInterval(3600), allDay: true),
            event("cancelled", start: now.addingTimeInterval(3600), status: "cancelled"),
            event("declined", start: now.addingTimeInterval(3600), response: "declined"),
            event("past", start: now.addingTimeInterval(-3600)),
        ]
        let desired = NotificationPlanner.desired(from: events, now: now, leadMinutes: 15,
                                                  showDeclined: false, accountLabel: { _ in "a@x.com" })
        #expect(desired.map(\.dedupKey) == ["future"])
    }

    @Test func fireTimeIsLeadMinutesBeforeStart() {
        let start = now.addingTimeInterval(3600)  // 60 min out
        let desired = NotificationPlanner.desired(from: [event("k", start: start)], now: now,
                                                  leadMinutes: 15, showDeclined: false, accountLabel: { _ in nil })
        #expect(desired.count == 1)
        #expect(abs(desired[0].fireAt.timeIntervalSince(start.addingTimeInterval(-900))) < 1)
    }

    @Test func planSchedulesNewButNotAlreadyPendingOrDelivered() {
        let start = now.addingTimeInterval(3600)
        let d = NotificationPlanner.desired(from: [event("k", start: start)], now: now,
                                            leadMinutes: 15, showDeclined: false, accountLabel: { _ in nil })
        let id = d[0].identifier
        let ledgerKey = NotificationPlanner.ledgerKey(dedupKey: "k", startTs: start)

        // Fresh: schedule it.
        var plan = NotificationPlanner.plan(desired: d, pendingIdentifiers: [], deliveredKeys: [])
        #expect(plan.toSchedule.count == 1)

        // Already pending: don't reschedule.
        plan = NotificationPlanner.plan(desired: d, pendingIdentifiers: [id], deliveredKeys: [])
        #expect(plan.toSchedule.isEmpty)

        // Already delivered: don't reschedule (prevents re-notify on resync).
        plan = NotificationPlanner.plan(desired: d, pendingIdentifiers: [], deliveredKeys: [ledgerKey])
        #expect(plan.toSchedule.isEmpty)
    }

    @Test func planCancelsPendingNoLongerDesired() {
        // A meeting that was pending but is now cancelled → not in desired → cancel it.
        let staleId = NotificationPlanner.identifier(dedupKey: "gone", startTs: now.addingTimeInterval(3600))
        let plan = NotificationPlanner.plan(desired: [], pendingIdentifiers: [staleId], deliveredKeys: [])
        #expect(plan.toCancelIdentifiers == [staleId])
    }

    @Test func movedMeetingReplacesOldPending() {
        // Same meeting, new start → new identifier; old identifier should be cancelled.
        let oldStart = now.addingTimeInterval(3600)
        let newStart = now.addingTimeInterval(7200)
        let oldId = NotificationPlanner.identifier(dedupKey: "k", startTs: oldStart)
        let d = NotificationPlanner.desired(from: [event("k", start: newStart)], now: now,
                                            leadMinutes: 15, showDeclined: false, accountLabel: { _ in nil })
        let plan = NotificationPlanner.plan(desired: d, pendingIdentifiers: [oldId], deliveredKeys: [])
        #expect(plan.toCancelIdentifiers == [oldId])
        #expect(plan.toSchedule.count == 1)
        #expect(plan.toSchedule[0].identifier != oldId)
    }
    @Test func fiveMinuteReminderAndLateArrival() {
        let start = now.addingTimeInterval(600)
        let desired = NotificationPlanner.desired(from: [event("k", start: start)], now: now, leadMinutes: 5,
                                                  showDeclined: false, accountLabel: { _ in nil })
        #expect(desired.first?.fireAt == start.addingTimeInterval(-300))
        let late = NotificationPlanner.desired(from: [event("k", start: now.addingTimeInterval(60))], now: now,
                                               leadMinutes: 5, showDeclined: false, accountLabel: { _ in nil })
        #expect(late.first?.fireAt == now.addingTimeInterval(1))
    }

    @Test func pendingContentChangesRequireReplacement() throws {
        let desired = try #require(NotificationPlanner.desired(from: [event("k", start: now.addingTimeInterval(600))], now: now,
            leadMinutes: 5, showDeclined: false, accountLabel: { _ in nil }).first)
        var pending = NotificationPlanner.PendingContent(title: desired.title, body: desired.body,
            meetingURL: desired.meetingURL, htmlLink: desired.htmlLink, leadMinutes: 5, sound: "gentle")
        #expect(!NotificationPlanner.needsReplacement(pending, desired: desired, leadMinutes: 5, sound: "gentle"))
        #expect(NotificationPlanner.needsReplacement(pending, desired: desired, leadMinutes: 10, sound: "gentle"))
        #expect(NotificationPlanner.needsReplacement(pending, desired: desired, leadMinutes: 5, sound: "silent"))
        pending.meetingURL = "https://meet.google.com/changed"
        #expect(NotificationPlanner.needsReplacement(pending, desired: desired, leadMinutes: 5, sound: "gentle"))
    }

    @Test func occurrenceParserHandlesDelimiterInsideKeyAndRejectsSnooze() {
        let identifier = NotificationPlanner.identifier(dedupKey: "a|b", startTs: now)
        #expect(NotificationPlanner.occurrence(from: identifier)?.key == "a|b")
        #expect(NotificationPlanner.occurrence(from: identifier)?.start == now)
        #expect(NotificationPlanner.occurrence(from: identifier + "|snooze") == nil)
        #expect(NotificationPlanner.occurrence(from: "halle-recording-prompt") == nil)
    }
    @Test func snoozesSurviveMeetingStartButNotCancellationOrReschedule() {
        let started = event("k", start: now.addingTimeInterval(-60))
        let id = NotificationPlanner.identifier(dedupKey: "k", startTs: started.startTs)
        #expect(NotificationPlanner.snoozableOccurrences(from: [started], now: now, showDeclined: false).contains(id))
        var cancelled = started; cancelled.status = "cancelled"
        #expect(NotificationPlanner.snoozableOccurrences(from: [cancelled], now: now, showDeclined: false).isEmpty)
        var moved = started; moved.startTs = now.addingTimeInterval(600)
        #expect(!NotificationPlanner.snoozableOccurrences(from: [moved], now: now, showDeclined: false).contains(id))
    }
}
