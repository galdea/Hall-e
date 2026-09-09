import SwiftUI
import EventKit
import GRDB

struct MacCalendarSettingsSection: View {
    @State private var appState = AppState.shared
    @State private var connected = MacCalendarProvider.enabled && MacCalendarProvider.authorized
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section("Google, Outlook & other calendars") {
            Text("Connect the accounts you use for meetings. macOS handles sign-in; Hall-e never needs your email password or a developer API key.")
            Text("1. Open Internet Accounts. Add Google for Gmail/Workspace, or Microsoft Exchange for your work or school Outlook/Microsoft 365 account. Enable Calendars. Already added? Check that Calendars is on.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Internet Accounts…") { SystemSettingsOpener.openInternetAccounts() }
                .buttonStyle(.borderedProminent)
            Link("Apple account setup guide ↗", destination: URL(string: "https://support.apple.com/guide/mac-help/add-an-internet-account-mh43559/mac")!)
            Text("2. Return here and allow Calendar access. macOS calls this Full Access; Hall-e only reads selected calendars and never edits events.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(connected ? "Refresh connected calendars" : "Allow Calendar access") {
                    Task { await connectOrRefresh() }
                }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Button("Calendar privacy settings…") { SystemSettingsOpener.openCalendarPrivacy() }
            }
            Text("Teams invitations come from your Microsoft calendar; no separate Teams sign-in is needed. Hall-e imports meeting links, not Teams chats or email messages. Only calendars visible in Apple Calendar can be imported; some organizations restrict this, and a standalone Outlook app sign-in is not enough.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if connected {
            Section("3. Choose calendars for Hall-e") {
                let calendars = appState.calendars(for: MacCalendarProvider.accountID)
                if calendars.isEmpty {
                    Text("No calendars found yet. Open Apple Calendar and check that your account has finished syncing, then return and refresh.")
                        .foregroundStyle(.secondary)
                    Button("Open Apple Calendar") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
                }
                ForEach(calendars) { calendar in
                    Toggle(calendar.summary, isOn: Binding(get: { calendar.isSelected }, set: { value in
                        Task { await select(calendar, value: value) }
                    })).disabled(busy)
                }
                let count = calendars.filter(\.isSelected).count
                Label(count == 0 ? "Choose at least one calendar to show meetings." : "\(count) calendars selected · meetings appear in your workspace.",
                      systemImage: count == 0 ? "calendar" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(count == 0 ? Color.secondary : Color.green)
                Text("If you also use the advanced Google connection, select each calendar through only one connection to avoid duplicate meetings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Disconnect Mac calendars from Hall-e", role: .destructive) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { try await MacCalendarProvider.shared.disconnect(); connected = false }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy)
                Text("Disconnecting removes Hall-e’s imported calendar cache. Your accounts and events remain in macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error {
            Section { Text(error).foregroundStyle(.red).font(.callout) }
        }
        Section {
            Text("Account setup is optional. You can record now and connect calendars later in Settings → Accounts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connected = MacCalendarProvider.enabled && MacCalendarProvider.authorized
            if MacCalendarProvider.enabled { Task { await refresh() } }
        }
    }

    private func connectOrRefresh() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if MacCalendarProvider.enabled && MacCalendarProvider.authorized {
                try await MacCalendarProvider.shared.refreshSources()
                await SyncCoordinator.shared.syncAll()
            } else { try await MacCalendarProvider.shared.connect() }
            connected = MacCalendarProvider.enabled && MacCalendarProvider.authorized
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await MacCalendarProvider.shared.refreshSources()
            await SyncCoordinator.shared.syncAll()
        } catch { self.error = error.localizedDescription }
    }
    private func select(_ calendar: CalendarSource, value: Bool) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AppDatabase.shared.dbQueue.write { db in
                var source = calendar
                source.isSelected = value
                try source.update(db)
                if !value {
                    try CalendarEvent.filter(CalendarEvent.Columns.accountEmail == source.accountEmail && CalendarEvent.Columns.calendarId == source.calendarId).deleteAll(db)
                    try UnifiedEvent.deleteAll(db)
                }
            }
            await SyncCoordinator.shared.syncAll()
        } catch { self.error = error.localizedDescription }
    }
}
