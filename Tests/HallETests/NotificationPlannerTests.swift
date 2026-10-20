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

    @Test func onlyDeliveredLedgerRowsSuppressReminder() {
        #expect(NotificationPlanner.ledgerStatusSuppressesReminder(.delivered))
        #expect(!NotificationPlanner.ledgerStatusSuppressesReminder(.pending))
        #expect(!NotificationPlanner.ledgerStatusSuppressesReminder(.cancelled))
        #expect(!NotificationPlanner.ledgerStatusSuppressesReminder(.skipped))
    }

    @Test func droppedPendingRequestIsScheduledAgain() {
        let start = now.addingTimeInterval(60)
        let desired = NotificationPlanner.desired(from: [event("k", start: start)], now: now,
                                                  leadMinutes: 5, showDeclined: false,
                                                  accountLabel: { _ in nil })
        #expect(desired.first?.fireAt == now.addingTimeInterval(1))

        // The database may still say pending after Notification Center drops the
        // request. Since pending is not delivery evidence, reconciliation must
        // leave deliveredKeys empty and schedule the catch-up reminder.
        let deliveredKeys: Set<String> = NotificationPlanner.ledgerStatusSuppressesReminder(.pending)
            ? [NotificationPlanner.ledgerKey(dedupKey: "k", startTs: start)]
            : []
        let plan = NotificationPlanner.plan(desired: desired,
                                            pendingIdentifiers: [],
                                            deliveredKeys: deliveredKeys)
        #expect(plan.toSchedule.map(\.dedupKey) == ["k"])
    }

    @Test func wakeCatchUpIsBoundedToTenMinutesAndMeetingEnd() {
        let started = event("started", start: now.addingTimeInterval(-9 * 60))
        let tooLate = event("too-late", start: now.addingTimeInterval(-11 * 60))
        let ended = event("ended", start: now.addingTimeInterval(-20 * 60))
        let desired = NotificationPlanner.desired(from: [started, tooLate, ended], now: now,
            leadMinutes: 5, showDeclined: false, accountLabel: { _ in nil })
        #expect(desired.map(\.dedupKey) == ["started"])
        #expect(desired.first?.fireAt == now.addingTimeInterval(1))
    }

    @Test func snoozeMustRemainBeforeOccurrenceEndAndOutsideQuietHours() {
        let running = event("running", start: now.addingTimeInterval(-20 * 60))
        let almostOver = UnifiedEvent(dedupKey: "short", title: "Short", startTs: now.addingTimeInterval(-26 * 60),
            endTs: now.addingTimeInterval(4 * 60), isAllDay: false, status: "confirmed", effectiveResponse: "accepted",
            meetingURL: nil, location: nil, descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
            iCalUID: nil, winnerAccountEmail: "test@example.test", projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
        #expect(NotificationPlanner.snoozeFireAt(now: now, event: running, showDeclined: false, quiet: { _ in false }) == now.addingTimeInterval(5 * 60))
        #expect(NotificationPlanner.snoozeFireAt(now: now, event: almostOver, showDeclined: false, quiet: { _ in false }) == nil)
        #expect(NotificationPlanner.snoozeFireAt(now: now, event: running, showDeclined: false, quiet: { _ in true }) == nil)
        var cancelled = running; cancelled.status = "cancelled"
        #expect(NotificationPlanner.snoozeFireAt(now: now, event: cancelled, showDeclined: false, quiet: { _ in false }) == nil)
    }

    @Test func morningActivityWindowAndAgendaRespectDayDeclinedAndAllDayRules() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
        #expect(NotificationPlanner.isMorningActivity(day, calendar: calendar))
        #expect(!NotificationPlanner.isMorningActivity(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!, calendar: calendar))
        #expect(NotificationPlanner.localDayKey(day, calendar: calendar) == "2026-10-20")
        #expect(NotificationPlanner.shouldSendMorningAgenda(enabled: true, lastSentDay: nil,
            activityAt: day, now: day.addingTimeInterval(60), calendar: calendar))
        #expect(!NotificationPlanner.shouldSendMorningAgenda(enabled: true, lastSentDay: "2026-10-20",
            activityAt: day, now: day.addingTimeInterval(60), calendar: calendar))
        #expect(!NotificationPlanner.shouldSendMorningAgenda(enabled: true, lastSentDay: nil,
            activityAt: day, now: calendar.date(bySettingHour: 12, minute: 1, second: 0, of: day)!, calendar: calendar))

        var allDay = event("all-day", start: calendar.startOfDay(for: day), allDay: true)
        allDay.endTs = calendar.date(byAdding: .day, value: 1, to: allDay.startTs)!
        var spanning = event("spanning", start: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: day))!, allDay: true)
        spanning.endTs = calendar.date(byAdding: .day, value: 2, to: spanning.startTs)!
        var declined = event("declined", start: day.addingTimeInterval(3600), response: "declined")
        declined.endTs = day.addingTimeInterval(7200)
        var cancelled = event("cancelled", start: day.addingTimeInterval(2 * 3600), status: "cancelled")
        cancelled.endTs = day.addingTimeInterval(3 * 3600)
        let events = [allDay, spanning, declined, cancelled]
        #expect(NotificationPlanner.morningAgendaEvents(events, on: day, showDeclined: false, calendar: calendar).map(\.dedupKey) == ["spanning", "all-day"])
        #expect(NotificationPlanner.morningAgendaEvents(events, on: day, showDeclined: true, calendar: calendar).map(\.dedupKey) == ["spanning", "all-day", "declined"])
    }

    @Test func catchUpClaimPreventsRepeatedReminder() {
        #expect(NotificationPlanner.ledgerStatusSuppressesReminder(.catchUpClaimed))
        #expect(!NotificationPlanner.ledgerStatusSuppressesReminder(.pending))
        #expect(NotificationPlanner.diagnosticState(for: .delivered) == .delivered)
        #expect(NotificationPlanner.diagnosticState(for: .catchUpClaimed) == .catchUpClaimed)
        #expect(NotificationPlanner.diagnosticState(for: .pending) == nil)
    }

    @Test func expiredOneShotRequestsAreRearmedEvenWhenTriggerDateIsNil() {
        #expect(!NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: now.addingTimeInterval(-1),
            nextTriggerDate: nil, now: now))
        #expect(!NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: nil,
            nextTriggerDate: nil, now: now))
        #expect(!NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: nil,
            nextTriggerDate: now.addingTimeInterval(-1), now: now))
        #expect(NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: now.addingTimeInterval(60),
            nextTriggerDate: nil, now: now))
    }
}
