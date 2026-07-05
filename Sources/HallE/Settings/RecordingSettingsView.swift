import SwiftUI
import AVFoundation
import Speech

struct RecordingSettingsView: View {
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var autoPromptCalls = AppPreferences.autoPromptWhatsAppCalls

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow("Microphone", ok: micStatus == .authorized,
                              detail: statusText(micStatus.rawValue == AVAuthorizationStatus.authorized.rawValue))
                Button("Request microphone access") {
                    Task { _ = await RecordingService.shared.requestMicAccess()
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
                .disabled(micStatus == .authorized)
            }

            Section("How recording works") {
                Label("Recording is always manual", systemImage: "hand.raised.fill")
                Label("A red menu-bar icon shows while recording", systemImage: "record.circle")
                Label("Audio is saved locally, outside your vault", systemImage: "internaldrive")
                Label("Consent reminder appears before every recording", systemImage: "exclamationmark.bubble")
                Text("Recordings live in ~/Library/Application Support/Hall-e/Recordings and are linked to the meeting note via its recording_path.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("WhatsApp calls") {
                Toggle("Prompt me to record when a WhatsApp call starts", isOn: $autoPromptCalls)
                    .onChange(of: autoPromptCalls) { _, v in AppPreferences.autoPromptWhatsAppCalls = v }
                Text("You can always start one from the menu bar → “Record WhatsApp call…”. Auto-detection is best-effort: it may also prompt on a voice message (just dismiss it) and can't see WhatsApp Web. Recording a call captures your mic + WhatsApp's audio (the other party) and needs the one-time “System Audio Recording” permission; the project is chosen from the transcript afterward.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
    }

    private func permissionRow(_ name: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(name)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func statusText(_ ok: Bool) -> String { ok ? "Granted" : "Not granted" }
}
