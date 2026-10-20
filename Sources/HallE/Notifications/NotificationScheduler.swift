import Foundation
import UserNotifications
import GRDB
import CoreGraphics
import AppKit

/// Applies `NotificationPlanner` decisions to UNUserNotificationCenter and keeps
/// the `notification_record` ledger so meetings never re-notify on every resync.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    static let categoryId = "HALLE_MEETING"
    static let morningAgendaCategoryId = "HALLE_MORNING_AGENDA"
    static let recordingSilenceCategoryId = "HALLE_RECORDING_SILENCE"
    static let recordingEndCategoryId = "HALLE_RECORDING_END"
    private let center = UNUserNotificationCenter.current()
    private let delegate = NotificationDelegate()
    private var authorized = false
    private var reconcileGeneration = 0
    private var reconciling = false
    private var queuedReconcile: ([UnifiedEvent], (UnifiedEvent) -> String?)?
    private var recordingPromptIdentifiers: Set<String> = []
    private var morningActivityTimer: Timer?
    private var morningWakeObserver: NSObjectProtocol?
    private var lastMouseActivityAt: Date?
    private var pendingMorningActivityAt: Date?
    private var morningAgendaDaysInFlight: Set<String> = []
    private var schedulingErrors: [String: String] = [:]

    private init() {}

    func configure() {
        center.delegate = delegate
        startMorningActivityMonitoring()
        let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
        let agenda = UNNotificationAction(identifier: "OPEN_AGENDA", title: "Open meeting / Project", options: [.foreground])
        let note = UNNotificationAction(identifier: "PREPARE_NOTE", title: "Prepare note", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "SNOOZE_5M", title: "Snooze 5 min", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId,
                                              actions: [join, agenda, note, snooze],
                                              intentIdentifiers: [], options: [])
        let openToday = UNNotificationAction(identifier: "OPEN_TODAY", title: "Open Today", options: [.foreground])
        let morningCategory = UNNotificationCategory(identifier: Self.morningAgendaCategoryId,
                                                     actions: [openToday], intentIdentifiers: [], options: [])
        let stop = UNNotificationAction(identifier: "RECORDING_STOP", title: "Stop recording",
                                        options: [.foreground, .destructive])
        let keep = UNNotificationAction(identifier: "RECORDING_KEEP", title: "Keep recording", options: [])
        let extend = UNNotificationAction(identifier: "RECORDING_EXTEND", title: "Extend 5 minutes", options: [])
        let silenceCategory = UNNotificationCategory(identifier: Self.recordingSilenceCategoryId,
                                                     actions: [stop, keep], intentIdentifiers: [], options: [])
        let endCategory = UNNotificationCategory(identifier: Self.recordingEndCategoryId,
                                                 actions: [stop, extend], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, morningCategory, silenceCategory, endCategory])
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

    @discardableResult
    func sendTestNotification() async throws -> String {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .provisional else {
            throw NotificationError.notAuthorized
        }
        let content = UNMutableNotificationContent()
        content.title = "Hall-e notifications are working"
        content.body = "Meeting reminders and recording prompts can appear on this Mac."
        content.sound = AppPreferences.meetingReminderSound.notificationSound
        let identifier = "halle-notification-test-\(UUID().uuidString)"
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil))
        return identifier
    }

    func testNotificationWasDelivered(identifier: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.contains {
                    $0.request.identifier == identifier
                })
            }
        }
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
            let storedFireAt = (info["fireAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            let nextTriggerDate = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            guard NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: storedFireAt,
                nextTriggerDate: nextTriggerDate, now: now) else { return false }
            return !NotificationPlanner.needsReplacement(
                .init(title: request.content.title, body: request.content.body,
                      meetingURL: info["meetingURL"] as? String, htmlLink: info["htmlLink"] as? String,
                      leadMinutes: info["leadMinutes"] as? Int, sound: info["soundChoice"] as? String),
                desired: target, leadMinutes: leadMinutes,
                sound: sound.rawValue)
        }
        let pendingIds = Set(unchanged.map(\.identifier))
        let deliveredKeys = await deliveredLedgerKeys()
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
                                "fireAt": d.fireAt.timeIntervalSince1970,
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
            await upsertLedger(dedupKey: d.dedupKey, startTs: d.startTs, scheduledFor: d.fireAt,
                               catchUpClaimed: d.startTs <= Date())
                schedulingErrors.removeValue(forKey: d.identifier)
            } catch {
                schedulingErrors[d.identifier] = error.localizedDescription
                Log.app.error("Could not schedule meeting reminder: \(error, privacy: .private)")
            }
        }
    }

    func reminderDiagnostics(events: [UnifiedEvent], now: Date = Date()) async -> NotificationPlanner.ReminderDiagnosticsSnapshot {
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests().filter { $0.content.categoryIdentifier == Self.categoryId }
        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
        let ledgerStatuses = await notificationLedgerStatuses()
        let auth = settings.authorizationStatus
        let authName: String = switch auth {
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .ephemeral: "Temporary"
        @unknown default: "Restricted"
        }
        let alertEnabled = settings.alertSetting == .enabled
        let soundEnabled = settings.soundSetting == .enabled
        let quietStart = AppPreferences.quietHoursStart, quietEnd = AppPreferences.quietHoursEnd
        let isQuiet: (Date) -> Bool = { date in
            let hour = Calendar.current.component(.hour, from: date)
            return quietStart <= quietEnd ? (quietStart..<quietEnd).contains(hour) : hour >= quietStart || hour < quietEnd
        }
        let rows = events.map { event -> NotificationPlanner.ReminderDiagnostic in
            let id = NotificationPlanner.identifier(dedupKey: event.dedupKey, startTs: event.startTs)
            let occurrenceKey = NotificationPlanner.ledgerKey(dedupKey: event.dedupKey, startTs: event.startTs)
            let (state, detail): (NotificationPlanner.ReminderState, String)
            if event.isAllDay { (state, detail) = (.allDay, "All-day events do not get meeting alerts.") }
            else if event.status == "cancelled" { (state, detail) = (.cancelled, "This event is cancelled.") }
            else if !AppPreferences.showDeclinedEvents && event.effectiveResponse == "declined" { (state, detail) = (.declined, "Declined events are hidden from reminders.") }
            else if !AppPreferences.notificationsEnabled { (state, detail) = (.disabled, "Meeting notifications are turned off in Hall-e.") }
            else if auth != .authorized && auth != .provisional { (state, detail) = (.permissionUnavailable, "macOS notification access is \(authName.lowercased()).") }
            else if !alertEnabled { (state, detail) = (.permissionUnavailable, "macOS banners and alerts are disabled for Hall-e. Enable them in System Settings.") }
            else if event.endTs <= now { (state, detail) = (.alreadyStarted, "The meeting has ended.") }
            else if event.startTs <= now && now.timeIntervalSince(event.startTs) > 10 * 60 { (state, detail) = (.alreadyStarted, "The meeting started more than 10 minutes ago; the wake catch-up window has passed.") }
            else if let request = pendingByID[id] {
                let storedFireAt = (request.content.userInfo["fireAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                let nextFireAt = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                if NotificationPlanner.pendingRequestHasNotExpired(scheduledFireAt: storedFireAt,
                    nextTriggerDate: nextFireAt, now: now) {
                    let fire = storedFireAt ?? nextFireAt!
                    (state, detail) = (event.startTs <= now ? .lateCatchUp : .scheduled,
                                       "Scheduled for \(fire.formatted(date: .omitted, time: .shortened)).")
                } else {
                    (state, detail) = (.notScheduled, "The pending one-shot expired; refresh the agenda to re-arm the wake catch-up.")
                }
            } else if NotificationPlanner.diagnosticState(for: ledgerStatuses[occurrenceKey]) == .delivered { (state, detail) = (.delivered, "macOS confirmed delivery for this meeting time.") }
            else if NotificationPlanner.diagnosticState(for: ledgerStatuses[occurrenceKey]) == .catchUpClaimed { (state, detail) = (.catchUpClaimed, "A wake catch-up request was accepted once; delivery has not been confirmed.") }
            else {
                let fire = max(event.startTs.addingTimeInterval(-TimeInterval(AppPreferences.notificationLeadMinutes * 60)), now.addingTimeInterval(1))
                if isQuiet(fire) { (state, detail) = (.quietHours, "The reminder time falls within quiet hours.") }
                else if event.startTs.timeIntervalSince(now) >= 48 * 3600 { (state, detail) = (.outsideHorizon, "Reminders are scheduled within 48 hours.") }
                else {
                    (state, detail) = (.notScheduled,
                        schedulingErrors[id].map { "macOS rejected this request: \($0)" }
                            ?? "No pending request is registered yet; refresh the agenda to reconcile reminders.")
                }
            }
            return .init(id: id, title: event.title, startTs: event.startTs, state: state, detail: detail)
        }.sorted { $0.startTs < $1.startTs }
        let next = pending.compactMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }.min()
        return .init(notificationsEnabled: AppPreferences.notificationsEnabled,
                     authorization: authName, alertsEnabled: alertEnabled, soundsEnabled: soundEnabled,
                     pendingCount: pending.count, nextFireAt: next, occurrences: rows)
    }

    private func startMorningActivityMonitoring() {
        guard AppPreferences.morningAgendaEnabled, morningActivityTimer == nil else { return }
        morningActivityTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMorningMouseActivity() }
        }
        checkMorningMouseActivity()
        if morningWakeObserver == nil {
            morningWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.checkMorningMouseActivity()
                }
            }
        }
    }

    private func checkMorningMouseActivity(now: Date = Date()) {
        guard AppPreferences.morningAgendaEnabled else { return }
        if let pendingMorningActivityAt,
           NotificationPlanner.shouldSendMorningAgenda(enabled: true,
               lastSentDay: AppPreferences.morningAgendaLastBriefDay,
               activityAt: pendingMorningActivityAt, now: now),
           !AppState.shared.isSyncing {
            self.pendingMorningActivityAt = nil
            Task { await postMorningAgenda(for: pendingMorningActivityAt) }
            return
        }
        let state = CGEventSourceStateID.combinedSessionState
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let idle = types.map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }.min() ?? .infinity
        guard idle.isFinite, idle >= 0, idle <= 15 else { return }
        let activityAt = now.addingTimeInterval(-idle)
        if let lastMouseActivityAt, activityAt.timeIntervalSince(lastMouseActivityAt) < 1 { return }
        lastMouseActivityAt = activityAt
        guard NotificationPlanner.shouldSendMorningAgenda(enabled: true,
            lastSentDay: AppPreferences.morningAgendaLastBriefDay,
            activityAt: activityAt, now: now) else { return }
        pendingMorningActivityAt = activityAt
        guard !AppState.shared.isSyncing else { return }
        let key = NotificationPlanner.localDayKey(activityAt)
        guard AppPreferences.morningAgendaLastBriefDay != key else { pendingMorningActivityAt = nil; return }
        pendingMorningActivityAt = nil
        Task { await postMorningAgenda(for: activityAt) }
    }

    private func postMorningAgenda(for activityAt: Date) async {
        let calendar = Calendar.current
        let key = NotificationPlanner.localDayKey(activityAt, calendar: calendar)
        guard NotificationPlanner.shouldSendMorningAgenda(enabled: AppPreferences.morningAgendaEnabled,
            lastSentDay: AppPreferences.morningAgendaLastBriefDay, activityAt: activityAt, now: Date(), calendar: calendar),
              !morningAgendaDaysInFlight.contains(key) else { return }
        morningAgendaDaysInFlight.insert(key)
        defer { morningAgendaDaysInFlight.remove(key) }
        let status = await center.notificationSettings()
        guard AppPreferences.morningAgendaEnabled,
              NotificationPlanner.shouldSendMorningAgenda(enabled: AppPreferences.morningAgendaEnabled,
                lastSentDay: AppPreferences.morningAgendaLastBriefDay, activityAt: activityAt, now: Date(), calendar: calendar) else { return }
        guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional,
              status.alertSetting == .enabled else { return }
        guard AppPreferences.morningAgendaLastBriefDay != key else { return }
        let identifier = "halle-morning-agenda|\(key)"
        let pendingIDs = await center.pendingNotificationRequests().map(\.identifier)
        let deliveredIDs = await center.deliveredNotifications().map { $0.request.identifier }
        if pendingIDs.contains(identifier) || deliveredIDs.contains(identifier) {
            AppPreferences.morningAgendaLastBriefDay = key
            return
        }
        let cached = try? await AppDatabase.shared.dbQueue.read { db in
            (try UnifiedEvent.fetchAll(db), try CalendarSource.filter(CalendarSource.Columns.isSelected == true).fetchCount(db) > 0)
        }
        guard let (events, hasSelectedCalendar) = cached, hasSelectedCalendar else { return }
        let dayEvents = NotificationPlanner.morningAgendaEvents(events, on: activityAt,
            showDeclined: AppPreferences.showDeclinedEvents, calendar: calendar)
        let summary = dayEvents.prefix(3).map { event in
            event.isAllDay ? "All day: \(event.title)" : "\(event.startTs.formatted(date: .omitted, time: .shortened)) \(event.title)"
        }.joined(separator: " · ")
        let remaining = dayEvents.count - min(3, dayEvents.count)
        let content = UNMutableNotificationContent()
        content.title = dayEvents.isEmpty ? "No meetings today" : "Today’s agenda · \(dayEvents.count) meeting\(dayEvents.count == 1 ? "" : "s")"
        content.body = dayEvents.isEmpty ? "You have no calendar meetings today. Open Today to review your agenda." : summary + (remaining > 0 ? " · +\(remaining) more in Today" : " · Open Today for the full agenda")
        content.categoryIdentifier = Self.morningAgendaCategoryId
        content.sound = AppPreferences.meetingReminderSound.notificationSound
        content.userInfo = ["agendaDate": calendar.startOfDay(for: activityAt).timeIntervalSince1970]
        guard AppPreferences.morningAgendaEnabled,
              NotificationPlanner.shouldSendMorningAgenda(enabled: AppPreferences.morningAgendaEnabled,
                lastSentDay: AppPreferences.morningAgendaLastBriefDay, activityAt: activityAt, now: Date(), calendar: calendar),
              AppPreferences.morningAgendaLastBriefDay != key else { return }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            AppPreferences.morningAgendaLastBriefDay = key
        } catch {
            Log.app.error("Could not schedule morning agenda notification: \(error, privacy: .private)")
        }
    }

    func morningAgendaPreferenceChanged() {
        if AppPreferences.morningAgendaEnabled {
            startMorningActivityMonitoring()
        } else {
            morningActivityTimer?.invalidate()
            morningActivityTimer = nil
            pendingMorningActivityAt = nil
        }
    }

    // MARK: - Ledger

    // Ledger access is async so SQLite I/O runs on GRDB's queue, not the main
    // actor (reconcile runs after every sync).
    private func deliveredLedgerKeys() async -> Set<String> {
        Set((await notificationLedgerStatuses()).compactMap { key, status in
            NotificationPlanner.ledgerStatusSuppressesReminder(status) ? key : nil
        })
    }

    private func notificationLedgerStatuses() async -> [String: NotificationStatus] {
        (try? await AppDatabase.shared.dbQueue.read { db -> [String: NotificationStatus] in
            let rows = try NotificationRecord.fetchAll(db)
            return Dictionary(rows.compactMap { row in
                guard let status = NotificationStatus(rawValue: row.status) else { return nil }
                return (NotificationPlanner.ledgerKey(dedupKey: row.dedupKey, startTs: row.startTs), status)
            }, uniquingKeysWith: { _, latest in latest })
        }) ?? [:]
    }

    private func upsertLedger(dedupKey: String, startTs: Date, scheduledFor: Date, catchUpClaimed: Bool = false) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            var rec = try NotificationRecord.fetchOne(db, key: ["dedupKey": dedupKey, "startTs": startTs])
                ?? NotificationRecord(dedupKey: dedupKey, startTs: startTs, scheduledFor: scheduledFor,
                                      status: NotificationStatus.pending.rawValue, deliveredAt: nil, snoozedUntil: nil)
            rec.scheduledFor = scheduledFor
            if rec.status != NotificationStatus.delivered.rawValue {
                rec.status = catchUpClaimed ? NotificationStatus.catchUpClaimed.rawValue : NotificationStatus.pending.rawValue
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
