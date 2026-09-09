import Foundation

/// Pure reconciliation between the *desired* set of meeting reminders and what's
/// already scheduled/delivered. Deciding what to schedule and cancel is separated
/// from UNUserNotificationCenter so it can be unit-tested.
enum NotificationPlanner {
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
                        showDeclined: Bool, accountLabel: (UnifiedEvent) -> String?) -> [DesiredNotification] {
        let lead = TimeInterval(leadMinutes * 60)
        return events.compactMap { e in
            guard !e.isAllDay, e.status != "cancelled" else { return nil }
            guard showDeclined || e.effectiveResponse != "declined" else { return nil }
            guard e.startTs > now else { return nil }
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
}
