import Foundation
import GRDB

/// Coordinates windowed calendar sync across all accounts, writes the raw cache,
/// and rebuilds the deduplicated `unified_event` table. Coalesces overlapping
/// requests so timers/wakes/manual refresh never pile up.
actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private var running = false
    private var rerunRequested = false

    /// Sync all accounts over the default near-term window. Coalesces.
    func syncAll() async {
        if running { rerunRequested = true; return }
        running = true
        defer { running = false }
        repeat {
            rerunRequested = false
            let (min, max) = Self.window()
            await performSync(timeMin: min, timeMax: max, isPrimaryWindow: true)
        } while rerunRequested
    }

    /// Fetch + rebuild an arbitrary range for the week/month browser. Does not run
    /// AI classification or notification reconciliation (near-term concerns only).
    func syncRange(_ min: Date, _ max: Date) async {
        await performSync(timeMin: min, timeMax: max, isPrimaryWindow: false)
    }

    /// Rebuild local derived state immediately after an account/calendar toggle,
    /// without requiring a network request.
    func rebuildAfterSourceChange() async {
        let (min, max) = Self.window()
        await rebuildUnifiedEvents(timeMin: min, timeMax: max)
        let agenda = (try? await AppDatabase.shared.dbQueue.read { try UnifiedEvent.fetchAll($0) }) ?? []
        await NotificationScheduler.shared.reconcile(events: agenda) { $0.winnerAccountEmail }
        await ProjectSourceImportCoordinator.shared.refreshLinkedCodexSources()
        await ProjectIntelligenceService.shared.scheduleRefreshAll()
    }

    private func performSync(timeMin: Date, timeMax: Date, isPrimaryWindow: Bool) async {
        let db = AppDatabase.shared.dbQueue
        let accounts: [ConnectedAccount]
        let sources: [CalendarSource]
        do {
            (accounts, sources) = try await db.read { db in
                (try ConnectedAccount.fetchAll(db),
                 try CalendarSource.filter(CalendarSource.Columns.isSelected == true).fetchAll(db))
            }
        } catch {
            Log.sync.error("sync read failed: \(error, privacy: .public)")
            return
        }
        guard !accounts.isEmpty else { return }

        await MainActor.run { AppState.shared.updateSyncStatus(isSyncing: true, error: nil) }
        defer { Task { @MainActor in AppState.shared.updateSyncStatus(isSyncing: false) } }

        let fetchedAt = Date()

        // Per-account isolation via a task group; one failure never blocks others.
        var accountErrors: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for account in accounts {
                let accountCalendars = sources.filter { $0.accountEmail == account.email }
                group.addTask {
                    await self.syncAccount(account, calendars: accountCalendars,
                                           timeMin: timeMin, timeMax: timeMax, fetchedAt: fetchedAt)
                }
            }
            for await (email, errorMessage) in group {
                if let errorMessage { accountErrors[email] = errorMessage }
                try? await db.write { db in
                    if var acct = try ConnectedAccount.fetchOne(db, key: email) {
                        acct.lastSyncAt = fetchedAt
                        acct.lastSyncError = errorMessage
                        if errorMessage == nil { acct.needsReauth = false }
                        try acct.save(db)
                    }
                }
            }
        }

        await rebuildUnifiedEvents(timeMin: timeMin, timeMax: timeMax)

        // AI classification + notifications are near-term concerns — only the
        // primary window triggers them; browsing far weeks/months does not.
        guard isPrimaryWindow else { return }

        await MainActor.run {
            AppState.shared.updateSyncStatus(isSyncing: false, lastSyncAt: fetchedAt,
                                              error: accountErrors.values.first,
                                              accountErrors: accountErrors)
        }

        // Optional LLM classification for events the rules left unclassified.
        await runAIClassificationIfEnabled()

        // Reconcile 15-min reminders against the fresh agenda.
        let agenda = (try? await AppDatabase.shared.dbQueue.read { try UnifiedEvent.fetchAll($0) }) ?? []
        await NotificationScheduler.shared.reconcile(events: agenda) { $0.winnerAccountEmail }
    }

    /// When AI is enabled, ask the LLM about a bounded number of still-unclassified
    /// upcoming events. Deterministic results are never overridden.
    private func runAIClassificationIfEnabled() async {
        let provider = LLMProviderFactory.make()
        if provider is DisabledLLMProvider { return }
        let classifier = MeetingClassifier()

        let candidates: [UnifiedEvent] = (try? await AppDatabase.shared.dbQueue.read { db in
            try UnifiedEvent
                .filter(UnifiedEvent.Columns.startTs > Date())
                .filter(sql: "projectId IS NULL")
                .filter(sql: "dedupKey NOT IN (SELECT dedupKey FROM event_project_assignment)")
                .filter(sql: "NOT EXISTS (SELECT 1 FROM recurring_project_assignment r WHERE r.seriesId = unified_event.iCalUID AND r.effectiveFrom <= unified_event.startTs)")
                .order(UnifiedEvent.Columns.startTs)
                .limit(8)
                .fetchAll(db)
        }) ?? []
        guard !candidates.isEmpty else { return }

        for event in candidates {
            guard let result = await classifier.aiClassify(event, provider: provider),
                  let project = result.project else { continue }
            try? await AppDatabase.shared.dbQueue.write { db in
                if var u = try UnifiedEvent.fetchOne(db, key: event.dedupKey) {
                    let assignments = Dictionary(uniqueKeysWithValues: try EventProjectAssignment.fetchAll(db).map { ($0.dedupKey, $0) })
                    let recurring = try RecurringProjectAssignment.fetchAll(db)
                    guard case .none = ProjectAssignmentResolver.decision(for: u, occurrenceAssignments: assignments, recurringAssignments: recurring), u.projectId == nil else { return }
                    u.projectId = project
                    u.projectConfidence = result.confidence
                    try u.update(db)
                }
            }
            Log.intel.info("LLM classified an event → \(project, privacy: .public)")
        }
    }

    /// Returns (email, errorMessage?) — errorMessage nil means success.
    private func syncAccount(_ account: ConnectedAccount, calendars: [CalendarSource],
                             timeMin: Date, timeMax: Date, fetchedAt: Date) async -> (String, String?) {
        let api = GoogleCalendarAPI(email: account.email, tokenStore: .shared)
        var lastError: String?
        for cal in calendars {
            do {
                let gevents = try await api.events(calendarId: cal.calendarId, timeMin: timeMin, timeMax: timeMax)
                let mapped = gevents.compactMap {
                    EventMapper.map($0, accountEmail: account.email, calendarId: cal.calendarId, fetchedAt: fetchedAt)
                }
                // Transactional window replace for this (account, calendar).
                try await AppDatabase.shared.dbQueue.write { db in
                    try CalendarEvent
                        .filter(CalendarEvent.Columns.accountEmail == account.email
                                && CalendarEvent.Columns.calendarId == cal.calendarId
                                && CalendarEvent.Columns.endTs > timeMin
                                && CalendarEvent.Columns.startTs < timeMax)
                        .deleteAll(db)
                    for var event in mapped { try event.insert(db, onConflict: .replace) }
                }
            } catch let GoogleOAuthClient.OAuthError.invalidGrant {
                try? await AppDatabase.shared.dbQueue.write { db in
                    if var acct = try ConnectedAccount.fetchOne(db, key: account.email) {
                        acct.needsReauth = true
                        try acct.save(db)
                    }
                }
                return (account.email, "Needs reconnect")
            } catch {
                lastError = error.localizedDescription
                Log.sync.error("sync \(account.email, privacy: .private) cal \(cal.calendarId, privacy: .private): \(error, privacy: .public)")
            }
        }
        return (account.email, lastError)
    }

    private func rebuildUnifiedEvents(timeMin: Date, timeMax: Date) async {
        let db = AppDatabase.shared.dbQueue
        do {
            let sources = try await db.read { try CalendarSource.fetchAll($0) }
            let colorMap = Dictionary(sources.map { (("\($0.accountEmail)\u{1F}\($0.calendarId)"), $0.colorHex) },
                                      uniquingKeysWith: { a, _ in a })
            let accountColor = try await db.read { db -> [String: String] in
                Dictionary(try ConnectedAccount.fetchAll(db).map { ($0.email, $0.colorHex) },
                           uniquingKeysWith: { a, _ in a })
            }
            let primary = AppPreferences.primaryAccountEmail

            try await db.write { db in
                let raw = try CalendarEvent
                    .filter(CalendarEvent.Columns.endTs > timeMin && CalendarEvent.Columns.startTs < timeMax)
                    .fetchAll(db)
                let unified = EventDeduplicator.deduplicate(raw, primaryEmail: primary) { email, calId in
                    colorMap["\(email)\u{1F}\(calId)"].flatMap { $0 } ?? accountColor[email]
                }
                // Classify each event (user pins → deterministic rules).
                let classifier = MeetingClassifier()
                let assignments = Dictionary(uniqueKeysWithValues: try EventProjectAssignment.fetchAll(db).map {
                    ($0.dedupKey, $0)
                })
                let recurringAssignments = try RecurringProjectAssignment.fetchAll(db)
                // Range-additive: only replace unified events in this window, so
                // other browsed periods (week/month navigation) stay cached.
                try UnifiedEvent
                    .filter(UnifiedEvent.Columns.startTs >= timeMin && UnifiedEvent.Columns.startTs < timeMax)
                    .deleteAll(db)
                for var u in unified {
                    if case let .assigned(pinned) = ProjectAssignmentResolver.decision(for: u, occurrenceAssignments: assignments, recurringAssignments: recurringAssignments) {
                        u.projectId = pinned.map { AliasStore.shared.projectName(for: $0) ?? $0 }
                        u.projectConfidence = pinned == nil ? nil : 1
                    } else {
                        let result = classifier.classify(u)
                        // Only confidently-classified events get a project (chip + filed
                        // to the project folder); the rest stay unclassified → Inbox.
                        u.projectId = result.requires_user_confirmation ? nil : result.project
                        u.projectConfidence = result.confidence
                    }
                    try u.insert(db, onConflict: .replace)
                }
            }
        } catch {
            Log.sync.error("rebuild unified failed: \(error, privacy: .public)")
        }
    }

    /// Local-today − pastDays … local-today + futureDays.
    static func window(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let startOfToday = cal.startOfDay(for: now)
        let min = cal.date(byAdding: .day, value: -AppPreferences.windowPastDays, to: startOfToday)!
        let max = cal.date(byAdding: .day, value: AppPreferences.windowFutureDays, to: startOfToday)!
        return (min, max)
    }
}
