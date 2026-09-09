import SwiftUI
import AppKit

struct PrivacySettingsView: View {
    @State private var appState = AppState.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Where your data lives") {
                dataRow("Calendar cache & metadata", "~/Library/Application Support/Hall-e/halle.sqlite")
                dataRow("Recordings", "~/Library/Application Support/Hall-e/Recordings")
                dataRow("Browser call signals", "~/Library/Application Support/Hall-e/CallCapture/Incoming")
                dataRow("Imported project conversations & generated briefs", "~/Library/Application Support/Hall-e/halle.sqlite")
                dataRow("Meeting notes", ObsidianVaultConfig.load()?.rootURL.path ?? "notes folder not set")
                dataRow("Secrets (tokens, API keys)", "macOS Keychain only")
            }

            Section("Privacy posture") {
                Label("Read-only calendar access", systemImage: "calendar")
                Label("Recordings & transcripts stay local until you grant each cloud-processing consent", systemImage: "lock.fill")
                Label("Deepgram, Speechmatics, and AI processing have separate permissions", systemImage: "checkmark.shield")
                Label("Browser call signals stay local and contain no audio", systemImage: "network.badge.shield.half.filled")
                Label("Transcript text leaves the Mac only if you enable cloud AI processing", systemImage: "cloud")
                Label("Codex indexing reads only linked project folders and visible user/assistant messages", systemImage: "terminal")
                Label("ChatGPT and WhatsApp data enters Hall-e only through files you select", systemImage: "square.and.arrow.down")
                Label("API keys and refresh tokens are stored in macOS Keychain", systemImage: "key.fill")
            }

            Section("Data controls") {
                Button("Reveal Hall-e data folder in Finder") {
                    NSWorkspace.shared.open(AppPaths.appSupport)
                }
                Button("Clear local calendar cache", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear cached events? Accounts and settings are kept; the next sync refetches.",
                                        isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear cache", role: .destructive) { clearCache() }
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }

    private func dataRow(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
            Text(path).font(.caption).foregroundStyle(.secondary).truncationMode(.middle).lineLimit(1)
        }
    }

    private func clearCache() {
        Task {
            try? await AppDatabase.shared.dbQueue.write { db in
                try CalendarEvent.deleteAll(db)
                try UnifiedEvent.deleteAll(db)
                try NotificationRecord.deleteAll(db)
            }
        }
    }
}
