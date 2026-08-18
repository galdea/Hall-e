import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts, calendars, notifications, obsidian, aiOrchestrator, recording, browserCalls, transcription, privacy, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: L10n.text("settings.accounts")
        case .calendars: L10n.text("settings.calendars")
        case .notifications: L10n.text("settings.notifications")
        case .obsidian: L10n.text("settings.vault")
        case .aiOrchestrator: L10n.text("settings.ai")
        case .recording: L10n.text("settings.recording")
        case .browserCalls: "Browser & Calls"
        case .transcription: L10n.text("settings.transcription")
        case .privacy: L10n.text("settings.privacy")
        case .advanced: L10n.text("settings.advanced")
        }
    }
    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"; case .calendars: "calendar"; case .notifications: "bell"
        case .obsidian: "externaldrive"; case .aiOrchestrator: "sparkles"; case .recording: "record.circle"
        case .browserCalls: "video.badge.waveform"
        case .transcription: "waveform"; case .privacy: "hand.raised"; case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = {
        guard let raw = ProcessInfo.processInfo.environment["HALLE_DEBUG_SETTINGS_TAB"] else { return .accounts }
        return SettingsSection(rawValue: raw.lowercased()) ?? .accounts
    }()
    @State private var language = AppLanguageStore.shared
    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in Label(section.title, systemImage: section.symbol).tag(section) }
                .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
        } detail: { detailView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        .frame(minWidth: 760, minHeight: 540).environment(\.locale, language.locale).id(language.language)
    }
    @ViewBuilder private var detailView: some View {
        switch selection {
        case .accounts: AccountsSettingsView()
        case .calendars: CalendarSettingsView()
        case .notifications: NotificationsSettingsView()
        case .obsidian: ObsidianSettingsView()
        case .aiOrchestrator: AISettingsView()
        case .recording: RecordingSettingsView()
        case .browserCalls: BrowserCallsSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}
