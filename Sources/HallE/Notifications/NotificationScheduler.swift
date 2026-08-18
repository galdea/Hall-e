import Foundation
import UserNotifications
import GRDB

/// Applies `NotificationPlanner` decisions to UNUserNotificationCenter and keeps
/// the `notification_record` ledger so meetings never re-notify on every resync.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    static let categoryId = "HALLE_MEETING"
    static let recordingSilenceCategoryId = "HALLE_RECORDING_SILENCE"
    static let recordingEndCategoryId = "HALLE_RECORDING_END"
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
        let stop = UNNotificationAction(identifier: "RECORDING_STOP", title: "Stop recording",
                                        options: [.foreground, .destructive])
        let keep = UNNotificationAction(identifier: "RECORDING_KEEP", title: "Keep recording", options: [])
        let extend = UNNotificationAction(identifier: "RECORDING_EXTEND", title: "Extend 5 minutes", options: [])
        let silenceCategory = UNNotificationCategory(identifier: Self.recordingSilenceCategoryId,
                                                     actions: [stop, keep], intentIdentifiers: [], options: [])
        let endCategory = UNNotificationCategory(identifier: Self.recordingEndCategoryId,
                                                 actions: [stop, extend], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, silenceCategory, endCategory])
    }

    enum RecordingPromptKind { case silence, scheduledEnd }

    func postRecordingPrompt(_ kind: RecordingPromptKind) {
        Task {
            await requestAuthorizationIfNeeded()
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = kind == .silence ? "Hall-e is still recording" : "Scheduled meeting ended"
            content.body = kind == .silence
                ? "No voice has been detected for 20 seconds."
                : "Stop now or extend the recording by five minutes."
            content.categoryIdentifier = kind == .silence
                ? Self.recordingSilenceCategoryId : Self.recordingEndCategoryId
            content.sound = .default
            content.userInfo = ["recordingPrompt": kind == .silence ? "silence" : "scheduledEnd"]
            let request = UNNotificationRequest(identifier: "halle-recording-prompt", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Ask for permission and return the status macOS reports after the request.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                authorized = false
                Log.app.error("notification authorization request failed: \(error, privacy: .public)")
            }
        default:
            authorized = false
        }
        return await authorizationStatus()
    }

    func sendTestNotification() async throws {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .provisional else {
            throw NotificationError.notAuthorized
        }
        let content = UNMutableNotificationContent()
        content.title = "Hall-e notifications are working"
        content.body = "Meeting reminders and recording prompts can appear on this Mac."
        content.sound = .default
        try await center.add(UNNotificationRequest(
            identifier: "halle-notification-test-\(UUID().uuidString)",
            content: content,
            trigger: nil))
    }

    private enum NotificationError: LocalizedError {
        case notAuthorized
        var errorDescription: String? { "Notifications are not allowed in System Settings." }
    }

    /// Reconcile scheduled reminders against the current agenda.
    func reconcile(events: [UnifiedEvent], accountColorLabel: @escaping (UnifiedEvent) -> String?) async {
        guard AppPreferences.notificationsEnabled else { return }
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let now = Date()
        let desired = NotificationPlanner.desired(
            from: events, now: now,
            leadMinutes: AppPreferences.notificationLeadMinutes,
            showDeclined: AppPreferences.showDeclinedEvents,
            accountLabel: accountColorLabel).filter { !AppPreferences.isQuietHour($0.fireAt) }

        let pending = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map(\.identifier))
        let deliveredKeys = await deliveredLedgerKeys()

        let plan = NotificationPlanner.plan(desired: desired,
                                            pendingIdentifiers: pendingIds,
                                            deliveredKeys: deliveredKeys)

        if !plan.toCancelIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: plan.toCancelIdentifiers)
            await markLedger(identifiers: plan.toCancelIdentifiers, status: .cancelled)
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
            await upsertLedger(dedupKey: d.dedupKey, startTs: d.startTs, scheduledFor: d.fireAt)
        }
    }

    // MARK: - Ledger

    // Ledger access is async so SQLite I/O runs on GRDB's queue, not the main
    // actor (reconcile runs after every sync).
    private func deliveredLedgerKeys() async -> Set<String> {
        (try? await AppDatabase.shared.dbQueue.read { db -> Set<String> in
            let rows = try NotificationRecord
                .filter(NotificationRecord.Columns.status == NotificationStatus.delivered.rawValue)
                .fetchAll(db)
            return Set(rows.map { NotificationPlanner.ledgerKey(dedupKey: $0.dedupKey, startTs: $0.startTs) })
        }) ?? []
    }

    private func upsertLedger(dedupKey: String, startTs: Date, scheduledFor: Date) async {
        try? await AppDatabase.shared.dbQueue.write { db in
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

    private func markLedger(identifiers: [String], status: NotificationStatus) async {
        // Identifiers encode dedupKey + start epoch; parse back to update rows.
        let parsed: [(dedupKey: String, startTs: Date)] = identifiers.compactMap { id in
            let parts = id.split(separator: "|")
            guard parts.count == 3, let epoch = TimeInterval(parts[2]) else { return nil }
            return (String(parts[1]), Date(timeIntervalSince1970: epoch))
        }
        guard !parsed.isEmpty else { return }
        try? await AppDatabase.shared.dbQueue.write { db in
            for entry in parsed {
                if var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": entry.dedupKey, "startTs": entry.startTs]) {
                    rec.status = status.rawValue
                    try rec.save(db)
                }
            }
        }
    }

    func markDelivered(dedupKey: String, startTs: Date) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            if var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs]) {
                rec.status = NotificationStatus.delivered.rawValue
                rec.deliveredAt = Date()
                try rec.save(db)
            }
        }
    }
}
