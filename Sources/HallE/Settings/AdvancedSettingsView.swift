import SwiftUI
import ServiceManagement
import AppKit

struct AdvancedSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var language = AppLanguageStore.shared
    @State private var migration = DeepgramMigrationModel()

    var body: some View {
        Form {
            Section(L10n.text("settings.language")) {
                Picker(L10n.text("settings.language"), selection: $language.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Button("Run setup assistant again…") { OnboardingWindowController.shared.show() }
            }
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
            DeepgramMigrationSection(model: migration)
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
        .navigationTitle(L10n.text("settings.advanced"))
    }
}
