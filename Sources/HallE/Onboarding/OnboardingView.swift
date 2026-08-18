import SwiftUI
import AppKit
import AVFoundation
import UserNotifications

struct OnboardingView: View {
    @State private var appState = AppState.shared
    @State private var language = AppLanguageStore.shared
    @State private var step = min(AppPreferences.onboardingStep, 6)
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var notificationsGranted = false
    @State private var notificationsDenied = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    let onClose: (Bool) -> Void

    private let steps = ["Welcome", "Google", "Calendars", "Vault", "Capture", "Notifications", "Ready"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 4)
                }
            }.padding(20)
            stepContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Skip for now") { onClose(false) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == steps.count - 1 ? "Open Hall-e" : "Continue") {
                    if step == steps.count - 1 { onClose(true) } else { step += 1; AppPreferences.onboardingStep = step }
                }.buttonStyle(.borderedProminent)
            }.padding(20)
        }
        .frame(width: 680, height: 520)
        .environment(\.locale, language.locale).id(language.language)
        .task { await updateNotificationStatus() }
    }

    @ViewBuilder private var stepContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case 0:
                setupHeader("sparkles", L10n.text("onboarding.title"), L10n.text("onboarding.subtitle"))
                Picker(L10n.text("settings.language"), selection: $language.language) { ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) } }.frame(maxWidth: 320)
                Label("Calendar context stays local.", systemImage: "calendar")
                Label("Recordings and transcripts stay on this Mac by default.", systemImage: "lock.fill")
                Label("You decide what is shared with ChatGPT.", systemImage: "hand.raised.fill")
            case 1:
                setupHeader("person.crop.circle.badge.plus", "Connect Google Calendar", "Hall-e uses read-only calendar access to build your agenda.")
                statusRow(appState.accounts.isEmpty ? "No account connected" : "\(appState.accounts.count) account(s) connected", complete: !appState.accounts.isEmpty)
                Button("Open Account Settings…") { SettingsWindowController.shared.show() }
            case 2:
                setupHeader("calendar", "Choose calendars", "Keep personal or noisy calendars out of your Hall-e agenda.")
                statusRow("\(appState.calendarSources.filter(\.isSelected).count) calendars selected", complete: appState.calendarSources.contains(where: \.isSelected))
                Button("Open Calendar Settings…") { SettingsWindowController.shared.show() }
            case 3:
                setupHeader("externaldrive", "Choose your Obsidian vault", "Hall-e keeps narrative meeting notes in a folder you control.")
                statusRow(VaultAccess.isReachable() ? "Vault connected" : "No reachable vault", complete: VaultAccess.isReachable())
                Button("Choose Vault…") { if VaultAccess.chooseVault() != nil { Features.current = ObsidianFeatureHooks() } }
            case 4:
                setupHeader("waveform", "Enable capture", "Recording always starts manually and shows a visible red indicator.")
                statusRow(micGranted ? "Microphone allowed" : "Microphone access needed", complete: micGranted)
                if !micGranted && AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    Text("Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings…") { SystemSettingsOpener.openMicrophonePrivacy() }
                } else {
                    Button("Request Microphone Access") { Task { micGranted = await RecordingService.shared.requestMicAccess() } }.disabled(micGranted)
                }
                Label("System audio will be requested only when you explicitly capture a supported app.", systemImage: "speaker.wave.2")
                    .font(.caption).foregroundStyle(.secondary)
            case 5:
                setupHeader("bell", "Meeting reminders", "Receive preparation reminders with Join and Note actions.")
                statusRow(notificationsGranted ? "Notifications allowed" : "Permission not granted", complete: notificationsGranted)
                if notificationsDenied {
                    Text("Notifications were denied. Enable them in System Settings → Notifications → Hall-e.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings…") { SystemSettingsOpener.openNotificationSettings() }
                } else {
                    Button("Request Notification Permission") { Task { await NotificationScheduler.shared.requestAuthorizationIfNeeded(); await updateNotificationStatus() } }
                }
                Toggle("Launch Hall-e at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in try? LaunchAtLogin.set(value) }
            default:
                setupHeader("checkmark.circle.fill", "Hall-e is ready", "You can revisit every setup choice from Settings.")
                checklist("Google Calendar", !appState.accounts.isEmpty)
                checklist("Selected calendars", appState.calendarSources.contains(where: \.isSelected))
                checklist("Obsidian vault", VaultAccess.isReachable())
                checklist("Microphone", micGranted)
                checklist("Notifications", notificationsGranted)
            }
            Spacer()
        }.padding(.horizontal, 44).padding(.bottom, 20)
    }
    private func setupHeader(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor); Text(title).font(.largeTitle.weight(.semibold)); Text(detail).font(.title3).foregroundStyle(.secondary) }
    }
    private func statusRow(_ text: String, complete: Bool) -> some View { Label(text, systemImage: complete ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(complete ? Color.green : Color.secondary) }
    private func checklist(_ text: String, _ complete: Bool) -> some View { HStack { Image(systemName: complete ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(complete ? Color.green : Color.secondary); Text(text); Spacer(); Text(complete ? "Ready" : "Optional").foregroundStyle(.secondary) } }
    private func updateNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsGranted = status == .authorized || status == .provisional
        notificationsDenied = status == .denied
    }
}
