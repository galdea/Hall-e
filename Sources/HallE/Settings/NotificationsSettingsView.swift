import SwiftUI
import UserNotifications
import AppKit

struct NotificationsSettingsView: View {
    @State private var enabled = AppPreferences.notificationsEnabled
    @State private var lead = AppPreferences.notificationLeadMinutes
    @State private var quietStart = AppPreferences.quietHoursStart
    @State private var quietEnd = AppPreferences.quietHoursEnd
    @State private var sound = AppPreferences.meetingReminderSound
    @State private var morningEnabled = AppPreferences.morningAgendaEnabled
    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var alertSetting: UNNotificationSetting?
    @State private var soundSetting: UNNotificationSetting?
    @State private var permissionMessage: String?
    var body: some View {
        Form {
            Section("Meeting reminders") {
                Toggle("Enable meeting notifications", isOn: $enabled).onChange(of: enabled) { _, value in
                    AppPreferences.notificationsEnabled = value
                    if value { Task { await requestPermission() } }
                    Task { await NotificationScheduler.shared.refreshReminders() }
                }
                Picker("Meeting alert", selection: $lead) {
                    ForEach([0, 1, 5, 10, 15, 30], id: \.self) { value in
                        Text(value == 0 ? "At start" : "\(value) minutes before").tag(value)
                    }
                    if ![0, 1, 5, 10, 15, 30].contains(lead) { Text("Custom · \(lead) minutes").tag(lead) }
                }.onChange(of: lead) { _, value in saveLead(value) }
                Stepper("Custom minutes: \(lead)", value: $lead, in: 0...60, step: 1)
                    .onChange(of: lead) { _, value in saveLead(value) }
                Picker("Reminder sound", selection: $sound) {
                    ForEach(MeetingReminderSound.allCases) { Text($0.title).tag($0) }
                }.onChange(of: sound) { _, value in
                    AppPreferences.meetingReminderSound = value
                    Task { await NotificationScheduler.shared.refreshReminders() }
                }
                Button("Preview sound") { sound.preview() }.disabled(sound == .silent)
                LabeledContent("System permission", value: statusText)
                LabeledContent("Alerts", value: alertStatusText)
                LabeledContent("Sound", value: soundStatusText)
                switch authorizationStatus {
                case .authorized?, .provisional?:
                    Button("Send Test Notification") { Task { await sendTestNotification() } }
                case .notDetermined?, nil:
                    Button("Allow Notifications") { Task { await requestPermission() } }
                default:
                    Text("Enable Allow Notifications for Hall-e in System Settings, then return here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Hall-e Notification Settings…") { SystemSettingsOpener.openNotificationSettings() }
                }
                if let permissionMessage { Text(permissionMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Quiet hours") {
                Picker("From", selection: $quietStart) { ForEach(0..<24) { Text(hour($0)).tag($0) } }.onChange(of: quietStart) { _, value in AppPreferences.quietHoursStart = value; Task { await NotificationScheduler.shared.refreshReminders() } }
                Picker("Until", selection: $quietEnd) { ForEach(0..<24) { Text(hour($0)).tag($0) } }.onChange(of: quietEnd) { _, value in AppPreferences.quietHoursEnd = value; Task { await NotificationScheduler.shared.refreshReminders() } }
                Text("Hall-e will not schedule alerts whose delivery time falls inside quiet hours.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Morning agenda") {
                Toggle("Send a daily agenda", isOn: $morningEnabled).onChange(of: morningEnabled) { _, value in
                    AppPreferences.morningAgendaEnabled = value
                    NotificationScheduler.shared.morningAgendaPreferenceChanged()
                    if value { Task { await NotificationScheduler.shared.requestAuthorizationIfNeeded(); await refreshStatus() } }
                }
                Text("When enabled, Hall-e sends one brief after your first mouse activity between 4:00 a.m. and noon local time. macOS Focus still applies. The alert previews a few meetings; choose Open Today for the full agenda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Actions") { Label("Join, open agenda, prepare note, and snooze are available from supported notifications.", systemImage: "bell.badge") }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("settings.notifications"))
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }
    private func refreshStatus() async {
        let previous = authorizationStatus
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        alertSetting = settings.alertSetting
        soundSetting = settings.soundSetting
        if previous != authorizationStatus,
           authorizationStatus == .authorized || authorizationStatus == .provisional {
            permissionMessage = nil
            await NotificationScheduler.shared.refreshReminders()
        }
    }
    private func saveLead(_ value: Int) {
        AppPreferences.notificationLeadMinutes = value
        Task { await NotificationScheduler.shared.refreshReminders() }
    }
    private func requestPermission() async {
        _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        await refreshStatus()
        permissionMessage = authorizationStatus == .denied ? "macOS denied access. Use the button below to enable Hall-e." : nil
    }
    private func sendTestNotification() async {
        do {
            try await NotificationScheduler.shared.sendTestNotification()
            permissionMessage = "macOS accepted the test request. Check Notification Center to confirm it appeared."
        } catch {
            permissionMessage = error.localizedDescription
        }
    }
    private var statusText: String {
        switch authorizationStatus {
        case .authorized?: "Allowed"
        case .provisional?: "Provisional"
        case .denied?: "Denied"
        case .notDetermined?: "Not requested"
        case .ephemeral?: "Temporary"
        case nil: "Checking…"
        default: "Restricted"
        }
    }
    private var alertStatusText: String {
        if alertSetting == .disabled { return "Blocked in macOS System Settings" }
        switch authorizationStatus {
        case .authorized?, .provisional?: return "Enabled in macOS"
        case .denied?: return "Blocked in macOS"
        case .notDetermined?, nil: return "Not checked yet"
        default: return "Unavailable"
        }
    }
    private var soundStatusText: String {
        if soundSetting == .disabled { return "Blocked in macOS System Settings" }
        switch authorizationStatus {
        case .authorized?, .provisional?: return "Hall-e sound: \(sound.title); macOS may mute it"
        case .denied?: return "Unavailable while notifications are blocked"
        default: return "Hall-e sound: \(sound.title)"
        }
    }
    private func hour(_ value: Int) -> String { DateComponents(calendar: .current, hour: value).date?.formatted(date: .omitted, time: .shortened) ?? "\(value):00" }
}
