import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts = "Accounts"
    case calendars = "Calendars"
    case notifications = "Notifications"
    case obsidian = "Obsidian"
    case aiOrchestrator = "AI Orchestrator"
    case recording = "Recording"
    case transcription = "Transcription"
    case projectRules = "Project Rules"
    case privacy = "Privacy"
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .calendars: "calendar"
        case .notifications: "bell"
        case .obsidian: "text.document"
        case .aiOrchestrator: "brain"
        case .recording: "record.circle"
        case .transcription: "waveform"
        case .projectRules: "folder.badge.gearshape"
        case .privacy: "hand.raised"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection =
        ProcessInfo.processInfo.environment["HALLE_DEBUG_SETTINGS_TAB"]
            .flatMap(SettingsSection.init(rawValue:)) ?? .accounts

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .accounts: AccountsSettingsView()
        case .calendars: SettingsStubView(section: .calendars)
        case .notifications: SettingsStubView(section: .notifications)
        case .obsidian: ObsidianSettingsView()
        case .aiOrchestrator: AISettingsView()
        case .recording: RecordingSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .projectRules: ProjectRulesSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

/// Placeholder for sections whose feature layer hasn't landed yet.
struct SettingsStubView: View {
    let section: SettingsSection

    var body: some View {
        ContentUnavailableView {
            Label(section.rawValue, systemImage: section.symbol)
        } description: {
            Text("This section is coming in a later build phase.")
        }
        .navigationTitle(section.rawValue)
    }
}
