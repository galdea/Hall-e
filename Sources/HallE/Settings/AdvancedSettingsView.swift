import SwiftUI
import ServiceManagement

struct AdvancedSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Hall-e at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                }
                LabeledContent("Bundle ID") {
                    Text(Bundle.main.bundleIdentifier ?? "—")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }
}
