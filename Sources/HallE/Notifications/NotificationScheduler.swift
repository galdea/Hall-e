import Foundation
import UserNotifications
import GRDB

/// Applies `NotificationPlanner` decisions to UNUserNotificationCenter and keeps
/// the `notification_record` ledger so meetings never re-notify on every resync.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    static let categoryId = "HALLE_MEETING"
    private let center = UNUserNotificationCenter.current()
    private let delegate = NotificationDelegate()
    private var authorized = false

    private init() {}

    func configure() {
        center.delegate = delegate
        let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
        let agenda = UNNotificationAction(identifier: "OPEN_AGENDA", title: "Open agenda", options: [.foreground])
        let note = UNNotificationAction(identifier: "PREPARE_NOTE", title: "Prepare note", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "SNOOZE_5M", title: "Snooze 5 min", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId,
                                              actions: [join, agenda, note, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Ask for permission (call the first time we actually have something to notify).
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    /// Reconcile scheduled reminders against the current agenda.
    func reconcile(events: [UnifiedEvent], accountColorLabel: @escaping (UnifiedEvent) -> String?) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let now = Date()
        let desired = NotificationPlanner.desired(
            from: events, now: now,
            leadMinutes: AppPreferences.notificationLeadMinutes,
            showDeclined: AppPreferences.showDeclinedEvents,
            accountLabel: accountColorLabel)

        let pending = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map(\.identifier))
        let deliveredKeys = deliveredLedgerKeys()

        let plan = NotificationPlanner.plan(desired: desired,
                                            pendingIdentifiers: pendingIds,
                                            deliveredKeys: deliveredKeys)

        if !plan.toCancelIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: plan.toCancelIdentifiers)
            markLedger(identifiers: plan.toCancelIdentifiers, status: .cancelled)
        }

        for d in plan.toSchedule {
            let content = UNMutableNotificationContent()
            content.title = d.title
            content.body = d.body
            content.categoryIdentifier = Self.categoryId
            content.sound = .default
            content.userInfo = ["dedupKey": d.dedupKey,
                                "meetingURL": d.meetingURL ?? "",
                                "htmlLink": d.htmlLink ?? ""]
            let interval = max(1, d.fireAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: d.identifier, content: content, trigger: trigger)
            try? await center.add(request)
            upsertLedger(dedupKey: d.dedupKey, startTs: d.startTs, scheduledFor: d.fireAt)
        }
    }

    // MARK: - Ledger

    private func deliveredLedgerKeys() -> Set<String> {
        (try? AppDatabase.shared.dbQueue.read { db -> Set<String> in
            let rows = try NotificationRecord
                .filter(NotificationRecord.Columns.status == NotificationStatus.delivered.rawValue)
                .fetchAll(db)
            return Set(rows.map { NotificationPlanner.ledgerKey(dedupKey: $0.dedupKey, startTs: $0.startTs) })
        }) ?? []
    }

    private func upsertLedger(dedupKey: String, startTs: Date, scheduledFor: Date) {
        try? AppDatabase.shared.dbQueue.write { db in
            var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs])
                ?? NotificationRecord(dedupKey: dedupKey, startTs: startTs, scheduledFor: scheduledFor,
                                      status: NotificationStatus.pending.rawValue, deliveredAt: nil, snoozedUntil: nil)
            rec.scheduledFor = scheduledFor
            if rec.status != NotificationStatus.delivered.rawValue {
                rec.status = NotificationStatus.pending.rawValue
            }
            try rec.save(db)
        }
    }

    private func markLedger(identifiers: [String], status: NotificationStatus) {
        // Identifiers encode dedupKey + start epoch; parse back to update rows.
        for id in identifiers {
            let parts = id.split(separator: "|")
            guard parts.count == 3, let epoch = TimeInterval(parts[2]) else { continue }
            let dedupKey = String(parts[1])
            let startTs = Date(timeIntervalSince1970: epoch)
            try? AppDatabase.shared.dbQueue.write { db in
                if var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs]) {
                    rec.status = status.rawValue
                    try rec.save(db)
                }
            }
        }
    }

    func markDelivered(dedupKey: String, startTs: Date) {
        try? AppDatabase.shared.dbQueue.write { db in
            if var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs]) {
                rec.status = NotificationStatus.delivered.rawValue
                rec.deliveredAt = Date()
                try rec.save(db)
            }
        }
    }
}
