import SwiftUI
import UniformTypeIdentifiers

struct AccountsSettingsView: View {
    @State private var appState = AppState.shared
    @State private var isAuthorizing = false
    @State private var errorMessage: String?
    @State private var showImportHelp = false

    var body: some View {
        Form {
            Section {
                if appState.googleClientConfigured {
                    Label("Google OAuth client imported", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Replace client JSON…") { importClientJSON() }
                } else {
                    Label("No Google OAuth client configured", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Import the Desktop OAuth client JSON you downloaded from Google Cloud Console.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Import client JSON…") { importClientJSON() }
                    Button("How do I get this?") { showImportHelp.toggle() }
                        .buttonStyle(.link)
                    if showImportHelp {
                        Text(Self.setupHelp)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Google OAuth Client")
            }

            Section("Connected Accounts") {
                if appState.accounts.isEmpty {
                    Text("No accounts connected yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(appState.accounts) { account in
                        HStack {
                            Circle().fill(Color(hex: account.colorHex) ?? .accentColor)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.email)
                                if account.needsReauth {
                                    Label("Needs reconnect", systemImage: "exclamationmark.arrow.circlepath")
                                        .font(.caption).foregroundStyle(.orange)
                                } else if let last = account.lastSyncAt {
                                    Text("Last synced \(last.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                GoogleAccountManager.removeAccount(account.email)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    Task { await addAccount() }
                } label: {
                    if isAuthorizing {
                        HStack { ProgressView().controlSize(.small); Text("Waiting for browser…") }
                    } else {
                        Label("Add Google Account…", systemImage: "plus")
                    }
                }
                .disabled(isAuthorizing || !appState.googleClientConfigured)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
    }

    private func addAccount() async {
        isAuthorizing = true
        errorMessage = nil
        defer { isAuthorizing = false }
        do {
            try await GoogleAccountManager.addAccount()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importClientJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the Google Desktop OAuth client JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                _ = try GoogleClientConfig.importFromJSON(data)
                appState.refreshClientConfigured()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    static let setupHelp = """
    1. Go to console.cloud.google.com → create a project named "Hall-e".
    2. APIs & Services → Library → enable "Google Calendar API".
    3. APIs & Services → OAuth consent screen → External → add your Gmail as a \
    test user (or set to In production so tokens don't expire in 7 days).
    4. Credentials → Create Credentials → OAuth client ID → Application type: \
    Desktop app → Download JSON. Import that file here.
    """
}

extension Color {
    /// Parse "#RRGGBB" (with or without leading #).
    init?(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        _ = s
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}
