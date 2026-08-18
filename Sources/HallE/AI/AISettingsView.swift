import SwiftUI
import AppKit

struct AISettingsView: View {
    @State private var config = LLMProviderConfig.load()
    @State private var apiKeyInput = ""
    @State private var keyIsSet = false
    @State private var revealKey = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $config.kind) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: config.kind) { _, kind in
                    if config.baseURL.isEmpty || !kind.baseURLEditable { config.baseURL = kind.defaultBaseURL }
                    if config.model.isEmpty { config.model = kind.defaultModel }
                    refreshKeyStatus()
                }

                if config.kind != .disabled {
                    TextField("Base URL", text: $config.baseURL)
                        .disabled(!config.kind.baseURLEditable)
                        .foregroundStyle(config.kind.baseURLEditable ? .primary : .secondary)
                    TextField("Model", text: $config.model)
                }
            }

            if config.kind != .disabled && config.kind.needsAPIKey {
                Section("API Key") {
                    HStack(spacing: 6) {
                        // Reveal toggle: paste works reliably in a plain TextField,
                        // and the explicit Paste button is a guaranteed path
                        // regardless of the macOS SecureField paste quirk.
                        if revealKey {
                            TextField("API key…", text: $apiKeyInput)
                        } else {
                            SecureField("API key…", text: $apiKeyInput)
                        }
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless).help(revealKey ? "Hide" : "Show")
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) { apiKeyInput = s }
                        }
                        .help("Paste from clipboard")
                        Button("Save") { saveKey() }
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                        Image(systemName: keyIsSet ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(keyIsSet ? .green : .secondary)
                        Text(keyIsSet ? "Key stored in macOS Keychain" : "No key stored")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if keyIsSet { Button("Clear") { clearKey() }.foregroundStyle(.red) }
                    }
                }
            }

            if config.kind != .disabled {
                Section("Connection") {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if testing { HStack { ProgressView().controlSize(.small); Text("Testing…") } }
                        else { Text("Test Connection") }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.caption)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Privacy") {
                Toggle("Use AI features", isOn: $config.useAI)
                Toggle("Allow cloud processing of transcripts and imported conversations",
                       isOn: $config.allowCloudTranscriptProcessing)
                    .disabled(!config.useAI)
                Toggle("Prefer local processing when available", isOn: $config.preferLocal)
                Text("Off by default. When disabled, remote providers receive project notes with raw transcript sections removed, but not imported ChatGPT, Codex, or WhatsApp conversation text. Local Ollama and LM Studio providers can use that local context without uploading it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Orchestrator")
        .onChange(of: config) { _, c in c.save() }
        .onAppear {
            migrateStaleModel()
            refreshKeyStatus()
        }
    }

    private func refreshKeyStatus() {
        // resolveAPIKey also migrates keys stored by older builds under the
        // host-derived account.
        keyIsSet = config.resolveAPIKey() != nil
    }

    /// Heal configs pointing at models Google has since retired.
    private func migrateStaleModel() {
        let retired = ["gemini-1.5-flash", "gemini-1.5-pro", "gemini-pro"]
        if config.kind == .gemini, retired.contains(config.model) {
            config.model = config.kind.defaultModel
            config.save()
        }
    }
    private func saveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore.set(trimmed, account: config.keychainAccount)
        apiKeyInput = ""
        revealKey = false
        refreshKeyStatus()
    }
    private func clearKey() {
        KeychainStore.delete(account: config.keychainAccount)
        if config.legacyKeychainAccount != config.keychainAccount {
            KeychainStore.delete(account: config.legacyKeychainAccount)
        }
        refreshKeyStatus()
    }

    private func testConnection() async {
        testing = true; testResult = nil
        defer { testing = false }
        config.save()
        let key = config.kind.needsAPIKey ? config.resolveAPIKey() : nil
        let provider = LLMProviderFactory.makeForTest(config: config, apiKey: key)
        do {
            let r = try await provider.testConnection()
            testResult = "✓ \(r.latencyMs) ms — \(r.detail)"
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}
