import Foundation
import Observation
import GRDB

/// Main-actor observable store backing the UI. Reactive to DB writes via GRDB
/// ValueObservation, so background sync updates the agenda automatically.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var accounts: [ConnectedAccount] = []
    var calendarSources: [CalendarSource] = []
    var agenda: [UnifiedEvent] = []
    private var syncedAgenda: [UnifiedEvent] = []
    private var localCaptureEvents: [LocalCaptureEvent] = []

    var isSyncing = false
    var lastSyncAt: Date?
    var lastSyncError: String?
    var syncStatus = SyncStatus()
    var googleClientConfigured = GoogleClientConfig.load() != nil

    /// Latest recording session per event dedupKey (for the transcript button).
    var recordingsByEvent: [String: RecordingSession] = [:]
    /// Ordering guards for `refreshRecordings`'s off-main-actor disk reads.
    private var recordingsRefreshToken = 0
    private var appliedRecordingsToken = 0
    var vaultDocuments: [VaultDocument] = []
    var actionItems: [IndexedActionItem] = []
    var projectSources: [ProjectSourceRecord] = []
    var projectSourceDocuments: [ProjectSourceDocument] = []
    var projectSnapshots: [ProjectSnapshotRecord] = []
    var projectAssistantMessages: [ProjectAssistantMessageRecord] = []

    private var observers: [AnyDatabaseCancellable] = []

    private init() {}

    /// Begin observing the database; call once at launch.
    func startObserving() {
        let db = AppDatabase.shared.dbQueue

        let accountsObs = ValueObservation.tracking { db in
            try ConnectedAccount.order(ConnectedAccount.Columns.email).fetchAll(db)
        }
        observers.append(accountsObs.start(in: db, scheduling: .async(onQueue: .main),
                                           onError: { Log.db.error("accounts obs: \($0, privacy: .public)") },
                                           onChange: { [weak self] in self?.accounts = $0 }))

        let calObs = ValueObservation.tracking { db in
            try CalendarSource.order(CalendarSource.Columns.accountEmail).fetchAll(db)
        }
        observers.append(calObs.start(in: db, scheduling: .async(onQueue: .main),
                                      onError: { Log.db.error("calendars obs: \($0, privacy: .public)") },
                                      onChange: { [weak self] in self?.calendarSources = $0 }))

        let agendaObs = ValueObservation.tracking { db in
            try UnifiedEvent.order(UnifiedEvent.Columns.startTs).fetchAll(db)
        }
        observers.append(agendaObs.start(in: db, scheduling: .async(onQueue: .main),
                                         onError: { Log.db.error("agenda obs: \($0, privacy: .public)") },
                                         onChange: { [weak self] in
                                            self?.syncedAgenda = $0
                                            self?.publishAgenda()
                                         }))

        let localCaptureObs = ValueObservation.tracking { db in
            try LocalCaptureEvent.order(LocalCaptureEvent.Columns.startTs).fetchAll(db)
        }
        observers.append(localCaptureObs.start(in: db, scheduling: .async(onQueue: .main),
                                               onError: { Log.db.error("local call obs: \($0, privacy: .public)") },
                                               onChange: { [weak self] in
                                                self?.localCaptureEvents = $0
                                                self?.publishAgenda()
                                               }))

        let docsObs = ValueObservation.tracking { db in
            try VaultDocument.order(VaultDocument.Columns.modifiedAt.desc).fetchAll(db)
        }
        observers.append(docsObs.start(in: db, scheduling: .async(onQueue: .main),
                                       onError: { Log.db.error("vault index observation: \($0, privacy: .public)") },
                                       onChange: { [weak self] in self?.vaultDocuments = $0 }))

        let actionsObs = ValueObservation.tracking { db in
            try IndexedActionItem.order(IndexedActionItem.Columns.isCompleted,
                                        IndexedActionItem.Columns.updatedAt.desc).fetchAll(db)
        }
        observers.append(actionsObs.start(in: db, scheduling: .async(onQueue: .main),
                                          onError: { Log.db.error("action index observation: \($0, privacy: .public)") },
                                          onChange: { [weak self] in self?.actionItems = $0 }))

        let sourcesObs = ValueObservation.tracking { db in
            try ProjectSourceRecord.order(ProjectSourceRecord.Columns.createdAt).fetchAll(db)
        }
        observers.append(sourcesObs.start(in: db, scheduling: .async(onQueue: .main),
                                          onError: { Log.db.error("project sources observation: \($0, privacy: .public)") },
                                          onChange: { [weak self] in self?.projectSources = $0 }))

        let sourceDocsObs = ValueObservation.tracking { db in
            try ProjectSourceDocument.order(ProjectSourceDocument.Columns.occurredAt.desc,
                                             ProjectSourceDocument.Columns.importedAt.desc).fetchAll(db)
        }
        observers.append(sourceDocsObs.start(in: db, scheduling: .async(onQueue: .main),
                                             onError: { Log.db.error("project source documents observation: \($0, privacy: .public)") },
                                             onChange: { [weak self] in self?.projectSourceDocuments = $0 }))

        let snapshotsObs = ValueObservation.tracking { db in
            try ProjectSnapshotRecord.order(ProjectSnapshotRecord.Columns.generatedAt.desc).fetchAll(db)
        }
        observers.append(snapshotsObs.start(in: db, scheduling: .async(onQueue: .main),
                                            onError: { Log.db.error("project snapshots observation: \($0, privacy: .public)") },
                                            onChange: { [weak self] in self?.projectSnapshots = $0 }))

        let assistantObs = ValueObservation.tracking { db in
            try ProjectAssistantMessageRecord.order(ProjectAssistantMessageRecord.Columns.createdAt).fetchAll(db)
        }
        observers.append(assistantObs.start(in: db, scheduling: .async(onQueue: .main),
                                            onError: { Log.db.error("assistant messages observation: \($0, privacy: .public)") },
                                            onChange: { [weak self] in self?.projectAssistantMessages = $0 }))

        // Recordings live as files on disk; refresh the index at launch and
        // whenever a recording/transcription changes state.
        NotificationCenter.default.addObserver(forName: .halleRecordingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRecordings()
        }
        refreshRecordings()
    }

    func refreshRecordings() {
        // Stopping a recording posts several state changes in quick succession
        // and each one reads the session folder off the main actor. Those reads
        // can finish out of order, so an older snapshot — taken before
        // `endedAt` was written — must never overwrite a newer one; otherwise
        // the just-finished recording keeps its in-flight shape in the UI.
        recordingsRefreshToken += 1
        let token = recordingsRefreshToken
        Task.detached {
            let map = RecordingStore.latestByEvent()
            await MainActor.run {
                let state = AppState.shared
                guard token > state.appliedRecordingsToken else { return }
                state.appliedRecordingsToken = token
                state.recordingsByEvent = map
            }
        }
    }

    private func publishAgenda() {
        agenda = (syncedAgenda + localCaptureEvents.map(\.unifiedEvent)).sorted { $0.startTs < $1.startTs }
    }

    func refreshClientConfigured() {
        googleClientConfigured = GoogleClientConfig.load() != nil
    }

    func updateSyncStatus(isSyncing: Bool? = nil, lastSyncAt: Date? = nil,
                          error: String? = nil, accountErrors: [String: String]? = nil) {
        if let isSyncing { self.isSyncing = isSyncing; syncStatus.isSyncing = isSyncing }
        if let lastSyncAt { self.lastSyncAt = lastSyncAt; syncStatus.lastSyncAt = lastSyncAt }
        self.lastSyncError = error
        syncStatus.error = error
        if let accountErrors { syncStatus.accountErrors = accountErrors }
    }

    func calendars(for email: String) -> [CalendarSource] {
        calendarSources.filter { $0.accountEmail == email }
    }
}
