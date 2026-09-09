import SwiftUI
import ServiceManagement
import AppKit

struct AdvancedSettingsView: View {
    @State private var migration = DeepgramMigrationModel()

    var body: some View {
        Form {
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
