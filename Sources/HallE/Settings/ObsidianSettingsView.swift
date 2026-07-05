import SwiftUI

struct ObsidianSettingsView: View {
    @State private var config = ObsidianVaultConfig.load()
    @State private var subfolder = ObsidianVaultConfig.load()?.subfolderName ?? "Hall-e"
    @State private var reachable = VaultAccess.isReachable()

    var body: some View {
        Form {
            Section("Vault") {
                if let config {
                    LabeledContent("Folder") {
                        Text(config.vaultPath).truncationMode(.middle).lineLimit(1)
                    }
                    LabeledContent("Vault name") {
                        Text(config.resolvedVaultName ?? "—")
                    }
                    HStack {
                        Image(systemName: reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(reachable ? .green : .orange)
                        Text(reachable ? "Vault is reachable and writable" : "Vault folder is missing or read-only")
                            .font(.callout)
                    }
                } else {
                    Text("No vault selected. Hall-e writes meeting notes into a subfolder of your Obsidian vault.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Button(config == nil ? "Choose Vault…" : "Change Vault…") {
                    if let picked = VaultAccess.chooseVault() {
                        config = picked
                        subfolder = picked.subfolderName
                        reachable = VaultAccess.isReachable()
                        Features.current = ObsidianFeatureHooks()
                    }
                }
            }

            if config != nil {
                Section("Folder structure") {
                    HStack {
                        Text("Subfolder")
                        TextField("Hall-e", text: $subfolder)
                            .onSubmit { saveSubfolder() }
                    }
                    Text("Notes go to \(subfolder)/Meetings, \(subfolder)/Projects, \(subfolder)/Daily, \(subfolder)/Inbox.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Hall-e writes non-destructively: it never overwrites your edits, only updates content between its own markers. Meeting notes, project indexes, and daily notes are created automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Obsidian")
    }

    private func saveSubfolder() {
        guard var c = config else { return }
        let trimmed = subfolder.trimmingCharacters(in: .whitespaces)
        c.subfolderName = trimmed.isEmpty ? "Hall-e" : trimmed
        c.save()
        config = c
    }
}
