import Foundation

/// Pure reconciliation between the *desired* set of meeting reminders and what's
/// already scheduled/delivered. Deciding what to schedule and cancel is separated
/// from UNUserNotificationCenter so it can be unit-tested.
enum NotificationPlanner {
    enum ReminderState: String, Equatable {
        case scheduled, delivered, lateCatchUp, quietHours, disabled, permissionUnavailable
        case alreadyStarted, outsideHorizon, declined, cancelled, allDay, notScheduled, catchUpClaimed
    }

    struct ReminderDiagnostic: Equatable, Identifiable {
        let id: String
        let title: String
        let startTs: Date
        let state: ReminderState
        let detail: String
    }

    struct ReminderDiagnosticsSnapshot: Equatable {
        let notificationsEnabled: Bool
        let authorization: String
        let alertsEnabled: Bool
        let soundsEnabled: Bool
        let pendingCount: Int
        let nextFireAt: Date?
        let occurrences: [ReminderDiagnostic]
    }

    struct DesiredNotification: Equatable {
        let identifier: String
        let dedupKey: String
        let startTs: Date
        let fireAt: Date
        let title: String
        let body: String
        let meetingURL: String?
        let htmlLink: String?
    }

    struct Plan: Equatable {
        var toSchedule: [DesiredNotification]
        var toCancelIdentifiers: [String]
    }

    struct PendingContent: Equatable {
        var title: String
        var body: String
        var meetingURL: String?
        var htmlLink: String?
        var leadMinutes: Int?
        var sound: String?
    }

    static func needsReplacement(_ pending: PendingContent, desired: DesiredNotification,
                                 leadMinutes: Int, sound: String) -> Bool {
        pending.title != desired.title || pending.body != desired.body
            || (pending.meetingURL ?? "") != (desired.meetingURL ?? "")
            || (pending.htmlLink ?? "") != (desired.htmlLink ?? "")
            || pending.leadMinutes != leadMinutes || pending.sound != sound
    }

    /// A pending one-shot request is current only while its scheduled fire date
    /// is in the future. macOS may return nil for `nextTriggerDate()` after it
    /// expires; in that case use the date persisted in the request payload.
    static func pendingRequestHasNotExpired(scheduledFireAt: Date?, nextTriggerDate: Date?, now: Date) -> Bool {
        guard let fireAt = scheduledFireAt ?? nextTriggerDate else { return false }
        return fireAt > now
    }

    static func diagnosticState(for status: NotificationStatus?) -> ReminderState? {
        switch status {
        case .delivered: .delivered
        case .catchUpClaimed: .catchUpClaimed
        default: nil
        }
    }

    static func occurrence(from identifier: String) -> (key: String, start: Date)? {
        guard identifier.hasPrefix("mtg|"), !identifier.hasSuffix("|snooze"),
              let split = identifier.lastIndex(of: "|"),
              let epoch = Double(identifier[identifier.index(after: split)...]) else { return nil }
        return (String(identifier[identifier.index(identifier.startIndex, offsetBy: 4)..<split]),
                Date(timeIntervalSince1970: epoch))
    }

    static func snoozableOccurrences(from events: [UnifiedEvent], now: Date, showDeclined: Bool) -> Set<String> {
        Set(events.filter {
            !$0.isAllDay && $0.status != "cancelled" && $0.endTs > now
                && (showDeclined || $0.effectiveResponse != "declined")
        }.map { identifier(dedupKey: $0.dedupKey, startTs: $0.startTs) })
    }

    /// Notification identifier is stable per (meeting, start) so a rescheduled
    /// meeting (new start) replaces the old pending request.
    static func identifier(dedupKey: String, startTs: Date) -> String {
        "mtg|\(dedupKey)|\(Int(startTs.timeIntervalSince1970))"
    }

