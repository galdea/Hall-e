import SwiftUI

/// Root of the menu-bar popover: header with date/actions, agenda content, footer.
struct PopoverRootView: View {
    @State private var appState = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AgendaView(events: appState.agenda, hasAccounts: !appState.accounts.isEmpty)
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 380, height: 540)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.headline)
                HStack(spacing: 5) {
                    Text(Date.now, style: .time)
                    if appState.isSyncing {
                        ProgressView().controlSize(.mini)
                    } else if let last = appState.lastSyncAt {
                        Text("· synced \(last.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await SyncCoordinator.shared.syncAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help("Refresh now").disabled(appState.isSyncing)
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("Hall-e").font(.caption2).foregroundStyle(.tertiary)
            if let err = appState.lastSyncError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
