import SwiftUI

enum SettingsGroup: String, CaseIterable, Identifiable {
    case general, capture, meetings, intelligence, storagePrivacy, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: PublicUICopy.text("General", "General")
        case .meetings: PublicUICopy.text("Calendar (optional)", "Calendario (opcional)")
        case .capture: PublicUICopy.text("Recording & transcription", "Grabación y transcripción")
        case .intelligence: PublicUICopy.text("AI (optional)", "IA (opcional)")
        case .storagePrivacy: PublicUICopy.text("Files & privacy", "Archivos y privacidad")
        case .advanced: PublicUICopy.text("About", "Acerca de")
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, transcription, accounts, calendars, notifications, browserCalls
    case aiOrchestrator, obsidian, privacy, advanced, about

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .general: .general
        case .accounts, .calendars, .notifications: .meetings
        case .recording, .transcription, .browserCalls: .capture
        case .aiOrchestrator: .intelligence
        case .obsidian, .privacy: .storagePrivacy
        case .advanced, .about: .advanced
        }
    }

    var title: String {
        switch self {
        case .general: PublicUICopy.text("General", "General")
        case .accounts: PublicUICopy.text("Accounts", "Cuentas")
        case .calendars: PublicUICopy.text("Calendar", "Calendario")
        case .notifications: PublicUICopy.text("Reminders", "Recordatorios")
        case .recording: PublicUICopy.text("Recording", "Grabación")
        case .browserCalls: PublicUICopy.text("Calls", "Llamadas")
        case .transcription: PublicUICopy.text("Transcription", "Transcripción")
        case .aiOrchestrator: PublicUICopy.text("AI Providers", "Proveedores de IA")
        case .obsidian: PublicUICopy.text("Notes folder", "Carpeta de notas")
        case .privacy: PublicUICopy.text("Privacy", "Privacidad")
        case .advanced: PublicUICopy.text("About", "Acerca de")
        case .about: PublicUICopy.text("About & support", "Acerca de y apoyo")
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
        case .advanced, .about: ["version", "about", "github", "star", "coffee", "support", "apoyo", "café"]
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
        let section = SettingsSection.debugValue(raw) ?? .general
        return section == .advanced ? .about : section
    }()
    @State private var searchQuery = ""
    @State private var language = AppLanguageStore.shared

    private var filteredSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0 != .advanced && $0.matches(searchQuery) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField(PublicUICopy.text("Search settings", "Buscar ajustes"), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                if filteredSections.isEmpty {
                    Text(PublicUICopy.text("No settings found", "No se encontraron ajustes")).foregroundStyle(.secondary).padding()
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
        case .advanced, .about: AboutSettingsView()
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
