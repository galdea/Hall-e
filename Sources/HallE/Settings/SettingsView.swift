import SwiftUI

enum SettingsGroup: String, CaseIterable, Identifiable {
    case general, meetings, capture, intelligence, storagePrivacy, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .meetings: "Meetings"
        case .capture: "Capture"
        case .intelligence: "Intelligence"
        case .storagePrivacy: "Storage & Privacy"
        case .advanced: "Advanced"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, accounts, calendars, notifications, recording, browserCalls
    case transcription, aiOrchestrator, obsidian, privacy, advanced

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .general: .general
        case .accounts, .calendars, .notifications: .meetings
        case .recording, .browserCalls: .capture
        case .transcription, .aiOrchestrator: .intelligence
        case .obsidian, .privacy: .storagePrivacy
        case .advanced: .advanced
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .calendars: "Calendar"
        case .notifications: "Reminders"
        case .recording: "Recording"
        case .browserCalls: "Calls"
        case .transcription: "Transcription"
        case .aiOrchestrator: "AI Providers"
        case .obsidian: "Vault"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .general: ["language", "setup", "preferences", "startup", "login"]
        case .accounts: ["google", "microsoft", "account", "sign in"]
        case .calendars: ["calendar", "sync", "events"]
        case .notifications: ["notifications", "reminders", "alerts", "quiet hours"]
        case .recording: ["recording", "audio", "microphone", "automatic", "silence", "countdown", "stop"]
        case .browserCalls: ["calls", "browser", "whatsapp", "meet", "zoom", "teams"]
        case .transcription: ["transcription", "speech", "deepgram", "speechmatics", "language"]
        case .aiOrchestrator: ["ai", "providers", "openai", "anthropic", "models"]
        case .obsidian: ["vault", "obsidian", "storage", "notes"]
        case .privacy: ["privacy", "cloud", "consent", "data"]
        case .advanced: ["advanced", "migration", "version", "about"]
        }
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return ([title, group.title] + searchTerms).contains {
            $0.localizedCaseInsensitiveContains(normalized)
        }
    }

    static func debugValue(_ value: String) -> SettingsSection? {
        let normalized = value.replacingOccurrences(of: "-", with: "").lowercased()
        return allCases.first {
            $0.rawValue.replacingOccurrences(of: "-", with: "").lowercased() == normalized
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = {
        guard let raw = ProcessInfo.processInfo.environment["HALLE_DEBUG_SETTINGS_TAB"] else { return .general }
        return SettingsSection.debugValue(raw) ?? .general
    }()
    @State private var searchQuery = ""
    @State private var language = AppLanguageStore.shared

    private var filteredSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.matches(searchQuery) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search settings", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                if filteredSections.isEmpty {
                    Text("No settings found").foregroundStyle(.secondary).padding()
                }
                List(selection: $selection) {
                    ForEach(SettingsGroup.allCases) { group in
                        let sections = filteredSections.filter { $0.group == group }
                        if !sections.isEmpty {
                            Section(group.title) {
                                ForEach(sections) { section in
                                    Text(section.title).tag(section)
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 560)
        .environment(\.locale, language.locale)
        .id(language.language)
        .onChange(of: searchQuery) { _, _ in
            if !filteredSections.contains(selection), let first = filteredSections.first {
                selection = first
            }
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .accounts: AccountsSettingsView()
        case .calendars: CalendarSettingsView()
        case .notifications: NotificationsSettingsView()
        case .recording: RecordingSettingsView()
        case .browserCalls: BrowserCallsSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .aiOrchestrator: AISettingsView()
        case .obsidian: ObsidianSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var language = AppLanguageStore.shared

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $language.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
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
            Section("Setup") {
                Button("Run setup assistant again…") {
                    OnboardingWindowController.shared.show()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