    /// Build the desired reminder set from unified events.
    static func desired(from events: [UnifiedEvent], now: Date, leadMinutes: Int,
                        showDeclined: Bool, accountLabel: (UnifiedEvent) -> String?,
                        catchUpMinutes: Int = 10) -> [DesiredNotification] {
        let lead = TimeInterval(leadMinutes * 60)
        return events.compactMap { e in
            guard !e.isAllDay, e.status != "cancelled" else { return nil }
            guard showDeclined || e.effectiveResponse != "declined" else { return nil }
            guard e.endTs > now else { return nil }
            guard e.startTs > now || now.timeIntervalSince(e.startTs) <= TimeInterval(catchUpMinutes * 60) else { return nil }
            // Only remind for the near horizon (today + tomorrow).
            guard e.startTs.timeIntervalSince(now) < 48 * 3600 else { return nil }

            let fireAt = max(e.startTs.addingTimeInterval(-lead), now.addingTimeInterval(1))
            let time = e.startTs.formatted(date: .omitted, time: .shortened)
            var parts = ["Starts at \(time)"]
            if let project = e.projectId { parts.append("Project: \(project)") }
            if e.meetingURL != nil { parts.append("has a meeting link") }
            if let label = accountLabel(e) { parts.append("via \(label)") }
            return DesiredNotification(
                identifier: identifier(dedupKey: e.dedupKey, startTs: e.startTs),
                dedupKey: e.dedupKey, startTs: e.startTs, fireAt: fireAt,
                title: e.title, body: parts.joined(separator: " · "),
                meetingURL: e.meetingURL, htmlLink: e.htmlLink)
        }
    }

    static func snoozeFireAt(now: Date, event: UnifiedEvent?, showDeclined: Bool,
                             quiet: (Date) -> Bool, minutes: Int = 5) -> Date? {
        guard let event, !event.isAllDay, event.status != "cancelled",
              showDeclined || event.effectiveResponse != "declined", event.endTs > now else { return nil }
        let fireAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        guard fireAt < event.endTs, !quiet(fireAt) else { return nil }
        return fireAt
    }

    static func isMorningActivity(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return (4..<12).contains(hour)
    }

    static func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func shouldSendMorningAgenda(enabled: Bool, lastSentDay: String?, activityAt: Date,
                                        now: Date, calendar: Calendar = .current) -> Bool {
        enabled && isMorningActivity(activityAt, calendar: calendar)
            && isMorningActivity(now, calendar: calendar)
            && localDayKey(activityAt, calendar: calendar) == localDayKey(now, calendar: calendar)
            && lastSentDay != localDayKey(activityAt, calendar: calendar)
    }

    static func morningAgendaEvents(_ events: [UnifiedEvent], on day: Date,
                                    showDeclined: Bool, calendar: Calendar = .current) -> [UnifiedEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return events.filter { event in
            guard event.status != "cancelled", showDeclined || event.effectiveResponse != "declined" else { return false }
            if event.isAllDay { return event.startTs < nextDay && event.endTs > dayStart }
            return calendar.isDate(event.startTs, inSameDayAs: day)
        }.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            return lhs.startTs < rhs.startTs
        }
    }

    /// Diff desired vs currently pending vs the delivered ledger.
    /// - pendingIdentifiers: identifiers already scheduled with the system.
    /// - deliveredKeys: (dedupKey, startEpoch) already delivered — never re-schedule.
    static func plan(desired: [DesiredNotification],
                     pendingIdentifiers: Set<String>,
                     deliveredKeys: Set<String>) -> Plan {
        let desiredIds = Set(desired.map(\.identifier))

        // Cancel anything pending that's no longer desired (cancelled/declined/moved).
        let toCancel = pendingIdentifiers.subtracting(desiredIds)

        // Schedule desired items that aren't pending and haven't already fired.
        let toSchedule = desired.filter { d in
            let ledgerKey = "\(d.dedupKey)|\(Int(d.startTs.timeIntervalSince1970))"
            return !pendingIdentifiers.contains(d.identifier) && !deliveredKeys.contains(ledgerKey)
        }

        return Plan(toSchedule: toSchedule, toCancelIdentifiers: Array(toCancel).sorted())
    }

    static func ledgerKey(dedupKey: String, startTs: Date) -> String {
        "\(dedupKey)|\(Int(startTs.timeIntervalSince1970))"
    }

    /// Only explicit delivery is durable evidence that a reminder was shown.
    /// A pending request can disappear from Notification Center without firing
    /// (for example across sleep/wake), so a stale pending ledger row must be
    /// eligible for reconciliation to schedule again.
    static func ledgerStatusSuppressesReminder(_ status: NotificationStatus) -> Bool {
        status == .delivered || status == .catchUpClaimed
    }
}
