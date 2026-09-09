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
    private var reconcileGeneration = 0
    private var reconciling = false
    private var queuedReconcile: ([UnifiedEvent], (UnifiedEvent) -> String?)?
    private var recordingPromptIdentifiers: Set<String> = []

    private init() {}

    func configure() {
        center.delegate = delegate
        let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
        let agenda = UNNotificationAction(identifier: "OPEN_AGENDA", title: "Open meeting / Project", options: [.foreground])
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

    func postRecordingPrompt(_ kind: RecordingPromptKind, sessionID: UUID, promptID: UUID) {
        let identifier = "halle-recording-prompt|\(promptID.uuidString)"
        recordingPromptIdentifiers.insert(identifier)
        Task {
            await requestAuthorizationIfNeeded()
            guard authorized, RecordingService.shared.currentSession?.id == sessionID,
                  RecordingService.shared.activePromptID == promptID else { return }
            let content = UNMutableNotificationContent()
            content.title = kind == .silence ? "Hall-e is still recording" : "Scheduled meeting ended"
            content.body = kind == .silence
                ? "No voice detected for \(Int(AppPreferences.recordingSilenceSeconds)) seconds. " + (AppPreferences.silenceAutoStopEnabled ? "Recording will stop in \(Int(AppPreferences.recordingConfirmationSeconds)) seconds unless you keep recording or speech resumes." : "Stop or keep recording.")
                : "Stop now or extend the recording by five minutes."
            content.categoryIdentifier = kind == .silence
                ? Self.recordingSilenceCategoryId : Self.recordingEndCategoryId
            content.sound = .default
            content.userInfo = ["recordingPrompt": kind == .silence ? "silence" : "scheduledEnd", "recordingSessionID": sessionID.uuidString, "recordingPromptID": promptID.uuidString]
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await center.add(request)
            if RecordingService.shared.currentSession?.id != sessionID || RecordingService.shared.activePromptID != promptID {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
        }
    }

    func clearRecordingPrompts() {
        let identifiers = Array(recordingPromptIdentifiers) + ["halle-recording-prompt"]
        recordingPromptIdentifiers.removeAll()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func refreshReminders() async {
        await reconcile(events: AppState.shared.agenda, accountColorLabel: { $0.winnerAccountEmail })
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
        content.sound = AppPreferences.meetingReminderSound.notificationSound
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
        reconcileGeneration += 1
        queuedReconcile = (events, accountColorLabel)
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        while let next = queuedReconcile {
            queuedReconcile = nil
            await reconcilePass(events: next.0, accountColorLabel: next.1)
        }
    }

    private func reconcilePass(events: [UnifiedEvent], accountColorLabel: @escaping (UnifiedEvent) -> String?) async {
        let generation = reconcileGeneration
        let leadMinutes = AppPreferences.notificationLeadMinutes
        let sound = AppPreferences.meetingReminderSound
        let showDeclined = AppPreferences.showDeclinedEvents
        let quietStart = AppPreferences.quietHoursStart
        let quietEnd = AppPreferences.quietHoursEnd
        let isQuiet: (Date) -> Bool = { date in
            let hour = Calendar.current.component(.hour, from: date)
            return quietStart <= quietEnd ? (quietStart..<quietEnd).contains(hour) : hour >= quietStart || hour < quietEnd
        }
        let pending = await center.pendingNotificationRequests()
        guard generation == reconcileGeneration else { return }
        let owned = pending.filter { $0.content.categoryIdentifier == Self.categoryId }
        guard AppPreferences.notificationsEnabled else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            await markLedger(identifiers: owned.map(\.identifier), status: .cancelled)
            return
        }
        await requestAuthorizationIfNeeded()
        guard authorized, generation == reconcileGeneration else { return }
        for notification in await center.deliveredNotifications() {
            let info = notification.request.content.userInfo
            if let key = info["dedupKey"] as? String, let epoch = info["startTs"] as? Double {
                await markDelivered(dedupKey: key, startTs: Date(timeIntervalSince1970: epoch))
            }
        }
        let now = Date()
        let desired = NotificationPlanner.desired(
            from: events, now: now,
            leadMinutes: leadMinutes,
            showDeclined: showDeclined,
            accountLabel: accountColorLabel).filter { !isQuiet($0.fireAt) }

        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
        let ordinary = owned.filter { !$0.identifier.hasSuffix("|snooze") }
        let unchanged = ordinary.filter { request in
            guard let target = desiredByID[request.identifier] else { return true }
            let info = request.content.userInfo
            return !NotificationPlanner.needsReplacement(
                .init(title: request.content.title, body: request.content.body,
                      meetingURL: info["meetingURL"] as? String, htmlLink: info["htmlLink"] as? String,
                      leadMinutes: info["leadMinutes"] as? Int, sound: info["soundChoice"] as? String),
                desired: target, leadMinutes: leadMinutes,
                sound: sound.rawValue)
        }
        let pendingIds = Set(unchanged.map(\.identifier))
        let deliveredKeys = await deliveredLedgerKeys(pendingIdentifiers: Set(ordinary.map(\.identifier)))
        guard generation == reconcileGeneration, AppPreferences.notificationsEnabled else { return }
        // Preserve snoozes while their occurrence remains eligible, cancel on changes.
        let eligible = NotificationPlanner.snoozableOccurrences(from: events, now: now, showDeclined: showDeclined)
        let snoozes = owned.filter { $0.identifier.hasSuffix("|snooze") }
        let obsoleteSnoozes = snoozes.filter { request in
            let fire = (request.content.userInfo["snoozeFireAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return !eligible.contains(String(request.identifier.dropLast(7))) || fire.map(isQuiet) == true
        }
        let obsoleteIDs = Set(obsoleteSnoozes.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: Array(obsoleteIDs))
        for snooze in snoozes where !obsoleteIDs.contains(snooze.identifier) {
            guard (snooze.content.userInfo["soundChoice"] as? String) != sound.rawValue,
                  let content = snooze.content.mutableCopy() as? UNMutableNotificationContent else { continue }
            let fire = (content.userInfo["snoozeFireAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? (snooze.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            guard let fire, fire > Date() else { continue }
            content.sound = sound.notificationSound
            content.userInfo["soundChoice"] = sound.rawValue
            content.userInfo["snoozeFireAt"] = fire.timeIntervalSince1970
            guard generation == reconcileGeneration else { return }
            try? await center.add(UNNotificationRequest(identifier: snooze.identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)))
            guard generation == reconcileGeneration else { return }
        }

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
            content.sound = sound.notificationSound
            content.userInfo = ["startTs": d.startTs.timeIntervalSince1970,
                                "leadMinutes": leadMinutes,
                                "soundChoice": sound.rawValue,
                                "dedupKey": d.dedupKey,
                                "meetingURL": d.meetingURL ?? "",
                                "htmlLink": d.htmlLink ?? ""]
            let interval = max(1, d.fireAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: d.identifier, content: content, trigger: trigger)
            guard generation == reconcileGeneration, AppPreferences.notificationsEnabled else { return }
            do {
                try await center.add(request)
                if generation != reconcileGeneration || !AppPreferences.notificationsEnabled {
                    center.removePendingNotificationRequests(withIdentifiers: [d.identifier])
                    return
                }
                await upsertLedger(dedupKey: d.dedupKey, startTs: d.startTs, scheduledFor: d.fireAt)
            } catch {
                Log.app.error("Could not schedule meeting reminder: \(error, privacy: .private)")
            }
        }
    }

    // MARK: - Ledger

    // Ledger access is async so SQLite I/O runs on GRDB's queue, not the main
    // actor (reconcile runs after every sync).
    private func deliveredLedgerKeys(pendingIdentifiers: Set<String>) async -> Set<String> {
        (try? await AppDatabase.shared.dbQueue.read { db -> Set<String> in
            let now = Date()
            let rows = try NotificationRecord.fetchAll(db).filter {
                $0.status == NotificationStatus.delivered.rawValue ||
                ($0.status == NotificationStatus.pending.rawValue && $0.scheduledFor <= now &&
                 !pendingIdentifiers.contains(NotificationPlanner.identifier(dedupKey: $0.dedupKey, startTs: $0.startTs)))
            }
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
            guard let occurrence = NotificationPlanner.occurrence(from: id) else { return nil }
            return (occurrence.key, occurrence.start)
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
            var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs])
                ?? NotificationRecord(dedupKey: dedupKey, startTs: startTs, scheduledFor: Date(),
                                      status: NotificationStatus.delivered.rawValue, deliveredAt: Date(), snoozedUntil: nil)
            rec.status = NotificationStatus.delivered.rawValue
            rec.deliveredAt = Date()
            try rec.save(db)
        }
    }
}
