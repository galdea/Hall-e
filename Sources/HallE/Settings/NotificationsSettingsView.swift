import SwiftUI
import UserNotifications
import AppKit

struct NotificationsSettingsView: View {
    @State private var enabled = AppPreferences.notificationsEnabled
    @State private var lead = AppPreferences.notificationLeadMinutes
    @State private var quietStart = AppPreferences.quietHoursStart
    @State private var quietEnd = AppPreferences.quietHoursEnd
    @State private var sound = AppPreferences.meetingReminderSound
    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var permissionMessage: String?
    var body: some View {
        Form {
            Section("Meeting reminders") {
                Toggle("Enable meeting notifications", isOn: $enabled).onChange(of: enabled) { _, value in
                    AppPreferences.notificationsEnabled = value
                    if value { Task { await requestPermission() } }
                    Task { await NotificationScheduler.shared.refreshReminders() }
                }
                Stepper("Notify \(lead) minutes before", value: $lead, in: 0...60, step: 5).onChange(of: lead) { _, value in
                    AppPreferences.notificationLeadMinutes = value
                    Task { await NotificationScheduler.shared.refreshReminders() }
                }
                Picker("Reminder sound", selection: $sound) {
                    ForEach(MeetingReminderSound.allCases) { Text($0.title).tag($0) }
                }.onChange(of: sound) { _, value in
                    AppPreferences.meetingReminderSound = value
                    Task { await NotificationScheduler.shared.refreshReminders() }
                }
                Button("Preview sound") { sound.preview() }.disabled(sound == .silent)
                LabeledContent("System permission", value: statusText)
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
        authorizationStatus = await NotificationScheduler.shared.authorizationStatus()
    }
    private func requestPermission() async {
        authorizationStatus = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        permissionMessage = authorizationStatus == .denied ? "macOS denied access. Use the button below to enable Hall-e." : nil
    }
    private func sendTestNotification() async {
        do {
            try await NotificationScheduler.shared.sendTestNotification()
            permissionMessage = "Test notification sent."
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
    private func hour(_ value: Int) -> String { DateComponents(calendar: .current, hour: value).date?.formatted(date: .omitted, time: .shortened) ?? "\(value):00" }
}
