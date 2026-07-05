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

    var isSyncing = false
    var lastSyncAt: Date?
    var lastSyncError: String?
    var googleClientConfigured = GoogleClientConfig.load() != nil

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
                                         onChange: { [weak self] in self?.agenda = $0 }))
    }

    func refreshClientConfigured() {
        googleClientConfigured = GoogleClientConfig.load() != nil
    }

    func calendars(for email: String) -> [CalendarSource] {
        calendarSources.filter { $0.accountEmail == email }
    }
}
