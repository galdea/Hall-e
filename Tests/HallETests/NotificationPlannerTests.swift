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
}
