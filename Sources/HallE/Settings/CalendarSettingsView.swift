import SwiftUI
import GRDB

struct CalendarSettingsView: View {
    @State private var appState = AppState.shared
    var body: some View {
        Form {
            if appState.accounts.isEmpty {
                ContentUnavailableView("No Google accounts", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("Connect an account before choosing calendars."))
            } else {
                ForEach(appState.accounts) { account in
                    Section(account.email) {
                        let calendars = appState.calendars(for: account.email)
                        if calendars.isEmpty { Text("No calendars loaded. Refresh from Accounts.").foregroundStyle(.secondary) }
                        ForEach(calendars) { calendar in
                            Toggle(isOn: Binding(get: { calendar.isSelected }, set: { update(calendar, selected: $0) })) {
                                HStack { Circle().fill(Color(hex: calendar.colorHex ?? "") ?? .secondary).frame(width: 9, height: 9); Text(calendar.summary); if calendar.isPrimary { HalleStatusBadge(text: "Primary") } }
                            }
                        }
                    }
                }
                Section { Button { Task { await SyncCoordinator.shared.syncAll() } } label: { Label("Refresh calendars", systemImage: "arrow.clockwise") }.disabled(appState.isSyncing) }
            }
        }.formStyle(.grouped).navigationTitle(L10n.text("settings.calendars"))
    }
    private func update(_ source: CalendarSource, selected: Bool) {
        // Async write keeps SQLite I/O off the main actor (this runs in a
        // Toggle setter); the sync only starts once the row is persisted.
        Task {
            try? await AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE calendar_source SET isSelected = ? WHERE accountEmail = ? AND calendarId = ?", arguments: [selected, source.accountEmail, source.calendarId])
                if !selected { try CalendarEvent.filter(CalendarEvent.Columns.accountEmail == source.accountEmail && CalendarEvent.Columns.calendarId == source.calendarId).deleteAll(db) }
            }
            await SyncCoordinator.shared.syncAll()
        }
    }
}
